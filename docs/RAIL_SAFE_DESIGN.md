# rail-safe: Sandboxed Rail-to-WASM Compiler

**Status**: DESIGN v2 — security review incorporated
**Date**: 2026-04-04
**Security review**: 8.5/10 — four high-severity gaps identified and addressed below

---

## Purpose

A hardened, minimal Rail compiler binary that accepts untrusted source code and produces sandboxed WASM output. Designed to be exposed publicly — via HTTP, embedded in a website, or as part of an on-chain verification pipeline.

The invariant: **no input, no matter how crafted, can affect the host system.**

---

## Security Model

### Principle: Whitelist, Not Blacklist

Do NOT strip dangerous builtins from the full compiler. Instead, build a new parser that only accepts a defined safe subset. If it's not on the whitelist, it doesn't parse.

### Safe Language Subset

**Allowed:**
- Integer literals, float literals, string literals, boolean literals
- Arithmetic: `+`, `-`, `*`, `/`, `%`
- Comparison: `==`, `!=`, `<`, `>`, `<=`, `>=`
- Logic: `if/then/else`
- Functions: named functions, recursion, tail calls
- Let bindings: `let x = expr`
- Pattern matching: `match expr | Pat -> body`
- ADTs: `type T = | A x | B y z`
- Lists: `[1,2,3]`, `cons`, `head`, `tail`, `length`, `append`, `reverse`, `map`, `filter`, `fold`
- Strings: string literals, `join`, `split`, `chars`, `show`, `append`
- Lambdas: `\x -> body`
- Pipe: `x |> f`
- Tuples: `(a, b)`, destructuring
- Print: `print` (maps to WASM fd_write — console only)

**Banned (not parsed, not compiled, not reachable):**
- `shell` — arbitrary command execution
- `read_file` / `write_file` — filesystem access
- `import` — loads arbitrary files from disk
- `ffi` / `foreign` — calls arbitrary C functions
- `spawn` / `thread` — process/thread creation
- `arena_mark` / `arena_reset` — runtime internals
- `error` / `try` — could be allowed later, but keep surface minimal at launch
- Any identifier starting with `_rail` — runtime internals

### Compilation Limits

| Limit | Value | Rationale |
|-------|-------|-----------|
| Max source size | 64 KB | Prevents memory exhaustion during parsing |
| Max compile time | 5 seconds | SIGALRM kills runaway compilation |
| Max AST depth | 500 | Prevents stack overflow in recursive descent |
| Max functions | 100 | Bounds codegen output size |
| Max output WASM | 256 KB | Prevents abuse as data exfiltration channel |

### WASM Output Constraints

The generated WASM module may only import:
- `wasi_snapshot_preview1.fd_write` — write to stdout (console output)
- `wasi_snapshot_preview1.proc_exit` — exit with code

No filesystem, no network, no clock, no random. The browser's WASM sandbox enforces this — we also enforce it at the compiler level by never emitting other imports.

---

## Architecture

### Not a Fork

`rail-safe` is NOT a copy of `compile.rail` with deletions. It is a **build configuration** of the same compiler. One source, two build modes.

```
compile.rail
  ├── parse (shared)
  │     └── safe_check(node) — rejects banned constructs
  ├── codegen
  │     ├── ARM64 (full only)
  │     ├── x86_64 (full only)
  │     ├── Linux (full only)
  │     └── WASM (shared — both full and safe)
  └── entry points
        ├── full: compile_program, self_compile, run_tests
        └── safe: compile_safe(src) → WAT string
```

### The Safe Check

**Principle: poison the name, not the call site.**

After parsing, before codegen, walk the ENTIRE AST and reject any node where a banned identifier appears — as a callee, a value, a binding, inside a lambda, inside a match arm, anywhere. A banned name is poison. If it exists in the AST, compilation fails.

```rail
-- Full AST traversal. Every node kind. Every child.
safe_check node =
  let tg = head node
  if tg == "V" then
    let nm = head (tail node)
    if is_banned nm then 1 else 0
  else if tg == "A" then
    let (fname, fargs) = flat node
    if is_banned fname then 1
    else safe_check_list (tail node)
  else if tg == "D" then
    let nm = head (tail node)
    if is_banned nm then 1
    else safe_check (head (tail (tail node))) + safe_check (head (tail (tail (tail node))))
  else if tg == "F" then
    safe_check (head (tail (tail node)))
  else if tg == "M" then
    safe_check (head (tail node)) + safe_check_arms (head (tail (tail node)))
  else if tg == "O" then
    safe_check (head (tail (tail node))) + safe_check (head (tail (tail (tail node))))
  else if tg == "?" then
    safe_check (head (tail node)) + safe_check (head (tail (tail node))) + safe_check (head (tail (tail (tail node))))
  else if tg == "L" then safe_check_list (head (tail node))
  else if tg == "TD" then
    safe_check (head (tail (tail node))) + safe_check (head (tail (tail (tail node))))
  else 0  -- I, S, B, FL, NULL are safe literals

is_banned name =
  name == "shell" || name == "read_file" || name == "write_file" ||
  name == "import" || name == "spawn" || name == "thread" ||
  name == "arena_mark" || name == "arena_reset" ||
  name == "error" || name == "ffi" ||
  str_starts_with "_rail" name
```

This catches:
- `shell "ls"` — banned at call site
- `let f = shell in f "ls"` — banned at value position (V node)
- `\x -> shell x` — banned inside lambda body
- `match x | _ -> shell "ls"` — banned inside match arm

No value-flow analysis needed. The name itself is forbidden everywhere.

### Binary Separation

Two binaries from one source:
- `rail_native` — full compiler (current, unchanged)
- `rail_safe` — compiled with a flag that excludes native backends and enables safe_check

The flag is a compile-time constant checked in `compile_program`:
```rail
compile_program src =
  let toks = tokenize src
  let decls = pprog toks
  if SAFE_MODE then
    let errs = safe_check_decls decls
    if errs > 0 then ""
    else wasm_program decls
  else
    -- full compilation (current behavior)
```

### WASM Output Validation (Gap C fix)

After codegen, before returning the WASM to the caller, validate the output:

1. Run `wasm-validate` (from wabt) on the output
2. Parse the import section and assert it contains ONLY:
   - `wasi_snapshot_preview1.fd_write(i32, i32, i32, i32) -> i32`
   - `wasi_snapshot_preview1.proc_exit(i32)`
3. If any unexpected import exists, reject the output. Fail closed.

This is defense-in-depth. Even if a codegen bug emits a dangerous import, the validator catches it before the WASM reaches the client.

### Compiler Self-Integrity (Gap D fix)

The `rail_safe` build process includes:

1. Compile `compile_safe.rail` → `rail_safe` binary
2. Run the full adversarial test suite against the new binary
3. If ANY banned-construct test passes when it should fail, the BUILD FAILS
4. Emit SHA-256 of the `rail_safe` binary to `rail_safe.sha256`

Clients and on-chain verifiers can check the binary hash. Any change to the compiler that weakens the sandbox is caught at build time.

### Arena Size

`rail_safe` uses 32MB arena (not 512MB). It only compiles small programs. This makes it lightweight enough to run alongside anything.

---

## HTTP Interface

### Endpoint

```
POST /compile
Content-Type: text/plain
Body: <Rail source code>

Response 200:
Content-Type: application/wasm
Body: <compiled .wasm bytes>

Response 400:
Content-Type: application/json
Body: {"error": "banned: shell", "line": 3}

Response 413:
Body: {"error": "source too large (max 64KB)"}

Response 408:
Body: {"error": "compilation timeout (5s)"}
```

### Server

Written in Rail using `stdlib/http_server.rail`. Hardened per security review:

**Request handling:**
1. Rate limit: 10 compiles per IP per minute, 100 per hour (tracked in-memory)
2. Check Content-Length ≤ 64KB before reading body
3. Read POST body
4. Fork child process:
   - Child drops privileges to dedicated `rail-sandbox` user
   - Child sets SIGALRM(5s) timeout
   - Child compiles source → WASM via `rail_safe`
   - Child validates WASM imports (fd_write + proc_exit only)
   - Child writes result to pipe, exits
5. Parent reads pipe, returns 200 (wasm) or 400 (error) to client

**Deployment isolation:**
- Server runs inside a container (Docker + seccomp profile limiting syscalls)
- Dedicated non-root user for both server and compilation
- No network access from child (compilation is pure computation)
- Structured logging: source hash, outcome, compile time, WASM hash for every request
- Alert on any compile hitting time or memory limits

**Error responses:**
- Sanitized: `"banned construct on line N"` — no AST dumps, no internal state
- No source echo in error responses

---

## Determinism

Rail compilation is deterministic: same source → same WASM, always. This is provable because:
1. The compiler is a pure function (source → assembly)
2. `as` and `wat2wasm` are deterministic
3. No timestamps, no randomness, no environment-dependent output

This property enables:
- **On-chain verification**: hash(source) → hash(wasm) is a fixed mapping
- **Reproducible builds**: anyone with `rail_safe` can verify the compilation
- **Audit trail**: store source on-chain, verify WASM matches

---

## Blockchain Considerations

### Smart Contract Compilation

Rail's WASM output is compatible with:
- **Near Protocol** — WASM smart contracts
- **Polkadot/Substrate** — WASM runtime
- **CosmWasm** — Cosmos WASM contracts
- **Solana SVM** — via eBPF/WASM adapter

Each chain has its own import conventions. The current WASM output uses WASI imports (fd_write, proc_exit). For smart contracts, the imports would be chain-specific (storage_read, storage_write, etc.).

### Future: Chain-Specific Backends

```
rail_safe --target wasi      # current: console programs
rail_safe --target near      # Near Protocol contracts
rail_safe --target cosmwasm  # CosmWasm contracts
```

Each target would:
1. Use the same safe language subset
2. Provide chain-specific builtins (storage, cross-contract calls)
3. Enforce chain-specific limits (gas metering, memory caps)

This is Phase 2. Phase 1 is the safe WASI compiler + HTTP endpoint.

---

## Testing

### Adversarial Test Suite

Before launch, run ALL of these against `rail_safe`. Every test must pass. This suite runs as part of the build — build fails if any test regresses.

**Banned construct tests (must reject):**
1. `main = shell "ls"` — direct call
2. `main = let f = shell in f "ls"` — via variable binding
3. `main = let f = \x -> shell x in f "ls"` — inside lambda
4. `main = match 1 | _ -> shell "ls"` — inside match arm
5. `main = let _ = read_file "/etc/passwd" in 0` — file read
6. `main = let _ = write_file "/tmp/x" "y" in 0` — file write
7. `import math` — import
8. `main = let _ = spawn (\_ -> 0) in 0` — thread spawn
9. `main = let _ = arena_mark 0 in 0` — runtime internal
10. `main = let f = \x -> \y -> shell x in 0` — nested lambda

**Resource limit tests (must reject or terminate):**
11. 100KB source file → reject (size limit)
12. `f x = f (f x)` with `main = f 1` → terminate (5s timeout)
13. 500+ nested let bindings → reject (depth limit)

**Valid program tests (must compile + produce correct output):**
14. All 7 playground demos (hello, fib, math, lists, ADTs, closures, fizzbuzz)
15. Empty main: `main = 0` → compiles, exits 0
16. String output: `main = let _ = print "hello" in 0`
17. Pattern matching with wildcards
18. ADT with 3+ constructors
19. Lambda with 2+ captured variables

**Output validation tests:**
20. Every compiled WASM has exactly 2 imports: fd_write + proc_exit
21. No compiled WASM contains unexpected function imports
22. fd_write is only called with fd=1 (stdout) in generated code

**Determinism tests:**
23. Compile same source 100 times → all WASM outputs byte-identical
24. SHA-256 of output matches across different machines (if same rail_safe binary)

**Parser robustness tests:**
25. Malformed UTF-8 input → clean error, no crash
26. Null bytes in source → clean error, no crash
27. Source that is all whitespace → clean error
28. Source with no main function → clean error

### Continuous Verification

This suite runs automatically:
- As part of `rail_safe` build (build fails if any test regresses)
- On every commit that touches compile.rail, wasm_runtime.wat, or compile_safe.rail
- Results logged with timestamp + binary hash

---

## Build Plan

### Phase 1: Safe Compiler (4 hours)
1. Add `safe_check` function to compile.rail
2. Add `compile_safe` entry point (WASM-only, with safe_check)
3. Add `safe` command to rail_native: `./rail_native safe input.rail` → `/tmp/rail_safe.wasm`
4. Build with 32MB arena
5. Run adversarial test suite

### Phase 2: HTTP Server (2 hours)
1. Write `tools/safe_server.rail` — HTTP handler using stdlib/http_server.rail
2. POST /compile endpoint with fork + timeout
3. Static HTML shell with textarea + "Compile & Run" button
4. Test with curl + browser

### Phase 3: Deploy (1 hour)
1. Start Cloudflare Tunnel to route ledatic.org → localhost
2. Serve the playground from Rail HTTP server
3. Pre-compiled WASM demos as fallback (if server is down, static demos still work)

### Phase 4: Chain Targets (future)
1. Near Protocol WASM target
2. CosmWasm target
3. On-chain source verification contracts
