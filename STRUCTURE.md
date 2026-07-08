# STRUCTURE.md — Repository layout

What every top-level entry is and why it exists. The rule: a line here
earns the entry's place. If you can't write the line, the entry is a
cleanup candidate.

## Directories

| Entry | Purpose |
|---|---|
| `tools/` | Everything Rail-source-but-not-compiler-or-stdlib: the compiler driver (`compile.rail`), deploy generators, fleet control plane, attestation kernel, training-arm orchestrator, plasma + Metal kernels, JIT, package manager, fuzz / lint / trace foundations, test harness, third-party device shims. The kitchen. |
| `stdlib/` | Rail's standard library — 101 modules. Everything `import`-able. |
| `examples/` | Hand-curated `.rail` programs that demonstrate language features. 32 files. |
| `tests/` | Placeholder dir; the actual test corpus is inside `tools/compile.rail` as `run_test` calls. See `tests/README.md`. |
| `docs/` | Current-truth documentation — language ref, stdlib, ABI, release runbook, active design docs. Dated retros / closed investigations live in `docs/archive/`. |
| `grammar/` | EBNF grammar derived from `tools/compile.rail`'s parser, for grammar-constrained LLM decoding. One file. |
| `editors/` | Editor integrations (VS Code). |
| `tree-sitter-rail/` | Tree-sitter grammar for syntax highlighting. |
| `jit/` | v0 JIT implementation — ARM64 emitter, codebuf manager, FFI trampolines, intermediate-rep fixtures. Used by `stdlib/jit*.rail`. |
| `notes/` | Durable technical references — bootstrap-convergence audit, v5 feasibility, x86 conformance classification, and the `v5_macho_ref/` Mach-O layout bundle used by the self-hosted emitter. |
| `releases/` | One subdirectory per tagged release (47 entries) holding the Ed25519 attestation JSONs + `index.json`. The signed bytes (`rail_native` + `compile.rail`) are recoverable from each git tag, so HEAD keeps only the proof. Published to `ledatic.org/releases/`. |
| `builds/` | One subdirectory per attested intermediate build (13 entries) — `result.json` + its attestation, no binary. The build-time analogue of `releases/`, for non-tagged commits. |
| `selfhost/` | Self-host fixed-point attestation artifacts — proof that a given `rail_native` 2-pass-compiles itself byte-identically. |
| `archive/` | **Gitignored.** Local-only retention for stale artifacts moved out of the public tree. |

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
| `SHIMS.md` | Ledger of every non-Rail file (C / ObjC / asm) in the build/runtime, with the reason each must exist. 31 in-tree files, ~407 KB. Pure-Rail discipline made visible. |
| `STRUCTURE.md` | This file. |
| `docs/archive/EXPERIMENT_PLAN.md` | Pure-Rail training-arm orchestrator queue. Consumed by `tools/orch/parse_plan.rail`. |
| `docs/archive/LEADERBOARD.md` | Auto-generated from `runs/` by `tools/orch/update_leaderboard.sh`. One row per training arm. |
| `SITE_CHANGELOG.md` | Changelog for `ledatic.org` (the site, not the language). |
| `rail_native` | Seed binary. 2-pass self-compile must produce byte-identical output. |
| `rail_safe` | Sandboxed Rail-to-WASM variant + `.sha256` checksum. |

## Conventions enforced here

- **Dated filenames belong in archives.** If a doc has `YYYY-MM-DD` in its name, it lives in `docs/archive/` (tracked) or `archive/` (gitignored), not at the canonical surface.
- **Single-file `tools/` subdirectories are intentional.** `tools/fuzz/`, `tools/trace/`, `tools/docs/`, `tools/cortex/`, `tools/debug/` each hold one tool that is one file. Not abandoned stubs — the tool *is* the dir's contents.
- **`archive/` (top-level) is gitignored.** Local-only retention. Files moved there leave git history.
- **`docs/archive/` is tracked.** Dated retros / handoffs / closed investigations stay browsable.

## Known cleanup candidates

These don't earn their lines yet:
- `rail_native` / `rail_safe` at root → consolidate into `bin/` with checksums. Tracked as a separate task (high blast-radius: every plist, script, and CI ref needs sweeping).
