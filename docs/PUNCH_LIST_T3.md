# TERMINAL 3 — Ecosystem: FFI Wrappers + Tree-sitter + WASM + Package Manager

## Read first
- `~/projects/rail/stdlib/math.rail` (example FFI wrapper pattern)
- `~/projects/rail/grammar/rail.ebnf` (grammar to convert to tree-sitter)
- `~/projects/rail/tools/compile.rail` (search `compile_program` for codegen structure, `build_linux` for cross-compile pattern)

## Task 1: 17 FFI wrappers (stdlib/)
Already have: math.rail, time.rail, env.rail. Write these:

```
stdlib/sqlite.rail    — sqlite3_open, sqlite3_exec, sqlite3_close (link -lsqlite3)
stdlib/file.rail      — fopen, fread, fwrite, fclose, fseek, ftell (already in libSystem)
stdlib/regex.rail     — regcomp, regexec, regfree (POSIX regex, in libSystem)
stdlib/socket.rail    — socket, bind, listen, accept, connect, send_sock, recv_sock
stdlib/dirent.rail    — opendir, readdir, closedir
stdlib/stat.rail      — stat, fstat (file metadata)
stdlib/signal.rail    — signal handler registration
stdlib/mmap.rail      — mmap, munmap
stdlib/dlopen.rail    — dlopen, dlsym, dlclose (dynamic loading)
stdlib/json.rail      — Pure Rail JSON parser (no FFI needed, string processing)
stdlib/http.rail      — HTTP request parser + response builder (pure Rail)
stdlib/url.rail       — URL parsing (pure Rail)
stdlib/base64.rail    — Base64 encode/decode (pure Rail)
stdlib/hash.rail      — Simple hash function (pure Rail, FNV-1a or similar)
stdlib/fmt.rail       — String formatting helpers (pure Rail)
stdlib/test.rail      — Test framework: assert_eq, assert_true, run_suite
stdlib/args.rail      — CLI argument parser (pure Rail)
```

Pattern for FFI wrappers:
```rail
foreign sqlite3_open path db_ptr -> int
foreign sqlite3_exec db sql callback ctx errmsg -> int
foreign sqlite3_close db -> int
```

For pure Rail libs (json, http, base64, etc.), no FFI needed — just Rail code.

**NOTE**: sqlite requires `--link "-lsqlite3"` which isn't implemented yet. For now, document the manual ld flag. The foreign declarations + Rail wrappers still work.

## Task 2: Tree-sitter grammar
Convert `grammar/rail.ebnf` to tree-sitter format:

1. Create `tree-sitter-rail/` directory
2. Write `grammar.js` following tree-sitter conventions
3. Key rules: program, function_def, let_expr, if_expr, match_expr, lambda, list_literal, etc.
4. Test: `tree-sitter parse` on all .rail files succeeds
5. Install: `npm init && npx tree-sitter generate`

Reference: https://tree-sitter.github.io/tree-sitter/creating-parsers

## Task 3: WASM backend (Phase 11)
Add `rail_native wasm prog.rail` → .wasm binary.

WASM is stack-based (not register-based like ARM64). Key differences:
1. No registers — use WASM local variables instead
2. Memory: linear memory with bump allocator (same model)
3. Section format: `.wat` text format, assemble with `wat2wasm`
4. I/O: WASI imports (fd_write for print, proc_exit for exit)

Implementation:
1. Add `compile_program_wasm` function that emits WAT
2. Function prologue: `(func $name (param ...) (result i64) (local ...)`
3. Arithmetic: `i64.add`, `i64.sub`, `i64.mul`, `i64.div_s`
4. Tagged pointers: same scheme (lsl 1, or 1)
5. Memory: `(memory 1 256)` — 256 pages = 16MB heap
6. Entry: `(func $_start (export "_start") ... call $main ... )`
7. Build: `wat2wasm /tmp/rail_out.wat -o /tmp/rail_out.wasm`
8. Run: `wasmtime /tmp/rail_out.wasm`

```bash
brew install wabt    # provides wat2wasm
brew install wasmtime  # WASM runtime
```

Start with: `main = 42` → .wasm that exits with 42. Then add arithmetic, functions, strings.

## Task 4: Package manager (Phase 10.1)
`rail_native get <package>` downloads a .rail file from a registry.

Simplest viable:
1. Registry = a JSON file at a URL (or local `~/.rail/registry.json`)
2. `rail get sqlite` → downloads `sqlite.rail` to `~/.rail/packages/sqlite/`
3. `import "sqlite"` resolves to `~/.rail/packages/sqlite/sqlite.rail`
4. Update import resolution in `pprog` to check `~/.rail/packages/`

For now, the "registry" can just be the local `stdlib/` directory:
```
rail get math  →  cp stdlib/math.rail ~/.rail/packages/math/math.rail
```

## Exit criteria
- 20 total stdlib .rail files (3 existing + 17 new)
- tree-sitter grammar parses all .rail files
- `rail_native wasm` produces valid .wasm for simple programs
- `rail get` installs packages locally
