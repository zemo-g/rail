# Rail Roadmap

## v1.0.0 (current)
- Self-hosting ARM64 compiler (1,762 lines of Rail)
- Fixed-point self-compilation — compiler compiles itself to byte-identical binary
- 67 tests: arithmetic, strings, lists, tuples, ADTs, closures, TCO, FFI, floats, GPU, channels, imports
- 22 stdlib libraries (json, http, sqlite, regex, base64, socket, mmap, etc.)
- Metal GPU backend — compile Rail expressions to Metal compute shaders
- WASM backend — compile Rail to WebAssembly
- tree-sitter grammar + VS Code extension
- `#generate` directive — compile-time AI code generation via local LLM
- No dependencies beyond `as` + `ld`

## v1.1.0 — Language completeness
- Pattern matching on strings
- Multi-char `split` delimiter
- Closures over mutable bindings
- Records / named fields
- Type checker (incremental)

## v1.2.0 — Developer experience
- REPL
- Formatter (`rail fmt`)
- Better error messages with source locations
- LSP server

## v2.0.0 — Platform
- Package manager (`rail get`)
- Module system with namespaced imports
- Algebraic effects
- Linux ARM64 native (libc.s exists, needs testing)
- x86_64 backend
