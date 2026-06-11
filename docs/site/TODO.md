# TODO — known bugs and deferred work

Per the "honest backlog" discipline: what's broken, what's deferred, and why.
The runnable subset of this list is enforced by `tools/prove/prove.sh` (bug
receipts R19 and the gated tiers) — see [PROOFS.md](../../PROOFS.md).

## Known compiler bugs (each has a receipt)

- **Division inside a tail-recursive self-call argument miscompiles** (found
  2026-06-10). The self-loop fallback computes the argument with generic
  tagged codegen (`lsl/orr` tag, `sdiv`, retag) and then moves the result
  into the raw untagged loop register *without untagging*, so the loop sees
  `2*(n/2)+1` and never terminates.
  - Minimal repro (hangs): `cnt n = if n == 0 then 0 else cnt (n / 2)`
  - Live receipt: `examples/tail_calls.rail` — first two demos print
    (`0`, `500000500000`), then the gcd demo spins forever.
  - Verified workaround: hoist the division into a helper function
    (`mod_ a b = a - ((a / b) * b)`; `gcd b (mod_ a b)` prints 6, 21).
    A let-binding does NOT help; a helper call does.
  - Where to fix: the self-loop arg-emit fallback in `tools/compile.rail`
    (~lines 1919–1989 — `self_loop_emit_fallback` / `self_temps_to_regs`;
    the direct path `cg_self_arg_direct` only handles `+`, `-`, `*`).
  - No test in the 170-suite covers this today — the suite passes with the
    bug present. A fix must add one.
- **`examples/native_closures.rail` segfaults after printing correct output**
  (`10` / `15`, then SIGSEGV on exit — closure-in-closure capture corrupts
  the frame). Replayed mechanically as receipt R19. Note `run` swallows the
  child's exit code; execute the binary directly to see exit 139.
- **Typechecker phantom warnings for FFI symbols**: compiling anything that
  imports `stdlib/file.rail` prints `WARNING: 'malloc' is not defined` /
  `WARNING: 'free' is not defined` (from `stdlib/file.rail:78` / `:83`).
  Both are FFI symbols that assemble and link fine — the warning pass
  doesn't know the FFI surface. Cosmetic, but it fronts every attestation
  verify run.
- **Cross-backend "success-ish" output is a display lie in two places**:
  `./rail_native x86` prints `Binary: /tmp/rail_x86` and exits 0 even when
  `ld` failed and no binary exists (same exit-0 swallow on `cortexm` /
  `riscv32` when host tools are missing). Anything gating on backend output
  must `test -s` the artifact, never trust the `Binary:` line or the exit
  code — `prove.sh` R12 does exactly that.

## Gated receipts we want to un-gate (the tier wishlist)

`prove.sh` skips these honestly today; each needs one piece of environment
to become a default-tier receipt:

- **R13 (net)** — pure-Rail TLS 1.3 live HTTPS GET. Needs network; could
  become default-on in CI with a pinned test endpoint.
- **R14/R15 (key)** — live LLM call + self-training loop run. Need an API
  key by design; the loop's *compile* is already a fast receipt.
- **R21 (gpu)** — self-emitted JIT-fused Metal kernels. Needs Apple Silicon
  GPU; runs anywhere the repo's primary target runs, so a mac CI runner
  would un-gate it.
- **hw tier** — Cortex-M4/Apollo2 on real hardware. QEMU
  (`qemu-system-arm -M mps2-an386`) is the documented verification path;
  SWD-flash to a real board has not been attempted in any pass yet.

## Backend verification gaps

- **Linux ARM64**: cross-binutils present on the capture host; the full
  static ELF emits from this clone (89,528 bytes for hello — receipt R12).
  No on-device (Pi) execution result is captured in this repo yet.
- **Linux x86_64**: emits `.s` (60,880 bytes for hello); final link needs a
  cross libc (`ld: cannot find -lc` on macOS hosts). Not exercised
  end-to-end. See the display-lie entry above.
- **RISC-V**: emits `.s` (`/tmp/rail_rv32.s`); assemble/link need brew llvm
  + lld. QEMU execution not re-verified in the latest pass.
- **WASM**: end-to-end green where `wat2wasm` (+ optionally `wasmtime`) is
  installed — hello compiles to a 4,553-byte `.wasm` and runs. Artifacts
  land at the fixed paths `/tmp/rail_out.wat` / `/tmp/rail_out.wasm`.

## Examples with caveats in `docs/site/examples/`

- **`examples/checkpoint_roundtrip.rail`** — green in-repo (`PASS 17/17`,
  ~10 s) and listed in [examples/README.md](../../examples/README.md). The
  remaining caveat is cwd-dependence: `import` resolution requires running
  from the repo root, so it stays out of the out-of-tree doc walkthroughs.
- **`examples/string_processing.rail`** — last output line is a live `date`
  call; not pinnable as expected output.

## Documentation gaps deferred

- **Interactive playground** — out of v0 scope. Would need a WASM build of
  `rail_native` itself plus a web shell. The existing playground at
  https://ledatic.org/#playground serves a fixed corpus of WASM-compiled
  examples, not a live compiler.
- **Generated `tools/` index** — there are ~50 useful programs under
  `tools/` (`tools/repl.rail`, `tools/lsp.rail`, `tools/cortexm_rt/`,
  `tools/deploy/*`, `tools/jit/*`). None have doc pages here; v0
  prioritized `examples/`. Follow-up should auto-index `tools/*.rail`
  similarly to how `stdlib.md` is generated.
- **API stability commitments** — the stdlib reference is descriptive, not
  normative. Functions whose name starts with `_` (or whose comments mark
  them as helpers) are not part of any public contract. A separate
  `stable-api.md` should curate the actual public surface.
- **Tutorial track** — pages walk from `hello` straight to `quicksort`. No
  deliberate ramp through algebraic data types, type inference, error
  handling, or the foreign function interface.
- **Compiler internals** — there is no doc on the AST shape, how
  `compile_program` lays out the binary, or how the GC interacts with the
  bump arena. The closest existing artifact is `CHANGELOG.md` and the
  comment headers in `tools/compile.rail`.

## What this site explicitly does *not* claim

- That every stdlib function listed in `stdlib.md` is robust or documented
  well. Many have empty docstrings — that's the actual source state, not a
  generator bug.
- That every example is the "best" version of its concept. They are the
  existing programs under `examples/` that compile and run. Some teach Rail
  well; others are smoke tests that happen to live there.

## v0+1: auto-deploy shipped 2026-05-12

The site at https://ledatic.org/rail/docs/ is auto-deployed by a
post-receive hook on the bare rail repo: changes under `docs/site/` pushed
to the `next` branch rebuild HTML and upload to Cloudflare KV without
manual intervention.
