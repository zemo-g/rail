# Tiny Language Runtimes: Stealable Ideas for Rail

Research date: 2026-03-16

---

## 1. Lua — The Gold Standard of Small

**Size**: ~25,000 lines of C. ~30 .c files. Binary is 200KB on 64-bit Linux. Lua 1.0 was under 8K LOC.

**Why it's so small — the actual decisions:**

- **ONE data structure**: The table is a hybrid array+hash. Integer keys 1..N go in a contiguous array part (no hashing, fast access). Everything else goes in a hash part using chained scatter with Brent's variation. The array part auto-sizes so that >50% of slots 1..N are used. This single structure replaces arrays, dictionaries, objects, modules, and namespaces. One implementation, not five.

- **Register-based VM with ~80 opcodes** (was ~35 in 5.0, grew to ~80 in 5.4). Register-based means fewer instructions than stack-based VMs — `a = b + c` is one instruction, not four (push b, push c, add, store a). Registers map to a stack window per call frame, so "register-based" is really "indexed stack slots."

- **Upvalue trick for closures**: An upvalue is a pointer. While the variable lives on the stack, the upvalue points there (open upvalue). When the variable's scope ends, Lua copies the value INTO the upvalue struct itself and repoints (closed upvalue). All access is through the pointer, so the migration is invisible to running code. Multiple closures sharing the same variable share the same upvalue struct. This is the entire closure implementation — no environment frames, no heap allocation per scope.

- **Mechanisms, not policies**: No class system — use tables + metatables. No module system — use tables. No exception types — use any value. No iterator protocol — use closures. Each of these is ~0 lines of dedicated implementation.

- **C API is THE interface**: Lua has no standalone runtime. It's a library. Every feature must work through the C API stack. This constraint prevents feature creep — if it can't be expressed cleanly through the stack-based API, it doesn't get added.

**What went wrong**: The one-data-structure approach means you can't optimize for specific patterns. LuaJIT had to build its own specialized array/hash representations to get real speed. The C API stack-based calling convention is error-prone and tedious for complex bindings.

**Steal**: The table hybrid (array part + hash part with implicit size calculation). The upvalue open/closed migration trick. The discipline of "if we add a mechanism, we must remove a policy."

---

## 2. Wren — The Readable Tiny VM

**Size**: Under 4,000 semicolons across the VM. ~11 .c files in src/vm/. You can read the entire thing in an afternoon.

**Key decisions:**

- **Single-pass compiler**: No AST. Tokens come in, bytecode goes out. One token of lookahead, one of lookbehind. This severely limits what syntax is possible (no complex expression forms, no multi-pass type analysis) but the compiler is tiny. `wren_compiler.c` is the biggest file (~4000 lines) and it IS the parser, analyzer, and code generator all at once.

- **Stack-based VM** (unlike Lua's register-based): Simpler to implement, slightly more instructions generated, but the compiler is much simpler because you don't need register allocation.

- **Class-based, not prototype-based**: Unlike Lua/JS, Wren has real classes. But classes are first-class values. Methods are stored in a flat array indexed by a global method ID, so dispatch is just `class->methods[methodID]` — O(1), no hash lookup.

- **Fibers as the concurrency primitive**: Cooperative multitasking built into the VM from day one. A fiber is just a separate stack + instruction pointer. Context switch = swap which fiber is active. No threads, no locks, no complexity.

- **Embedding API is slot-based**: Instead of Lua's raw stack manipulation, Wren uses numbered slots. Less flexible but much harder to get wrong.

**What went wrong**: The single-pass constraint made some features impossible to add later. Wren never got a large ecosystem because the language limitations (driven by implementation simplicity) made it feel too constrained for non-embedded use. Bob Nystrom moved on to write Crafting Interpreters (which teaches Wren-like techniques) and the project lost momentum.

**Steal**: The single-pass compiler approach (if your language syntax is designed for it from the start). Fiber = stack + IP, nothing more. Method dispatch as array index, not hash lookup.

---

## 3. Janet — Full Language in 375KB

**Size**: The amalgamated `janet.c` is ~30,000 lines. Total binary footprint ~375KB. Single header `janet.h` for embedding.

**How it packs so much in:**

- **Amalgamation build**: All source concatenated into one .c file. The compiler can see everything, optimize across module boundaries, eliminate dead code. This is why Janet is 375KB and not 1MB.

- **PEG parsing built in**: Instead of regex (which would need a big library), Janet includes a PEG (Parsing Expression Grammar) engine as a core feature. PEGs are more powerful than regex, and the implementation is ~2000 lines. This one decision means Janet can parse complex formats without external dependencies.

- **NaN-boxing for values**: All Janet values fit in 64 bits by exploiting IEEE 754 NaN representation. Pointers, integers, booleans, nil — all packed into a double. Zero overhead for type checks (just mask off some bits). This eliminates the need for tagged union structs.

- **Struct vs Table split**: Janet has immutable structs (hash once, read many) AND mutable tables. The struct can use a simpler implementation (frozen after creation, no resize logic needed).

- **Built-in FFI (since 1.23.0)**: Uses libffi under the hood on x86-64. Lets you `ffi/native` to load a .so/.dylib, declare function signatures in Janet syntax, and call them directly. No C compilation needed for bindings. The tradeoff: it's slower than native C bindings and platform-limited.

**What went wrong**: The FFI is x86-64 only (not ARM64 until recently). NaN-boxing means you can't have 64-bit integers without boxing them to the heap. The Lisp syntax (s-expressions) turns away developers who would otherwise love the runtime.

**Steal**: Amalgamation as a distribution strategy — ship one .c file, done. PEG as a built-in parsing primitive instead of regex. NaN-boxing if you want a dynamic typed layer.

---

## 4. Nelua — Lua Syntax, C Output, No Runtime

**Size**: Compiler is written in Lua (~15K lines of Lua). Generates clean, readable C.

**The codegen trick:**

- **Lua syntax → type-annotated AST → C source → GCC/Clang**: The entire compiler is a Lua program. It parses Nelua code, type-checks it, then emits C. The generated C is meant to be human-readable. You can debug it with gdb/lldb and read the output.

- **No runtime, no GC by default**: Unlike Lua, Nelua has no garbage collector. Memory management is manual or via arenas. This means the generated C has zero runtime dependencies — it's just the C standard library.

- **Compile-time metaprogramming via Lua**: Since the compiler IS Lua, your Nelua code can contain `##` preprocessor blocks that are arbitrary Lua code running at compile time. This Lua code can modify the AST, generate code, compute types. It's hygienic macros on steroids, and it costs zero lines of dedicated macro implementation — it's just "run Lua during compilation."

- **C interop is trivial**: Since the output is C, calling C functions means just declaring them with the right types. No FFI layer, no marshaling. The compiler emits a `#include` or an `extern` declaration and you're done.

**What went wrong**: Small community. The "compiler written in Lua" means you need Lua installed to bootstrap. Compile times are slower than they should be because of the Lua→C→native double compilation. The metaprogramming is powerful but poorly documented.

**Steal**: Compiler-as-Lua-program (or compiler-as-Rail-program) for maximum hackability. The `##` preprocessor that runs the host language at compile time. Clean C output that humans can read and debug.

---

## 5. Odin — FFI That Doesn't Suck

**Size**: Large compiler (~100K+ lines), but the FFI design is what matters.

**The FFI design:**

```
foreign import libc "system:c"

foreign libc {
    printf :: proc(fmt: cstring, #c_vararg args: ..any) -> i32 ---
    malloc :: proc(size: c.size_t) -> rawptr ---
    free   :: proc(ptr: rawptr) ---
}
```

That's it. `foreign import` names a library. `foreign <name> { }` block declares functions with `---` meaning "body is elsewhere." Default calling convention inside foreign blocks is "c". No wrappers, no code generation step, no binding libraries.

**Key decisions:**

- **`cstring` type**: A dedicated type for C's zero-terminated strings, separate from Odin's length-prefixed strings. The type system enforces the conversion, preventing bugs.

- **`[^]T` multi-pointer**: C-style pointer-to-array-of-T. Different from Odin's normal pointers/slices. Exists solely for FFI — acknowledges that C's pointer model is different and gives it a first-class type rather than pretending it doesn't exist.

- **`@(link_prefix="SDL_")`**: Attribute that auto-prefixes all function names in a foreign block. So you write `Init` in Odin but it links to `SDL_Init`. Eliminates repetitive prefixing without code generation.

- **Platform-conditional imports**: `when ODIN_OS == .Windows do foreign import foo "foo.lib"` — library selection at compile time per platform, right next to the declarations.

**What went wrong**: Odin passes an implicit context pointer as the last argument to all Odin procedures. This wastes a register when calling foreign code. The FFI is great for calling C FROM Odin, but exposing Odin functions TO C requires explicit `export` annotations and awareness of the context parameter.

**Steal**: The `foreign import` + `foreign { }` block syntax. The `cstring` type as a first-class FFI type. Link prefix attributes. Platform-conditional `when` clauses for library paths.

---

## 6. Nim — Compile Through C

**Size**: Nim compiler is ~100K+ lines of Nim (self-hosted). But the C codegen strategy is the idea.

**How it works:**

1. Nim source → AST (parser)
2. AST → semantic checking + type inference (multiple passes, macros expand here)
3. Typed AST → "transf" pass (desugars closures, iterators, exception handling into simpler forms)
4. Transformed AST → C code generator emits .c files into `nimcache/` directory
5. GCC/Clang/MSVC compiles .c → binary

**Why compile through C:**

- **Instant portability**: Runs anywhere C runs. Microcontrollers, phones, mainframes. Zero effort.
- **Free optimizations**: GCC/Clang have 40 years of optimization passes. Nim doesn't need to reimplement any of them.
- **Free C interop**: Calling C is just... calling C. The output IS C. `{.importc: "printf", header: "<stdio.h>".}` is the entire FFI for one function.
- **Debuggable output**: The nimcache .c files are readable. You can step through them in gdb.

**The transf pass is the key insight**: Before generating C, Nim rewrites high-level constructs (closures → struct + function pointer, iterators → state machines, try/except → setjmp/longjmp or C++ exceptions) into forms that map directly to C. This pass is where the complexity lives — the C codegen itself is relatively straightforward tree-walking.

**What went wrong**: Generated C is NOT platform-independent — code generated on Linux won't compile on Windows. Nim's GC (now ARC/ORC) must be reflected in the generated C, which adds runtime complexity. The nimcache directory is a mess to manage. Compile times are slow because of the double-compilation.

**Steal**: The transf pass pattern — desugar everything complex before touching codegen. The `nimcache` directory approach for inspectable intermediate output. `{.importc.}` pragma for zero-ceremony C interop.

---

## 7. Crystal — The Global Inference Trap

**Size**: Self-hosted compiler. Uses LLVM for codegen. Large project (~300K+ lines).

**Architecture:**

1. Lexer → tokens
2. Parser → AST
3. **Global type inference** → fully-typed AST (the expensive part)
4. CodeGenVisitor → LLVM IR
5. LLVM → native binary

**The type inference approach:**

Crystal has Ruby-like syntax with NO type annotations required. The compiler figures out all types globally. `x = 1` → x is Int32. `x = "hello"` → x is String. If a function gets called with both, x is `Int32 | String` (a union type). Method resolution depends on knowing all possible types at every call site.

**Why this is both brilliant and disastrous:**

- Brilliant: You write Ruby-looking code and get C-speed binaries.
- Disastrous: The compiler must analyze the ENTIRE program to resolve types. No separate compilation. Every change recompiles everything. Large Crystal projects hit 30-60 second compile times. The team had to redesign the inference algorithm to make it tractable.

**C interop:**

```crystal
lib LibC
  fun printf(format : UInt8*, ...) : Int32
end

LibC.printf("hello %d\n", 42)
```

This compiles to a direct C function call. No overhead. Crystal's `lib` blocks are essentially Odin's `foreign` blocks.

**What went wrong**: Global type inference doesn't scale. No incremental compilation. The compiler is written in Crystal, so bootstrapping is painful (you need a working Crystal to build Crystal). Fibers exist but true parallelism (multi-core) is still incomplete as of 2026.

**Steal**: The `lib` block syntax for C interop. Union types as the answer to "what if a variable could be multiple types." The cautionary tale — global inference is a trap for compiled languages; do local inference with explicit function signatures instead.

---

## 8. JSON Parsing — The Simplest Correct Way

**jsmn approach** (~500 lines of C, header-only):

jsmn does NOT build a data structure. It's a tokenizer only. Given `{"name": "Rail", "version": 1}`, jsmn produces:

```
Token 0: OBJECT  [0..33]  (3 children)
Token 1: STRING  [2..6]   "name"
Token 2: STRING  [10..14]  "Rail"
Token 3: STRING  [17..24]  "version"
Token 4: PRIMITIVE [27..28] "1"
```

Tokens are `{type, start, end, children_count}`. No memory allocation for strings — tokens point into the original JSON buffer (zero-copy). The caller walks tokens to extract what they need. This is the simplest correct approach because:

1. No allocator needed (caller provides a fixed token array)
2. No string copies (offsets into source buffer)
3. No recursive data structure (flat token array)
4. Full JSON spec compliance (strings, numbers, booleans, null, nested objects/arrays)
5. Handles malformed JSON (returns error codes)

**For a compiled language like Rail, the minimum viable JSON parser is:**

1. A tokenizer function: `json_tokenize(input: string) -> [Token]` (~200 lines)
2. Token type: `{kind: enum, start: int, end: int, size: int}`
3. Helper functions: `json_get(tokens, key)`, `json_string(token, source)` (~50 lines)

Total: ~300 lines for a working, zero-allocation JSON parser. No need for a JSON "value" tree — the flat token array IS the parsed representation.

**Alternative — recursive descent**: ~150 lines for the parser, but requires heap allocation for the value tree (objects, arrays, strings). Simpler API but more memory.

**Steal**: The jsmn flat-token, zero-copy approach. Perfect for a language that doesn't have a GC yet. Token = {kind, start, end, size} is the entire data model.

---

## 9. Memory Management — Minimum Viable Approaches

### Bump Allocator (~15 lines)

```
struct Bump { char *base; char *ptr; char *end; };
void *bump_alloc(Bump *b, size_t size) {
    size = (size + 7) & ~7;  // align to 8
    if (b->ptr + size > b->end) return NULL;
    void *p = b->ptr;
    b->ptr += size;
    return p;
}
void bump_reset(Bump *b) { b->ptr = b->base; }
```

Allocation is a pointer increment. Deallocation is "reset everything." Individual frees are impossible. Perfect for: compiler passes, request handling, frame-scoped game data.

### Arena Allocator (~50-100 lines)

An arena is a bump allocator that chains multiple blocks. When the current block fills, allocate a new block and link it. Free = walk the chain and free all blocks.

```
struct Arena {
    Block *current;   // current block being bumped into
    Block *first;     // head of block chain
};
```

Core operations: `arena_alloc()` (bump or new block), `arena_reset()` (reset all blocks, keep memory), `arena_free()` (return all memory to OS). Tsoding's implementation is ~300 lines as a polished single-header library. The core logic is ~50 lines.

### Simple Mark-and-Sweep GC (~200-400 lines)

Bob Nystrom's "Baby's First Garbage Collector" is ~200 lines and handles the core algorithm:
1. Mark phase: walk roots (stack, globals), follow pointers, set mark bit
2. Sweep phase: walk all allocated objects, free unmarked ones, clear marks
3. Trigger: when total allocated bytes exceeds a threshold (typically 2x the live set after last collection)

The minimum: a linked list of all heap objects, a mark bit per object, a root set. That's it.

### What to use for Rail (recommendation):

**Phase 1 (now)**: Arena allocator. All allocations bump forward. Functions that need temporary memory get a scratch arena. Long-lived data goes in a persistent arena. No individual frees. Reset arenas at well-defined points (after a request, after a compilation pass, etc.).

**Phase 2 (later, if needed)**: Add a simple GC for the dynamic/scripting layer only. Keep arenas for the compiler and performance-critical paths.

**Phase never**: Reference counting. It's more complex than a simple GC, can't handle cycles without a cycle collector (which IS a GC), and the inc/dec overhead is measurable.

---

## 10. Simplest FFI That Actually Works

### Level 0: Known signatures at compile time (~10 lines per function)

If Rail compiles to native code, and you know the function signature at compile time:

```
// Rail compiler emits this:
extern int64_t some_c_function(int64_t a, double b);
// ... then just calls it normally
```

This is what Odin, Nim, Crystal, and Nelua do. The "FFI" is just emitting the right extern declaration and calling convention. Zero overhead. Zero lines of FFI runtime. The linker does the work.

For Rail compiling to ARM64: emit a `BL` to an external symbol, let the linker resolve it. The calling convention (x0-x7 for int args, d0-d7 for float args, x0 for return) must match. That's it.

### Level 1: dlopen/dlsym for dynamic loading (~30 lines)

```c
void *lib = dlopen("libfoo.dylib", RTLD_NOW);
typedef int64_t (*add_fn)(int64_t, int64_t);
add_fn f = (add_fn)dlsym(lib, "add");
int64_t result = f(40, 2);  // calls libfoo's add()
```

This works when you know the signature at compile time but want to load the library at runtime. Rail's compiler can emit the dlopen/dlsym calls and the typedef. ~30 lines of generated C or ~20 ARM64 instructions.

**Limitation**: You must know the function signature at compile time. The cast from `void*` to a typed function pointer is what makes it work — the compiler generates the right calling convention code.

### Level 2: libffi for fully dynamic calls (~50 lines per call site)

Only needed if Rail wants to call functions whose signatures are determined at RUNTIME (e.g., a plugin system, or calling functions described in a config file). Uses `ffi_prep_cif` to describe the signature, then `ffi_call` to invoke.

**Recommendation for Rail**: Level 0 is sufficient. Rail compiles to ARM64 Mach-O. C functions are just external symbols. Emit the right calling convention (ARM64 AAPCS), link against the library. The FFI is literally just:

```rail
@foreign("libSystem.B.dylib")
fn write(fd: i64, buf: *u8, len: i64) -> i64
```

The compiler sees `@foreign`, emits an extern declaration + BL instruction, adds the library to the link command. Done. That's ~50 lines of compiler code to support, not 50 lines per call.

For dlopen-style dynamic loading, add ~100 lines of runtime support (a `load_library` and `get_symbol` builtin). This gives you Level 1 for free.

---

## Summary: What Rail Should Steal

| From | Idea | Effort |
|------|------|--------|
| Lua | Hybrid array+hash table | Medium |
| Lua | Open/closed upvalue trick for closures | Low |
| Lua | "Mechanisms not policies" discipline | Free |
| Wren | Single-pass compiler (if syntax allows) | Already doing |
| Wren | Fiber = stack + IP | Low |
| Janet | Amalgamation for distribution | Free |
| Janet | PEG as built-in parsing primitive | Medium |
| Nelua | Compile to C as a backend option | Medium |
| Nelua | Host language runs at compile time (`##`) | Rail already has this potential |
| Odin | `foreign import` + `foreign {}` block syntax | Low |
| Odin | `cstring` as dedicated FFI type | Low |
| Nim | Transf pass: desugar before codegen | Medium |
| Nim | `{.importc.}` zero-ceremony C calls | Low |
| Crystal | Union types for multi-typed variables | Medium |
| Crystal | AVOID global type inference | Free (don't do it) |
| jsmn | Zero-copy flat-token JSON parsing | Low (~300 lines) |
| Arena | Arena allocator as primary memory strategy | Low (~50 lines core) |
| FFI | Level 0: extern + BL instruction, ~50 lines of compiler support | Low |

### The 80/20 for Rail's next moves:

1. **Arena allocator** — 50 lines, replaces malloc/free for everything
2. **Foreign function syntax** — `@foreign` attribute, ~50 lines of compiler changes, unlocks all of C
3. **jsmn-style JSON** — 300 lines, zero-copy, no GC needed
4. **Upvalue trick** — if closures need to capture variables, use Lua's open/closed pointer migration

Sources:
- [Small is Beautiful: the design of Lua (Stanford slides)](https://web.stanford.edu/class/ee380/Abstracts/100310-slides.pdf)
- [A Look at the Design of Lua (CACM 2018)](https://www.lua.org/doc/cacm2018.pdf)
- [The Implementation of Lua 5.0](https://www.lua.org/doc/jucs05.pdf)
- [Lua Table Implementation Notes](https://poga.github.io/lua53-notes/table.html)
- [Closures in Lua (Ierusalimschy & de Figueiredo)](https://www.cs.tufts.edu/~nr/cs257/archive/roberto-ierusalimschy/closures-draft.pdf)
- [Wren Language](https://wren.io/)
- [Wren GitHub](https://github.com/wren-lang/wren)
- [Janet Language](https://janet-lang.org)
- [Janet FFI Documentation](https://janet-lang.org/docs/ffi.html)
- [Nelua Language](https://nelua.io/)
- [Nelua GitHub](https://github.com/edubart/nelua-lang)
- [Odin: Binding to C](https://odin-lang.org/news/binding-to-c/)
- [Nim Backend Integration](https://nim-lang.github.io/Nim/backends.html)
- [Nim Compiler Internals](https://nim-lang.github.io/Nim/intern.html)
- [Crystal DeepWiki](https://deepwiki.com/crystal-lang/crystal)
- [jsmn JSON Parser](https://zserge.com/jsmn/)
- [Arena Allocator Tips and Tricks (nullprogram)](https://nullprogram.com/blog/2023/09/27/)
- [Memory Allocation Strategies (gingerBill/Odin creator)](https://www.gingerbill.org/article/2019/02/08/memory-allocation-strategies-002/)
- [Tsoding Arena Allocator](https://github.com/tsoding/arena)
- [libffi with dlopen (Eli Bendersky)](https://eli.thegreenplace.net/2013/03/04/flexible-runtime-interface-to-shared-libraries-with-libffi)
- [Crafting Interpreters: Closures](https://craftinginterpreters.com/closures.html)
