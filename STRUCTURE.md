# STRUCTURE.md — Repository layout

What every top-level entry is and why it exists. The rule: a line here
earns the entry's place. If you can't write the line, the entry is a
cleanup candidate.

Counts below verified 2026-06-10 against this tree; each count cites
the command that reproduces it.

## Directories

| Entry | Purpose |
|---|---|
| `tools/` | Everything Rail-source-but-not-compiler-or-stdlib. The compiler itself lives here (`tools/compile.rail` — `wc -l` → 8,049 lines), plus 38 subdirectories cataloged in the next table, plus root-level tools: the REPL (`repl.rail`, `repl_jit.rail`), LSP (`lsp.rail`, `lsp_server.rail`), package manager driver (`pkg.rail`), HTTP demo, sandbox server, and the runtime `.s` shims listed in `SHIMS.md`. The kitchen. |
| `stdlib/` | Rail's standard library — 94 modules (`ls stdlib/*.rail \| wc -l`). Everything `import`-able. |
| `examples/` | Hand-curated `.rail` programs that demonstrate language features — 24 files (`ls examples/*.rail \| wc -l`), plus `wasm/` demo assets. |
| `tests/` | Placeholder dir; the actual test corpus is embedded in `tools/compile.rail` as `run_test` calls. See `tests/README.md`. |
| `docs/` | Current-truth documentation — `site/` (rendered docs: quickstart, stdlib, backends, JIT), design docs, and `docs/archive/` for dated retros, closed investigations, and the GitHub Linguist submission materials (`archive/linguist-pr/`). |
| `grammar/` | EBNF grammar (`rail.ebnf`) derived from `tools/compile.rail`'s parser, for grammar-constrained LLM decoding. One file. |
| `editors/` | Editor integrations (`vscode/` — TextMate grammar + language configuration). |
| `tree-sitter-rail/` | Tree-sitter grammar for syntax highlighting. `src/parser.c` is generated output, not hand-written C. |
| `jit/` | v0 JIT — lexer/parser/lowering/codegen for a Rail subset, ARM64 emitter, codebuf manager, FFI trampolines, optimization passes, per-stage tests. Used by `stdlib/jit*.rail`. |
| `notes/` | Durable technical references — bootstrap-convergence audit, v5 feasibility, x86 conformance classification, the `v5_macho_ref/` Mach-O layout bundle used by the self-hosted emitter. Dated session handoffs live in `docs/archive/` per the convention below. |
| `releases/` | One subdirectory per attested ref — 47 entries (`ls releases \| wc -l`), mostly tagged releases plus a few attested dev builds and the pinned witness-node key — holding the Ed25519 attestation JSONs + `index.json`. The signed bytes (`rail_native` + `compile.rail`) are recoverable from each git tag, so HEAD keeps only the proof. Published to `ledatic.org/releases/`. |
| `builds/` | One subdirectory per attested intermediate build — 13 entries (`ls builds \| wc -l`) — `result.json` plus, for all but one entry, its attestation; no binary. The build-time analogue of `releases/`, for non-tagged commits. |
| `selfhost/` | Self-host fixed-point attestation artifacts — 12 entries (`ls selfhost \| wc -l`) — proof that a given `rail_native` 2-pass-compiles itself byte-identically. |
| `archive/` | **Gitignored.** Local-only retention for stale artifacts moved out of the public tree. |

## tools/ subdirectories

All 38, one line each (`ls -d tools/*/`).

| Entry | Purpose |
|---|---|
| `tools/ad/` | Compile-time autodiff (`#grad`) oracle harnesses: synthesized gradients checked against an independent symbolic differentiator (`diff.rail`) and central finite differences — forward + reverse mode, through transcendentals / let-DAGs / `if` / `match`. |
| `tools/agent/` | Agentic JIT loop: problem statement → LLM-generated Rail → JIT compile → answer. |
| `tools/apps/` | Small applications — HTTP control panel, LLM call helper, brain loop. |
| `tools/attest/` | Attestation kernel: `attest.rail` + signing scripts for releases, self-host fixed points, and test runs. |
| `tools/audit/` | Read-only audit walkers (shell) that check public surfaces and service state for drift. |
| `tools/auth/` | Authenticated data structures: `authkit.rail` (Merkle membership oracle), `authdict.rail` (authenticated key→value BST). Companions to the compiler's `auth` type synthesis. |
| `tools/bench/` | Benchmark harnesses — BPE throughput, JIT fused-kernel benches, substrate hard-bench. |
| `tools/bucket/` | Checkpoint bundle + model-card emitters for published training checkpoints. |
| `tools/cortex/` | Single script (`cortex_tick.sh`). |
| `tools/cortexm/` | Cortex-M backend: `.cm` sample programs + compile drivers. |
| `tools/cortexm_rt/` | Bare-metal bringup: startup assembly + linker scripts for Cortex-M4 and RISC-V (see `SHIMS.md` §4). |
| `tools/debug/` | Single tool (`gc_probe.rail`). |
| `tools/deploy/` | Site/page generators + Cloudflare KV uploader (the daily deploy chain for `ledatic.org` dynamic pages). |
| `tools/desk/` | Quartz event-tap bridge — ObjC dylib + Rail smoke test (see `SHIMS.md` §3). |
| `tools/diagnose/` | CPU-vs-GPU divergence bisection harnesses. |
| `tools/dnra/` | DNRA — Deliberation-Native Reasoning Architecture: spec, design, implementation, falsification sets. |
| `tools/docs/` | Single tool (`gen_stdlib_ref.rail`) — stdlib reference generator. |
| `tools/domains/` | Domain plugin convention (`README.rail` prints it) + plugins: `neural_plasma/`, `s0_pcfg/`. |
| `tools/edge_cases/` | Compiler edge-case corpus — small `.rail` programs probing known-hard shapes. |
| `tools/fleet/` | Pure-Rail TCP control-plane agent example + display tooling; bind address read from runtime config so one binary deploys across hosts. |
| `tools/fuzz/` | Differential fuzzer (`diff_fuzz.rail`) + `repros/` corpus. |
| `tools/garmin/` | Garmin FIT-file decoder + workout analyzers in pure Rail. |
| `tools/labrat/` | Autonomous kernel-optimizer agent. |
| `tools/lint/` | Quirk checker + smoke runner. |
| `tools/mcp/` | MCP server exposing compile/run/test to MCP clients. |
| `tools/metal/` | Metal GPU tensor kernels — ObjC hosts, MSL sources, benches, probes (see `SHIMS.md` §2). |
| `tools/orch/` | Training-arm orchestrator: `parse_plan.rail` consumes `tools/orch/EXPERIMENT_PLAN.md`; `update_leaderboard.sh` emits `tools/orch/LEADERBOARD.md` from a local (gitignored) `runs/` directory. |
| `tools/pkg/` | Package manager internals (`pkg_resolve.rail`, `pkg_link.rail`) + `SPEC.md`. |
| `tools/plasma/` | MHD plasma simulations — Metal compute hosts, WASM renderer, beacon daemons, live viewers. |
| `tools/playground/` | Public Rail playground: sanitizer + compile server (HTTP handler). |
| `tools/railml/` | ML data/eval pipeline for Rail code generation (Python tooling + MSL kernels). |
| `tools/runtime/` | Concurrent runtime shim — C channels + pthreads behind `stdlib/concurrent.rail` (see `SHIMS.md` §6). |
| `tools/test/` | Standalone `.rail` test programs (69 entries) beyond the embedded suite. |
| `tools/tls/` | TLS 1.3 test suite — RFC 8448 traces, live cert-chain tests. |
| `tools/trace/` | Single tool (`rail_trace.rail`). |
| `tools/train/` | Training pipeline + curriculum — self-train loop, transformer LM, corpus generators (206 entries). |
| `tools/v5/` | Self-hosted toolchain: assembler, ELF + Mach-O emitters, byte-verification `.s` fixtures. |
| `tools/witness/` | Witness consensus fixtures + visualization. |

## Files

| Entry | Purpose |
|---|---|
| `README.md` | Project intro. The first thing a stranger reads. |
| `CHANGELOG.md` | Per-version release notes. Canonical — tag annotations and commit messages reference this. |
| `CLAUDE.md` | Briefing for Claude Code sessions working in this repo. Project conventions, bootstrap pattern, current test count. |
| `CONTRIBUTING.md` | How to send a patch. |
| `SECURITY.md` | Security policy + disclosure. |
| `LICENSE` | BSL 1.1. |
| `Dockerfile.safe` | Sandboxed build environment for `rail_safe` (the WASM-sandboxed variant). |
| `SHIMS.md` | Ledger of every non-Rail file (C / ObjC / asm) in the build/runtime, with the reason each must exist. 31 in-tree files, ~408 KB. Pure-Rail discipline made visible. |
| `STRUCTURE.md` | This file. |
| `rail_native` | Seed binary. 2-pass self-compile must produce byte-identical output. |
| `rail_safe` | Sandboxed Rail-to-WASM variant. `rail_safe.sha256` is its checksum. |

## Conventions enforced here

- **Dated filenames belong in archives.** If a doc has `YYYY-MM-DD` in its name, it lives in `docs/archive/` (tracked) or `archive/` (gitignored), not at the canonical surface. `notes/` keeps undated durable references only.
- **Single-file `tools/` subdirectories are intentional.** `tools/cortex/`, `tools/debug/`, `tools/docs/`, `tools/trace/` each hold exactly one tool (`ls` each to confirm). Not abandoned stubs — the tool *is* the dir's contents.
- **`archive/` (top-level) is gitignored.** Local-only retention. Files moved there leave git history.
- **`docs/archive/` is tracked.** Dated retros / handoffs / closed investigations stay browsable.

## Known cleanup candidates

These don't earn their lines yet:
- `rail_native` / `rail_safe` at root → consolidate into `bin/` with checksums for both. Tracked as a separate task (high blast-radius: every plist, script, and CI ref needs sweeping).
