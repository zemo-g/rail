# THE RAIL PROPOSAL

*What nobody has built, and how we build it.*

Written 2026-03-16 after synthesizing research across self-hosting compilers, tiny runtimes, GPU compute languages, AI code generation, and edge computing. This is not a safe composite. This is what comes next.

---

## What's missing from everything that exists

After reading about Go, Rust, Zig, Hare, Lua, Wren, Janet, Futhark, Halide, Taichi, DSPy, SGLang, TinyGo, and dozens of other projects, one pattern is screaming:

**Every language is designed for humans to write. No language is designed for AI to write and machines to run.**

- Python is easy for humans. AI generates it well because there's tons of training data. But it's slow, huge, and can't run on a GPU.
- Rust is fast and safe. AI generates it poorly because the borrow checker is adversarial to statistical pattern matching.
- CUDA/Metal is fast on GPU. No AI generates it well. Humans barely write it well.
- Futhark compiles functional code to GPU. But nobody uses it because the ecosystem is zero and the learning curve is steep.

The slot that's empty: **a language small enough for a local model to master, compilable enough to run on CPU and GPU, simple enough that grammar-constrained decoding eliminates syntax errors entirely.**

Rail is already in this slot. It just doesn't know it yet.

---

## Patterns that cut across the best implementations

### 1. The 70% rule
QBE gives 70% of LLVM's performance in 10% of the code. Lua gives 70% of Python's convenience in 10% of the runtime. TinyGo gives 70% of Go's capability in 10% of the binary.

**The lesson: 70% of the capability at 10% of the complexity wins every time for solo builders.** Don't chase 100%. Chase "good enough that nobody notices, small enough that you own every line."

### 2. One mechanism, not five policies
Lua uses ONE data structure (table) for arrays, maps, objects, modules, and namespaces. Wren uses fibers (stack + instruction pointer) for all concurrency. Forth uses two stacks for everything.

**The lesson: find the minimal primitive that handles multiple use cases.** Rail's tagged pointers already do this — one bit distinguishes integers from heap objects. Push this further.

### 3. Grammar as API
Grammar Prompting (NeurIPS 2023) proved that giving an LLM a BNF grammar makes it dramatically better at generating DSL code. XGrammar/Outlines/SGLang can constrain token generation to a grammar at decode time.

**The lesson: Rail's parser IS the AI's guardrails.** The grammar isn't documentation — it's the interface between the model and the language. Design the grammar to be machine-navigable, not just human-readable.

### 4. FFI is the ecosystem cheat code
Janet, Odin, Zig — every successful small language eventually says "just call C." 50 lines of FFI infrastructure gives you access to SQLite, OpenSSL, curl, zlib, and every other C library ever written.

**The lesson: don't build a standard library. Build an FFI and write 20 wrappers.**

### 5. The binary IS the deployment
TinyGo: 5.5KB hello world on ARM. Zig: 4-6KB for GPIO. Hare: full bootstrap in 3.5 minutes. Rail: 186KB.

**The lesson: when the binary is small and self-contained, deployment is `scp`. No Docker. No pip install. No node_modules.** This is the edge computing advantage.

---

## What nobody has tried

### 1. Grammar-constrained AI code generation for a self-hosting language
SGLang/XGrammar can constrain LLM output to a BNF grammar at decode time. Rail has a BNF grammar (it has a parser). Nobody has combined these: a language where the AI literally CANNOT produce syntax errors because the grammar is enforced at the token level during generation.

### 2. A language that compiles the same source to CPU AND GPU
Futhark compiles to GPU. Rust compiles to CPU. Nobody has a single language where `map (\x -> x * 3 + 1) data` compiles to ARM64 for small data and Metal for large data, with the compiler choosing automatically based on input size.

Rail already has both backends. The auto-dispatch (CPU if N < 50K, GPU if N >= 50K) is trivial to add. Nobody else has this because nobody else has both a self-hosting CPU compiler and a GPU compiler in the same codebase.

### 3. A locally-trained model as a language feature
The model doesn't just generate Rail code — it becomes part of the toolchain. `rail generate "sort a list"` calls the local 27B with the Rail LoRA adapter, grammar-constrains the output, compiles it, and runs it. The model is a first-class tool, not a separate product.

### 4. Compile-time AI execution (Jai's #run meets LLMs)
Jai lets you run any function at compile time. What if Rail's compile-time execution could call the local model? A `#generate` directive that asks the 27B to fill in a function body, validates it with the type checker, and bakes the result into the binary. The AI runs ONCE at compile time — the deployed binary has no AI dependency.

---

## THE PROPOSAL: How to build Rail

Not a roadmap. A philosophy materialized as code.

### Principle 1: The grammar is the product

Rail's grammar is tiny. Keep it tiny. Every production rule must be justifiable. The grammar does three jobs simultaneously:
- **For humans**: readable, minimal syntax
- **For the compiler**: recursive descent, one-pass parseable
- **For AI**: grammar-constrained decoding target

This means: no context-sensitive syntax, no significant whitespace (move to explicit blocks if needed), no ambiguous productions. The grammar should be expressible in <50 BNF rules. Every rule should be a line in a file that gets fed to XGrammar at inference time.

### Principle 2: FFI on day one, stdlib never

Don't build `rail/http`, `rail/json`, `rail/sqlite`. Build:
```
foreign sqlite3_open : String -> Ptr -> Int
foreign sqlite3_exec : Ptr -> String -> Ptr -> Ptr -> Ptr -> Int
```

~50 lines of compiler changes: parse `foreign` declarations, emit `bl _symbolname` with appropriate calling convention. The linker resolves symbols against `-lsqlite3`, `-lcurl`, etc.

Then write 20 Rail wrappers:
```
sqlite_query db sql =
  let result = foreign_sqlite3_exec db sql
  ...
```

These wrappers ARE the standard library. They're .rail files, not built into the compiler. Anyone can write more.

### Principle 3: Two backends, one dispatch

```
map f data =
  if length data < 50000 then cpu_map f data
  else gpu_map f data
```

The compiler knows which functions are GPU-safe (no allocation, no I/O, no recursion — just arithmetic on inputs). For GPU-safe functions, it emits both ARM64 and Metal. At runtime, the dispatch is a single branch.

Futhark's SOAC model (map, reduce, scan) is the right abstraction. Rail should have `map`, `reduce`, `scan`, `filter` as parallel primitives that auto-dispatch. Adjacent primitives should fuse (map-then-map → single pass, map-then-reduce → single kernel).

### Principle 4: The model is a tool, not a feature

```bash
# Generate a function
rail generate "reverse a linked list" >> my_program.rail

# Generate and compile
rail speak "compute fibonacci of each element" | rail run

# Generate, validate, insert at cursor
rail complete my_program.rail:42
```

The 27B with Rail LoRA is a dev tool. It generates .rail files. The compiler compiles them. The grammar constrains the output. The type checker validates it. Three layers of defense — grammar (syntax), types (semantics), tests (behavior).

Invest in training data. 33 examples got loss from 2.02 to 0.06. 1,000 examples is the sweet spot. Generate them: for each of Rail's 37 tests, create 10 variants with different descriptions. That's 370 pairs. Add the real source files (compiler, site generator, brain, gpu, speak, deploy tools). Add natural language descriptions of each function. Hit 1,000 easily.

### Principle 5: Cross-compile, don't port

The compiler runs on macOS ARM64. It EMITS code for any target:
- `rail build --target macos-arm64` (today)
- `rail build --target linux-arm64` (ELF header + GNU as/ld, ~20 lines)
- `rail build --target linux-x86_64` (different register set, ~200 lines of codegen)
- `rail build --target wasm` (future — enables browser, edge)

The compiler stays on the Mac Mini. The binaries go everywhere. Cross-compilation is easier than porting the compiler itself.

For the Pi Zero 2 W: cross-compile a static Linux ARM64 binary on the Mac, scp it over Tailscale. The Pi runs the binary. If it needs the model, it calls back to the Mac over Tailscale (sub-ms LAN latency). The Pi never runs the compiler — it runs the output.

### Principle 6: Concurrency via processes, not threads

Rail compiles to standalone binaries. The simplest concurrency model: fork N processes, each running a compiled Rail binary on a slice of data, merge results. The OS handles scheduling across your 10 cores.

```
par_map f data n_workers =
  let chunks = split_into n_workers data
  let pids = map (\chunk -> fork_exec "rail_worker" chunk) chunks
  let results = map wait_result pids
  flatten results
```

This is the Erlang/Elixir model without the VM. Each "process" is a native binary. IPC via pipes or shared memory. No threads, no locks, no data races.

Later, add async I/O via kqueue for the event-loop pattern (HTTP servers, file watchers). But processes-first is the right starting point.

### Principle 7: Arena per request, not GC

Rail's bump allocator is fine for short-lived programs. For long-running services, the fix isn't garbage collection — it's arena reset.

```
handle_request req =
  arena_enter ()           -- mark the allocation pointer
  let response = process req
  let result = arena_escape response  -- copy response out
  arena_reset ()           -- reset pointer to mark
  result
```

This is what game engines do. Allocate freely during a frame, reset at frame boundary. Zero GC pauses, zero fragmentation, trivial implementation (~20 lines of runtime).

For the rare case where you need long-lived heap objects (closures in a server's callback table), use a separate "permanent" arena that never resets.

---

## The build order (what to do, in what order, and why)

### Week 1: Make Rail usable
- `foreign` declarations (FFI) — 50 lines of compiler
- JSON via jsmn approach — 300 lines of Rail wrapping C's jsmn
- `char_at`, `substring`, `replace` — string builtins in runtime
- Negative number literals — 1 hour parser fix
- **Why first**: every subsequent tool needs strings and JSON. Unblock everything.

### Week 2: Make Rail portable
- Linux ARM64 ELF backend — ~20 lines in compile.rail
- Cross-compilation: `rail build --target linux-arm64`
- Test on Pi Zero 2 W over Tailscale
- **Why second**: portability multiplies the value of everything else. Pi deployment proves it's real.

### Week 3: Make Rail fast
- `par_map` via fork — process-based parallelism
- GPU auto-dispatch: CPU if N < 50K, GPU if N >= 50K
- Map fusion: adjacent maps → single pass
- Arena reset for long-running services
- **Why third**: performance is the argument for using Rail over Python.

### Week 4: Make Rail AI-native
- Grammar-constrained generation — feed Rail's BNF to XGrammar
- Expand training data to 1,000 pairs
- `rail generate` CLI command
- `rail complete` for editor integration
- **Why fourth**: the AI features are the moat, but they need a usable language underneath.

### Month 2: Make Rail an ecosystem
- Package manager: `rail get sqlite`, `rail get http`
- 20 FFI wrappers: sqlite, curl, openssl, zlib, json, etc.
- Tree-sitter grammar for editor support
- Documentation site (generated by Rail, of course)

### Month 3: Make Rail undeniable
- WASM backend (runs in browser)
- `#generate` compile-time AI (Jai's #run meets LLMs)
- Self-improving: model generates Rail → Rail trains model → better model generates better Rail
- Ship it publicly with the story: "A language that taught itself to write itself"

---

## The headline

Rail is not competing with Python or Rust. Rail is the first language designed to exist in the loop between a human, a local AI model, and local hardware — CPU and GPU.

The human says what they want. The model writes Rail. Rail compiles to native code or GPU shaders. The results come back. The model improves on each iteration. The whole loop runs on one machine with zero cloud dependency.

That's not a programming language. That's an intelligence runtime.

Build it.
