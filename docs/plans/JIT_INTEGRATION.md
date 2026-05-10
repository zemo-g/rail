# JIT integration plan

## State of the JIT branches (read 2026-05-09)

The Rail JIT v1 lives across four branches: `jit-frontend`, `jit-codegen`, `jit-opt`, and the consolidated `jit` branch (which has all of them merged + docs). It's substantial:

| Branch | Files |
|---|---|
| `jit-frontend` | `jit/{ir, parse, print, fixtures_ir, test_parse}.rail` + `stdlib/metal_kernel.rail` |
| `jit-codegen` | `jit/{arm64, build_trampoline.sh, codebuf, emit, ffi, ir_c, loader, test_codegen, test_enc}.rail` + `tools/jit_call.c` |
| `jit-opt` | `jit/{icache, ir_b, opt_const_fold, opt_dce, profile, test_opt}.rail` |
| `jit` (consolidated) | All of the above + `jit/{CHANGELOG, CONTINUATION, NEXT_STAGES, README, SESSION_PROMPT_*}.md` + `jit/closures.md` |

Memory: `jit_in_pure_rail.md` ("3-session parallel build, Rail-emitted ARM64 bytes execute end-to-end, branches not yet merged"); `jit_distill_integration_negligible.md` ("2.06× wall-clock on real-corpus 2,357 triples after wiring `diagnose_fast` into the harvester").

## What v1 supports

Per `jit/README.md` on the `jit` branch:

- Integer arithmetic (`add`, `sub`, `mul`, `lt`)
- Branches (`jmp`, `jz`)
- Multi-arg recursion via `op_call` (1-4 args)
- String literals + builtins (`print_str`, `str_len`, `str_eq`, `str_at`)
- Lists (`nil`, `cons`, `head`, `tail`, `is_nil`) — emit wired but exec blocked on foreign-pointer ABI
- Decimal stdout printing via `svc` syscall
- 21 opcodes total

**What it does NOT support yet:**

- Floats. No `op_fadd` / `op_fmul` etc. The forward pass of a transformer is float-heavy → JIT v1 cannot accelerate inference's tensor operations directly.
- Memory loads/stores beyond the cons-cell allocator (no float arrays, no general heap).
- Foreign function call to dylib symbols (the `tgl_*` Metal entry points).

## What v1 *can* accelerate today

Anything the bench harness does at the **integer / control-flow level**:

- The candidate-program parse/lex pre-check (a candidate that doesn't even lex shouldn't be sent to a full `./rail_native` invocation; the JIT can run a fast lexer rejection)
- The compile-rate gate in distill harvest (already wired per `jit_distill_integration_negligible.md`, 2.06×)
- Strip-grade: detecting trailing `<` artifacts before sending to the compiler (per `bench_harness_gen_source.md` + `strip_lever_validated_2026-05-04.md`)
- Argument permutation / fuzzing for `compile.rail:3974` argv-mangling repro tests

The biggest practical lever inside `lm_infer_cpu.rail` is the **per-token-loop compile-grade for re-ranked samples in N=20**. For each generated 128-char sample, the bench compiles it via shelling out to `./rail_native`. That shell-out is dominated by spawning rail_native and re-loading stdlib — milliseconds per shot. JIT can't replace the compiler, but it can replace the *gate* deciding whether a sample is worth compiling at all.

## v2 stretch: float support

For JIT to actually accelerate the transformer forward pass, it'd need:

- `op_fadd`, `op_fmul`, `op_fdiv` mapping to `fadd d0, d0, d1` etc. ARM64 has 32 d-registers; allocate v0-v9 to d8-d17 (caller-save), v10-v19 to d18-d27 (callee-save).
- Float array load/store — either pin a base pointer in x0 and emit `ldr d0, [x0, x1, lsl #3]` for index-style access, or wrap `float_arr_get`/`float_arr_set` as builtins.
- Foreign call into `tgl_*` (so JIT-emitted code can dispatch to Metal kernels). Stage 2 of the roadmap.

This is multi-day work, not the right next move.

## Concrete integration plan (today)

### Phase A — Get JIT files onto main

```
# Don't merge yet — just stage the files for inspection.
git checkout jit -- jit/
./rail_native run jit/test_codegen.rail   # 8 fixtures
./rail_native run jit/test_print.rail     # 5 print fixtures
./rail_native run jit/test_parse.rail     # 5 round-trip parse tests
./rail_native run jit/test_opt.rail       # 29 optimizer assertions
./rail_native run jit/test_enc.rail       # 17 encoder unit tests
./rail_native run jit/test_lower.rail     # 26 end-to-end source→JIT
```

If all green, the JIT v1 is healthy on this Studio. If any fail, fix the discrepancy before anything else (likely a stdlib/compile.rail change since the JIT branches forked).

### Phase B — JIT-accelerated lex pre-check

Write `tools/orch/jit_lex_check.rail`:
- IR-encoded lexer that returns `1` if input is plausibly Rail, `0` otherwise
- Used as a gate before invoking `./rail_native` for compile-grading

For bench_strip.rail's parallel-rerank, this saves a process spawn per rejected sample. With ~14% sample-pass rate (per `structural_advantage_confirmed.md`), 86% of samples die at lex anyway — a JIT-side rejection saves ~5ms × 86% × N=20 × 30 prompts ≈ 2.6 sec per bench run × ~20 ckpts = ~1 min. Modest. The bigger win is the absence of `./rail_native` warm-up jitter, which destabilises wall-clock.

### Phase C — JIT verification for compile-loss

When the trainer harvests rollouts (per `compile_loss_scaffolding.md`), each rollout is graded by compilation. JIT can pre-filter so the trainer only sends syntactically-plausible samples to `./rail_native`. Increases harvest throughput and reduces variance.

This is meaningful only after compile-loss scaffolding is wired into a trainer, which is currently deferred.

### Phase D — Decision: extend JIT to floats?

If the per-layer divergence map (see `GPU_DIVERGENCE_MAP.md`) shows that fp16 precision is fundamentally lossy on Apple Silicon, then the path forward for inference acceleration is **CPU-side JIT with float support**, not GPU. That's a multi-day extension to JIT v1. Decide after the divergence map result.

## Risk register

| Risk | Mitigation |
|---|---|
| `git checkout jit -- jit/` overwrites main accidentally if `jit/` exists already | `ls jit/` before the checkout; refuse if non-empty |
| JIT tests fail on Studio because branches forked from old `compile.rail` | Cherry-pick into a separate `wip/jit-merge` branch; rebase onto main; resolve conflicts |
| JIT lex pre-check has a false negative (rejects valid Rail) | Write a comprehensive corpus of valid samples; assert 100% pass before integrating |
| JIT v1's pthread overhead dominates lex pre-check (~50-200µs) | Stage 2a: add `call_addr` primitive to compile.rail. Memory says this is one bootstrap cycle. |

## Cost estimates

- Phase A (test JIT on main): 30 min
- Phase B (jit_lex_check + bench wiring): 2-3 hr
- Phase C (compile-loss filter): blocked on compile-loss trainer fork
- Phase D decision: 0 (just the divergence-map result)
- Phase E (JIT v2 floats): 2-3 days

## Recommended order

1. **GPU divergence map first** (`GPU_DIVERGENCE_MAP.md`). If it says "pure precision drift," we know JIT-v2-with-floats is the unlock. If it says "kernel arithmetic bug," GPU repair is the unlock and JIT v2 isn't required.
2. **JIT Phase A** in parallel (cheap, independent).
3. Then Phase B if Phase A is clean.
4. Phase D decision based on (1).
