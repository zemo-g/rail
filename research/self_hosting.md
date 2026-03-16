# Self-Hosting Compilers & Bootstrapping: Research for Rail

Research compiled 2026-03-16. Sources cited inline.

---

## 1. Go: C-to-Go Machine Translation (2014-2015)

### The Approach
Go's compiler was written in C from 2007 to 2014. Rather than rewrite from scratch, Russ Cox built `cmd/c2go`, an automatic C-to-Go translator. The output was intentionally ugly — it was a **mechanical translation**, not a rewrite. The resulting Go code looked like C with Go syntax.

### The Five-Phase Plan
1. Develop `c2go` translator capable enough to convert the existing C compiler
2. Use translator to convert compilers from C to Go, **delete the C copies** — compiler is now Go but still "a C program in disguise"
3. Use `gofix`-like tools to split into packages, clean up, add tests — turn it into **idiomatic Go**
4. Profile and optimize memory/CPU, potentially add parallelization
5. Replace the front end with `go/parser` and `go/types`

Phase 2 shipped in Go 1.5 (August 2015). Phases 3-5 are still ongoing over a decade later.

### What Went Wrong
- **Bootstrap chain keeps growing.** Go 1.5 required Go 1.4 to build. Go 1.20 required Go 1.17. Go 1.22 requires Go 1.20. Pattern now: Go 1.N requires Go 1.(N-2 rounded to even). Every year the minimum bumps. This is the long tail of self-hosting — you need *yourself* to build yourself, forever.
- **Go 1.4 couldn't run on modern hardware.** M1 Macs (darwin/arm64) aren't supported by Go 1.4, so the original bootstrap path is broken on new machines.
- **Russ Cox on the chicken-and-egg bug:** When trying to fix a compiler bug, he found the code to fix the bug *triggered* the bug, so it couldn't be compiled. This is the fundamental self-hosting trap.
- **Build time for bootstrap:** The 3-step build (build Go 1.x compiler with Go 1.4, then rebuild Go 1.x with itself) added only ~20 seconds on a MacBook Pro. Surprisingly cheap.

### Why They Waited to Self-Host
Cox explicitly argued **against** bootstrapping early: "If the Go compiler had been the first big Go program, that use case would have had undue influence on the language design." They wanted Go to be shaped by server software, not compiler needs.

### Rail Insight
- Machine translation is viable for the Rust->Rail transition. Ugly output is fine — clean up later.
- The bootstrap chain growth problem is real. Zig's WASI approach (below) solves this.
- **Don't let the compiler be your first real program.** Rail already has HTTP serving, dashboard deploy, and tooling written in Rail — this is the right order.

Sources:
- [Go 1.5 Bootstrap Plan](https://go.googlesource.com/proposal/+/master/design/go15bootstrap.md)
- [Go 1.3+ Compiler Overhaul](https://docs.google.com/document/u/0/d/1P3BLR31VA8cvLJLfMibSuTdwTuF7WWLux71CYD0eeD8/mobilebasic)
- [Go, from C to Go (Russ Cox talk)](https://go.dev/talks/2014/c2go.slide)
- [Bootstrap version bumps](https://github.com/golang/go/issues/54265)

---

## 2. Rust: OCaml to Self-Hosting (2010-2011)

### The Approach
The original Rust compiler (`rustboot`) was ~38,000 lines of OCaml with a hand-written x86 code generator. The self-hosted `rustc` used LLVM as backend instead of hand-written codegen.

### Timeline
- **2010**: rustboot written in OCaml, targeting x86 with hand-written codegen
- **April 20, 2011**: First self-compilation. **Took one hour.** Laughably slow, but it worked.
- **May 13, 2011**: OCaml rustboot **deleted** — just 23 days after first self-compile. Graydon Hoare threw it away because there wasn't enough manpower to maintain two implementations.

### What Was Surprisingly Hard
The hardest part was **not the bootstrapping itself** — it was the **long-term compile time damage**. Key failure mode:

1. First self-compile took 1 hour (bad codegen, fixable bugs)
2. Performance improved enough to be tolerable
3. Graydon deleted OCaml compiler — no going back
4. Team became **acclimated** to slow compile times
5. Nobody recognized the severity during Rust's crucial early design phase
6. Compile times became a permanent language-level problem (monomorphization, deep type checking)

The "Rust Compilation Model Calamity" essay argues this was one of the most consequential early mistakes. The team **normalized** bad compile times because they were always working in the self-hosted compiler where slow was the baseline.

### Rail Insight
- **Delete the seed compiler early** — Graydon did it 23 days after self-compile. Maintaining two implementations is a resource drain for a small team.
- **But measure compile times obsessively from day one.** Rust's failure was normalizing slowness. Rail should have a compile-time benchmark that runs on every commit.
- 38,000 lines of OCaml for a seed compiler is large. Rail's Rust implementation is much smaller — this is an advantage.

Sources:
- [Rust Compilation Model Calamity](https://idiks.com/blog/rust-compilation-model-calamity/)
- [HN: rustboot OCaml implementation](https://news.ycombinator.com/item?id=6932601)
- [Rust Wikipedia](https://en.wikipedia.org/wiki/Rust_(programming_language))

---

## 3. Zig: The WASI Bootstrap Binary (2020-2022)

### The Approach
Zig's compiler was originally written in C++. Andrew Kelley spent **years** rewriting it in Zig using data-oriented design. The self-hosted compiler shipped in Zig 0.10 (November 2022).

### The Key Innovation: WASI Bootstrap Seed
Instead of requiring "Zig N-1 to build Zig N" (Go's growing chain problem), Zig commits a **WebAssembly binary** to the repo:

1. `zig build update-zig1` produces a WASI binary using LLVM backend
2. Binary is optimized with `wasm-opt -Oz` → 2.4 MiB
3. Compressed with zstd → **655 KB** committed to source control
4. Any system with a WASI runtime can bootstrap from this blob
5. Jacob Young then built a **wasm2c** converter (4,000 lines of C) that converts the WASM to C, letting you bootstrap with just a C compiler

This means: **constant-time bootstrap from any commit.** No chain. No "find Go 1.17 to build Go 1.20."

### Performance Numbers
- Old C++ compiler: **9.6 GB RAM** to build itself
- New self-hosted compiler: **2.8 GB RAM** — 3.4x reduction
- Build time: 13m20s (C++ path, 10.3 GiB peak) vs 10m53s (WASI path, 3.2 GiB peak)
- The memory savings came from **data-oriented design** — struct-of-arrays instead of OOP, careful arena allocation

### Design Decisions
- **No LLVM dependency for bootstrap.** LLVM is used for optimized builds but the bootstrap path avoids it entirely.
- **WebAssembly as universal seed format.** WASI is OS-agnostic, subject to LLVM optimization, and simple enough to interpret.
- **wasm2c is 4,000 lines** vs a full WASI interpreter at 60,000 lines. Converting WASM to C and using the system C compiler is effectively JIT compilation for free.

### Rail Insight
- **The WASI seed approach is brilliant for Rail.** Once Rail compiles to ARM64, produce a small seed binary and commit it. No chain growth.
- The wasm2c trick is clever but Rail targets ARM64 directly — a simpler approach would be to commit a Mach-O binary or a hex dump of one.
- 655 KB for a compiler seed is the benchmark to beat. Rail's compile.rail output should be trackable in size.
- Data-oriented design matters for compiler performance. Rail's AST representation will determine memory behavior.

Sources:
- [Goodbye to the C++ Implementation of Zig](https://ziglang.org/news/goodbye-cpp/)
- [Zig Is Self-Hosted Now, What's Next?](https://kristoff.it/blog/zig-self-hosted-now-what/)
- [WASI bootstrap PR #13560](https://github.com/ziglang/zig/pull/13560)
- [The Grand Bootstrapping Plan](https://github.com/ziglang/zig/issues/853)

---

## 4. Hare: No Dependencies, 3.5-Minute Bootstrap

### The Approach
Drew DeVault designed Hare to be bootstrappable from scratch with **no LLVM, no GCC dependency**. The backend is QBE — a compiler backend that aims for "70% of the performance of LLVM in 10% of the code."

### Key Numbers
- **Full bootstrap from scratch: 3.5 minutes** including building QBE, building harec, and running all tests
- Compare: bootstrapping LLVM alone takes 30-60 minutes on fast hardware
- QBE is ~14,000 lines of C. LLVM is millions.

### Design Philosophy
- The build driver was the **first fully bootstrapped Hare program** — chosen deliberately as a good first target
- Standard library includes `hare::lex`, `hare::parse`, `hare::types` — the compiler's own parse/type-check infrastructure is in stdlib
- This means any Hare program can parse and analyze Hare code — metaprogramming via library, not macros

### Bootstrap Path
1. Build QBE (C, ~14K lines)
2. Build harec (the Hare compiler, initially in C)
3. Build the Hare build driver (in Hare)
4. Rebuild harec in Hare using itself

### What Went Right
- QBE produces **good enough** code. The 70% performance target is pragmatic — most programs aren't bottlenecked on codegen quality.
- 3.5-minute bootstrap means developers can verify the full chain regularly.
- No LLVM means no 30GB build dependency.

### Rail Insight
- **QBE's philosophy maps directly to Rail's ARM64 codegen.** Rail doesn't need LLVM-quality optimization — it needs correct, fast-to-produce ARM64 code. 70% of optimal is fine.
- **3.5 minutes is the target.** If Rail's bootstrap takes longer than that, something is wrong.
- Putting compiler infrastructure in the standard library (lexer, parser, type checker) is smart. Rail should expose its own AST manipulation as Rail functions.
- **The build driver as first self-hosted program** is a good pattern. Rail's `compile.rail` is already this.

Sources:
- [Hare's path to a self-hosting toolchain](https://harelang.org/blog/2021-03-14-a-self-hosting-toolchain/)
- [Announcing Hare](https://harelang.org/blog/2022-04-25-announcing-hare/)
- [Introduction to QBE (FOSDEM 2022)](https://archive.fosdem.org/2022/schedule/event/lg_qbe/attachments/slides/4878/export/events/attachments/lg_qbe/slides/4878/qbe.pdf)
- [QBE Users](https://c9x.me/compile/users.html)

---

## 5. cproc: Self-Hosting C11 in ~8,000 Lines

### The Approach
Michael Forney's cproc is a C11 compiler using QBE as backend. Written in C. Self-hosting. ~8,000 lines of code.

### What It Can Build
Despite its size, cproc can compile: **itself, GCC 4.7, binutils, util-linux, BearSSL, git, and u-Boot.** This is not a toy — it's a functional C11 compiler that builds real-world software.

### What It Deliberately Omits
- No variable-length arrays (VLAs)
- No thread-local storage
- No position-independent code (no shared libraries, no PIE)
- No inline assembly
- No preprocessor (uses an external one)
- No digraphs (will never be implemented)

### The Design Choice
cproc proves that a **useful** self-hosting compiler doesn't need to be complete. By omitting features that are rarely needed for bootstrapping (VLAs, TLS, PIC), the implementation stays small enough for one person to maintain and understand.

### Rail Insight
- **8,000 lines is the reference point for a minimal self-hosting compiler.** Rail's compile.rail should aim for this ballpark.
- The "useful subset" strategy works. Rail doesn't need closures, advanced strings, or every feature to self-host — it needs enough to compile the compiler.
- Using an external preprocessor/tool for what you don't need is pragmatic. Rail can shell out for things that aren't worth implementing yet.
- **QBE keeps appearing** — it's the go-to backend for minimal compilers. Rail's direct ARM64 output is actually simpler than using QBE.

Sources:
- [cproc on SourceHut](https://sr.ht/~mcf/cproc/)
- [cproc on GitHub](https://github.com/michaelforney/cproc)

---

## 6. Small Self-Hosting Languages (Under 5,000 Lines)

### Rui Ueyama's chibicc (~10,000 lines, self-hosting C)
Written as a teaching compiler. The key methodology: **one commit = one feature.** Started with a "compiler" that accepted a single number, then added one language feature per commit until reaching C11. Based on Abdulaziz Ghuloum's "An Incremental Approach to Compiler Construction" paper.

Architecture: Tokenize -> Preprocess -> Parse (recursive descent) -> Codegen (direct x86-64)

**This is the exact approach Rail is taking.** Incremental, one feature at a time, self-hosting as the goal.

### 8cc (Ueyama's earlier compiler, ~1,000 lines at first self-host)
The first version of 8cc became self-hosting after ~1,000 lines. After 40 days, it was a full C11 compiler. Ueyama's retrospective: he'd use yacc for parsing and introduce an intermediate representation earlier. Hand-written recursive descent was faster to start but harder to extend.

### mini-js (~1,000 lines, self-hosting JavaScript subset)
A minimal self-hosted JavaScript compiler in 1K lines that can compile itself. Proves the concept that you can achieve self-hosting with absurdly little code if you restrict the language subset.

### Starforth (Forth, self-hosting from assembler)
A Forth variant that bootstraps with nothing but an assembler. Forth is cheating for self-hosting because the language is so minimal, but the **approach** — start from assembler, build up — is instructive.

### QSCM (Scheme, compiles to C)
A bootstrapped Scheme compiler that compiles to C. Uses C as the "assembly language" target — compile Scheme to C, compile C with cc, done.

### Onramp (C, bootstraps from hex)
A remarkable project that bootstraps a full C17 compiler from **raw hexadecimal machine code**:
1. Hex tool (handwritten machine code) — converts commented hex to bytes
2. VM (handwritten hex) — runs simple bytecode
3. Minimal linker — resolves labels
4. Assembler — custom assembly language
5. Minimal C compiler — tiny C subset
6. Partial C99 compiler
7. Full C17 compiler

Each stage is plain text, human-readable. The first two stages are the only platform-specific code. Can compile DOOM.

### Rail Insight
- **1,000 lines is the minimum viable self-hosting point** (8cc proves this for C). Rail's compile.rail is already at 8/8 tests — how many lines is it?
- The Ghuloum incremental approach (one feature per commit) is exactly right. Keep doing this.
- **Onramp's staged approach** is the gold standard for trust. Rail could theoretically bootstrap from a hex ARM64 seed, but that's overkill — the Rust interpreter is a fine seed.
- Compiling to C (QSCM approach) is a cheat code for portability. Rail compiles to ARM64 directly, which is better for performance but worse for portability.

Sources:
- [chibicc on GitHub](https://github.com/rui314/chibicc)
- [How I wrote a self-hosting C compiler in 40 days](https://www.sigbus.info/how-i-wrote-a-self-hosting-c-compiler-in-40-days)
- [Onramp on GitHub](https://github.com/ludocode/onramp)
- [mini-js on GitHub](https://github.com/maierfelix/mini-js)
- [QSCM](https://c9x.me/qscm/)
- [Starforth](https://www.elektito.com/2023/06/28/starforth-1/)

---

## 7. Terra: Lua + LLVM — What Worked and What Didn't

### The Approach
Terra (Zachary DeVito, Stanford) is a two-language system: Lua is the meta-language, Terra is the low-level language. Terra code compiles to LLVM IR and runs at C speed. Lua code runs at interpretation time and can generate/manipulate Terra code.

### What Worked
- **Performance:** Terra code runs within 5% of equivalent C/Clang output
- **JIT integration:** Terra code can be JIT-compiled and run interleaved with Lua — runtime code generation is a first-class operation
- **Simplicity of the split:** Instead of C++'s Frankenstein of preprocessor + templates + constexpr, you have exactly two languages with a clean boundary

### What Didn't Work
- **Abandoned by creator.** DeVito moved on (to Meta AI, working on PyTorch). Maintained by a single person.
- **Documentation is broken.** The `defer` keyword exists but isn't documented. Features that don't exist yet ARE documented. The website lies.
- **Build system is fragile.** CMake doesn't work with LLVM 7 without undocumented flags. Linux compilation is unreliable.
- **Dynamic typing tax.** Because Lua is dynamically typed, metaprogramming requires constant `:istype()` and `:isstruct()` checks throughout. No compile-time type safety for the meta-level.
- **LLVM dependency.** LLVM is huge, changes constantly, and Terra must track it. This is a maintenance burden that killed the project for a solo maintainer.
- **The niche is too small.** High-performance computing people use Fortran/C++/CUDA. Language enthusiasts want to write their own thing. Nobody wants to learn Lua + Terra + LLVM.

### Rail Insight
- **The two-language approach has merit but the maintenance burden kills solo projects.** Rail being one language that interprets and compiles itself avoids this.
- **LLVM is a trap for small projects.** Terra, Zig (originally), and many others got burned by LLVM's size and churn. Rail's direct ARM64 codegen avoids this entirely.
- **If the creator leaves, the project dies.** Rail must be simple enough that it can survive without you. Self-hosting helps here — the language documents itself.
- The dynamic typing problem is real. Rail's type system (even if simple) for compiler internals is an advantage over Lua/Terra.

Sources:
- [Terra language](https://terralang.org/)
- [A Rant on Terra](https://erikmcclure.com/blog/a-rant-on-terra/)
- [On the State of Terra in 2022](https://elliottslaughter.com/2022/05/state-of-terra)
- [The Design of Terra (Stanford paper)](https://cs.stanford.edu/~zdevito/snapl-devito.pdf)

---

## 8. Jai: Compile-Time Everything (Jonathan Blow)

### The Approach
Jai's core innovation: **any function can run at compile time.** No special macro language, no separate build system, no template metaprogramming. `#run` takes any function and executes it during compilation, with full read-write access to the AST.

```
// This is Jai pseudocode
#run generate_entity_system();  // Runs at compile time, inserts code into the program
```

### Key Design Decisions
- **Compiler is the build system.** No Makefiles, no CMake, no cargo. The compiler runs your build logic as `#run` directives.
- **AST is a runtime data structure.** Compile-time code can inspect and modify the program's syntax tree. This replaces templates, macros, and code generation.
- **Target: 1 million lines per second.** Public demos show 80,000 lines compiling in under 1 second. This is ~10x faster than optimized C++ compilation.
- **No LLVM.** Custom backend. This is necessary for the speed target — LLVM's optimization passes are too slow for interactive compilation.
- **Still in closed beta** as of February 2026. Expected to open after Blow's game "Order of the Sinking Star" ships in 2026.

### What's Unique
The `#run` + AST manipulation approach means:
- Build scripts are Jai code
- Code generation is Jai code
- Data baking (converting assets to compiled data) is Jai code
- Test harnesses are Jai code
- Everything is one language, one compiler, one mental model

### What's Risky
- 16+ years in development (started ~2010), still closed beta
- Single person bottleneck (Blow)
- No open-source path announced
- The "compile-time everything" approach increases compiler complexity enormously

### Rail Insight
- **`#run` is the right idea.** Rail's effects system could provide something similar — compile-time code execution with structured access to the program.
- **1 million lines/second is the gold standard** for compile speed. Rail should track lines/second from day one.
- **No LLVM is correct for speed.** Blow confirms what Hare/QBE also show — LLVM is too slow for fast iteration.
- **The single-person bottleneck is a warning.** Jai has been in development for 16 years because one person is doing everything. Rail needs to self-host and open-source to avoid this fate.
- Compile-time AST access is more powerful than macros. Worth considering for Rail's design — let Rail programs inspect and generate Rail code.

Sources:
- [Jai Primer](https://github.com/BSVino/JaiPrimer/blob/master/JaiPrimer.md)
- [Jai in 2026](https://www.mrphilgames.com/blog/jai-in-2026)
- [Jai, the game programming contender](https://bitshifters.cc/2025/04/28/jai.html)
- [Jai Wikipedia](https://en.wikipedia.org/wiki/Jai_(programming_language))

---

## 9. Seed Compilers & Bootstrapping Chains: Best Practices

### The Trusting Trust Problem
Ken Thompson (1984): A compiler can be modified to insert a backdoor. The backdoor propagates through every future compiler binary, even if the source is clean. Once the attack is in the binary, inspecting source code cannot detect it.

### Defense: Diverse Double-Compiling (DDC)
David Wheeler's formally proven defense: compile the same source with two independently-developed compilers. If both produce identical output, neither contains a hidden backdoor. GNU Mes team demonstrated this across three distributions (Guix, Nix, Debian) with different GCC versions — bit-for-bit identical results.

### The Bootstrappable Builds Movement
Goal: minimize the "binary seed" — the smallest trusted binary you need to start from.

**stage0 project**: Starts from machine code small enough for humans to disassemble **by hand** (~512 bytes). Progressively builds up to a Scheme interpreter, then a C compiler.

**GNU Mes + MesCC**: Reduced the trusted binary seed by ~120MB (half of previous requirement).

**Onramp**: Bootstraps from commented hexadecimal machine code, building through 8 stages to a full C17 compiler.

### Alex Kladov's "Reasonable Bootstrap" (matklad)
Key argument: WebAssembly is the ideal seed format because:
1. **Target-agnostic** — describes abstract computation independent of host architecture
2. **Simple** — easy to implement a WASM interpreter in anything
3. **Deterministic** — compiling bootstrap sources with the .wasm blob produces a byte-for-byte identical .wasm blob
4. **Constant-time bootstrap** — any version of the language can be bootstrapped without walking a chain

This is exactly what Zig adopted.

### Best Practices Summary
1. **Keep the seed small.** Zig: 655 KB compressed. Onramp: a few KB of hex.
2. **Make the seed verifiable.** Either human-readable (Onramp) or deterministically reproducible (Zig).
3. **Avoid chain growth.** Don't require version N-1 to build version N. Use a fixed seed format.
4. **Test reproducibility.** Same source + same seed = same binary, across machines.
5. **Document the bootstrap path.** Every step from seed to working compiler should be explicit.

### Rail Insight
- **Commit a seed binary to the repo.** Once compile.rail produces working ARM64 Mach-O binaries, check in a compressed binary. This is the Rail seed.
- **Verify reproducibility.** Rail seed binary from Rust interpreter should match Rail seed binary from Rail self-compile.
- **The Rust interpreter IS the seed compiler.** It's small, readable, and can be audited. This is fine for now.
- **Long-term: produce a hex-auditable seed** like Onramp if trust verification matters. For a private project, the Rust seed is sufficient.

Sources:
- [Reasonable Bootstrap (matklad)](https://matklad.github.io/2023/04/13/reasonable-bootstrap.html)
- [Trusting Trust (Wheeler)](https://dwheeler.com/trusting-trust/)
- [About Bootstrapping (notgull)](https://notgull.net/bootstrapping/)
- [Finding the Bottom Turtle](https://blog.dave.tf/post/finding-bottom-turtle/)

---

## 10. What Makes a Self-Hosting Compiler USEFUL vs Just a Proof of Concept

### The Proof-of-Concept Trap
Many self-hosting compilers exist that can compile themselves and nothing else. They demonstrate the concept but have no practical value. The distinguishing factors:

### What Makes It Useful

**1. It can compile other programs, not just itself.**
cproc compiles git, GCC 4.7, binutils, and u-Boot. That's useful. A compiler that only compiles itself is a circular proof of nothing.

**2. It improves when you use it to develop itself.**
The core argument for self-hosting: developers find bugs and missing features by dogfooding. Rust's self-hosting found real language design issues. But only if you pay attention to the pain points (Rust failed on compile times because they normalized the pain).

**3. Error messages are good.**
A self-hosting compiler that produces "segfault" on bad input is useless for anyone else. Error reporting is the difference between a tool and a demo.

**4. It's fast enough for interactive development.**
If compile-edit-test cycles take more than a few seconds, developers will avoid changing the compiler. Hare's 3.5-minute full bootstrap is the upper bound. Incremental compilation should be under 1 second.

**5. It has platform independence.**
Self-hosting enables cross-compilation: add support for a new target, cross-compile the compiler itself to that target. This is one of the strongest practical arguments.

**6. Someone other than the author can modify it.**
If the compiler is so complex that only the author understands it, self-hosting provides no community benefit. Simplicity and documentation matter.

### The Progression from PoC to Useful
1. **PoC**: Compiler compiles itself (Rail is nearly here)
2. **Viable**: Compiler compiles itself + can build 2-3 non-trivial programs
3. **Useful**: Compiler has good errors, reasonable speed, and can be modified by others
4. **Production**: Compiler is the primary development tool for all programs in the language

### Rail Insight
- **Rail is at the PoC->Viable boundary.** compile.rail works (8/8 tests). Next milestone: compile bootstrap.rail with compile.rail. That's the self-compile proof.
- **After self-compile, target "useful" immediately:** good error messages, fast compilation, ability to build the site deploy tool and other Rail programs.
- **The real test: can someone else write Rail?** Self-hosting only matters if the language is usable by humans. Error messages and documentation are the differentiator.
- **Track these metrics from now:**
  - Lines of Rail compiled per second
  - Peak memory during compilation
  - Binary size of compiled output
  - Number of non-compiler Rail programs that compile successfully

Sources:
- [What is self-hosting, and is there value in it?](https://dev.to/mortoray/what-is-self-hosting-and-is-there-value-in-it-2p9p)
- [Self-hosting (compilers) Wikipedia](https://en.wikipedia.org/wiki/Self-hosting_(compilers))
- [Kalyn: a self-hosting compiler for x86-64](https://intuitiveexplanations.com/tech/kalyn)

---

## Summary: What Rail Should Steal

| From | Steal This | Avoid This |
|------|-----------|------------|
| Go | Machine translation for migration | Growing bootstrap chain |
| Rust | Delete seed compiler fast (23 days) | Normalizing slow compile times |
| Zig | WASI/binary seed committed to repo (655KB) | Multi-year rewrite timeline |
| Hare | QBE-style "70% perf, 10% code" backend | — |
| cproc | Useful subset (8K lines, builds git) | Feature completionism |
| chibicc | One feature per commit, incremental | — |
| Terra | — | LLVM dependency, two-language maintenance |
| Jai | `#run` compile-time execution, no LLVM | 16-year single-person bottleneck |
| Onramp | Staged bootstrap with human-readable steps | Over-engineering trust chain |
| matklad | Deterministic reproducible seed binary | — |

### Rail's Concrete Next Steps (derived from research)
1. **Self-compile:** compile.rail compiles compile.rail. This is THE milestone.
2. **Commit a seed binary** to the Rail repo. Compressed ARM64 Mach-O. Track its size.
3. **Measure lines/second** from the first self-compile. Never let it regress.
4. **Delete `src/` (Rust)** within weeks of self-compile, not months. Maintain momentum.
5. **Build non-compiler programs** with the self-hosted compiler immediately. deploy_site.rail, bootstrap.rail. Prove it's useful.
6. **Keep the compiler under 10,000 lines** of Rail. cproc does C11 in 8K. Rail is simpler than C.
