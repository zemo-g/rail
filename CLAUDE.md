# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Output Discipline

- Keep responses concise to avoid hitting the 500 output token limit; chunk long outputs across multiple turns.
- Avoid verbose explanations and large code dumps in chat — prefer bullet points and structured reports.
- When delivering reports/handoffs, or pasting prompt content/artifacts, write to a file rather than dumping inline.

## Environment

Sessions run on either the Mac Mini or the Mac Studio: confirm with `hostname` before assuming a side. Parallel session prompts labeled for other lanes (Stream 4, Session B, Mini-side) should be declined unless explicitly retargeted.

## Project Conventions

- This is a Rail-on-Rail project: write tooling and helpers in pure Rail, not Python or other languages, unless explicitly asked.
- Before assuming you're on Mini vs Studio, check `hostname` — sessions often run on Studio.

## Verification Discipline

Before declaring a hypothesis confirmed, run the falsification test (e.g., for fp16/precision claims, compare bit-identical loss across runs; for parse-pass criteria, include adversarial garbage-continuation cases). Read runtime/asm before guessing at allocator or memory-pressure causes.

## Hypothesis Discipline

- Before spending >30 min on a perf/regression hypothesis, write it down and define the falsification test.
- Read the actual runtime artifact (asm, logs, sentinel files like .no_gpu) before theorizing about exotic causes.
- When a benchmark or measurement looks like a breakthrough, suspect a measurement bug first.

## Session Resumption

- At session start, check for a handoff doc (HANDOFF.md, NEXT_SESSION.md, or recent commit messages) before exploring.
- Verify branch state with `git log --oneline -10` and `git status` before claiming what's merged — don't trust stale memory.

## Rail Compiler

Self-hosting programming language. Compiler written in Rail, compiles itself to ARM64, x86_64, and Linux ARM64.

- **Compiler source**: `tools/compile.rail` (~9,900 lines)
- **Seed binary**: `rail_native` (729K ARM64) — checked into repo, self-compile produces byte-identical output (fixed point)
- **Native floats**: unboxed IEEE 754 doubles in ARM64 d-registers wherever the compiler has proved float; boxed (tag 6) only when stored into a tuple, list or ADT field or passed generically, and read back through `_rail_fval` (docs/NUMERICS.md, 2026-09-11). Float arrays, foreign float calls (`sin`/`cos`/`tanh`/`sqrt`), auto int→float promotion.
- **REPL**: `./rail_native run tools/repl.rail` — interactive, persistent definitions
- **HTTP server**: `stdlib/http_server.rail` + `tools/http_demo.rail` — compile handler binary, serve via `tools/http_server.py`
- **Error messages**: `file:line:col: error: message` — parse errors halt cleanly instead of segfaulting.
- **Runtime**: Zero C dependencies. GC is ARM64 assembly embedded in the compiler. Only needs `as` + `ld`.
- **GC**: Conservative mark-sweep garbage collector in ARM64 assembly. Scans stack frames, marks reachable tagged objects, sweeps into free list. Triggered when 512MB arena bump-alloc fails.
- **Allocator**: 512MB bump arena + GC free list + malloc fallback. 256MB thread stack. `arena_mark`/`arena_reset` still work.
- **Effect handlers**: `try body handler` — setjmp/longjmp non-local error recovery. Deep unwinding, nested handlers.
- **Type checker**: Forward inference pass emits warnings (not errors) for: head/tail on non-list, arithmetic on non-numeric, wrong arity, calling non-functions.
- **Package manager**: `import math` (bare imports), `rail get github.com/...`, `rail pkg` reads `rail.toml`.
- **Tests**: `./rail_native test` — 203/203 on master (2026-09-11). Count fluctuates only when concurrent sessions collide on `/tmp/rail_out` — rerun with `--out-prefix` to confirm.
- **Checkpoints**: `stdlib/checkpoint.rail` — `save_checkpoint prefix weights adams step best_val` + `load_checkpoint` / in-place `load_model_into` / `load_adam_states_into`. Atomic via `<prefix>.committed` sentinel. `corpus_split text val_pct` for eval splits. `tools/train/lm_transformer.rail:run_segments` wires resume + periodic checkpoint into the training loop.
- **Performance**: Tail-recursive loops match C -O2 (5 instructions/iteration). Self-loop optimization, untagged register params, bottom-test with `subs`.
- **Targets**: macOS ARM64 (native), Linux ARM64 (Pi Zero), Linux x86_64 (cross-compile)

### Key Commands

```bash
./rail_native test                    # run the suite (203/203)
RAIL_ARENA_MB=6000 ./rail_native self # self-compile. The compiler now INLINES the pure-Rail
                                      #   Mach-O linker (tools/v5/link_lib.rail), so self_compile
                                      #   DEFAULTS to in-process rail-link (NO as/ld/codesign) when
                                      #   RAIL_ARENA_MB>=5000, else falls back to as/ld. The inlined
                                      #   source is bigger -> needs an arena (bare 1GB will thrash).
                                      #   The committed rail_native seed IS this rail-linked binary;
                                      #   it self-reproduces byte-identically (R1==R2 fixed point).
                                      #   /tmp/.rail_force_as_ld forces the as/ld path.
./rail_native run file.rail           # compile + execute
./rail_native file.rail               # compile only → /tmp/rail_out
./rail_native x86 file.rail           # compile to x86_64 Linux → /tmp/rail_x86.s
./rail_native linux file.rail         # cross-compile to Linux ARM64 → /tmp/rail_linux
./rail_native get <package>           # install package (stdlib name or github.com/user/pkg)
./rail_native pkg                     # install dependencies from rail.toml
```

### Runtime Safety

- `head []` returns 0 (not segfault). `head` on non-list returns 0.
- `tail []` returns `[]`. `tail` on non-list returns `[]`.
- Type errors on head/tail are graceful. Other type errors (arithmetic on strings, calling non-functions) may still segfault.

### Known Compiler Limitations

- **`split` is single-character**: `split "abc" s` splits on `a`, `b`, and `c` individually. Use `str_split` for multi-char delimiters.
- **Polymorphic show**: `show` works on ints, floats, strings, lists (including nested), and nil. Tuples/closures not yet supported.
- **WASM backend**: closures, ADTs, pattern matching, string ops (append/join/show/reverse) all work. 1MB memory, 7 playground demos live. Missing: filter/map/fold/chars/split as WASM builtins.
- **Exhaustive match**: Non-exhaustive `match` is a compile-time error (not warning). Runtime trap on fallthrough.
- **`read_line` zero-arg**: Use `read_line 0` (pass dummy arg) — zero-arg dispatch has a codegen quirk in the V-handler.
- **Cross-function float return inference**: Works via `__fret_` markers, but `show(user_func(1.0))` won't auto-detect float return. Use `show_float` explicitly.
- **Float self-loop TCO**: Deferred — `body_has_float` guard prevents int-TCO corruption but float-specific d8-d15 TCO not yet implemented.
- **Deeply-nested `match` chains**: A `match | ADT -> match | ADT -> ...` chain 5+ levels deep inside a function body with side-effecting `let`s after it triggers "expected decl" parse errors. **Workaround**: flatten multiple `match`es into a single chained form on one indent level — all ADT destructures at the top of the function body followed by a linear `let` stream. See `tools/train/three_class_mlp.rail:train_step` for the pattern that works.
- **Mixed float+int arithmetic (v2.1.2)**: `0.0 + int_expr` now promotes correctly even when the int operand's type can't be statically inferred. The O-handler emits a runtime `tst x, #1` path that picks scvtf or fmov based on the tag bit. Regression test: `t106 mixed_float_int_op`.

### Modifying the Compiler

Read `docs/COMPILER_BOOTSTRAP.md` before editing `tools/compile.rail`: bootstrap cycles, the diagnostic pattern, the data-section and ASCII-only traps. Always: `RAIL_ARENA_MB=6000 ./rail_native self`, then `./rail_native test` (203/203), then self again and `cmp` for the fixed point.

## Substrate beyond compile.rail (shipped 2026-05-11)

Seven foundation tools landed via parallel-v0 workflow. **Use them. Don't redo them.**

| Tool | Path | When |
|---|---|---|
| Test runner | `./rail_native run tools/test/rail_test.rail <dir>` | New tests. Convention: exit 0 AND last-line `PASS`. Exit-code-honest (relies on the 2026-05-02 fix) |
| Diff fuzzer | `./rail_native run tools/fuzz/diff_fuzz.rail --seed=42 --n=20` | Before any compile.rail change. Catches silent miscompilation via two-path differential eval. Int-only grammar today |
| Type-quirk lint | `./rail_native run tools/lint/check_quirks.rail <file>.rail` | Before merging .rail. Codes: Q001 het-list, Q002 high-arity, Q003 unwrapped float-return. For compile.rail use `RAIL_ARENA_MB=4096` (else 10min GC thrash) |
| Perf trace | `./rail_native run tools/trace/rail_trace.rail <prog>.rail [args...]` | Any perf claim. Wall/CPU/RSS/page-faults/ctxsw + JSON sidecar. v0 has no per-fn sampling |
| Channels/spawn | `bash tools/runtime/build_concurrent.sh` then `import "stdlib/concurrent.rail"` — `rc_chan_make / rc_chan_send / rc_chan_recv / rc_spawn` | Producer/consumer, parallel work. int64-only values today. Symbols `rc_*` (Rail) / `rcon_*` (C) to avoid colliding with compiler-internal `_rail_spawn` |
| Pkg manifest | `tools/pkg/` — `pkg_resolve.rail`, `pkg_link.rail`, INI manifest `rail.toml` | Multi-package projects. Local-path deps only in v0. Spec in `tools/pkg/SPEC.md` |
| Stdlib docs | `./rail_native run tools/docs/gen_stdlib_ref.rail` | After any stdlib edit, regen `docs/site/stdlib.md` |

Public docs: **https://ledatic.org/rail/docs/** — md→html build + deploy recipe in memory entry `docs_deploy_rail.md`.

### Recent emit-class gotchas surfaced by foundations work

- **Phantom builtins** in `compile.rail:~2233` `str_returning_builtin` list: `trim`, `str_to_int`. Declared but no codegen → `ld` undefined symbol at link. Inline a helper or extend emit.
- **`to_int "42"` silently returns 0** — `to_int` is float→int only. There is no string-to-int builtin. Write a digit-walking helper inline.
- **3-movk codegen** (FIXED 2026-05-12, `feat/c-3-movk-literals`): `emit_load_int` at `compile.rail:829` now emits movz + up to 3 movk chunks (bits 0-15, 16-31, 32-47, 48-63), with zero chunks at >=#32 skipped. Both positive (`movz`+`movk`) and negative (`movn`+`movk` with inverted bits) paths handle the full 64-bit range. Regression tests: t132 (3-movk), t133 (4-movk), t134 (4-movk negative). Note: `k16/k32/k48` constants computed via `shl 1 N` so `opt` constant-folding doesn't bake them as 64-bit literals the seed can't emit.
- **Stale FFI dylib at link time** (FIXED 2026-05-16): when ld errors point to an unrelated Rail function (e.g. `_mul_acc in rail_build_XXXXXX.o` referenced from when the real undefined symbol is `_tgl_matmul_bf16`), the "referenced from" is the nearest preceding label, not the actual call site. Root cause is usually a stale `tools/metal/libtensor_gpu.dylib` (or sibling) that lacks symbols added to the `.m`/`.c` source since last rebuild. `compile.rail`'s `ensure_fresh_dylib` helper now auto-rebuilds when source mtime exceeds dylib mtime; manual rebuild scripts live at `tools/metal/build_tensor_gpu.sh`, `tools/runtime/build_concurrent.sh`, `tools/desk/build_quartz_bridge.sh`, `jit/build_trampoline.sh`. All four dylibs are gitignored (per-machine artifacts).

## Related repos

Rail is the compiler + stdlib. A few things that used to live here moved out on 2026-04-20:

- **Training infrastructure** → [`Ledatic-Empire/rail-training`](https://github.com/Ledatic-Empire/rail-training) (private). Flywheel orchestrator, dataset pipeline, model cards, small corpora. Weights kept on disk, not in git. Depends on `rail_native` + stdlib from this repo.
- **Website source** → [`Ledatic-Empire/ledatic-site`](https://github.com/Ledatic-Empire/ledatic-site) (public). Hand-rolled HTML/CSS/JS/GLSL for ledatic.org, plus the Cloudflare Worker. Dynamic pages (mission control, changelog, plasma landing) still generated from `tools/deploy/gen_*.rail` here.
- **UAV / AIGP** → [`Ledatic-Empire/zemog`](https://github.com/Ledatic-Empire/zemog) (private). Nested at `tools/uav/` in the working tree (gitignored).

## Self-training (in tree)

`tools/train/self_train.rail` is a compiler-verified self-training loop: an LLM generates Rail, `rail_native` compiles it, passes get harvested. 25 levels, auto-advances at 80%+ for 3 rounds, falls back on 2 zero rounds. `stdlib/llm.rail` + `stdlib/anthropic_client.rail` + `stdlib/mlx_client.rail` provide the LLM clients over pure-Rail TLS.

Runners and data live in `Ledatic-Empire/rail-training`; the library code that makes them possible lives here (`stdlib/autograd.rail`, `stdlib/transformer.rail`, `stdlib/optim.rail`, `stdlib/checkpoint.rail`, `stdlib/bpe.rail`, `stdlib/tokenizer.rail`).

## Site generation (dynamic pages)

```bash
./rail_native run tools/deploy/gen_mission_control.rail    # /system mission control
./rail_native run tools/deploy/gen_changelog.rail          # /changelog
./rail_native run tools/deploy/gen_feed.rail               # Atom feed
./rail_native run tools/deploy/gen_plasma_landing.rail     # /plasma
./rail_native run tools/deploy/daily_deploy.rail           # cron orchestrator
```

Pure-static pages live in `Ledatic-Empire/ledatic-site` and deploy with a shell script there.

## Cross-compile (Linux ARM64 for Pi Zero / similar)

```bash
./rail_native linux tools/compile.rail && scp /tmp/rail_linux <host>:~/rail_native
```

Runtime libs live at `tools/linux_libc.s` and `tools/linux_data.s`.
