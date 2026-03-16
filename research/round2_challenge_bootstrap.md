# Round 2: Challenging Rail's Bootstrap Assumptions

**Date**: 2026-03-16
**Purpose**: Devil's advocate research — strongest arguments AGAINST our current plan

---

## 1. "Delete the Seed Compiler Fast" — COUNTERARGUMENTS

### The Rust Cautionary Tale (It's Worse Than You Think)

You cite Rust deleting OCaml in 23 days as a success story. It was not. The consequences are still being paid:

- **Bootstrapping Rust 1.81 takes 3.5 hours** compared to OCaml's 3 minutes and 17 seconds — 63x slower. The Rust source tree is 1.9GB, 50 million lines across 276K files. OCaml needs 500K lines total. ([source](https://www.ntecs.de/blog/2026-02-01-bootstrapping-rust-considered-harmful/))
- **Each Rust version must be bootstrapped by exactly the previous version.** Compiling from source to a modern Rust requires building ~100 intermediate compilers, keeping a build machine busy for 10+ days. ([source](https://www.ntecs.de/blog/2026-02-01-bootstrapping-rust-considered-harmful/))
- **No bootstrap compiler exists in any other language.** This created a hard circular dependency. The community had to create mrustc (a C++ reimplementation) just to break the cycle. mrustc skips borrow checking entirely and outputs ugly C — it exists purely because deleting OCaml was a mistake. ([source](https://github.com/thepowersgang/mrustc))
- **Security and sovereignty concerns**: Developers in restricted countries must download binary compilers from US servers. Supply chain vulnerability is real. ([source](https://www.ntecs.de/blog/2026-02-01-bootstrapping-rust-considered-harmful/))

### Projects That KEPT Their Bootstrap Compiler

**GHC (Haskell) maintains THREE backends**: C, NCG (native code generator), and LLVM.

| Backend | Compile Time | Runtime | Purpose |
|---------|-------------|---------|---------|
| NCG | baseline | baseline | Default, fastest compilation |
| LLVM | +22.7% slower | -4.5% faster | Numeric/array-heavy code, SIMD |
| C (unregistered) | slowest | slowest | **Porting to new platforms** |

The C backend exists specifically so GHC can bootstrap to **any platform with a C compiler**. The prerequisite tools reduce to just gcc, as, and ld. This is the definition of "kept it and benefited." ([source](https://andreaspk.github.io/posts/2019-08-25-Opinion%20piece%20on%20GHC%20backends.html))

**Jai keeps LLVM for release builds** while using a custom fast backend for debug builds. This dual-backend approach gives 100Kloc/second compilation during development AND full LLVM optimization for shipping. Jonathan Blow didn't delete LLVM — he added a fast path alongside it. ([source](https://news.ycombinator.com/item?id=21762981))

### The D Language Catch-22

D (DMD) went self-hosted. When someone tried to port it to OpenBSD:
- The build system tries to download a bootstrap DMD binary — but none exists for your platform
- You need a D compiler to build DMD, but you don't have one
- Solution required finding GDC (GNU D Compiler, written in C++), bootstrapping from that, then building DMD
- This took significant community effort and platform-specific debugging

**Verdict**: Deleting your seed compiler creates a portability prison. Every new platform requires heroic bootstrapping effort. ([source](https://briancallahan.net/blog/20211013.html))

### What This Means for Rail

**Keep the Rust interpreter.** Or at minimum, keep a C-emitting backend. The cost of maintaining it is low. The cost of not having it — when you want to port to RISC-V, or someone wants to build from source on a platform you didn't anticipate — is enormous.

---

## 2. "70% of LLVM Performance Is Fine" — COUNTERARGUMENTS

### The Actual Numbers Are Worse Than 70%

QBE's own documentation claims "70% of the performance of industrial optimizing compilers in 10% of the code." But the real benchmarks tell a different story:

- **BearSSL compiled with cproc (QBE frontend)**: Tests ran in 62.87s vs GCC's 43.79s — that's **43% slower**, not 30%. ([source](https://lobste.rs/s/ivvs8p/qbe_small_x64_compiler_backend_pure_c))
- **SpecCPU on Intel i7-9700K**: QBE achieved "almost 80% performance" vs GCC -O2 — but this varies wildly by workload. Some workloads hit 75%, others hit 25% of LLVM performance. ([source](https://archive.fosdem.org/2022/schedule/event/lg_qbe/))
- **QBE doesn't do SIMD at all.** Any workload that benefits from vectorization gets 0% of that performance. ([source](https://tilde.team/~kiedtl/blog/hare/))

### Where 70% Performance KILLS You

The 70% claim assumes uniform degradation. Reality is non-uniform:

- **Tight loops**: Without loop unrolling, strength reduction, or vectorization, inner loops can be 2-5x slower
- **Numeric code**: QBE's lack of SIMD means crypto, physics, audio, and ML workloads are devastated
- **Memory-bound code**: Without alias analysis and proper scheduling, cache utilization suffers

**Hare's experience**: The language explicitly chose QBE and explicitly chose not to support macOS or Windows. Critics argue these decisions together ensure Hare will "not replace a fraction of the C code that's been written." The performance ceiling IS a contributing factor to limited adoption. ([source](https://tilde.team/~kiedtl/blog/hare/))

### The Odin Warning

Odin used LLVM and found it consumed **85-90% of total compilation time**. But rather than abandoning LLVM, they're building a custom backend (Tilde) **alongside** LLVM — not replacing it. The LLVM backend stays for release builds. ([source](https://odin.handmade.network/blog/p/2210-working_on_a_custom_backend_for_odin))

Even Odin's creator, who has every reason to hate LLVM, won't delete it.

### What This Means for Rail

70% average means some workloads hit 50%. If Rail ever compiles anything compute-bound — its own compiler included — you'll feel it. The correct strategy may be Jai/Odin's: fast custom backend for development, LLVM (or C backend piped to GCC) for release.

---

## 3. "Commit a Binary Seed to the Repo" — COUNTERARGUMENTS

### Git Problems at Scale

- Binary files cause **repository bloat that is permanent**. Every update to the seed binary adds its full size to history. You cannot diff binaries meaningfully. ([source](https://robinwinslow.uk/dont-ever-commit-binary-files-to-git))
- Cloning and branch switching slow down considerably with committed binaries. Removing them requires **rewriting history**, which is extremely dangerous for a public repo. ([source](https://fekir.info/post/git-and-binary-files/))
- Git LFS exists as a mitigation but adds infrastructure dependency.

### The Trust Problem (Ken Thompson's Attack)

Ken Thompson's 1984 Turing Award lecture demonstrated that a compiler binary can contain a backdoor that **self-propagates into every future version compiled by it** — invisible in the source code. This is not theoretical paranoia; it's the foundational security concern of compiler bootstrapping. ([source](https://www.sumitchouhan.com/when-the-compiler-lies-lessons-from-reflections-on-trusting-trust-and-the-science-of-verifiable-software))

Committing a binary seed means users must **blindly trust** that seed. With Zig's WASM approach, critics noted: "users currently need to have blind faith that updates to the WASM blob aren't malicious." ([source](https://lobste.rs/s/g55iso/goodbye_c_implementation_zig))

### The Guix Alternative: Full-Source Bootstrap

GNU Guix has achieved something remarkable: a package graph of **22,000+ nodes rooted in a 357-byte program**. Their bootstrap chain:

1. `hex0` — a 357-byte binary (human-auditable hex pairs)
2. Progressively builds assemblers, then a minimal C compiler (GNU Mes)
3. Builds GCC 4.7, then modern GCC
4. Full system from auditable source

This is the gold standard for trust. A 357-byte seed vs. a multi-megabyte WASM blob. ([source](https://guix.gnu.org/en/blog/2023/the-full-source-bootstrap-building-from-source-all-the-way-down/))

### Zig's WASI Approach: Criticized More Than You'd Expect

- The generated C file from wasm2c is **181MB from a 2.6MB WASM source**. Critics called this "clearly broken." ([source](https://lobste.rs/s/g55iso/goodbye_c_implementation_zig))
- The 6-step bootstrap process was criticized as "pretty complicated" — bootstrap processes should be "bullet-proof." ([source](https://lobste.rs/s/g55iso/goodbye_c_implementation_zig))
- Critics asked: why not just compile Zig directly to C? The WASM intermediary adds complexity without clear benefit. ([source](https://lobste.rs/s/g55iso/goodbye_c_implementation_zig))
- Alternative suggestion: ship the compiler as **portable C** (like Nim does) instead of WASM.

### What This Means for Rail

If you commit a binary seed, use Git LFS and keep it small. But seriously consider the alternative: **emit C from your compiler**. Then the seed is just C source — human-auditable, diffable, and trustworthy. No binary trust problem at all.

---

## 4. "Direct ARM64 Codegen Is Better Than Compiling Through C" — COUNTERARGUMENTS

### The Case FOR Compiling Through C

This is where the evidence most strongly contradicts your assumption.

**Nim's approach** — compile to C, let the platform's C compiler optimize:
- Runs on **any platform with a C compiler** — embedded microcontrollers to servers
- Gets GCC/Clang's optimizer for free: loop unrolling, vectorization, alias analysis, instruction scheduling
- Cross-compilation is trivial: just point at a different C compiler
- No separate optimizer needed: "Nim has no separate optimizer, but the C code that is produced is very efficient. Most C compilers have excellent optimizers." ([source](https://nim-lang.org/docs/backends.html))

**Chicken Scheme's approach** — CPS transform to C:
- Translates Scheme to Continuation Passing Style, then emits C functions that never return
- GCC can **inline C code into compiled Scheme and vice-versa** because they're in the same file
- The machine's stack pointer serves as an allocation register — fast allocation
- `call/cc` comes for free as a consequence of the CPS transform
- Compiles to executables on any platform with GCC ([source](https://wiki.call-cc.org/chicken-compilation-process))

**Gambit Scheme's approach** — portable C output:
- Programs compile for Linux, macOS, Windows, and any Unix — from the same source
- Inline C in Scheme files with `(c-include)` and `(c-lambda)` — zero-cost FFI
- Ship executables without requiring users to install a runtime ([source](https://en.wikipedia.org/wiki/Gambit_(Scheme_implementation)))

**Cakelisp's approach** — transpile to C/C++:
- Human-readable C output: you can debug the generated code with GDB and Valgrind
- No runtime to port (hot-reloading is optional and uses standard `dlopen`)
- "Projects using Cakelisp are just as portable as any C/C++ project"
- Compile-time metaprogramming: macros can inspect and modify the AST before C emission ([source](https://macoy.me/blog/programming/CakelispIntro))

### Specific Advantages of C Backend Over Direct Codegen

1. **Portability**: C runs everywhere. ARM64-only codegen means Rail is ARM64-only forever (or until you write more backends).
2. **Optimization**: GCC -O2 gives you decades of optimization research for free. Your Rail codegen would need to implement each optimization manually.
3. **Debugging**: Generated C can be stepped through in GDB/LLDB. Your generated ARM64 needs custom DWARF emission — a massive undertaking.
4. **Tooling**: Valgrind, AddressSanitizer, profilers all work on C output. Direct ARM64 codegen needs explicit support.
5. **Maintenance**: GCC/Clang handle new CPU features (SVE, SME). Direct codegen must be updated for each new ARM extension.
6. **FFI**: C interop is trivial when your output IS C.

### The Counter-Counter: Why Direct Codegen Exists

Direct codegen has ONE clear advantage: **compilation speed**. No subprocess spawning, no C compiler in the loop. Jai compiles 100Kloc/second with its custom backend.

But Nim compiles fast enough for most purposes. And you can always cache the C output.

### What This Means for Rail

A C backend would give Rail instant portability to x86-64, ARM64, RISC-V, WASM (via Emscripten), and any platform with GCC. Your current ARM64-only codegen is a strategic limitation. Consider: keep the direct ARM64 codegen for speed, but ADD a C backend for portability and optimization. This is exactly what GHC, Jai, and Odin do.

---

## 5. "Keep the Compiler Under 10K Lines" — COUNTERARGUMENTS

### Why Compilers Grow

**Go's compiler** has 37+ optimization passes in its SSA backend alone. Each pass is necessary:
- Dead code elimination
- Nil check elimination
- Register allocation
- Escape analysis
- Bounds check elimination
- Inlining decisions
- Architecture-specific rewrites

That's just the backend. The frontend needs: parser, type checker, generic instantiation, module system, error reporting with source locations, incremental compilation state. ([source](https://segflow.github.io/post/go-compiler-optimization/))

**Swift's type checker** alone is a cautionary tale: checking 12 lines of code can take **42 seconds on an M1 Pro** due to exponential constraint solving. Complex type systems demand complex implementations. ([source](https://danielchasehooper.com/posts/why-swift-is-slow/))

**Rust's compiler** started at ~38,000 lines of OCaml. Today it's millions of lines of Rust. The growth was forced by:
- Borrow checker
- Trait resolution
- Macro expansion
- Incremental compilation
- Error diagnostics (Rust's error messages are a feature)
- Multiple codegen backends

### What Forces Growth Past 10K

Based on compiler history, these features consistently blow the budget:

| Feature | Typical Cost | Why |
|---------|-------------|-----|
| Error messages with context | 1-3K lines | Source mapping, span tracking, helpful suggestions |
| Generics/parametric polymorphism | 2-5K lines | Monomorphization or dictionary passing |
| Closures with captures | 500-2K lines | Upvalue analysis, closure conversion |
| Pattern matching compilation | 500-1K lines | Decision tree or backtracking automaton |
| Module/import system | 1-2K lines | Dependency resolution, visibility |
| Standard library (in-language) | 2-10K lines | Must be compiled by your compiler |
| Debug info emission | 1-3K lines | DWARF generation for any real debugging |
| Register allocation | 500-2K lines | Even linear scan |
| Multiple backends | 2-5K lines each | Each target architecture |
| Incremental compilation | 2-5K lines | Dependency tracking, cache invalidation |

A realistic minimum for a useful self-hosted compiler with decent error messages, closures, and one backend: **15-25K lines**.

### The Self-Hosting Tax

Self-hosting acts as a complexity brake — any feature added must also work in the compiler. But this cuts both ways: if your compiler lacks a feature (say, hashmaps), you must work around it everywhere in the compiler code, adding boilerplate that inflates line count in a different way.

### What This Means for Rail

10K lines is achievable only if Rail stays minimal: no generics, no complex type system, no debug info, basic error messages, one backend. The moment you want any of these, you'll blow past 10K. Plan for 15-25K realistically, or accept that the 10K compiler will produce a language too limited for serious use.

---

## 6. "No LLVM Is Correct for Speed" — COUNTERARGUMENTS

### LLVM's Compile-Time Cost Is Real But Overstated

For the Cone compiler (a small language): LLVM consumed **99.3% of total compilation time**. Frontend took 800us, LLVM took 115,500us. But here's the breakdown:

| Stage | Time | % of LLVM |
|-------|------|-----------|
| Setup | 2,500us | 2% |
| Generate IR | 11,000us | 10% |
| Verify IR | 3,000us | 3% |
| Optimize | 15,000us | 13% |
| Object file generation | 84,000us | **73%** |

Object file generation dominates — not optimization. Even removing all optimization passes only saves 13% of LLVM's time. The bottleneck is LLVM's code generation infrastructure itself. ([source](https://pling.jondgoodwin.com/post/compiler-performance/))

### LLVM Alternatives Exist But Are Immature

- **Cranelift**: Rust-based, designed for fast compilation. But still developing, limited platform support.
- **QBE**: 10K lines of C. But no SIMD, unmaintained at times, limited architectures.
- **libFirm**: Academic, limited adoption.

None match LLVM's breadth. The "no LLVM" choice means writing your own optimizer or accepting permanently inferior code quality.

### Julia's Cautionary Tale

Julia chose LLVM for JIT compilation. Result: **first function call is dramatically slow** (the "time-to-first-plot" problem). Every new type signature triggers fresh LLVM compilation. The community has spent years building workarounds (PackageCompiler.jl, system images, precompilation). ([source](https://news.ycombinator.com/item?id=26519251))

But they can't leave LLVM because the performance of compiled code IS Julia's value proposition. They're trapped — LLVM is too slow to compile but too good to give up.

### Odin's LLVM Pain

Odin found LLVM consumed **85-90% of compilation time**. Additionally:
- LLVM generates debug information incorrectly, causing miscompilation
- LLVM passes structs through the stack even when they fit in registers
- LLVM's ABI handling has bugs for non-C languages

Yet Odin is building a SECOND backend (Tilde) — not removing LLVM. The release path through LLVM stays. ([source](https://odin.handmade.network/blog/p/2210-working_on_a_custom_backend_for_odin))

### V Language: What Happens Without LLVM or a C Backend

V (vlang) promised fast compilation with direct codegen. Critics found:
- "Fast compilation doesn't do much optimization"
- "If/when it does optimize, it won't be as fast anymore (and probably will reinvent LLVM in the process)"
- No points for compiled code performance in direct-to-machine-code mode
- The language has persistent criticism about undelivered performance claims ([source](https://mawfig.github.io/2022/06/18/v-lang-in-2022.html))

### What This Means for Rail

"No LLVM" is correct for **compilation speed**. But it means accepting a permanent performance ceiling on generated code — unless you build your own optimizer, which grows the compiler well past 10K lines. The escape hatch is a C backend: compile to C, run through GCC -O2 for release builds. You get 95%+ of LLVM performance without touching LLVM.

---

## 7. Criticisms of Zig, Hare, and Jai

### Zig Criticisms

- **WASM bootstrap is over-engineered**: Critics asked "why not just emit C directly?" The WASM→C path produces 181MB of C from 2.6MB WASM — "clearly broken." ([source](https://lobste.rs/s/g55iso/goodbye_c_implementation_zig))
- **Bootstrap chain is complex**: Six steps. "Bootstrap processes should be bullet-proof," not elaborate.
- **Binary trust problem**: Users must trust the WASM blob isn't malicious. No practical auditability.
- **WebAssembly itself is complex**: Control-flow integrity, memory safety features, WASI for I/O — "there's a lot more in the embedding than just WebAssembly." Simpler VMs exist. ([source](https://lobste.rs/s/gnt3fr/reasonable_bootstrap))

### Hare Criticisms

- **QBE performance varies 25-75%** of LLVM depending on workload — not consistently 70%. ([source](https://vfoley.xyz/hare/))
- **No SIMD support at all** — entire categories of software are impossible.
- **QBE appears unmaintained** at times — sustainability risk. ([source](https://tilde.team/~kiedtl/blog/hare/))
- **No generics**: Must reimplement hash tables from scratch. Language design doesn't even allow providing them as a library. ([source](https://ayende.com/blog/197185-B/criticizing-hare-language-approach-for-generic-data-structures))
- **No macOS, no Windows**: "Deliberately choosing not to support them means you're not going to replace a fraction of the C code written." ([source](https://tilde.team/~kiedtl/blog/hare/))
- **No ownership tracking**: Programs are open to use-after-free and double-free bugs.

### Jai Criticisms

- **Still not publicly available** years after announcement — vapor risk
- **LLVM is still used for release builds** — the custom backend doesn't replace it
- Multiple backends (first was C→compile→link, current is custom, plus LLVM) suggest no single approach was sufficient
- Closed development means limited external validation

---

## 8. Languages That Died From Premature Self-Hosting

No language has publicly "died" solely from premature self-hosting, but the pattern manifests as **chronic disability**:

- **D**: Self-hosting created the OpenBSD catch-22. Every new platform requires finding an alternative D compiler (GDC, LDC) just to bootstrap. Only 4 platforms are officially supported by the D Language Foundation. ([source](https://briancallahan.net/blog/20211013.html))
- **Rust**: Self-hosting + mandatory version-chain bootstrapping means building from source is essentially impractical for individuals. mrustc exists as community life support. ([source](https://guix.gnu.org/en/blog/2018/bootstrapping-rust/))
- **The general pattern**: Self-hosting doesn't kill languages directly. It kills *portability* and *bootstrappability*. The language lives on but can never reach platforms the maintainers don't actively support.

The real risk isn't death — it's **calcification**. Once self-hosted, the language can only evolve as fast as the compiler (written in the language) allows. If you self-host before the language is mature, every language change requires updating the compiler in a language that's still changing. This is a recursive instability.

---

## 9. The "Compile Through C" Strategy — Deep Dive

### Chicken Scheme

**Architecture**: Scheme → CPS transform → C functions that never return → GCC

Key insight: By transforming to Continuation Passing Style, Chicken makes continuations (and therefore threads, coroutines, and call/cc) zero-cost. The C stack IS the nursery generation of the GC. Stack pointer serves as allocation pointer.

**Why this works**:
- GCC optimizes the generated C aggressively, including cross-language inlining
- CPS conversion eliminates the need for a Scheme runtime stack
- Tail calls compile to C tail calls (or jumps with GCC's TCO)
- Minimal garbage retained: only free variables in closure records
- Portable to any platform with GCC

([source](https://wiki.call-cc.org/chicken-compilation-process))

### Gambit Scheme

**Architecture**: Scheme → optimized intermediate → portable C

Gambit emphasizes **embedding C in Scheme** — `(c-include)`, `(c-lambda)`, `(c-define)` let you write C directly in Scheme files. GCC optimizes and inlines across the boundary because it's all one compilation unit.

**Why this works**:
- Complete portability: Linux, macOS, Windows, any Unix
- Zero-cost C FFI: C code IS the output
- Ship standalone executables without runtime dependencies
- Decades of proven production use

([source](https://www.deusinmachina.net/p/gambit-c-scheme-and-c-a-match-made))

### Cakelisp

**Architecture**: S-expressions → compile-time macro expansion → C/C++

Unique feature: compile-time code execution modifies the AST before C emission. Hot reload via `dlopen` — optional, no runtime dependency if unused.

**Why this works**:
- Human-readable C output: debug with standard tools
- No runtime to port
- Compile-time metaprogramming without a complex type system
- "Projects using Cakelisp are just as portable as any C/C++ project"

([source](https://macoy.me/blog/programming/CakelispIntro))

### Nim

**Architecture**: Nim → semantic analysis → C code → platform C compiler

Nim is the strongest existence proof that compiling through C works at scale. It has a real community, package ecosystem, and production users.

**Why this works**:
- "Porting Nim to a new architecture is pretty easy, since C is the most portable programming language"
- Supports GCC, Clang, MSVC, MinGW — any C compiler
- Cross-compilation is built-in
- Runs "from the tiniest micro-controllers to mobile apps to servers"
- Multiple backend options: C, C++, Objective-C, JavaScript

([source](https://nim-lang.org/docs/backends.html))

### Summary: Why C Backends Win

| Property | Direct ARM64 | C Backend |
|----------|-------------|-----------|
| Compilation speed | Fast (no subprocess) | Slower (invokes cc) |
| Output optimization | Only what you implement | GCC -O2 for free |
| Platform support | ARM64 only | Everywhere |
| Debugging | Need DWARF emission | GDB/LLDB/Valgrind work |
| FFI | Manual ABI work | C interop is free |
| New CPU features | Manual updates | GCC handles it |
| SIMD | Must implement | GCC auto-vectorizes |
| Maintenance | High | Low |

---

## 10. Register Allocation — Does Rail Need It?

### The Performance Cost of Not Having It

**Without register allocation** (everything on the stack):
- Every value loads from memory, computes, stores back
- On x86 (register-limited): **20% increase in dynamic memory accesses** ([source](https://en.wikipedia.org/wiki/Register_allocation))
- On ARM64 (31 GPRs): penalty is smaller but still significant for tight loops

**With even basic allocation**:
- **Linear scan** achieves within **5-10% of optimal** (graph coloring) on SPEC benchmarks
- Linear scan is **15-68x faster to compile** than graph coloring
- A "fast, simple algorithm usually achieves performance within 12% of optimal register allocation on a machine with 31 general purpose registers" ([source](https://web.cs.ucla.edu/~palsberg/course/cs132/linearscan.pdf))

### ARM64-Specific Considerations

ARM64 has 31 general-purpose registers. This is generous — it masks poor allocation. But:

- **Spilling to stack**: Each spill costs a load-store pair. ARM64 has excellent load-store unit, but it still hurts in tight loops.
- **Research shows** spill-to-register optimization gives ~10% improvement on AArch64 workloads
- **Without allocation**: You're leaving 10-20% performance on the table on ARM64, and 20-40% on x86-64

### The Practical Answer

**For bootstrapping: No.** Register allocation is not needed to get a self-hosting compiler working. Stack-only codegen is fine.

**For a language anyone would use: Yes.** Even linear scan (500-1000 lines of code) gets you within 10% of optimal. Without it, your compiler produces code that's measurably slower than GCC -O0 in many cases.

**The C backend escape hatch**: If Rail emits C, GCC handles register allocation for you. Problem solved without adding a single line of register allocator code to Rail.

---

## Summary: The Strongest Arguments Against the Current Plan

### Critical Risks

1. **ARM64-only codegen is a strategic trap.** Every other successful "compile through C" language (Nim, Chicken, Gambit) has instant portability. Rail can't run on x86-64, RISC-V, or WASM. A C backend costs ~2K lines and gives you the world.

2. **Deleting the Rust seed creates a bootstrapping prison.** D, Rust, and every self-hosted language without an alternative implementation has this problem. Keep the Rust interpreter OR add a C backend before deleting it.

3. **The 70% performance claim is marketing.** Real benchmarks show 57-80% depending on workload, with zero SIMD. The missing 30-43% is not uniformly distributed — some workloads are devastated.

4. **10K lines is a fantasy for a useful compiler.** Realistic self-hosted compilers with decent error messages, closures, and one backend need 15-25K lines. Plan accordingly or accept severe language limitations.

### Recommended Changes

| Current Plan | Proposed Alternative | Rationale |
|---|---|---|
| Delete Rust seed fast | Keep Rust interpreter indefinitely | Portability, bootstrapping safety |
| ARM64 codegen only | Add C backend (primary), keep ARM64 (fast path) | Portability, free optimization, tooling |
| Commit binary seed | Emit C from compiler; seed is C source | Trust, auditability, diffability |
| No LLVM ever | No LLVM, but C→GCC for release builds | 95% of LLVM quality without LLVM dependency |
| Under 10K lines | Budget 15-20K lines | Realistic for closures + errors + stdlib |
| No register allocator | Let GCC handle it via C backend | Zero implementation cost, optimal output |

### The Strongest Single Argument

**Add a C backend.** It solves portability (runs anywhere), performance (GCC -O2 for free), debugging (GDB/Valgrind), trust (no binary seed needed), register allocation (GCC handles it), SIMD (GCC auto-vectorizes), and maintenance (GCC handles new CPU features). It costs ~2K lines of code. Every "compile through C" language in history has validated this approach. Direct ARM64 codegen can remain as a fast-compilation option, but the C backend should be the primary output target.

---

## Sources

- [Bootstrapping Rust Considered Harmful](https://www.ntecs.de/blog/2026-02-01-bootstrapping-rust-considered-harmful/)
- [mrustc — Alternative Rust Compiler](https://github.com/thepowersgang/mrustc)
- [GHC Backend Opinion Piece](https://andreaspk.github.io/posts/2019-08-25-Opinion%20piece%20on%20GHC%20backends.html)
- [Packaging DMD for OpenBSD](https://briancallahan.net/blog/20211013.html)
- [QBE vs LLVM](https://c9x.me/compile/doc/llvm.html)
- [QBE FOSDEM Talk](https://archive.fosdem.org/2022/schedule/event/lg_qbe/)
- [Hare Impressions](https://vfoley.xyz/hare/)
- [Hare Criticisms (kiedtl)](https://tilde.team/~kiedtl/blog/hare/)
- [Hare Generics Criticism](https://ayende.com/blog/197185-B/criticizing-hare-language-approach-for-generic-data-structures)
- [Compiler Performance and LLVM](https://pling.jondgoodwin.com/post/compiler-performance/)
- [How Bad Is LLVM Really](https://c3.handmade.network/blog/p/8852-how_bad_is_llvm_really)
- [Odin Custom Backend](https://odin.handmade.network/blog/p/2210-working_on_a_custom_backend_for_odin)
- [V Language Review 2022](https://mawfig.github.io/2022/06/18/v-lang-in-2022.html)
- [Zig Goodbye C++ (Lobsters)](https://lobste.rs/s/g55iso/goodbye_c_implementation_zig)
- [Reasonable Bootstrap (matklad)](https://matklad.github.io/2023/04/13/reasonable-bootstrap.html)
- [Chicken Compilation Process](https://wiki.call-cc.org/chicken-compilation-process)
- [Gambit Scheme and C](https://www.deusinmachina.net/p/gambit-c-scheme-and-c-a-match-made)
- [Cakelisp Introduction](https://macoy.me/blog/programming/CakelispIntro)
- [Nim Backend Integration](https://nim-lang.org/docs/backends.html)
- [GHC Backends Documentation](https://ghc.gitlab.haskell.org/ghc/doc/users_guide/codegens.html)
- [Jai Compiler Info](https://github.com/Ivo-Balbaert/The_Way_to_Jai/blob/main/book/04A_More_info_about_the_compiler.md)
- [Linear Scan Register Allocation](https://web.cs.ucla.edu/~palsberg/course/cs132/linearscan.pdf)
- [Register Allocation (Wikipedia)](https://en.wikipedia.org/wiki/Register_allocation)
- [Guix Full-Source Bootstrap](https://guix.gnu.org/en/blog/2023/the-full-source-bootstrap-building-from-source-all-the-way-down/)
- [Ken Thompson Trusting Trust](https://www.sumitchouhan.com/when-the-compiler-lies-lessons-from-reflections-on-trusting-trust-and-the-science-of-verifiable-software)
- [Swift Type Checker Slowness](https://danielchasehooper.com/posts/why-swift-is-slow/)
- [Julia LLVM Startup](https://news.ycombinator.com/item?id=26519251)
- [Bootstrapping Rust (Guix)](https://guix.gnu.org/en/blog/2018/bootstrapping-rust/)
- [Go SSA Optimization](https://segflow.github.io/post/go-compiler-optimization/)
- [Git and Binary Files](https://fekir.info/post/git-and-binary-files/)
