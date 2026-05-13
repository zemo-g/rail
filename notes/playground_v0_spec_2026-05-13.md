# Public Rail Playground — v0 spec

**Phase:** Strategic arc step 2 (developer surface).
**Date:** 2026-05-13.
**Author:** auditor.
**Status:** SPEC. Not implementation. ~500 words.

## Goal

Let someone who is **not the user** write a Rail program in a browser, compile it to WASM, run it, and see output — without installing anything, without a GitHub account, without an LLM helper. The minimum demonstration that Rail has a usable on-ramp for a stranger. Today the public surface is read-only (8 prebuilt base64 demos embedded by `tools/deploy/gen_site.rail`, plus docs at `https://ledatic.org/rail/docs/`). v0 turns the playground into a write-able surface.

## Non-goals

- **Sharing / permalinks / gists.** v1.
- **Persistence across sessions** (localStorage save is OK if free; backend persistence is not).
- **Multi-file projects, imports, package manager.** Single-file, no `import`. v2+.
- **Native (ARM64/x86) targets.** WASM only — that's the only browser-deliverable backend.
- **Server-side LLM helper / Rail tutor.** Keep the scope honest: an editor + compile button + output pane.
- **Authentication, rate-limit per user, telemetry beyond aggregate counts.** Compile load is the only resource concern.
- **Touching the 8 existing embedded demos.** They stay; the new playground links to them as starter snippets.

## User flow

1. Visitor lands on `https://ledatic.org/playground` (new page) or clicks a "Try it" button on `rail.html` and `rail/docs/`.
2. Sees a code editor (left pane) prefilled with `main = 42` or a "Hello, world" snippet, plus a sidebar of the 8 existing demos as one-click loaders.
3. Edits Rail source.
4. Clicks **Run**. Inline status: "Compiling..." → "Running..." → output.
5. Output pane (right) shows stdout (from `print` calls) plus the int exit value of `main`.
6. On compile error: parse-error message inline (Rail's `file:line:col: error: message` format).
7. On infinite loop: 5-second hard timeout; output pane says "Stopped after 5s (output above is what was emitted)."

## Architecture

Two paths considered. v0 picks **Path B** (server compile, browser run). Rationale at the end.

**Path A — pure browser (rejected for v0):** ship `rail_native` itself as a WASM binary, run the compile in the browser, then run the emitted WASM in the same browser. Pros: zero server cost. Cons: `rail_native` is 729 KB ARM64 today; no WASM self-host port exists; the emit pipeline shells out to `as` and `ld` (no analog in browser); estimated ~4-6 agent-sessions to port the emit to a pure WASM binary.

**Path B — server compile, browser run (chosen):** the Cloudflare Worker fronts a `/api/playground/compile` endpoint that POSTs the Rail source to a small compile service running on Mini (or Studio fallback). The service runs `./rail_native wasm <stdin>` in a per-request sandbox dir, returns `{ wasm_b64, error_msg, build_ms }`. The browser instantiates the returned WASM with the same WASI stub-shim used by the existing 8 demos and runs `_start`. Output captured by intercepting `fd_write` (stub today; turn into a buffer-collector). Pros: leverages today's `rail_native wasm` pipeline unchanged; build time per program ≈ 200-500 ms (same order as `build_wasm_demos.sh`); reuses `rail_wasm_abi.md` host glue.

Cons / mitigations:
- Compile service is shell-fork. Sandbox via `mktemp -d` + `ulimit -t 5 -v 524288` + reject sources >32 KB.
- Source-injection risk (Rail source is parsed, not eval'd, on the host — but `shell` and `write_file` builtins can hit the FS). Mitigation: run inside a Docker `--read-only` Linux container OR strip `shell`/`write_file`/`read_file`/`foreign` from the lexed AST before compile (preferred — pure-Rail intervention in `tools/compile.rail`).
- Cold-start latency: first request to Mini might be 2-3 s. Acceptable for v0.

## Build artifacts (what files land where)

- **Rail repo** (`~/projects/rail/`):
  - `tools/playground/compile_server.rail` — the HTTP handler binary (uses `stdlib/http_server.rail` + `tools/http_server.py` driver). Pattern: same as `tools/http_demo.rail`.
  - `tools/playground/sanitize.rail` — strip dangerous builtins from AST before compile (or fork `tools/compile.rail` into a `--playground-mode` flag).
  - `examples/playground/` — link to existing `examples/wasm/*.rail` (no new sources).
  - Memory entry update: `playground_v0.md` after ship.
- **ledatic-site repo** (`~/projects/ledatic-site/`):
  - `playground.html` — single-page editor + run button. Vanilla JS + a tiny editor (CodeMirror 6 minimal build, ~80 KB, or just a styled `<textarea>` for v0 honesty).
  - `_shared/rail_playground.js` — WASM instantiation shim (extends the existing demo runner pattern).
  - `worker/worker.js` — add `/api/playground/compile` route that proxies to Mini's compile service over Tailscale.
- **Mini deploy:** `~/projects/rail/tools/playground/compile_server.rail` compiled + run as a systemd service or just a `tmux` window for v0.

## Test plan (3 user-shippable example programs)

A non-author user must be able to ship each of these end-to-end via the playground URL alone:

1. **Echo & arithmetic.** `main = let _ = print "hi"\n  let _ = print (show (3 + 4))\n  0`. Output: `hi\n7\n`. Exit: 0.
2. **Recursive function.** `fact n = if n <= 1 then 1 else n * fact (n - 1)\nmain = let _ = print (show (fact 10))\n  0`. Output: `3628800\n`.
3. **Pattern match + ADT.** `type Option = | Some x | None\nmain = match (Some 42)\n  | Some x -> x\n  | None -> 0`. Exit: 42.

Each of these compiles cleanly in `./rail_native wasm` today. The test plan IS the acceptance criterion: paste each into the playground, click Run, verify the expected output, by an account other than the user's.

## Open questions

- **Where does the compile service actually live?** Mini is the natural fit (already runs the deploy hook + Worker token storage), but Mini's a Mac mini under desk-power. Studio is fast but is the user's primary dev box. Question: ok to add a `rail-playground` systemd-style daemon to Mini?
- **Sanitization location: AST level vs Docker container?** AST-level is cheaper to operate (no Docker daemon) but harder to prove sound. Docker is operationally heavier. Lean: AST sanitization for v0; revisit if a sandbox escape surfaces.
- **Editor:** CodeMirror, Monaco-mini, or `<textarea>` for v0? Honest answer: `<textarea>` ships fastest and is most accessible.
- **Rate limiting:** the Worker can do per-IP rate limit (10 compiles/min). Sufficient for v0 unannounced launch.
- **Output capture without WASI:** Today the emitted WASM imports `wasi_snapshot_preview1.fd_write` and the host stubs it (no-op). v0 needs to actually capture the `iovec` payload and concatenate it into a string. Not hard — ~30 lines of JS — but mentioned explicitly because the existing 8 demos don't do this (they only show `_start`'s return value).

## Estimated build size

**~3 agent-sessions:**
1. **Session A** — sanitizer + compile_server.rail + smoke test on Studio (`curl POST '{ "src": "main = 42" }'` → returns base64 wasm). ~1 session.
2. **Session B** — playground.html + JS shim + WASI fd_write capture + worker.js route. Local-only test against Studio compile_server. ~1 session.
3. **Session C** — Mini deploy + Worker integration test + end-to-end ship + test plan execution by a non-author account. ~1 session.

If sanitizer is harder than expected (the `--playground-mode` flag forks compile.rail's parser), budget 1 extra session.
