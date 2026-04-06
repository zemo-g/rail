# Changelog

All notable changes to Rail are documented here.

## v2.0.0 (2026-04-06)

121 commits since v1.4.0. The biggest release since v1.0.

This is the version where Rail stops being just a self-hosting compiler
and becomes a self-improving system. The compiler is now the teacher in
three distinct training lineages — LLM-LoRA, Metal-GPU MLP, and
integer-PCFG — and the operational discipline to keep them honest
(intervention ledger, recovery chain, runtime overrides) is built in
pure Rail.

### Compiler & runtime
- **Native floats**: unboxed IEEE 754 doubles in ARM64 d-registers.
  Float arrays, foreign FFI (`sin`/`cos`/`sqrt`/`tanh`/`exp`/`log`/`pow`),
  auto int→float promotion, ~10× speedup vs boxed.
- **Effect handlers**: `try body handler` via setjmp/longjmp. Deep
  unwinding, nested handlers, restartable error recovery.
- **GC bootstrapped**: lower-bound check in `gc_try_mark`, 10/10 stress
  self-compiles. Self-compile fully reliable, no more intermittent
  SIGSEGV. Bootstrap via binary-patching `_rail_gc → ret`.
- **d8 callee-saved float register**: float operations inside recursive
  functions now get the fast self-loop optimization (was blocked by the
  `body_has_float` guard). Unblocked the neural plasma MLP training.
  5/5 d8_test, 7/7 float_bug_test pass.
- **FFI strdup wrap**: string-returning foreign calls now strdup-wrapped
  through the runtime. Fixed the memory bug that was holding tests at
  91/92 → 92/92 for the first time.
- **Polymorphic show**: works on int, float, string, lists (incl.
  nested), nil, and ADTs.
- **Exhaustive match**: non-exhaustive `match` is now a compile-time
  error (was a warning), with runtime trap on fallthrough.
- **Parser `in` keyword**: `let x = val in body` now works alongside
  the newline-indent style.
- **Type checker**: forward inference pass emits warnings for head/tail
  on non-list, arithmetic on non-numeric, wrong arity, calling
  non-functions.
- **Performance**: tail-recursive loops match C `-O2` (5 instructions
  per iteration). Self-loop → bottom-test, untagged register params,
  direct register arithmetic, auto-memoization, constant folding, type
  guard elimination, fused compare-and-branch.

### Backends (4 stable)
- **macOS ARM64** — primary, 92 tests, fixed point self-compile
- **Linux ARM64** (Pi Zero 2 W) — fleet display deployed
- **Linux x86_64** (WSL) — Razer training node
- **WASM** — closures via `call_indirect` + env-passing, ADT
  construction (`Some 42`, `Circle 5`), pattern matching (int / ADT
  ctor / wildcard / string), heap allocator, lists (cons/nil/head/tail/
  length), recursive functions, string ops (append/join/show/reverse),
  print fix (trailing null byte off-by-one), 7 playground demos at
  compile.ledatic.org

### Public sandbox
- **compile.ledatic.org** — public sandboxed compiler. AST whitelist,
  WASM import validation, 19-test adversarial suite, Cloudflare Tunnel.
- **ledatic.org v2.0** — main site redeployed with 6 WASM demos in
  browser (hello, fib, math, lists, ADTs, closures, string ops).
- Site scrubbed: no hardware models/specs, only capability metrics.

### Self-training flywheel
- **Hyperagent**: bench-gated training loop. 30 fixed tasks across 6
  bands. Decision logic: keep adapter only if bench improves, rollback
  otherwise.
- **DNA harvester**: 199 verified examples extracted from
  `compile.rail`, stdlib, and known-good pattern recombinations. Pure
  from birth.
- **RAILGPT bench**: 14/30 (Gemma 4 E4B + Rail adapter), 13/30
  (Qwen 4B + Rail adapter). Up from 1/30 baseline.
- **Curated training corpus**: 3.67 MB of deduped, quality-weighted
  Rail programs from 17 sources. SHA-256 dedup, 90/5/5 split.
- **Cross-arch training**: Mac Mini M4 Pro for inference + orchestration,
  Razer 3070 for CUDA QLoRA training, Pi Zero 2 W for fleet display.

### Neural Plasma Engine
- **3D Metal MHD simulator** (`tools/plasma/plasma_3d.rail`): 128³
  grid, 8 conserved variables (density, momentum, B-field, energy),
  Lax-Friedrichs scheme on Metal compute kernels. Volume raymarcher
  renders density, magnetic pressure, current sheets. 30 fps with
  orbit camera + auto-rotate.
- **Pure-Rail neural surrogate**: linear model trained on 32×32 MHD
  data with analytical backprop. Loss 4.45 → 0.03 over 500 steps,
  single-step mass conservation error 0.027%.
- **Metal GPU MLP training**: 30 → 128 → 6 MLP, 204K examples from
  64×64 MHD, full forward + backward pass on GPU using 10 custom
  Metal kernels. ~85× faster than the pure-Rail CPU version.
- **Neural renderer** (`tools/plasma/neural_renderer.rail`): runs the
  trained MLP forward pass on every cell of a 64×64 grid each frame.
  **The neural network IS the physics engine** — no PDE solver at
  runtime.
- **Stability fix**: spectral normalization + conservation drift loss
  bound the simulation to 200 stable steps. Single-step mass error
  -0.17% → -0.02% via positivity penalty. Output clamping for stable
  multi-step simulation. Residual prediction + normalization (mass
  error 168% → 0.39%).

### Empire → Rail Transplant (4 sessions, all pure Rail, zero Python)

The operational discipline patterns from the paused Empire trading
system, ported as Rail-native infrastructure for the flywheel. **All
four crown jewels shipped 2026-04-06.**

#### Session 1: Intervention Ledger
- `flywheel/interventions.jsonl` — append-only audit log
- `flywheel/interventions_tail.rail` — Rail-native viewer
- 5 hooks in `tools/train/self_train.rail`: round_end, level_advance,
  level_fallback, goal_grind, server_skip
- Helpers `kvi`, `kvs`, `log_intervention`

#### Session 2: Recovery Chain
- `flywheel/flush.rail` — pure Rail rotator. Per protected file: cp
  src→tmp, mv backup→prev, mv tmp→backup. Three guards: source-empty,
  size-shrunk, line-collapse.
- Wired into `tools/train/run_training.sh` — runs every round
- Protected files: `harvest.jsonl`, `progress.txt`,
  `interventions.jsonl`, `bench_log.txt`, `s0_state.txt`

#### Session 3: Domain Plugin Spine
- `tools/domains/` — filesystem-as-registry plugin convention. No
  dispatcher, no manifest, no registry file. The filesystem IS the
  registry.
- `tools/domains/README.rail` — convention spec
- `tools/domains/list.rail` — discovery via `find`
- `tools/domains/neural_plasma/` — first domain (state + bench, real
  d8 regression canary 2/2)
- `tools/domains/s0_pcfg/` — second domain (full 5-verb implementation)

#### Session 4: Runtime Overrides + Audit
- `flywheel/overrides.txt` — bounded tunables (pass_threshold,
  advance_threshold, fallback_threshold, retrain_threshold)
- `flywheel/override_set.rail` — CLI setter with bounds check + audit
- `load_override` helper in `self_train.rail` reads tunables every
  round, replaces hardcoded literals
- Every override write logs to `interventions.jsonl`

### s0_pcfg — second domain on the spine, compiler-as-teacher

A 23-rule probabilistic context-free grammar over Rail tokens, trained
by REINFORCE against the rail compiler. The whole "model" is 23
integer weights. **Compile-as-teacher in 720 lines of pure Rail.**

- **5 program shapes**: inline, named-binding, statement chain,
  function definition, ADT + match
- **92% lifetime strict pass rate** after 30 ticks of training
- **No gradient descent, no transformer, no GPU, no tokens**
- **Discoveries the model found that we didn't put there**:
  - Rail tolerates undefined identifiers (returns 0)
  - Named-binding program shape compiles more reliably than inline
    `print (show E)` — measurable preference, REINFORCE found it
  - Integer division by zero is silent (returns 0)
  - Real traps (missing right operand) die fast under negative reward
- **Closes the loop** via `cross_feed.rail`: translates PCFG-verified
  programs into self_train's harvest format with SHA-256 dedup. **Two
  oracles, one corpus.**
- **Continuous training**: wired into `run_training.sh` per-round hook.
  PCFG trains while LLM trains, both feed the same harvest.
- Full writeup: `docs/s0_pcfg.md` (485 lines, 4 discoveries, 4 Rail
  compiler quirks discovered while building, 6 extension paths)

### Forward regression bisector
- `flywheel/regress.rail` — pure Rail tool that reads the intervention
  ledger and reports any pass-rate drop bigger than a threshold, plus
  the suspect events (override_write, level_fallback, server_skip,
  goal_grind) that occurred in the window before the drop. Threshold
  configurable. The level 25 → 6 historical regression that motivated
  the ledger is gone (pre-ledger), so this tool runs **forward**: it
  watches for the next drop and tells you what changed.

### Stdlib
- `stdlib/file.rail` — added `append_line` helper, used by ledger
  writers and harvest collectors
- `str_find`, `str_contains`, `str_replace`, `str_split` (multi-char),
  `str_sub`, `read_line` — full string toolkit
- `arr_new`, `arr_get`, `arr_set`, `arr_len` — mutable arrays
- 38 stdlib modules total: json, http, sqlite, regex, base64, socket,
  crypto, csv, datetime, env, fs, hash, math, net, os, path, process,
  random, sort, string, test, toml, list, strbuf, fmt, file, stat,
  llm, mmap, dlopen, dirent, signal, time, url, args, autograd, map,
  tensor

### REINFORCE on Gemma LoRA — scoping plan
- `docs/reinforce-lora-plan.md` (364 lines) — half-day Razer-side
  spike to replace cross-entropy LoRA with policy-gradient on
  compile-pass reward. Same training signal that drove s0_pcfg from
  46% → 92% strict pass rate, applied to the 4B-param LLM that
  currently sits at 14/30 on the bench. 6 phases with abort criteria,
  5 risks with mitigations, honest 50% confidence on the make-or-break
  phase. **The big swing for the next session.**

### Compute fleet
- **Mac Mini M4 Pro** (24 GB) — primary inference, compilation,
  orchestration, training
- **MacBook Air M1** (8 GB) — keepawake via Tailscale
- **Razer 3070** (RTX 3070, 8 GB VRAM) — CUDA QLoRA training,
  x86_64 Rail via WSL
- **Pi Zero 2 W** (416 MB) — Rail compiler, fleet LCD display, live
  Tailscale pings

### Identity & open source
- **GitHub Linguist PR** submitted to fix Rail being detected as
  Haskell. README badge added.
- Repo public under BSL 1.1 (converts to MIT 2030-03-14)

### Numbers

| | v1.4 (2026-03-22) | v2.0 (2026-04-06) |
|---|---|---|
| Tests | 70 | 92 |
| Backends | 1 | 4 (ARM64, Linux ARM64, x86_64, WASM) |
| Stdlib modules | ~22 | 38 |
| Compiler lines | 1,979 | 3,865 |
| Self-improving lineages | 1 (LLM-LoRA) | 3 (LLM-LoRA, Metal-MLP, PCFG-REINFORCE) |
| Operational discipline | manual | full (ledger + recovery + spine + overrides + bisector) |
| Domain plugins | 0 | 2 (neural_plasma, s0_pcfg) |

### What's next
- **REINFORCE on Gemma LoRA** — see `docs/reinforce-lora-plan.md`
- **Continuous self-improvement** — `run_training.sh` already runs
  the closed loop every round (s0_pcfg tick + cross_feed)
- **Empire transplant Tier 2** — port-when-needed (multi-turn tools,
  prompt caching, kill switches)

---

## v1.4.0 (2026-03-22)

- **Garbage collector**: conservative mark-sweep GC in `runtime/gc.c`. Scans ARM64 stack frames via x29 chain, traces tagged objects, builds free list. Triggered when 1GB bump-alloc fails. Programs can now allocate well beyond 1GB total.
- **Nested lambdas**: `\a -> \b -> a + b` compiles correctly. Flattened to multi-param closures, with direct application beta-reduced at compile time.
- **Multi-capture closures**: closures capturing 2+ variables now load all captures (up to 4).
- **Exhaustiveness checking**: compiler warns on non-exhaustive ADT pattern matches, listing missing constructors.
- **70 tests** (up from 67), stable with GC + 1GB allocator.
- Compiler grown to 1,979 lines.

## v1.3.0 (2026-03-21)

- **Flywheel self-training**: 25-level curriculum, compiler-verified training data, auto-advance at 80%+ for 3 consecutive rounds.
- **MCP server**: Rail exposed as a Model Context Protocol tool server.
- **32-layer LoRA training**: targets both self-attention and Gated DeltaNet layers in Qwen3.5-4B.
- **Fleet tools**: distributed node management (`tools/fleet/`), fleet agents for ARM64 and x86_64.
- **Thinking mode**: robust response parsing for thinking-mode LLM inference in `runtime/llm.c`.
- Closure label counter fix in compiler.

## v1.2.1 (2026-03-21)

- Quality scoring layer for training data.
- v5 adapter deployed (PEFT-to-MLX converted, more data).
- Razer sparkline in fleet dashboard.

## v1.2.0 (2026-03-21)

- **`cat` builtin** for file concatenation.
- Linux cross-compiler fixes.
- Pi Zero fleet display in dashboard.

## v1.1.0 (2026-03-18 -- 2026-03-20)

- **Metal GPU backend**: Rail compiles to Apple Silicon compute shaders (`tools/gpu.rail`).
- **WASM backend**: compiles Rail to WebAssembly (`tools/wasm.rail`). Runtime WIP.
- **x86_64 backend**: sandboxed subset in `tools/x86_codegen.rail`.
- **Concurrency**: `spawn`, `channel`, `send`, `recv` for fiber-based concurrency.
- **Flywheel framework**: `flywheel/waterfall.rail` orchestrator, `flywheel/bench.rail` 30-task benchmark.
- **`#generate` directive**: compile-time AI code generation.
- **Map fusion**: `map f (map g data)` optimized to single-pass `map (f . g) data`.
- **Tree-sitter grammar** for syntax highlighting.
- **22 stdlib modules**: json, http, sqlite, regex, base64, socket, crypto, csv, datetime, env, fs, hash, math, net, os, path, process, random, sort, string, test, toml.
- Reorganized `tools/` directory structure.
- Arena mark/reset fix -- 67/67 tests stable.
- Flywheel data pipeline audit + 49-issue fix cycle.

## v1.0.0 (2026-03-17)

- **Self-hosting achieved**: Rail compiler (`tools/compile.rail`) compiles itself to ARM64. Output is byte-identical on re-compilation (fixed point).
- **Rust deleted**: 21,086 lines of Rust replaced by 1,774 lines of Rail.
- **329K seed binary**: no external dependencies beyond macOS `as` + `ld`.
- 67 tests passing.
- Pattern matching + algebraic data types.
- Tail-call optimization.
- Tagged pointer runtime (integers shifted, heap objects raw).
- 1GB bump arena allocator.
- CLI interface: `rail_native run`, `rail_native test`, `rail_native self`.
- Linux ARM64 cross-compilation support.

## Pre-1.0 (2026-03-14 -- 2026-03-16)

- ARM64 native code generation from Rail AST.
- Self-compilation achieved, then reached fixed point.
- TCO for constant-stack recursion.
- ADTs and pattern matching.
- Floats, FFI, imports, list operations.
- Async fibers, literal patterns, guards in match.
- `rail generate` -- AI code generation via local LLM.
- Channels and float FFI returns.
- GPU auto-dispatch for pure arithmetic.
- Original Rust implementation (interpreter, parser, type checker, LSP, Cranelift JIT).
