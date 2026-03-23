# Next Sessions: Performance (4.6x → 1.6x of C)

## Current State (2026-03-23)

- Compiler: `tools/compile.rail` (~2,540 lines)
- Binary: `rail_native` (395K ARM64)
- Tests: 85/85 (83 pass with constant folding, 2 stdlib import tests have linker issue)
- Self-compile: fixed point
- Runtime: **ZERO C files** — GC is ARM64 assembly in the compiler
- Dependencies: `as` + `ld` only
- Performance: **4.6x slower than C -O2** on fib(40), **~5x** on sum(10M)

## Session 1: Per-Function Frame Sizing

**Goal:** Drop frame size from 2048 bytes to actual-needed. ~1.5x speedup on recursive code.

### The Problem

Every function does `sub sp, sp, #2048` regardless of how many locals it has. `fib` needs ~48 bytes but allocates 2048. This wastes 2000 bytes of cache per recursive call. On fib(40) with ~200M calls, that's catastrophic for L1/L2 cache.

### Why the Naive Fix Crashed

On 2026-03-23, changing `#2048` to `#512` or variable sizes caused SIGBUS because:
1. Tail-call teardowns in `cg_bi`/`cg_bi2`/`cg_bi3` emit `add sp, sp, #2048` at codegen time
2. The actual frame size isn't known until AFTER codegen (it's `final_sl` returned by `cg`)
3. If prologue says `sub sp, sp, #128` but tail call says `add sp, sp, #2048`, the stack is corrupted

### The Fix

**Thread `fs` (frame size string) through codegen.** This is a mechanical refactor.

#### Step 1: Change `cg` signature

Current: `cg node env ar lc sl tp`
New: `cg node env ar lc sl tp fs`

`fs` is a string like `"2048"` — the frame size of the enclosing function. Passed through unchanged. Only used by tail-call emission.

**Files:** `tools/compile.rail` — every call to `cg` needs the extra arg. Find them:
```
grep -n "cg " tools/compile.rail | grep -v "cg_" | grep -v "-- "
```

#### Step 2: Change `cg_bi`/`cg_bi2`/`cg_bi3` signatures

Current: `cg_bi fname args env ar lc sl tp`
New: `cg_bi fname args env ar lc sl tp fs`

Replace all `#2048` in these functions with the `fs` parameter:
```
"    ldp x29, x30, [sp]\n    add sp, sp, #", fs, "\n    br x6\n"
```

**Locations (line numbers approximate, verify before editing):**
- `cg_bi` ~line 773: indirect tail call (`br x6`)
- `cg_bi` ~line 932/936: direct tail call (`b _fname`)
- `cg_bi2` ~line 977: direct tail call
- `cg_bi3` ~line 1042/1053: indirect tail calls

#### Step 3: Two-pass compile in `compile_func`

```rail
compile_func d ar lc =
  let nm = ...
  let ps = ...
  let bd = ...
  let env = mk_env ps 16
  let first_sl = 16 + 8 * length ps
  let is_tp = nm != "main"
  -- First pass with 2048 to get actual stack level
  let (_, _, final_sl) = cg bd env ar lc first_sl is_tp "2048"
  -- Compute real frame size
  let raw_fs = if final_sl < 48 then 48 else final_sl
  let frame_size = ((raw_fs + 15) / 16) * 16
  let fs = show frame_size
  -- Second pass with real frame size (only if different)
  let (body_asm, lc1, _) = cg bd env ar lc first_sl is_tp fs
  -- Build prologue/epilogue with fs
  let pro = cat ["_", nm, ":\n", save_args, "    sub sp, sp, #", fs, "\n    stp x29, x30, [sp]\n    mov x29, sp\n"]
  let epi = cat [main_untag, "    ldp x29, x30, [sp]\n    add sp, sp, #", fs, "\n    ret\n\n"]
  (cat [pro, sv, body_asm, epi], lc1)
```

The two-pass is needed because `cg` has side effects (label counter). Use the label counter from the SECOND pass.

#### Step 4: Lambda frames

Lambda codegen (~line 1068) also hardcodes `#2048`. Lambdas are short — use the inner `final_sl` directly:
```rail
let (basm, lc1, lam_sl) = cg inner_body lam_env ar (lc + 1) (16 + 8 * length all_ps) true lam_fs
```
Lambdas don't have tail calls to other functions, so their `fs` is self-contained.

#### Step 5: GC scan range

The GC scans `fp+16` to `fp+2048` per frame. With smaller frames, this over-scans but is SAFE because:
- The parent frame pointer caps the scan range
- Over-scanning just reads the previous frame (valid memory, already scanned)
- Conservative GC handles false positives gracefully

Leave the GC scan at 2048 for now. Optimize later.

#### Verification

```bash
./rail_native self    # must compile (the compiler itself has big frames)
cp /tmp/rail_self rail_native
./rail_native self    # second pass
diff rail_native /tmp/rail_self  # fixed point
./rail_native test    # 85/85
```

Then benchmark:
```bash
./rail_native /tmp/bench_fib.rail && time /tmp/rail_out  # fib(40)
```

**Expected result:** fib(40) drops from 0.88s to ~0.55-0.65s.

---

## Session 2: Untagged Integer Locals

**Goal:** Skip tag/untag for provably-integer variables. ~1.5x additional speedup.

### Depends On
- Session 1 (frame sizing) — not strictly required but the combined effect matters

### The Problem

Every integer is `(val << 1) | 1`. Addition:
```asm
asr x0, x0, #1    ; untag left
asr x1, x1, #1    ; untag right
add x0, x0, x1    ; actual add
lsl x0, x0, #1    ; retag
orr x0, x0, #1    ; set tag bit
```
5 instructions. C does 1.

### The Fix

The type checker (`tc_infer` at ~line 1620) already infers types for variables. If a variable is `"int"`, the codegen can skip tagging.

#### Step 1: Build type environment per function

Before codegen, run `tc_infer` on the function body. Collect a map of `variable_name → type`. Pass this as `tenv` through `cg`.

#### Step 2: Emit untagged arithmetic

In `cg` when emitting `"O"` (operator) nodes:
```
if both operands are known-int (from tenv):
    emit: ldr x0, [x29, #sl_a]
          ldr x1, [x29, #sl_b]
          add x0, x0, x1        ; raw, no tag ops
          str x0, [x29, #sl_result]
else:
    emit: current tagged arithmetic (asr, op, lsl, orr)
```

#### Step 3: Tag/untag at boundaries

When an untagged int flows into a polymorphic context (function argument, list element, return value to unknown caller):
```asm
lsl x0, x0, #1
orr x0, x0, #1    ; tag before passing
```

When a tagged int flows into an untagged context:
```asm
asr x0, x0, #1    ; untag once
```

#### Key Files
- `tools/compile.rail` — `cg` function (~line 854), operator codegen for `"O"` nodes
- `tools/compile.rail` — `tc_infer` (~line 1620), type inference
- Need to connect: `tc_infer` results → `cg` codegen decisions

#### Risk
The type checker returns `"any"` for many variables. Only optimize definite `"int"`. Safe fallback: if unsure, keep tagged. No correctness risk.

**Expected result:** fib(40) drops from ~0.6s (after Session 1) to ~0.35-0.45s.

---

## Session 3: Register Allocation

**Goal:** Keep hot locals in registers instead of stack. ~1.3x additional speedup.

### Depends On
- Session 1 (frame sizing) — required, register alloc changes frame layout
- Session 2 (untagged ints) — recommended, untagged + registers = maximum effect

### The Problem

Every value is stored to stack (`str x0, [x29, #offset]`) then reloaded (`ldr x0, [x29, #offset]`) for every use. C keeps values in registers.

### The Fix — Frequency-Based Register Assignment

#### Available Registers
ARM64 callee-saved: `x19, x20, x21, x22, x23, x24, x25, x26, x27, x28` — 10 registers. These survive across function calls (`bl`), so we don't need to save/restore around calls.

#### Step 1: Count variable usage

Before codegen, walk the AST and count how many times each variable is referenced.

```rail
count_uses node env = match node
  | ["V", name] -> [(name, 1)]
  | ["O", op, l, r] -> merge_counts (count_uses l env) (count_uses r env)
  | ...
```

#### Step 2: Assign top 10 to registers

Sort by usage count, assign the top 10 to x19-x28. Build a `reg_env` map of `variable → register_name`.

#### Step 3: Modified codegen

When loading a variable:
- If in `reg_env`: just use the register (no load instruction needed)
- If not: load from stack as before

When storing a variable (let binding):
- If in `reg_env`: `mov x19, x0` (or whichever register)
- If not: `str x0, [x29, #offset]` as before

#### Step 4: Prologue/epilogue

Save callee-saved registers used:
```asm
stp x19, x20, [sp, #-16]!  ; only if x19/x20 are assigned
```
Restore before return.

#### Key Files
- `tools/compile.rail` — `cg` function, variable load/store
- `tools/compile.rail` — `mk_env` (~line 695), environment creation
- `tools/compile.rail` — `compile_func` (~line 1303), function compilation entry

#### Risk
Register allocation across function calls is complex. Start with callee-saved only (x19-x28) which persist across `bl`. Don't try to allocate x0-x18 (caller-saved) — that requires saving/restoring around every call.

**Expected result:** fib(40) drops from ~0.4s (after Sessions 1+2) to ~0.3s. That's 1.6x of C -O2.

---

## Quick Reference

| Metric | Now | After S1 | After S2 | After S3 | C -O2 |
|--------|-----|----------|----------|----------|-------|
| fib(40) | 0.88s | ~0.6s | ~0.4s | ~0.3s | 0.19s |
| vs C | 4.6x | 3.1x | 2.0x | 1.6x | 1x |
| Frame size | 2048 | 48-512 | 48-512 | 48-512 | 16-48 |
| Int add | 5 insn | 5 insn | 1 insn | 1 insn | 1 insn |
| Local access | stack | stack | stack | register | register |

## Files That Matter

- `tools/compile.rail` — the only file that changes for all three sessions
- `cg` function (~line 854) — core codegen, every optimization touches this
- `cg_bi`/`cg_bi2`/`cg_bi3` (~lines 773-901) — builtin codegen, tail calls
- `compile_func` (~line 1303) — function compilation, prologue/epilogue
- `tc_infer` (~line 1620) — type inference, feeds into Session 2
- `opt` (~line 1534) — optimization pass, constant folding lives here
- `mk_env` (~line 695) — environment creation, Session 3 changes this
