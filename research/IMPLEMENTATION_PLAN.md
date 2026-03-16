# RAIL IMPLEMENTATION PLAN

*Exhaustive plan synthesized from PROPOSAL.md (vision) and PROPOSAL_v2.md (adversarial corrections), grounded in the actual codebase state as of 2026-03-16.*

---

## CURRENT STATE (what exists right now)

| Component | Status | Detail |
|-----------|--------|--------|
| Compiler | SELF-HOSTING | 1,077 lines, 37/37 tests, fixed-point proven |
| Binary | 207KB Mach-O | ARM64, macOS, `as`+`ld` toolchain |
| Memory | 256MB bump alloc | Tagged pointers, no GC, no arena reset |
| Types | int, string, list, tuple, closure, ADT | No floats, no records in native |
| TCO | PROVEN | 50K recursion, constant stack |
| GPU | Metal codegen exists | `tools/gpu.rail` (92 lines), `gpu_host.m` |
| FFI | NONE | Zero foreign function support |
| Concurrency | NONE | No threads, no fibers, no async |
| Modules | NONE | Single-file only in native compiler |
| Pattern matching | PARTIAL | ADTs (Some/None/MkPair), no deep patterns |
| Floats | NONE | Integer-only in native compiler |
| Cross-compile | NONE | macOS ARM64 only |
| AI generation | RUST-ERA ONLY | LoRA training at step 1,010 (1.5B model) |
| String interp | BROKEN | `{}` conflicts with JSON/CSS |

---

## PHASE 0: FOUNDATION HARDENING (Week 1)

*Before adding features, fix what's fragile and fill gaps that block everything downstream.*

### 0.1 — Negative number literals
- **What**: Parser currently chokes on `-42` as a literal. Treats `-` as operator.
- **How**: In lexer, when `-` is followed by digit and preceded by operator/open-paren/start-of-expr, emit a negative integer token.
- **LOC**: ~15 lines in lexer section of compile.rail
- **Test**: `neg=-42` → program prints `-42`
- **Blocks**: Any real program using negative numbers

### 0.2 — Float literals and arithmetic
- **What**: Native compiler is integer-only. Need f64 for any numeric work.
- **How**:
  - Tagged pointer scheme: floats boxed on heap as `[tag=5][f64_bits]`
  - Lexer: recognize `3.14`, `.5`, `1e-3`
  - Codegen: `fmov`, `fadd`, `fsub`, `fmul`, `fdiv` using NEON `d0-d7` registers
  - Runtime: `_rail_print_float` via `snprintf "%.15g"`
  - Arithmetic dispatch: check tag, branch to int or float path
- **LOC**: ~150 lines (codegen + runtime + lexer)
- **Tests**: `float_lit`, `float_arith`, `float_cmp`, `int_float_mix`
- **Blocks**: Any scientific/financial computation, GPU dispatch thresholds

### 0.3 — String escape sequences
- **What**: No way to write `{`, `}`, `\n`, `\t`, `\"` in string literals
- **How**: In lexer string scanning, recognize `\{`, `\}`, `\\`, `\n`, `\t`, `\"`. Emit actual bytes.
- **LOC**: ~30 lines in lexer
- **Test**: `escapes` → prints literal braces, newlines, tabs
- **Blocks**: JSON generation, CSS embedding, any string with braces

### 0.4 — Multi-line list literals
- **What**: Parser ends expression at `]` + newline, breaking multi-line lists
- **How**: Track bracket depth in parser. Don't end expression while inside `[...]`.
- **LOC**: ~10 lines in parser
- **Test**: `multiline_list` → `[1, 2, 3]` across lines works
- **Blocks**: Any program with large data structures

### 0.5 — `read_line` builtin
- **What**: Can't read stdin interactively
- **How**: Runtime function calling `getline()` or equivalent, returns string
- **LOC**: ~20 lines
- **Test**: `readline` → pipe input, check output
- **Blocks**: REPL, interactive tools

### 0.6 — Integer literal > 65535
- **What**: ARM64 `mov x0, #imm` only supports 16-bit. Large ints crash.
- **How**: Use `movz`/`movk` sequence for large immediates (up to 64-bit). Already have `bigint` test but it uses arithmetic — need direct large literal support.
- **LOC**: ~25 lines in codegen
- **Test**: `biglit` → `let x = 1000000 in print (show x)` → `1000000`

**Phase 0 exit criteria**: 43+ tests passing. Negative numbers, floats, escapes, multi-line lists, large ints all work.

---

## PHASE 1: FFI — THE ECOSYSTEM UNLOCK (Week 2)

*v1 said 50 lines. v2 said 500-1000. Reality: 500 LOC with safety, built incrementally.*

### 1.1 — `foreign` declaration syntax
- **What**: `foreign sqlite3_open : Ptr -> Ptr -> Int` parsed and stored in symbol table
- **How**: New AST node `["F", name, arg_types, return_type]`. Parser recognizes `foreign` keyword.
- **LOC**: ~30 lines (parser)
- **Test**: Parse foreign decl, verify AST structure

### 1.2 — C calling convention codegen
- **What**: Emit `bl _symbol` with args in x0-x7 per ARM64 ABI
- **How**:
  - Integer/pointer args: x0-x7 (already how Rail calls functions)
  - Return value: x0
  - Stack alignment: sp must be 16-byte aligned before `bl`
  - Variadic functions (printf): args on stack via `str x0, [sp, #offset]`
- **LOC**: ~80 lines (codegen)
- **Test**: `foreign_puts` → call C `puts("hello")`

### 1.3 — Linker flag passing
- **What**: `--link "-lsqlite3 -lcurl"` flag on CLI, or pragma in source
- **How**: Collect link flags, pass to `ld` command
- **LOC**: ~15 lines
- **Test**: Link against libsqlite3, call sqlite3_open

### 1.4 — Pointer type and unsafe operations
- **What**: `Ptr` type for opaque C pointers. `ptr_read`, `ptr_write`, `ptr_offset` builtins.
- **How**: Pointers are untagged 64-bit values (tag bit 0 = 0, like heap objects). Need a `null` literal (zero).
- **LOC**: ~60 lines (codegen for builtins)
- **Test**: Allocate via malloc, write/read through pointer

### 1.5 — Pin mechanism for FFI-crossing data
- **What**: `pin expr` prevents arena reset from invalidating a pointer. Pinned data uses malloc, not bump allocator.
- **How**: `_rail_pin` calls `malloc`, copies data, returns stable pointer. Pinned objects tracked in a side table for eventual free.
- **LOC**: ~50 lines (runtime)
- **Test**: Pin a string, pass to C, arena reset, string still valid

### 1.6 — Callback support (Rail function → C function pointer)
- **What**: Pass a Rail closure to C as a callback
- **How**: Trampoline: generate a small stub that loads closure captures from a known address, then calls the Rail function body. Register the stub address as the C callback.
- **LOC**: ~100 lines (codegen + runtime)
- **Complexity**: HIGH. May defer to Phase 4 if it blocks progress.
- **Test**: `qsort` with Rail comparison function

### 1.7 — First FFI wrappers
- **What**: Prove FFI works end-to-end with real libraries
- **How**: Write .rail wrapper files:
  - `ffi/sqlite.rail` — open, exec, close (~40 lines)
  - `ffi/file.rail` — fopen, fread, fwrite, fclose (~30 lines)
  - `ffi/env.rail` — getenv, setenv (~10 lines)
- **LOC**: ~80 lines of Rail
- **Test**: `ffi_sqlite` → create table, insert, query, verify result

**Phase 1 exit criteria**: Can call C functions, link external libraries, SQLite wrapper works end-to-end. ~50 tests passing.

---

## PHASE 2: MEMORY MODEL — TWO-TIER (Week 3)

*v1 proposed arena-only. v2 proved that FFI needs stable pointers and long-running services need non-resetting memory.*

### 2.1 — Arena mark/reset
- **What**: `arena_mark()` saves allocation pointer. `arena_reset()` restores it. All allocations between mark/reset are freed in O(1).
- **How**: Store mark as a saved pointer value. Reset = restore pointer. Dead simple.
- **LOC**: ~20 lines (runtime)
- **Test**: `arena_reset` → allocate 1MB, reset, allocate again, no OOM

### 2.2 — Reference-counted heap
- **What**: `rc_alloc(size)` returns a refcounted object. `rc_retain`/`rc_release` manage lifetime.
- **How**: Object layout: `[refcount][tag][data...]`. Retain = atomic increment. Release = atomic decrement, free on zero.
- **LOC**: ~80 lines (runtime)
- **Test**: `rc_basic` → alloc, retain, release, verify freed

### 2.3 — Automatic RC for FFI objects
- **What**: `pin` returns an RC object instead of a raw malloc. FFI-crossing data is automatically refcounted.
- **How**: `_rail_pin` allocates via RC heap. C-side retains. Rail-side releases when scope ends.
- **LOC**: ~40 lines (codegen for scope-end release)
- **Test**: `rc_ffi` → pin object, pass to C, verify no leak

### 2.4 — Per-request arena pattern
- **What**: For HTTP servers: mark before request, reset after response.
- **How**: Wrapper function:
  ```
  handle_request req =
    let mark = arena_mark ()
    let response = process req
    let result = rc_alloc_copy response  -- escape to RC heap
    arena_reset mark
    result
  ```
- **LOC**: ~10 lines (library code)
- **Test**: `arena_server` → simulate 1000 requests, memory stable

**Phase 2 exit criteria**: Two-tier memory works. Arena for fast scratch, RC for long-lived/FFI data. ~55 tests.

---

## PHASE 3: PATTERN MATCHING & ADTs — FULL (Week 3-4)

*Native compiler has basic ADTs (Some/None/MkPair). Need full pattern matching for real programs.*

### 3.1 — Deep pattern matching
- **What**: Match on nested constructors: `match x | Some (Pair a b) -> a + b | None -> 0`
- **How**: Compile to nested tag checks + field extraction. Each pattern becomes a sequence of loads and compares.
- **LOC**: ~100 lines (codegen)
- **Test**: `deep_match` → nested ADT patterns

### 3.2 — Wildcard and literal patterns
- **What**: `_` matches anything. `42` matches literal. `"hello"` matches string.
- **How**: Wildcard = skip check. Literal = emit comparison.
- **LOC**: ~30 lines (parser + codegen)
- **Test**: `wildcard_match`, `literal_match`

### 3.3 — Guard clauses
- **What**: `match x | n if n > 0 -> "positive" | _ -> "non-positive"`
- **How**: After pattern binds variables, evaluate guard expression. If false, fall through to next arm.
- **LOC**: ~40 lines (codegen)
- **Test**: `guard_match`

### 3.4 — Exhaustiveness checking
- **What**: Warn if match doesn't cover all constructors
- **How**: Track which constructors are covered per ADT. Emit warning (not error — keep pragmatic).
- **LOC**: ~60 lines (analysis pass)
- **Test**: Intentionally incomplete match → warning

### 3.5 — Record types
- **What**: `type Person = { name : String, age : Int }`. Field access: `p.name`.
- **How**: Records are heap objects with named fields at known offsets. Dot syntax compiles to field offset load.
- **LOC**: ~120 lines (parser + codegen)
- **Test**: `record_create`, `record_access`, `record_update`

**Phase 3 exit criteria**: Full pattern matching with deep patterns, guards, wildcards, records. ~65 tests.

---

## PHASE 4: MODULES & IMPORTS (Week 4)

*Single-file programs don't scale. Need modules before building any real tool in native Rail.*

### 4.1 — `import` syntax
- **What**: `import "lib/list.rail"` brings all definitions into scope
- **How**:
  - Parse import declaration
  - Read + lex + parse the imported file
  - Merge its definitions into the current compilation's symbol table
  - Codegen all functions (imported + local) into one assembly file
  - Prevent duplicate definitions (error on collision)
- **LOC**: ~80 lines (parser + driver)
- **Test**: `import_basic` → import a file with helper functions, call them

### 4.2 — Qualified imports
- **What**: `import "lib/math.rail" as Math` → `Math.sqrt x`
- **How**: Prefix all imported names with `Math_` (or similar mangling) in symbol table
- **LOC**: ~30 lines (parser)
- **Test**: `import_qualified` → no name collision

### 4.3 — Export control
- **What**: Only `export`-marked definitions are visible to importers
- **How**: Mark functions as public/private. When importing, only merge public symbols.
- **LOC**: ~20 lines (parser + symbol table)
- **Test**: `import_private` → accessing private function is error

### 4.4 — Standard library files
- **What**: Ship a `stdlib/` directory with common utilities:
  - `stdlib/list.rail` — map, filter, fold, zip, take, drop, reverse, sort
  - `stdlib/string.rail` — trim, pad, starts_with, ends_with, contains, replace
  - `stdlib/option.rail` — Option type + helpers
  - `stdlib/result.rail` — Result type + helpers
  - `stdlib/io.rail` — file I/O wrappers
- **How**: Pure Rail files, no special compiler support
- **LOC**: ~300 lines of Rail across files
- **Test**: Import and use each stdlib module

**Phase 4 exit criteria**: Multi-file programs work. stdlib provides basics. ~75 tests.

---

## PHASE 5: GREEN THREADS & CONCURRENCY (Week 5-6)

*v1 proposed fork (broken on macOS per v2). v2 proposed green threads + message passing.*

### 5.1 — Fiber data structure
- **What**: A fiber = saved stack pointer + saved registers + state (running/suspended/dead)
- **How**:
  - Each fiber gets a malloc'd stack (64KB default)
  - Context switch: save x19-x28, x29, x30, sp to fiber struct. Load from target fiber.
  - Assembly routine `_rail_fiber_switch(from, to)` — ~30 instructions
- **LOC**: ~100 lines (runtime, assembly)
- **Test**: `fiber_basic` → create fiber, switch to it, switch back

### 5.2 — Cooperative scheduling
- **What**: `yield ()` suspends current fiber, resumes scheduler. Scheduler picks next ready fiber.
- **How**: Round-robin ready queue. `yield` = switch to scheduler fiber. Scheduler picks next from queue.
- **LOC**: ~80 lines (runtime)
- **Test**: `fiber_yield` → two fibers interleave execution

### 5.3 — Channels (message passing)
- **What**: `let ch = channel ()` / `send ch value` / `let v = recv ch`
- **How**: Channel = queue + waiting-sender list + waiting-receiver list. `send` on full channel suspends sender. `recv` on empty channel suspends receiver.
- **LOC**: ~120 lines (runtime)
- **Test**: `channel_basic` → producer/consumer pattern

### 5.4 — `spawn` and `await`
- **What**: `let fib = spawn (\() -> compute_thing ())` / `let result = await fib`
- **How**: `spawn` creates fiber, adds to ready queue. `await` suspends caller until target fiber completes, returns its result.
- **LOC**: ~60 lines
- **Test**: `spawn_await` → spawn 10 fibers, await all, collect results

### 5.5 — Parallel map via fibers
- **What**: `par_map f list` spawns one fiber per element (or per chunk), collects results
- **How**: Chunk list into N pieces (N = core count). Spawn N fibers. Await all. Concatenate results.
- **LOC**: ~40 lines (library, using spawn/await)
- **Test**: `par_map` → parallel computation produces same result as sequential

**Phase 5 exit criteria**: Green threads work. Channels enable producer/consumer. par_map provides easy parallelism. ~85 tests.

---

## PHASE 6: CROSS-COMPILATION (Week 6-7)

*Both proposals agree: cross-compile from Mac, don't port the compiler.*

### 6.1 — Target abstraction in codegen
- **What**: Factor out platform-specific codegen into a target descriptor: register names, calling convention, section directives, entry point format
- **How**: Target struct with fields for each platform difference. Codegen reads target instead of hardcoding macOS.
- **LOC**: ~50 lines (refactor)

### 6.2 — Linux ARM64 (ELF) backend
- **What**: `rail_native compile --target linux-arm64 prog.rail`
- **How**:
  - ELF section directives (`.section .text`, not `.text` alone)
  - `_start` entry point (not `_main`)
  - Syscalls instead of libc for basic I/O (write = syscall #64, exit = #93)
  - OR: link against musl libc for full C interop
  - Emit `.s` file, call `aarch64-linux-gnu-as` + `aarch64-linux-gnu-ld`
- **LOC**: ~100 lines (new target descriptor + syscall stubs)
- **Test**: Cross-compile hello world, run on Pi via SSH
- **Dependency**: GNU cross-toolchain (`brew install aarch64-elf-gcc` or similar)

### 6.3 — Linux x86_64 backend
- **What**: `rail_native compile --target linux-x64 prog.rail`
- **How**:
  - Different register set: rdi, rsi, rdx, rcx, r8, r9 (not x0-x7)
  - Different calling convention (System V AMD64)
  - Different instruction encoding (entirely different ISA)
  - Runtime functions need x86_64 assembly rewrites
- **LOC**: ~400 lines (full codegen rewrite for x86_64)
- **Complexity**: HIGH. Most instruction-for-instruction translation needed.
- **Test**: Cross-compile, run in Docker or VM

### 6.4 — Static linking
- **What**: Produce fully static binaries (no dynamic linker needed)
- **How**: Link against musl (Linux) or static libSystem (macOS). `-static` flag to ld.
- **LOC**: ~10 lines (linker flags)
- **Test**: `ldd` shows no dynamic deps

### 6.5 — Deployment automation
- **What**: `rail_native deploy prog.rail user@host:/path`
- **How**: Compile for target → scp binary → optional ssh to run
- **LOC**: ~30 lines (shell wrapper or Rail script)
- **Test**: Deploy to Pi, verify runs

**Phase 6 exit criteria**: Linux ARM64 binaries work on Pi. x86_64 stretch goal. `scp` deployment. ~90 tests.

---

## PHASE 7: GPU INTEGRATION — CPU/GPU AUTO-DISPATCH (Week 7-8)

*Both proposals agree: same source, auto-dispatch based on data size. v2 says measure actual crossover, don't hardcode 50K.*

### 7.1 — GPU-safe function analysis
- **What**: Compiler identifies functions safe for GPU: no allocation, no I/O, no recursion, no string ops. Pure arithmetic on numeric inputs only.
- **How**: Walk AST, check each called function. Transitively verify purity.
- **LOC**: ~80 lines (analysis pass)
- **Test**: Correctly classify pure vs impure functions

### 7.2 — Metal shader emission
- **What**: For GPU-safe functions used in `map`/`reduce`, emit Metal Shading Language kernel
- **How**: Translate Rail arithmetic to MSL. Wrap in `kernel void` with threadgroup indexing.
  ```metal
  kernel void rail_map(device float* in [[buffer(0)]],
                       device float* out [[buffer(1)]],
                       uint id [[thread_position_in_grid]]) {
      out[id] = in[id] * 3 + 1;
  }
  ```
- **LOC**: ~150 lines (MSL codegen)
- **Test**: `gpu_map` → map function over array, verify results match CPU

### 7.3 — Metal host runtime
- **What**: Objective-C runtime that loads .metallib, creates buffers, dispatches compute
- **How**: Expand existing `gpu_host.m`:
  - `MTLCreateSystemDefaultDevice()`
  - `newBufferWithBytes:length:options:`
  - `newComputePipelineStateWithFunction:`
  - `dispatchThreads:threadsPerThreadgroup:`
- **LOC**: ~200 lines (Objective-C)
- **Test**: Round-trip: Rail data → Metal buffer → compute → read back

### 7.4 — Crossover calibration
- **What**: Measure actual CPU vs GPU crossover point on M4 Pro. Not 50K — measure it.
- **How**: Benchmark `map (\x -> x * 3 + 1) data` for N = 1K, 10K, 50K, 100K, 1M on both CPU and GPU. Find crossover.
- **Output**: Constant baked into compiler (likely ~10K-100K depending on operation)
- **Test**: `gpu_calibrate` → runs benchmark, reports crossover

### 7.5 — Auto-dispatch at runtime
- **What**: `map f data` checks `length data` vs crossover. CPU path if small, GPU path if large.
- **How**: Single branch instruction at call site. Both paths compiled.
- **LOC**: ~30 lines (codegen for dispatch)
- **Test**: `auto_dispatch` → small data uses CPU, large data uses GPU, same results

### 7.6 — Kernel fusion
- **What**: `map f (map g data)` → single GPU kernel applying `g` then `f`
- **How**: When compiler sees adjacent maps, compose functions and emit one kernel
- **LOC**: ~80 lines (optimization pass)
- **Test**: `map_fusion` → fused version runs faster, same results
- **Complexity**: MEDIUM-HIGH. Defer if timeline is tight.

### 7.7 — Reduce and scan
- **What**: `reduce (+) 0 data` and `scan (+) 0 data` as GPU-dispatchable operations
- **How**: Standard parallel reduction pattern (tree reduction in shared memory)
- **LOC**: ~100 lines (MSL + runtime)
- **Test**: `gpu_reduce`, `gpu_scan`

**Phase 7 exit criteria**: CPU/GPU auto-dispatch works for map/reduce. Crossover calibrated. ~100 tests.

---

## PHASE 8: AI-NATIVE TOOLING (Week 8-10)

*v1 dreamed big. v2 grounded it. Plan: grammar-constrained generation with validation loops.*

### 8.1 — Export Rail grammar as BNF/EBNF
- **What**: Machine-readable grammar file derived from the parser
- **How**: Write `grammar/rail.ebnf` that exactly matches what the parser accepts. Keep in sync manually (parser is source of truth).
- **LOC**: ~50 lines of EBNF
- **Test**: Validate every existing .rail file parses under the EBNF

### 8.2 — Scale training data to 1,000+ examples
- **What**: Generate description→code pairs for LoRA training
- **How**:
  - For each of 37 tests: generate 20 natural-language descriptions + Rail solutions (740 pairs)
  - For each .rail tool file: "explain this code" + "write code that does X" pairs (200+)
  - Error cases: "this code has bug X, fix it" (100+)
  - Edge cases: closures, TCO, ADTs, pattern matching (100+)
  - Total: 1,000-1,200 pairs
- **LOC**: ~1,200 JSONL entries
- **Tool**: Expand `tools/build_training_data.rail` to auto-generate variants

### 8.3 — LoRA fine-tuning round 2
- **What**: Retrain on 1,000+ examples, measure generalization
- **How**:
  - Hold out 10% as test set (patterns NOT in training)
  - Train until validation loss plateaus (not just training loss)
  - Target: generate correct Rail for held-out tasks >60% of the time
- **Metric**: Held-out task success rate, not just loss value

### 8.4 — Validation loop: generate → compile → test → retry
- **What**: `rail generate "sort a list"` doesn't just generate — it validates
- **How**:
  1. Model generates Rail code (unconstrained reasoning, constrained emission per v2)
  2. Compiler attempts to compile it
  3. If compile fails: feed error back to model, regenerate (max 3 retries)
  4. If compile succeeds: run against any provided test cases
  5. If tests fail: feed test output to model, regenerate
  6. Return first version that compiles + passes tests (or best attempt)
- **LOC**: ~150 lines (orchestration in Rail or shell)
- **Test**: `rail generate "fibonacci"` → produces working function

### 8.5 — Grammar-constrained emission via XGrammar
- **What**: Feed Rail's EBNF to XGrammar/Outlines to constrain final token generation
- **How**:
  - Convert EBNF to XGrammar format
  - Model thinks freely (unconstrained) about the solution
  - Final code emission pass uses grammar mask on logits
  - Per v2: constrain ONLY final output, not reasoning
- **LOC**: ~50 lines (integration with MLX inference)
- **Dependency**: XGrammar or Outlines library
- **Test**: Generated code always parses (syntax error rate → 0%)

### 8.6 — `rail generate` CLI command
- **What**: `rail_native generate "description"` → outputs .rail code
- **How**: Call local model (via HTTP to :8080 or direct), apply grammar constraints, validate, print
- **LOC**: ~60 lines
- **Test**: End-to-end: description → working Rail program

### 8.7 — `rail complete` for editor integration
- **What**: Given a file and cursor position, generate the next function/expression
- **How**: Read file up to cursor, send as context to model with "complete this" prompt, grammar-constrain output, insert
- **LOC**: ~80 lines
- **Test**: Partial file → completed function

### 8.8 — Overfitting test suite
- **What**: Per v2, explicitly test for memorization vs generalization
- **How**:
  - 20 tasks the model has NEVER seen in training
  - Measure: does it generate correct Rail? Or just regurgitate training examples?
  - Track this metric over time as training data grows
- **LOC**: ~20 test cases
- **Metric**: >60% novel-task success = generalization achieved

**Phase 8 exit criteria**: `rail generate` produces working code >60% of the time for novel tasks. Grammar-constrained emission eliminates syntax errors. ~105 tests.

---

## PHASE 9: ASYNC I/O & HTTP SERVER (Week 10-11)

*Needed for long-running services. Builds on green threads from Phase 5.*

### 9.1 — kqueue event loop
- **What**: Non-blocking I/O via macOS kqueue
- **How**:
  - FFI to `kqueue()`, `kevent()` (from Phase 1 FFI)
  - Event loop fiber: waits on kqueue, wakes fibers when their fd is ready
  - `async_read fd` / `async_write fd data` suspend fiber until I/O ready
- **LOC**: ~150 lines (runtime + FFI wrappers)
- **Test**: `async_read` → non-blocking file read

### 9.2 — TCP server
- **What**: `listen "0.0.0.0" 8080 handler` accepts connections, spawns fiber per connection
- **How**:
  - FFI to `socket()`, `bind()`, `listen()`, `accept()`
  - Each accepted connection → `spawn` handler fiber
  - Handler fiber does async reads/writes
- **LOC**: ~100 lines
- **Test**: `tcp_echo` → echo server handles multiple connections

### 9.3 — HTTP request parser
- **What**: Parse HTTP/1.1 requests (method, path, headers, body)
- **How**: Pure Rail string parsing. No external dep.
- **LOC**: ~80 lines (Rail)
- **Test**: Parse GET, POST, headers, query params

### 9.4 — HTTP response builder
- **What**: Build HTTP responses with status, headers, body
- **How**: String concatenation with proper CRLF formatting
- **LOC**: ~40 lines (Rail)
- **Test**: Build 200 OK with JSON body

### 9.5 — HTTP server library
- **What**: `http_serve 8080 routes` where routes = list of (method, path, handler)
- **How**: Combines TCP server + HTTP parser + response builder + arena-per-request memory
- **LOC**: ~60 lines (Rail, composing above)
- **Test**: `http_hello` → serve "Hello World", curl it, verify

### 9.6 — JSON serialization
- **What**: Rail values → JSON strings. Complement to json_parse.
- **How**: Pattern match on value type, emit appropriate JSON syntax
- **LOC**: ~50 lines (Rail)
- **Test**: `json_emit` → list of records → valid JSON

**Phase 9 exit criteria**: Can build HTTP APIs in native Rail. Arena-per-request prevents memory growth. ~115 tests.

---

## PHASE 10: PACKAGE MANAGER & ECOSYSTEM (Month 3)

### 10.1 — `rail get` package manager
- **What**: `rail_native get sqlite` downloads `ffi/sqlite.rail` from a registry
- **How**:
  - Registry = git repo or HTTP endpoint with `packages.json` index
  - `rail get` fetches .rail file(s) into `~/.rail/packages/<name>/`
  - Import resolution checks packages directory
- **LOC**: ~100 lines
- **Test**: `rail get` a test package, import it, use it

### 10.2 — 20 FFI wrapper packages
- **What**: Cover the most-needed C libraries
- **Packages**:
  1. `sqlite` — database
  2. `curl` — HTTP client
  3. `json` — jsmn-based parsing
  4. `zlib` — compression
  5. `openssl` — TLS/crypto
  6. `pcre` — regex
  7. `readline` — line editing
  8. `termios` — terminal control
  9. `mmap` — memory-mapped files
  10. `dlopen` — dynamic library loading
  11. `time` — strftime, mktime
  12. `math` — libm functions (sin, cos, sqrt, etc.)
  13. `socket` — raw sockets (beyond TCP server)
  14. `stat` — file metadata
  15. `dirent` — directory listing
  16. `signal` — signal handling
  17. `pthread` — (for OS thread spawning if needed)
  18. `iconv` — character encoding
  19. `png` — libpng image creation
  20. `metal` — Metal compute dispatch
- **LOC**: ~20-50 lines each, ~600 total
- **Test**: Each package has at least one integration test

### 10.3 — Tree-sitter grammar
- **What**: Editor syntax highlighting and structural navigation
- **How**: Write `tree-sitter-rail/grammar.js` matching Rail's syntax
- **LOC**: ~200 lines (JavaScript grammar definition)
- **Test**: Parse all .rail files without error

### 10.4 — Documentation site
- **What**: Generated by Rail (dogfooding), hosted on ledatic.org/rail
- **How**: Rail program that reads .rail files, extracts doc comments, generates HTML
- **LOC**: ~200 lines of Rail
- **Test**: Generates valid HTML for all stdlib modules

**Phase 10 exit criteria**: Package manager works. 20 FFI wrappers available. Editor support. Docs.

---

## PHASE 11: WASM BACKEND (Month 3-4)

### 11.1 — WASM codegen
- **What**: `rail_native compile --target wasm prog.rail`
- **How**:
  - WASM has its own instruction set (stack-based, not register-based)
  - Emit .wat (text format), assemble with `wat2wasm`
  - Or emit .wasm binary directly (more complex but no external tool)
  - Memory: linear memory with bump allocator (same model as native)
  - No FFI (browser sandbox) — only WASI imports for I/O
- **LOC**: ~500 lines (new codegen backend)
- **Test**: Hello world runs in wasmtime + browser

### 11.2 — WASI support
- **What**: fd_write, fd_read, args_get for command-line WASM programs
- **How**: Import WASI preview1 functions
- **LOC**: ~50 lines
- **Test**: WASM binary runs on wasmtime with stdio

### 11.3 — Browser runtime
- **What**: HTML page that loads .wasm, provides DOM interop
- **How**: JavaScript glue that provides `print` → console.log, DOM manipulation via imported functions
- **LOC**: ~100 lines (JS)
- **Test**: Rail program renders to browser DOM

**Phase 11 exit criteria**: Rail programs run in browser and edge runtimes.

---

## PHASE 12: COMPILE-TIME AI — #GENERATE (Month 4)

*The most ambitious feature. Jai's `#run` meets local LLMs. v2 validated the concept but cautioned about expectations.*

### 12.1 — `#generate` directive
- **What**:
  ```
  #generate "a function that sorts a list of integers"
  sort : List Int -> List Int
  ```
  At compile time: calls local model, validates output, bakes into binary.
- **How**:
  - Compiler encounters `#generate`, pauses compilation
  - Sends prompt to local model (via HTTP to :8080)
  - Grammar-constrains output to Rail syntax
  - Parses result, type-checks against provided signature
  - If valid: splices into AST, continues compilation
  - If invalid: compile error with model's output for debugging
- **LOC**: ~100 lines (compiler integration)
- **Test**: `#generate "add two numbers"` → working function in binary

### 12.2 — Compile-time execution (`#run`)
- **What**: `#run expr` evaluates expr at compile time, bakes result into binary
- **How**: Interpret the expression during compilation (use the interpreter, or a simple eval pass). Result becomes a constant in the binary.
- **LOC**: ~80 lines
- **Test**: `#run (3 + 4)` → binary contains `7` as constant, no runtime addition

### 12.3 — Conditional compilation
- **What**: `#if target == "wasm" then ... else ...`
- **How**: Evaluate condition at compile time, only compile the taken branch
- **LOC**: ~30 lines
- **Test**: Different code for different targets

**Phase 12 exit criteria**: AI generates code at compile time. Binary has zero AI dependency.

---

## PHASE 13: SELF-IMPROVEMENT LOOP (Month 4-5)

*The flywheel: model generates Rail → Rail trains model → better model generates better Rail.*

### 13.1 — Automated training data generation
- **What**: Rail program that generates (description, code) pairs from the codebase
- **How**:
  - Parse every .rail file → extract functions
  - For each function: generate 5 natural-language descriptions using local model
  - Pair description + function code = training example
  - Filter: only keep pairs where generated code from description matches original
- **LOC**: ~100 lines (Rail)
- **Output**: Growing JSONL dataset

### 13.2 — Continuous quality measurement
- **What**: Nightly benchmark: generate Rail for 50 held-out tasks, measure success rate
- **How**: Cron job runs `rail generate` on test suite, logs pass/fail/compile-error rates
- **LOC**: ~50 lines (Rail + launchd plist)
- **Output**: Time-series of model quality

### 13.3 — Iterative LoRA refinement
- **What**: When new training data accumulates, retrain LoRA adapter
- **How**:
  - Trigger retrain when 100+ new examples since last train
  - Compare new model vs old on held-out tasks
  - Only deploy if quality improves
- **LOC**: ~30 lines (training script wrapper)
- **Metric**: Monotonically improving held-out success rate

**Phase 13 exit criteria**: Automated loop running. Quality measurably improving over time.

---

## DEPENDENCY GRAPH

```
Phase 0 (foundations)
  ↓
Phase 1 (FFI) ←──────────────────────────────┐
  ↓                                           │
Phase 2 (memory) ← depends on FFI for RC/pin  │
  ↓                                           │
Phase 3 (pattern matching) ← independent      │
  ↓                                           │
Phase 4 (modules) ← independent               │
  ↓                                           │
Phase 5 (green threads) ← needs memory model  │
  ↓                                           │
Phase 6 (cross-compile) ← independent         │
  ↓                                           │
Phase 7 (GPU) ← needs FFI for Metal runtime ──┘
  ↓
Phase 8 (AI tooling) ← needs grammar + model
  ↓
Phase 9 (HTTP server) ← needs threads + FFI
  ↓
Phase 10 (ecosystem) ← needs FFI + modules
  ↓
Phase 11 (WASM) ← independent backend
  ↓
Phase 12 (compile-time AI) ← needs AI tooling
  ↓
Phase 13 (self-improvement) ← needs everything
```

**Parallelizable pairs** (can be worked on simultaneously):
- Phase 3 (pattern matching) + Phase 6 (cross-compile)
- Phase 4 (modules) + Phase 7 (GPU)
- Phase 8 (AI tooling) + Phase 11 (WASM)

---

## RISK REGISTER

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| FFI ABI incompatibility with specific C libs | HIGH | MEDIUM | Test each lib individually. Start with simple libs (sqlite, puts) |
| Green thread stack overflow on M4 | LOW | HIGH | Guard pages on fiber stacks. Detect and report clearly |
| Metal shader compilation failures | MEDIUM | MEDIUM | Validate MSL offline. Keep CPU fallback always available |
| LoRA model doesn't generalize at 1K examples | MEDIUM | HIGH | Scale to 2K-5K. Add error correction pairs. Try larger base model |
| Grammar-constrained decoding too slow | LOW | MEDIUM | Cache grammar automaton. Only constrain final emission |
| Cross-compile toolchain not available | LOW | LOW | Document Homebrew install. Docker fallback for cross-as/ld |
| Scope creep (adding features vs finishing phases) | HIGH | HIGH | Each phase has exit criteria with test counts. Don't start next phase until current passes |
| Bump allocator OOM on large programs | MEDIUM | MEDIUM | Phase 2 (arena reset) directly addresses this |
| Self-hosting compiler regression during refactoring | MEDIUM | HIGH | Always run `rail_native test` (37 tests) after ANY compiler change. Binary backup in git |

---

## METRICS TO TRACK

| Metric | Current | Phase 4 Target | Phase 8 Target | Phase 13 Target |
|--------|---------|----------------|----------------|-----------------|
| Compiler LOC | 1,077 | 2,500 | 3,500 | 5,000 |
| Test count | 37 | 75 | 105 | 130 |
| Binary size | 207KB | 300KB | 400KB | 500KB |
| Supported targets | 1 (macOS ARM64) | 2 (+Linux ARM64) | 3 (+WASM) | 3 |
| FFI wrappers | 0 | 5 | 10 | 20 |
| Training examples | ~33 | 200 | 1,000 | 2,000+ |
| AI generation success (novel tasks) | 0% | — | >60% | >80% |
| Self-compile time | ~2s | ~3s | ~4s | ~5s |

---

## THE INVARIANT

After every phase, these must remain true:

1. **`rail_native test` passes all tests** — the compiler never regresses
2. **`rail_native self` produces identical output** — the fixed point holds
3. **The compiler stays under 10K lines** — complexity is the enemy
4. **The binary stays under 1MB** — deployment remains `scp`
5. **Zero external runtime dependencies** — `as` + `ld` + the binary, nothing else
6. **Everything runs on one Mac Mini** — no cloud, no cluster, no Docker

---

*Build it.*
