# Round 2: Challenge the Runtime Assumptions

**Date**: 2026-03-16
**Purpose**: Adversarial research against Rail's six core runtime assumptions
**Verdict**: Three assumptions hold with caveats, two need redesign, one is actively dangerous

---

## 1. "FFI is the ecosystem cheat code — 50 lines gives you all of C"

### The Claim
FFI into C libraries replaces the need for a stdlib. Minimal wrapper code, maximum capability.

### The Counter-Evidence

**It's not 50 lines. It's 50 lines plus an infinite maintenance surface.**

- **ABI Hell is real**: clang and gcc have historically failed to pass `__int128` between each other correctly. There is no "C ABI" — there are platform-specific calling conventions that compilers implement differently. The [ABI Cafe](https://faultlore.com/blah/abi-puns/) project documents how even Rust and Swift, with dedicated ABI teams, get struct passing wrong across compiler boundaries.

- **Callback GC interaction is a showstopper**: When C code holds a function pointer back into Rail, the GC/arena can collect the closure out from under it. Node.js's `node-ffi` has a [long-standing bug](https://github.com/node-ffi/node-ffi/issues/241) where callbacks are garbage collected while C still holds pointers to them. Haskell had to add `StablePtr` specifically because safe FFI calls don't keep arguments alive. Rail will hit this exact problem the moment anyone passes a callback to a C library (libcurl, libuv, SQLite callbacks, signal handlers).

- **Memory ownership is ambiguous**: C code that calls `malloc` returns memory that Rail's arena knows nothing about. C code that receives a Rail pointer and stores it will crash after arena reset. Every FFI boundary is a potential use-after-free. Rust dedicated an entire [Rustonomicon chapter](https://doc.rust-lang.org/nomicon/ffi.html) to this and still has CVEs from FFI boundaries.

- **libffi/dyncall exist but aren't trivial**: libffi is ~60KB as a shared object and requires platform-specific assembly for each calling convention. It doesn't support callbacks on all platforms (no MIPS, limited SPARC). dyncall is smaller but requires hand-written assembly per architecture. Neither is "50 lines."

### Verdict: PARTIALLY TRUE, DANGEROUSLY INCOMPLETE
FFI gives you access to C libraries, yes. But the claim that it's cheap is wrong. The real cost is:
1. Preventing arena-allocated Rail objects from being passed to C (or pinning them)
2. Preventing C-allocated memory from leaking (or wrapping it in Rail destructors)
3. Preventing callbacks from being collected
4. Testing every library on every platform because ABI isn't portable

**Minimum viable FFI is ~500-1000 lines** counting the type marshaling, callback trampolines, and safety checks. Without those checks, you ship use-after-free as a feature.

---

## 2. "Arena reset per request, not GC" (game engine model)

### The Claim
Each HTTP request gets an arena. When the request ends, reset the arena. Zero per-object overhead. No GC pauses.

### The Counter-Evidence

**This model breaks on anything that isn't a stateless HTTP request-response cycle.**

- **WebSockets**: Connection lives for hours/days. Arena can't reset because the connection state is still alive. You either leak memory for the connection lifetime or need a separate allocation strategy. Real WebSocket servers [routinely experience](https://oneuptime.com/blog/post/2026-01-24-websocket-memory-leak-issues/view) memory growing unbounded because buffers accumulate and closures capture state.

- **Streaming responses**: SSE, chunked HTTP, LLM token streaming — the response isn't complete when you start sending. Arena reset point is... when? After the last byte? Then you've held the entire arena for the duration of the stream.

- **Coroutines/async that suspend mid-request**: If a coroutine yields (waiting for I/O), its stack frame and local variables must survive. Multiple coroutines sharing an arena means no single one can trigger a reset. This is exactly why Go has a garbage collector despite being systems-oriented.

- **Background tasks**: Request handler spawns a background job (send email, write to queue). The request arena resets, but the background job still references data from it. Use-after-free.

- **Connection pools**: Database connections, HTTP clients — these outlive any single request. Where do they live? A "global" arena that never resets? That's just malloc with extra steps.

- **Caches**: In-memory caches (LRU, session stores) hold data across requests. Arena-per-request means cache data must be copied to a long-lived region on every cache write.

### What the Game Industry Actually Does
Game engines use arenas for per-frame allocation, yes — but they ALSO have:
- A persistent heap for assets, entity state, and systems
- A per-frame scratch arena (your model)
- Often a third "double-buffered" arena for data that lives exactly 2 frames
- A traditional allocator for everything else

The game engine model is **multi-tier**, not arena-only.

### Verdict: TRUE FOR THE HAPPY PATH, BREAKS ON REAL SERVERS
Arena-per-request works for stateless REST APIs. The moment you need WebSockets, streaming, background jobs, caches, or connection pools, you need at least two tiers:
1. Per-request arena (reset on completion)
2. Long-lived heap (for connections, caches, state)

And the long-lived heap needs either manual free or GC. You've just re-introduced the thing you were avoiding.

---

## 3. "Concurrency via fork, not threads"

### The Claim
Process isolation via fork() gives you safe concurrency without shared memory bugs.

### The Counter-Evidence

**This is the most dangerous assumption. fork() is broken on macOS, which is Rail's primary platform.**

- **macOS fork() is a minefield**: Apple's official position is that [fork() without exec() is not safe on any Apple platform](https://developer.apple.com/forums/thread/747499). After fork(), Mach ports are not shared correctly. Any code that touches CoreFoundation, libdispatch, Keychain, Metal, or Objective-C runtime will crash or deadlock in the child. The error message `__THE_PROCESS_HAS_FORKED_AND_YOU_CANNOT_USE_THIS_COREFOUNDATION_FUNCTIONALITY___YOU_MUST_EXEC__` is infamous.

- **vLLM hit this exact wall**: The [vLLM project discovered](https://lxyuan0420.github.io/posts/til-vllm-metal-macos-fork-spawn) that importing Metal/ObjC libraries before fork() crashes on macOS. The fix was switching from fork to spawn. Python 3.14 is [changing its default](https://discuss.python.org/t/switching-default-multiprocessing-context-to-spawn-on-posix-as-well/21868) from fork to spawn on all POSIX platforms because of these issues.

- **fork() in multithreaded programs deadlocks**: [fork() without exec() is dangerous in large programs](https://www.evanjones.ca/fork-is-dangerous.html). Only the calling thread survives fork(). If any other thread held a mutex (including inside malloc, printf, or any library function), that mutex is locked forever in the child. The child will deadlock on the next memory allocation. This is not theoretical — it's why Google's style guide bans fork without exec.

- **IPC overhead is real**: Process-to-process communication via pipes costs [60-100ns per syscall](https://howtech.substack.com/p/ipc-mechanisms-shared-memory-vs-message) plus data copying. Shared memory avoids the copy but then you need synchronization — which is the thread problem again. For fine-grained communication (e.g., a work-stealing scheduler), IPC overhead dominates.

- **Memory overhead**: Even with copy-on-write, each forked process gets its own page tables, file descriptor tables, signal tables. macOS COW is [less efficient than Linux](https://www.wefearchange.org/2018/11/forkmacos.rst). A forked process that touches even a few pages of its heap (which any allocator will do) triggers COW faults for those pages.

- **The Erlang comparison is misleading**: Erlang BEAM processes are NOT OS processes. They're [2KB green threads](https://hauleth.dev/post/beam-process-memory-usage/) scheduled by the VM, with message passing as the only communication primitive. BEAM can run 1M processes in ~1GB. OS fork() creating 1M processes would require ~1TB of page tables alone.

### What Actually Happened to Fork-Based Servers
Apache's prefork MPM (process-per-request) was replaced by nginx's async event loop because:
- [Each Apache process used dedicated RAM](https://www.sitepoint.com/apache-vs-nginx-performance-optimization-techniques/) for the embedded PHP interpreter
- At 10K concurrent connections, Apache needed 10K processes; nginx needed 4 workers
- Nginx uses [~2.5MB per 10K inactive connections](https://www.dreamhost.com/blog/nginx-vs-apache/) vs Apache's ~2.5MB per connection

### Verdict: BROKEN ON MACOS, WRONG MODEL AT SCALE
Fork-based concurrency has three fatal problems for Rail:
1. macOS actively sabotages fork-without-exec
2. Multithreaded libraries (which includes most C libraries you'd FFI into) make fork unsafe
3. The overhead is orders of magnitude worse than green threads or async I/O

**Recommendation**: Look at Erlang-style lightweight processes (green threads with message passing) or structured concurrency (like Zig's). If you want process isolation, use `posix_spawn` + exec, not fork.

---

## 4. "Don't build a stdlib, build FFI wrappers"

### The Claim
Instead of a standard library, provide thin FFI wrappers around C libraries.

### The Counter-Evidence

**Every language that skipped a stdlib regretted it.**

- **The "ecosystem" problem**: Research on [programming language adoption](https://dl.acm.org/doi/10.1145/2509136.2509515) shows that open source libraries and existing code are the primary drivers of language adoption — more than language features. A language without a stdlib has no ecosystem seed. FFI wrappers are not an ecosystem — they're a tax on every user who has to learn both Rail and the C library's API.

- **Python's "batteries included"** is [explicitly cited](https://www.anaconda.com/blog/why-python) as a key reason for Python's dominance. Users can `import json`, `import http.server`, `import sqlite3` without installing anything. The zero-friction path to "hello world web server" matters enormously.

- **What users actually need** (the minimum viable stdlib):
  - String manipulation (split, join, trim, format, Unicode)
  - File I/O (read, write, path manipulation)
  - Collections (list, map, set with standard iteration)
  - JSON/data parsing
  - HTTP client (even a basic one)
  - Error handling patterns
  - Time/date basics
  - Printing/formatting

- **FFI wrappers leak C semantics**: Wrapping `fopen`/`fread`/`fclose` means Rail users deal with C strings, null checks, errno, and manual resource cleanup. The entire point of a high-level language is to abstract these away. If your file I/O looks like C with different syntax, why not just write C?

- **The Nim lesson**: Nim has excellent C FFI and is [described as](https://ayende.com/blog/194466-A/looking-into-odin-and-zig-my-notes) "doesn't really shine in any particular area" despite being technically capable. Easy FFI is necessary but not sufficient — you need idiomatic, well-documented standard APIs.

### Verdict: WRONG
Build a minimal stdlib. The FFI is the escape hatch, not the front door. Target:
- ~2000 lines of Rail implementing: strings, file I/O, collections, JSON, basic HTTP
- FFI available for everything else
- Users should never need to think about C for the first 80% of tasks

---

## 5. "Bump allocator with arena reset is enough"

### The Claim
A bump allocator (pointer increment) with arena-wide reset is the only allocator needed.

### The Counter-Evidence

**Bump allocation is fast and simple. It's also incompatible with FFI and long-lived data.**

- **C libraries expect malloc/free**: Any C library that calls `malloc` internally returns memory from the system allocator, not your arena. Any C library that expects you to `free` the memory it gives you needs a real free function. You now have two memory systems that don't know about each other.

- **C libraries that store pointers**: If you pass an arena-allocated pointer to SQLite, libcurl, or any C library that stores it for later use, arena reset will invalidate it. This is use-after-free at the FFI boundary — the exact class of bug that kills programs silently.

- **No individual deallocation**: If a request allocates 100MB in an arena but only the last 1MB is still needed, the other 99MB is wasted until arena reset. For long-running processes with variable workloads, this means memory usage equals peak usage, not current usage.

- **Fragmentation across resets**: Bump allocators don't fragment within a lifetime, but across resets, the arena size must accommodate the peak allocation of any request. If one request uses 500MB and the next uses 1KB, you're holding 500MB. The [OS may not reclaim](https://medium.com/@rtopensrc/theory-rides-cpu-understanding-memory-allocators-on-modern-processors-i-the-problem-space-1496bef3a885) the virtual pages unless you `madvise(MADV_DONTNEED)`.

- **Real allocators in real systems**: Even game engines use multiple allocator types. The [Bitsquid engine](https://bitsquid.blogspot.com/2015/08/allocation-adventures-3-buddy-allocator.html) uses bump allocators, buddy allocators, pool allocators, and heap allocators for different object lifetimes. One size does not fit all.

### Verdict: NECESSARY BUT NOT SUFFICIENT
Keep the bump allocator for per-request scratch space. But you also need:
1. A pool allocator for fixed-size objects (hash table entries, AST nodes)
2. A way to "promote" objects from arena to long-lived heap
3. A strategy for FFI-allocated memory (ref-counted wrappers? destructor callbacks?)

---

## 6. "Lua's table is the gold standard for small runtimes"

### The Claim
A single hash-table-plus-array hybrid (Lua's table) is the ideal data structure for a small language runtime.

### The Counter-Evidence

**Lua tables have known performance pathologies that Lua users work around constantly.**

- **Hash collision attacks**: Lua's hash function for integers is just [key mod table_size](https://kate.io/blog/simple-hash-collisions-in-lua/). Since table size is always a power of 2, any set of keys sharing low bits will collide. The Factorio game [hit this in production](https://forums.factorio.com/viewtopic.php?t=108993) — sequences with 1-2 million elements became "excessively slow" due to integer hash collisions.

- **String hashing is weak**: Lua's string hash function [ignores most of the string](https://luyuhuang.tech/2021/07/30/hash-collision.html) for long strings, sampling only a few characters. This makes collision generation trivial and enables hash-flooding DoS attacks.

- **Rehashing is expensive**: When a Lua table grows, it [rehashes all existing keys](https://www.itworkman.com/lua-performance-optimization-skills-iii-about-table/) into the new array. For a table with 1M entries, that's 1M hash computations and 1M pointer updates. The standard advice is to pre-allocate, which means users need to know sizes in advance.

- **Type confusion**: A single `table` type means no static type checking. `t.x` could be an array index, a method call, or a field access. This makes optimization hard and errors subtle. Wren and Janet both chose to have separate Array and Map types for this reason.

- **Memory overhead**: Each table entry in Lua stores a full TValue (type tag + value) for both key and value. For an array of integers, that's 16+ bytes per element vs 4-8 bytes for a typed array.

### What Small Languages Actually Do
| Language | Collections | Notes |
|----------|------------|-------|
| Lua | Table (hybrid) | Fast for small sizes, pathological for large |
| Wren | List + Map | Separate types, static dispatch |
| Janet | Array + Table + Struct + Tuple | Immutable variants for safety |
| Zig | ArrayList + HashMap | Typed, allocator-aware |

### Verdict: GOOD START, NOT GOLD STANDARD
Lua's table works for prototyping but has real problems at scale. Consider:
- Separate Array and Map types (like Wren) for type safety and optimization
- SipHash or similar for hash-flooding resistance (Rail serves HTTP — this matters)
- Typed arrays for numeric data (massive memory savings)

---

## 7. Bonus: The GC You're Avoiding Might Be Smaller Than You Think

### Implementation Sizes (approximate)

| Implementation | Type | LOC (approx) |
|---------------|------|-------------|
| Lua 5.1 lgc.c | Incremental mark-sweep | ~700 |
| Lua 5.4 lgc.c | Generational + incremental | ~1800 |
| Wren (entire VM) | Mark-sweep | ~4000 semicolons total |
| Crafting Interpreters clox | Mark-sweep | ~200 (educational) |
| Bob Nystrom's "Baby's First GC" | Mark-sweep | ~150 |

A basic mark-sweep GC is **150-300 lines of C**. An incremental one that avoids pauses is ~700 lines. A generational one with good throughput is ~1800 lines.

Your arena allocator is simpler, yes. But the delta between "arena + manual workarounds for every edge case" and "arena + 300-line GC for the long-lived heap" might be negative. The GC pays for itself by eliminating the entire class of "where does this object live" bugs.

### Reference Counting vs Tracing

For a small language, the comparison is:

| | Reference Counting | Tracing GC |
|---|---|---|
| Implementation | Simpler (~100 LOC for basic) | More code (~300 LOC for basic) |
| Cycles | **Cannot handle** without cycle detector (+200 LOC) | Handles naturally |
| Throughput | Worse (inc/dec on every assignment) | Better (batch processing) |
| Latency | Deterministic | Requires incremental/generational for low pause |
| FFI | Easier (prevent free while ref > 0) | Harder (need GC roots for FFI pointers) |
| CPython | Uses RC + cycle detector | - |
| Swift | Uses ARC (compile-time RC) | - |
| Lua, Wren, Janet | - | All use tracing GC |

**The pragmatic choice for Rail**: Arena for per-request + RC with cycle detection for long-lived objects. Total: ~300 lines. Gets you deterministic destruction (good for FFI resource cleanup) without the pathological cases of pure arenas.

---

## 8. Concurrency: What Actually Works

### Languages That Got It Wrong Initially

| Language | Original Model | Problem | Fix |
|----------|---------------|---------|-----|
| Python | GIL (1992) | No true parallelism | 34 years to remove (PEP 703, 2026) |
| Ruby | GIL (Green threads) | Same | Ractors (Ruby 3.0), still limited |
| Node.js | Single-threaded event loop | CPU-bound work blocks everything | Worker threads (2018), still awkward |
| PHP | Process-per-request (Apache prefork) | Memory explosion at scale | Moved to nginx + PHP-FPM pools |
| Early Java | OS threads, no memory model | Data races, broken DCL | Java Memory Model (JSR-133, 2004) |

### What the Winners Look Like

| Model | Example | Overhead per unit | Scalability |
|-------|---------|------------------|-------------|
| OS Process (fork) | Apache prefork | ~2-10MB | ~1K concurrent |
| OS Thread | Java, C++ | ~1-8MB (stack) | ~10K concurrent |
| Green thread / goroutine | Go, Erlang | ~2-4KB | ~1M concurrent |
| Async / coroutine | Rust tokio, Node.js | ~200B-1KB | ~1M concurrent |
| Event loop (single thread) | nginx, Redis | 0 (multiplexed) | ~100K concurrent |

**Fork is the worst performer in every dimension**: highest memory, lowest scalability, most platform-specific bugs.

---

## Summary: Where the Plan Breaks

| Assumption | Status | Action Required |
|-----------|--------|----------------|
| FFI is cheap | PARTIALLY TRUE | Budget 500-1000 LOC for safe FFI. Pin/prevent arena objects at boundary. |
| Arena per request | TRUE FOR REST | Add long-lived heap tier for WebSockets, caches, connection pools. |
| Fork for concurrency | **BROKEN** | Replace with green threads + message passing or async I/O. Fork is unsafe on macOS. |
| No stdlib | **WRONG** | Build ~2000-line minimal stdlib. FFI is escape hatch, not front door. |
| Bump allocator only | INSUFFICIENT | Add pool allocator + object promotion + FFI-aware wrappers. |
| Lua tables | GOOD START | Add typed arrays, SipHash, consider separate Array/Map types. |

### The Three Things That Will Actually Kill Rail

1. **Fork on macOS** — This will crash the moment any FFI'd library touches CoreFoundation, Metal, or Objective-C. Python and Ruby both hit this wall and spent years fixing it. Don't repeat their mistake.

2. **Arena-only memory with FFI** — C libraries allocate with malloc, store pointers, and expect them to stay valid. Arena reset will cause silent corruption. This is the kind of bug that takes weeks to diagnose.

3. **No stdlib** — Users will evaluate Rail by how fast they can build something useful. If "read a JSON file" requires understanding C's `fopen` semantics through FFI, they'll use Lua instead.

### What to Build Instead

```
Concurrency:  Green threads + message passing (like Erlang, ~500 LOC)
Memory:       Arena (per-request) + RC heap (long-lived) + malloc bridge (FFI)
Collections:  Array (typed) + Map (SipHash) + Table (Lua-style, convenience)
Stdlib:       strings, file I/O, JSON, HTTP client, collections (~2000 LOC Rail)
FFI:          Safe wrapper layer with pinning, destructor callbacks (~500 LOC)
```

Total additional code: ~3500 LOC. In exchange, you get a language that actually works for real programs instead of one that works for demos.

---

## Sources

- [Rust's Hidden Dangers: Unsafe, Embedded, and FFI Risks](https://www.trust-in-soft.com/resources/blogs/rusts-hidden-dangers-unsafe-embedded-and-ffi-risks)
- [Control what crosses FFI boundaries - Effective Rust](https://effective-rust.com/ffi.html)
- [Pair Your Compilers At The ABI Cafe](https://faultlore.com/blah/abi-puns/)
- [Fearless FFI: Memory Safety](https://verdagon.dev/blog/fearless-ffi)
- [node-ffi callback GC bug](https://github.com/node-ffi/node-ffi/issues/241)
- [Haskell FFI call safety and GC](https://frasertweedale.github.io/blog-fp/posts/2022-09-23-ffi-safety-and-gc.html)
- [WebSocket Memory Leak Issues](https://oneuptime.com/blog/post/2026-01-24-websocket-memory-leak-issues/view)
- [Go Long-Lived Connection Memory Management](https://goperf.dev/02-networking/long-lived-connections/)
- [Postgres Arena Allocator](https://www.enterprisedb.com/blog/exploring-postgress-arena-allocator-writing-http-server-scratch)
- [fork is no-no - Apple Developer Forums](https://developer.apple.com/forums/thread/747499)
- [TIL: fork crashes on macOS with Metal/ObjC](https://lxyuan0420.github.io/posts/til-vllm-metal-macos-fork-spawn)
- [How macOS Broke Python](https://www.wefearchange.org/2018/11/forkmacos.rst)
- [fork() without exec() is dangerous](https://www.evanjones.ca/fork-is-dangerous.html)
- [Python switching from fork to spawn](https://discuss.python.org/t/switching-default-multiprocessing-context-to-spawn-on-posix-as-well/21868)
- [fork() is evil; vfork() is goodness](https://gist.github.com/nicowilliams/a8a07b0fc75df05f684c23c18d7db234)
- [BEAM Process Memory Usage](https://hauleth.dev/post/beam-process-memory-usage/)
- [IPC: Shared Memory vs Message Queues](https://howtech.substack.com/p/ipc-mechanisms-shared-memory-vs-message)
- [Apache vs Nginx Performance](https://www.sitepoint.com/apache-vs-nginx-performance-optimization-techniques/)
- [Empirical Analysis of Programming Language Adoption](https://dl.acm.org/doi/10.1145/2509136.2509515)
- [Lua Hash Collisions](https://kate.io/blog/simple-hash-collisions-in-lua/)
- [Factorio Lua integer hash collision bug](https://forums.factorio.com/viewtopic.php?t=108993)
- [Lua Table Hash Collision Analysis](https://luyuhuang.tech/2021/07/30/hash-collision.html)
- [Allocation Adventures: Buddy Allocator](https://bitsquid.blogspot.com/2015/08/allocation-adventures-3-buddy-allocator.html)
- [Memory Allocators on Modern Processors](https://medium.com/@rtopensrc/theory-rides-cpu-understanding-memory-allocators-on-modern-processors-i-the-problem-space-1496bef3a885)
- [Allocator Designs - Writing an OS in Rust](https://os.phil-opp.com/allocator-designs/)
- [Understanding Lua's Garbage Collection](https://dl.acm.org/doi/fullHtml/10.1145/3414080.3414093)
- [Crafting Interpreters: Garbage Collection](https://craftinginterpreters.com/garbage-collection.html)
- [CPython Reference Counting Internals](https://blog.codingconfessions.com/p/cpython-reference-counting-internals)
- [Is Ref Counting Slower than GC?](https://mortoray.com/is-reference-counting-slower-than-gc/)
- [Python GIL Removal History](https://lwn.net/Articles/939981/)
- [libffi - Wikipedia](https://en.wikipedia.org/wiki/Libffi)
- [The Rustonomicon: FFI](https://doc.rust-lang.org/nomicon/ffi.html)
