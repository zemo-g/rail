# Rail Roadmap

## v0.3.0 (complete)
- Thinking tag stripping (case-insensitive, 10 tags, unclosed handling)
- `par_prompt` with MAX_CONCURRENT: 4
- Algebraic effects: perform/handle/resume
- String interpolation, hot reload, purity analysis
- 120 tests (28 unit + 92 integration)

## v0.4.0 (complete)
- Multi-line list literals `[a,\n  b,\n  c]`
- Multi-line record literals `{ x: 1,\n  y: 2 }`
- Trailing comma support in lists, records, tuples
- Tuple destructuring in let: `let (a, b) = expr`
- Recursion depth limit (200, prevents stack overflow)
- Better parser errors with context

## v0.5.0 (complete)
- `agent_loop` builtin — multi-turn tool-use loops
- `prompt_stream` builtin — streaming LLM responses via callbacks
- `prompt_typed` builtin — structured JSON output with retry
- Conversation context: `context_new`, `context_push`, `context_prompt`

## v0.6.0 (complete)
- LSP server (`rail lsp`) — diagnostics, hover, completion, go-to-definition
- VS Code extension (editors/vscode/) — syntax highlighting + LSP client
- Formatter (`rail fmt`, `rail fmt --check`)
- Built-in test runner (`rail test`) — discovers test_ functions
- REPL improvements — :help command, history persistence (~/.rail_history)
- GitHub Actions CI — test on macOS + Linux, release binaries

## v0.7.0 — Packages (next)
- `rail.toml` dependencies (git + path)
- `rail add` / `rail install`
- Namespaced imports
- crates.io publish

## v0.8.0 — Native compiler parity (optional for v1.0)
- Strings, lists, records, ADTs in native codegen
- FFI for calling C functions

## v0.9.0 — Stability
- Fuzz testing
- Benchmarks
- Error recovery in parser (multiple diagnostics)
- Edge case hardening

## v1.0.0 — Stable release
- Syntax frozen until v2.0
- Builtins API frozen (additions OK, no removals/renames)
- 200+ tests, LSP, CI, `cargo install rail-language`
