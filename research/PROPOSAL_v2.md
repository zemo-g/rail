# THE RAIL PROPOSAL v2

*Revised after adversarial research. What changed, why, and what we actually build.*

---

## What round 2 broke

Four adversarial agents found real problems. Here's what we believed, what they found, and what we're changing.

### BROKEN: "Concurrency via fork"
**Finding**: Apple explicitly says fork-without-exec is unsafe on macOS. CoreFoundation, Metal, libdispatch, Objective-C runtime — any FFI'd library that touches these will crash or deadlock in the child process. Python 3.14 is switching from fork to spawn because of this.
**Impact**: Our primary platform is macOS. Our concurrency model is dead on arrival.
**Change**: Green threads + message passing. Cooperative scheduling, not OS processes. ~500 LOC for a basic fiber system (stack + instruction pointer, like Wren). This is actually simpler to implement and works everywhere.

### BROKEN: "FFI is 50 lines"
**Finding**: ABI hell (clang/gcc disagree on struct passing), callback GC interaction (C holds pointer to collected closure), memory ownership ambiguity (arena reset invalidates C's pointers). Real FFI is 500-1000 LOC with safety checks.
**Impact**: FFI still works but isn't cheap. Need: pinned memory for C-crossing pointers, callback prevent-collection mechanism, malloc bridge for C-allocated data.
**Change**: Budget 500 LOC for FFI, not 50. Add a `pin` mechanism for data crossing the FFI boundary. Route FFI allocations through malloc, not the arena. Accept the complexity.

### BROKEN: "Arena reset, not GC"
**Finding**: Arena reset + FFI = silent corruption. Long-lived connections (websockets, streaming) don't fit request/response arenas. C libraries call malloc internally and store pointers that arena reset invalidates.
**Impact**: Arena-only memory is fine for CLI tools (Rail's current use) but breaks for servers and FFI.
**Change**: Two-tier memory. Arena for request-scoped short-lived data (fast, reset between requests). Reference-counted heap for long-lived data and FFI-crossing objects. This is what game engines actually do — they have both, not just arenas.

### BROKEN: "33 LoRA examples is training"
**Finding**: Research consensus is 1,000 examples minimum for generalization. 33 examples is memorization, not learning. Our model will fail on any pattern not in the training set.
**Impact**: The LoRA demo works for demos. It doesn't work for real generation.
**Change**: Scale to 1,000-2,000 training examples before claiming the model "knows Rail." Generate variants: for each of 37 tests, create 20-30 descriptions and Rail solutions. Add the full source of every .rail file as "explain this code" pairs. Add error cases: "this Rail code has a bug, fix it."

### BROKEN: "Grammar-constrained decoding eliminates errors"
**Finding**: GCD guarantees syntax but actively hurts semantics. Distribution distortion pushes the model toward "easy to keep valid" prefixes, not correct ones. CRANE (2025) found you need to alternate between unconstrained reasoning and constrained generation.
**Impact**: GCD is a tool, not a solution. "It compiles" ≠ "it works."
**Change**: Use GCD for the final output step only, not during reasoning. Let the model think freely (unconstrained), then constrain only the final code emission. Add a validation loop: generate → compile → run test → if fail, regenerate with error context. Three layers: grammar (syntax), compiler (types), tests (behavior).

### WEAKENED: "Rail is first in AI-native languages"
**Finding**: BAML (YC-backed, 7 languages), Outlines (Rust core, HuggingFace TGI), Instructor (11K stars, 3M downloads), Mojo ($130M funding). The space is crowded.
**Impact**: "AI-native language" is not a unique claim. The unique claim is the combination: self-hosting + Metal GPU + local model + zero dependencies. Nobody else has all four. But "nobody has this combination" is a weaker moat than "nobody does this at all."
**Change**: Stop claiming to be first. Claim to be the most integrated. The story isn't "AI-native language" — it's "the entire stack on one machine, owned by one person."

### VALIDATED: "The person most served by Rail is its creator"
**Finding**: The market agent said this as a criticism. It's actually the insight.
**Impact**: Rail's first customer IS you. The ad intel pipeline, the trading system, the site generator, the service monitor — these are all YOUR tools. Rail succeeds by making YOUR workflow better, not by convincing strangers.
**Change**: Stop trying to be a product for others. Be a product for yourself. If it's good enough that others want it, that happens naturally. Zig, Lua, and SQLite all started this way.

---

## What round 2 validated

### VALIDATED: "70% of LLVM in 10% of code"
The adversarial agent found QBE benchmarks showing 57-80% of LLVM performance with zero SIMD. That's actually fine for Rail. Rail's workloads are string processing, list manipulation, and orchestration — not tight numeric loops. The GPU backend handles compute-heavy work. Keep the simple ARM64 codegen for CPU.

### VALIDATED: "Direct ARM64 is better than compile-through-C"
The adversarial agent made a strong case for a C backend (portability, free optimization). But: Rail already has a working ARM64 backend AND a Metal backend. Adding a C backend is additive, not a replacement. Keep ARM64 as the fast path, add C as a portability backend later if cross-platform demand materializes.

### VALIDATED: "Keep the compiler under 10K lines"
cproc does C11 in 8K lines and builds git. Rail is at 1,077 lines with ADTs, TCO, closures, GPU codegen. Growth will come from FFI, green threads, and the C backend — but 5K-8K is achievable.

### VALIDATED: "The binary IS the deployment"
TinyGo: 5.5KB. Zig: 4-6KB. Rail: 206KB. For CLI tools and edge deployment, this matters. Not because developers choose languages by binary size — but because `scp` beats Docker.

---

## What nobody is building (refined)

Round 1 claimed Rail occupies an empty slot. Round 2 proved the slot is more crowded than we thought. Here's what's ACTUALLY unique after removing the false claims:

**Nobody has the full vertical stack on one machine:**
- BAML does structured LLM output → but doesn't compile to native code or GPU
- Mojo does GPU compilation → but requires cloud, LLVM, and a team of 50
- Outlines does grammar-constrained generation → but it's a library, not a language
- Futhark does functional→GPU → but has no AI integration and no self-hosting story

**Rail's actual unique position:**
```
Human describes intent
  → local 27B model generates Rail (LoRA-tuned, grammar-validated)
  → Rail compiler (self-hosting, 1K lines) compiles to:
      → ARM64 native binary (CPU) or
      → Metal compute shader (GPU)
  → Results feed back to refine next generation
  → Entire loop on one Mac Mini, zero cloud, zero API cost
```

This full loop doesn't exist anywhere else. Not because it's impossible — because nobody has bothered to close it. The pieces exist (MLX, Metal, grammar decoding). The integration doesn't.

---

## THE REVISED PLAN

### Principle changes from v1:

| v1 | v2 | Why |
|----|-----|-----|
| Fork-based concurrency | Green threads + message passing | Fork broken on macOS with Metal/FFI |
| Arena-only memory | Arena + refcounted heap | FFI needs stable pointers |
| FFI in 50 lines | FFI in 500 lines with safety | ABI hell, callback GC, ownership |
| "First AI-native language" | "Most integrated local AI stack" | BAML, Outlines, Mojo exist |
| GCD eliminates errors | GCD for syntax only, tests for semantics | Distribution distortion hurts correctness |
| 33 training examples | 1,000+ training examples | 33 is memorization |
| Build for others | Build for yourself | You are the first customer |

### What stays the same:
- Grammar as AI interface
- Two backends (CPU + GPU)
- Cross-compile, don't port
- FFI over stdlib (but with real safety budget)
- The model as a dev tool, not runtime dependency
- Keep compiler under 10K lines

---

## The revised build order

### Week 1: Make Rail usable (unchanged)
- `foreign` declarations — 500 LOC with safety (pin mechanism, malloc bridge)
- JSON parsing — jsmn wrapper
- String builtins — char_at, substring, replace
- Negative number literals
- **NEW**: Scale LoRA training data to 200+ examples (generate variants of existing tests)

### Week 2: Make Rail honest
- **NEW**: Overfitting test — ask the trained model for patterns NOT in training data. Measure actual vs memorized performance.
- **NEW**: Validation loop — generate → compile → run → if fail, regenerate
- Linux ARM64 ELF backend for cross-compilation
- Test on Pi Zero 2 W over Tailscale

### Week 3: Make Rail concurrent
- **CHANGED**: Green threads, not fork. Cooperative fibers (~500 LOC)
- Message passing between fibers (channels)
- GPU auto-dispatch with cost model (not blind 50K threshold — measure actual crossover on M4 Pro)
- **NEW**: Two-tier memory (arena + refcounted heap)

### Week 4: Make Rail integrated
- `rail generate` CLI — model generates, compiler validates, test confirms
- **CHANGED**: Unconstrained reasoning + constrained emission (not pure GCD)
- Scale training to 1,000 examples
- `rail complete` for editor integration

### Month 2-3: Same as v1
- Package manager, FFI wrappers, tree-sitter, docs site, WASM backend
- But now with honest expectations about market position

---

## The honest framing

Rail is not going to compete with Mojo's $130M or BAML's YC backing on their terms.

Rail competes on integration depth. One person who understands every byte from the grammar to the GPU shader to the LoRA adapter. That understanding IS the moat — not any single feature.

The market agent was right: Rail's first customer is its creator. The ad intel pipeline, the trading system, the service monitor, the site generator. Every tool written in Rail makes Rail better. Every Rail improvement makes every tool better. That's the flywheel.

If that flywheel spins fast enough, others will notice. If it doesn't, it's still the most capable personal infrastructure stack anyone has built on a Mac Mini.

Both outcomes are fine.

Build it.
