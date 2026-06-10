# TODO — what's deferred for v0

Per the "honest backlog" discipline, here is what didn't make v0 and why.

## Examples not included in `docs/site/examples/` (with rationale)

- **`examples/native_closures.rail`** — segfaults in the documentation-capture environment (`/bin/sh: line 1: 70740 Segmentation fault`). Excluded until the regression is fixed; the same closure semantics are demonstrated in `examples/closures.rail` and `examples/wasm/closure.rail`.
- **`examples/tail_calls.rail`** — does 2,000,000 tail-recursive calls. Compiles and starts to run, but wall-clock exceeded the 120s timeout budgeted for the doc-capture pass. The smaller version `examples/tco_test.rail` (1M-iter count_down + 1M-iter sum_acc) is included instead and demonstrates the same property in ~30s.
- **`examples/checkpoint_roundtrip.rail`** — depends on `stdlib/checkpoint.rail`, `stdlib/tensor.rail`, `stdlib/optim.rail`. The `import` lookup path failed out-of-tree during the v0 pass; needs investigation before promoting to a doc example.

## Backend verification gaps

- **Linux ARM64**: cross-binutils (`aarch64-elf-as`, `aarch64-elf-ld`) not installed in the documentation-capture environment; `./rail_native linux ...` was documented from a known-failing run rather than a known-good binary. The path is verified via `tools/compile.rail` reading the toolchain commands directly, but no Pi Zero execution result is captured here.
- **Linux x86_64**: emits `.s` only on macOS hosts. Requires a remote `gcc` to execute. Not exercised end-to-end.
- **RISC-V**: `qemu-system-riscv32 -M virt -bios none -kernel /tmp/rail_rv32.elf` execution path didn't print/exit cleanly during the v0 pass; needs a longer monitor window. The compile path is green.
- **Cortex-M4 / Apollo2 chip**: SWD-flash to real Garmin Instinct hardware was *not* attempted in this v0 documentation pass. QEMU verification of CMSDK UART programs is documented as the verification path.

## Documentation gaps deferred

- **Interactive playground** — out of v0 scope. Would need a WASM build of `rail_native` itself plus a web shell. The existing playground at https://ledatic.org/#playground serves a fixed corpus of WASM-compiled examples, not a live compiler.
- **Generated `tools/` index** — there are ~50 useful programs under `tools/` (`tools/repl.rail`, `tools/lsp.rail`, `tools/cortexm_rt/`, `tools/deploy/*`, `tools/jit/*`). None have doc pages here; v0 prioritized `examples/`. Follow-up should auto-index `tools/*.rail` similarly to how `stdlib.md` is generated.
- **API stability commitments** — the stdlib reference is descriptive, not normative. Functions whose name starts with `_` (or whose comments mark them as helpers) are not part of any public contract. A separate `stable-api.md` should curate the actual public surface.
- **Tutorial track** — pages walk from `hello` straight to `quicksort`. No deliberate ramp through algebraic data types, type inference, error handling, or the foreign function interface.
- **Compiler internals** — there is no doc on the AST shape, how `compile_program` lays out the binary, or how the GC interacts with the bump arena. The closest existing artifact is `CHANGELOG.md` and the comment headers in `tools/compile.rail`.

## What v0 explicitly does *not* claim

- That every stdlib function listed in `stdlib.md` is robust or documented well. Many have empty docstrings — that's the actual source state, not a generator bug.
- That every example is the "best" version of its concept. They are the existing programs under `examples/` that compile and run. Some teach Rail well; others are smoke tests that happen to live there.
- That the doc site is deployed anywhere. v0 explicitly builds local files only; deploy is a separate task gated on review of these files.

## v0+1: auto-deploy shipped 2026-05-12

The site at https://ledatic.org/rail/docs/ is now auto-deployed by a post-receive hook on the bare rail repo: changes under `docs/site/` pushed to the `next` branch rebuild HTML and upload to Cloudflare KV without manual intervention.
