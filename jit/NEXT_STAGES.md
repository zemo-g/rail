# Rail JIT — staged roadmap beyond v1

v1 (this branch) covers integer arithmetic, integer recursion, branches, and decimal-stdout printing — the substrate needed for the model training session's Option-1 sandbox and the `print (show n)` form for ~10/30 bench prompts. Below is the staged plan to widen coverage and close the architectural gaps.

---

## Stage 2 — Direct call (escape pthread overhead)

**Motivation.** v1's `call_jit` spawns a `pthread` per invocation (~50–200 µs on Apple Silicon). For RLVR rollouts that call the JIT once per program, this is fine. For:

* Loops invoking the JIT many times per rollout
* Sub-ms gradient-coupled verification claims
* High-throughput distill harness over 2,500 candidates

…the pthread spawn dominates. Direct-call would be ~ns.

**Approach.** Two equally clean paths:

* **(2a) `compile.rail` primitive.** Add `foreign call_addr addr arg -> int` whose emit pattern is `blr x0` after argument shuffling. ~30 lines of `compile.rail`, one bootstrap cycle (per CLAUDE.md cycle table — source-only logic). Then `call_jit page arg` becomes a direct `call_addr page arg`, no thread.
* **(2b) Inline-asm trampoline via existing `foreign`.** Build a tiny `jit/libjit_trampoline.dylib` with a `void *jit_trampoline(void *(*fn)(void *), void *arg)` wrapper. `dlopen` + `dlsym` once, cache, invoke. Avoids the compiler edit; costs one `.dylib` file checked in.

**Recommendation:** (2a). The compiler edit is small, makes the JIT first-class in Rail, and unblocks any future runtime that needs indirect call (plugin systems, hot-reload, future strings/lists).

**Blast radius.** (2a) touches `compile.rail` (one bootstrap cycle, must verify byte-identical fixed point). (2b) is purely additive — new file in `jit/`, no compiler changes.

**Expected lift.** `call_jit` overhead → ~ns. Gradient-coupled rollouts at ~1 µs per program become realistic. Dwarfs all other costs in the inner loop.

---

## Stage 3 — Lowering harness (Rail source → IR)

**Motivation.** Today, IR is hand-built per fixture. To use the JIT as a bench filter or distill verifier, we need: take a Rail source string from the model, parse it, attempt to lower to IR, run if successful. Failed lowering = punt to slow `./rail_native` grade.

**Approach.** Stand on `tools/compile.rail`'s parser. Walk the Rail AST; for each construct:

| Rail construct                         | Maps to                                |
| -------------------------------------- | -------------------------------------- |
| `let x = expr in body`                 | SSA-lite vreg allocation               |
| Integer literal                        | `op_const`                             |
| `+`, `-`, `*`                          | `op_add` / `op_sub` / `op_mul`         |
| `<`                                    | `op_lt`                                |
| `if cond then a else b`                | `op_jz` + two blocks                   |
| Named function call `f(x)`             | `op_call` (resolve `f` to fn_idx)      |
| `print (show n)` (n : int)             | `op_print_int n`                       |
| Anything else (strings, lists, ADTs)   | **fail**: bail out, fallback to shell  |

Output: a Rail list of `make_fn`-built functions for `emit_program`, or a "cannot lower" tag.

**Approach concretely.**

```
lower : RailAst -> Maybe (List FnStruct)
lower_main : RailMainBody -> Maybe FnStruct
lower_expr : RailExpr -> RegEnv -> (IR, vreg)
```

**Blast radius.** New file `jit/lower.rail` (~400–600 lines). Reads from the Rail AST exposed by `tools/compile.rail`. Doesn't modify the compiler — only consumes its parse tree.

**Expected lift.** Bench filter for distillation: for the 4–10/30 bench prompts that lower cleanly, JIT-grade in-process at sub-ms. Saves ~100 ms × 33% × N rollouts during distill.

---

## Stage 4 — Strings + `print_str`

**Motivation.** ~5/30 of bench prompts (the `comprehend` band) use strings beyond `print (show n)`. To grade those without shelling out, the JIT needs strings.

**Approach.** Bytewise-only for v1 (no encoding, no length-prefix beyond an int header):

* `op_alloc_str cap` — `vDst := mmap'd RW string buffer of capacity cap`
* `op_set_byte buf idx val` — `buf[idx] = val`
* `op_str_len buf` — return `int`
* `op_print_str buf len` — `write(1, buf, len)`
* `op_concat dst a b` — copy `a` then `b` into `dst`

Backing memory: stack-allocated for short, mmap'd for longer. Copy semantics, no GC.

**Blast radius.** Adds 5 opcodes + a string-buffer descriptor. ~150 bytes per opcode emit. Doesn't break v1; pure addition.

**Expected lift.** ~5/30 → ~15/30 bench coverage when combined with Stage 3 lowering for string operations.

---

## Stage 5 — Lists + `match` + ADT (PARTIALLY SHIPPED 2026-05-06)

**Status:** `op_nil/cons/head/tail/is_nil` + list literals + heap allocator
all WORK end-to-end. Verified via `len [1,2,3,4,5]` (recursive list
traversal, returns 5), `sum [10,20,30]` (head + recurse, returns 60).

**Two key insights from the unblock:**

1. Rail represents pointers from `foreign` returns (e.g., `alloc_pages`)
   as `(real_address >> 1)`. The foreign-call boundary multiplies by 2
   (`shl 1`) when passing args to C. Verified: pass `p` via `call_jit`'s
   arg, JIT receives `x0 = (p << 1) = real_address`.

2. Heap setup is "pass heap as pthread arg + capture in x27 in prologue."
   `mov x27, x0` is the first useful instruction after frame setup.
   `op_cons` reads the bump pointer via `ldr x21, [x27, #0]`.

3. The bump pointer stored at `heap[0..7]` must be the REAL address
   (not the Rail handle). `heap_alloc` does `shl p 1` before storing
   the initial bump value (= real_addr | 8).

**Still pending under Stage 5:**

- `match` syntax + lowering (parser extension; ADT dispatch via op_is_nil + op_jz pattern is doable today via if/then/else, but the surface syntax would be cleaner).
- Closures (`\x -> body`) — needs heap-allocated closure record + indirect call. Substantial.
- File I/O — needs more `foreign` bindings (open/read/write).

**Motivation.** The remaining bench bands (`io`, `tools`, `adv`) use lists, `fold`/`map`/`filter`, ADT match, closures. Most of the bench depends on these.

**Approach.** Lists as cons-cells (head + tail pair). Heap allocation. Eventually: GC integration with rail_native's existing arena. ADT match → tag-dispatch via `op_match` opcode.

**Blast radius.** Substantial. Probably ~2–3 PRs:

1. `op_cons` + `op_head` + `op_tail` + `op_nil`. Heap-allocated pairs in mmap'd region.
2. `op_match` for tagged-union dispatch + ADT layout convention.
3. Closures: `op_make_closure` + `op_call_closure`. Boxed env.

**Expected lift.** Full bench coverage (modulo file I/O, which probably stays slow-path forever).

---

## Stage 6 (parallel) — Lowering verifier

**Motivation.** Even with Stages 3-5, some Rail programs will be subtly wrong in IR (e.g., we lowered `+` but the model emitted float arithmetic). Need a verifier: for the subset that lowers, compare JIT output to `./rail_native` output on the same inputs. Mismatch = bug in lowering.

**Approach.** Tiny harness:

```
for each lowerable bench prompt P:
  for each test input I:
    jit_out = run_jit (lower P) I
    rail_out = shell_grade P I
    assert jit_out == rail_out
```

**Blast radius.** Pure additive harness. Catches lowering bugs before they leak into training rewards.

---

## Sequencing recommendation

Path of leverage-per-hour for the Spur sprint, given the training session's bench categorization:

1. **(now, this PR)** v1: `op_call` + `op_print_int` → 10/30 reachable + recursion sandbox.
2. **Stage 3 (lowering harness)** → JIT participates in distill at all. Without this, the JIT is a hand-written-IR-only demo.
3. **Stage 2 (direct call)** → make sub-ms claims true. Compiler edit, one bootstrap cycle.
4. **Stage 4 (strings)** → unlocks comprehend band beyond integer-print form.
5. **Stage 5 (lists/ADT)** → full bench coverage, long-tail.
6. **Stage 6 (verifier)** runs alongside Stages 3–5 to catch regressions.

Stage 3 is the highest-leverage "unlock" because it's what connects the JIT to the actual model training distribution. Stage 2 is a performance lever — important, but you can train on the slower path while it's missing.

---

## Out of scope (deferred indefinitely)

* **Just-In-Time *re*compilation** — for now we always emit fresh, no profile-guided recompile. The profiler/icache scaffolding from Session B is in place but unused.
* **GC integration** — `rail_native`'s conservative mark-sweep scans Rail-tagged stack frames. JIT pages are outside that scan. For v1 this means JIT-allocated lists would leak. Lists therefore require GC integration before they're sound.
* **Cross-platform** — ARM64 macOS only. x86_64 / Linux ARM64 backends are large additional efforts and not on the critical path for the Spur model training.
* **Float arithmetic** — not in any current bench prompts. Add when needed.
