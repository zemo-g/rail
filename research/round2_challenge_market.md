# ROUND 2: DEVIL'S ADVOCATE — MARKET REALITY CHECK

*Written 2026-03-16. Every claim in the PROPOSAL.md stress-tested against market evidence.*

**Bottom line up front**: Rail is a genuine technical achievement and a cool project. It is not yet a product. The gap between those two things is wider than the PROPOSAL acknowledges, and the threats are more concrete than assumed. This document identifies exactly where.

---

## 1. "Rail is the first language designed for AI to write and machines to run"

**Verdict: The claim is crowded, not unique.**

### Who else is in this space RIGHT NOW

| Project | What it does | Funding | GitHub stars | Status |
|---------|-------------|---------|-------------|--------|
| **BAML** (Boundary) | DSL for AI function calls. Generates type-safe structured output from LLMs. Rust core, Python/TS/Ruby/Java/C#/Go bindings. | YC-backed | ~7K+ | Active, heading to 1.0 in 2026 |
| **Instructor** | Python library for structured LLM output via Pydantic. 15+ provider support. | Community | 11K+ | 3M+ monthly downloads |
| **Outlines** (dottxt) | Token-level grammar-constrained generation. Rust core. | Funded | ~10K+ | Core rewritten in Rust, adopted by TGI |
| **TypeChat** (Microsoft) | Schema engineering for natural language interfaces. | Microsoft | ~8K+ | Active |
| **Mojo** (Modular) | "AI-native" systems language. Python superset, GPU compilation. | $130M+ raised | 50K+ community | Heading to 1.0 in H1 2026, open-source compiler by end 2026 |
| **SGLang** | Grammar-constrained LLM serving with structured generation. | Stanford/community | Growing fast | Production use |

### The hard truth

BAML is the closest direct competitor to Rail's "AI writes structured code" vision. It is:
- YC-backed with a full team
- Already supports 7 languages
- Benchmarks show it is 2-4x faster than OpenAI function calling
- Has a VS Code playground with live prompt previews
- Is heading to 1.0 stability

BAML's approach (DSL for structured AI output) is arguably MORE practical than Rail's approach (entire language for AI to write) because BAML integrates with existing codebases rather than replacing them. A developer can add BAML to their Python/TS project today. They cannot add Rail to anything.

Outlines has rewritten its core in Rust and is integrated into Hugging Face's text-generation-inference. It does grammar-constrained decoding at the token level -- the exact capability Rail's PROPOSAL identifies as novel. It is not novel. It ships today.

Mojo has $130M+ in funding, Chris Lattner (creator of LLVM and Swift), a 50K+ community, and is targeting 1.0 in H1 2026. If Mojo succeeds, it owns "AI-native systems language" as a category. Rail cannot outspend, outship, or out-community Mojo. However -- Mojo has its own problems: the compiler is still closed-source, community adoption has been described as "the market has efficiently rejected Mojo" on HN, and it is seen as "an internal tool that Modular released publicly." Mojo may stumble, but that does not mean Rail catches the ball.

**What this means for Rail**: The "first language designed for AI to write" claim needs to be much more specific. "First self-hosting language with grammar-constrained generation and native ARM64 compilation" is defensible. "First language designed for AI" is not -- there are at least 6 well-funded projects making similar claims.

---

## 2. "The moat is the closed loop"

**Verdict: A moat requires something competitors cannot easily replicate. This loop is replicable.**

The loop (human -> model -> Rail -> binary -> results) can be approximated by:
- Human -> Claude -> Python -> `pyinstaller` -> results
- Human -> local model -> BAML -> existing app -> results
- Human -> Copilot -> Rust -> `cross` -> ARM binary -> results

The PROPOSAL's moat is really three things combined:
1. Grammar-constrained generation (Outlines/SGLang already do this)
2. Native ARM64 compilation (GCC/LLVM/Zig already do this)
3. Self-hosting (a technical achievement, not a market differentiator)

What would ACTUALLY be a moat:
- A fine-tuned model that writes Rail better than GPT-4 writes Python (not proven yet)
- Compile-time AI execution that competitors cannot replicate (not built yet)
- A specific vertical where this loop solves a $$ problem (not identified yet)

---

## 3. "No cloud dependency is a selling point"

**Verdict: Yes, BUT the market disagrees with you on scale.**

### The local-first movement IS growing
- Local-First Conf 2026 exists as a dedicated conference
- FOSDEM 2026 has a Local-First track
- Apple has incorporated local-first sync into products
- Privacy regulations (GDPR, state-level US laws) push toward local processing
- New startups (Pushpin, Fission, PowerSync, RxDB) are building local-first tools

### But cloud AI is winning by every dollar metric
- Cloud AI market: $121.74B in 2025, projected $1.73T by 2033 (39.3% CAGR)
- AI code assistant market: $4.7B in 2025, projected $14.6B by 2033
- ChatGPT (82%) and GitHub Copilot (68%) dominate developer AI tool usage
- Enterprise Copilot deployments grew 142% YoY

### Deloitte's 2026 prediction is damning
> "Almost all AI computing performed in 2026 will be done mainly in giant AI data centers or on relatively expensive high-end AI servers owned by enterprises, **not on PCs and smartphones**."

Inference workloads will be ~2/3 of all compute in 2026, but Deloitte predicts most of it stays in data centers. Edge inference is real but it is for **latency-critical industrial applications** (predictive maintenance, smart retail, autonomous vehicles) -- not for developer tooling.

### The developer sentiment question
The 2025 Stack Overflow survey shows:
- 84% of developers use or plan to use AI tools
- But positive sentiment DROPPED from 70%+ to 60%
- More developers DISTRUST AI accuracy (46%) than trust it (33%)
- 51% use AI tools daily -- almost entirely cloud-based

The local-first developer is real but rare. Privacy-conscious developers exist. But the mass market is using ChatGPT and Copilot, not running local models. "No cloud" is a niche selling point, not a mass market one.

---

## 4. "186K binary size is an advantage"

**Verdict: Almost nobody chooses a language because of binary size.**

Binary size matters in exactly three contexts:
1. **Embedded systems / IoT** -- where flash storage is measured in KB
2. **Demoscene** -- an art form, not a market
3. **Edge deployment at scale** -- where you ship millions of devices

For the developer tool market Rail targets, binary size is a footnote. Nobody evaluating Go, Rust, Python, or TypeScript lists binary size as a top-5 decision factor. The JetBrains State of Developer Ecosystem surveys do not even ask about it.

Zig produces ~2KB hello-world binaries. TinyGo produces 5.5KB ARM binaries. Both are smaller than Rail's 186KB. If binary size were the deciding factor, Zig would have already won.

**What binary size DOES buy**: trivially easy deployment (`scp` a binary). That is a real advantage, but it is a deployment story, not a language story. Frame it as "deploy in one command" not "186KB binary."

---

## 5. "Cross-compile on Mac, deploy to Pi over Tailscale"

**Verdict: Real but painful, and the use case is thin.**

### Cross-compilation pain points (macOS to ARM Linux)
Real-world problems documented by developers:
- **OpenSSL/SSL library dependencies** -- the most common failure point
- **Case-insensitive filesystem** -- macOS default breaks Linux projects expecting case sensitivity
- **Toolchain installation** -- finding `arm-linux-musleabihf-gcc` and friends
- **Cascading dependency failures** -- C libraries not available for cross-compilation
- **Apple Silicon complications** -- ARM Mac -> ARM Linux is arm64-to-arm64 but different ABIs and syscalls

The 2024-2025 consensus: **Docker containers have become the primary solution** because native cross-compilation from macOS is too fragile.

Rail's advantage: it generates assembly directly, avoiding the C toolchain dependency chain. This is genuinely simpler than cross-compiling a Rust project. But it only works as long as Rail programs do not need C libraries -- which the PROPOSAL explicitly says they will (`foreign` FFI declarations for sqlite, curl, openssl, etc.). The moment you need FFI, you need cross-compiled C libraries, and you are back in dependency hell.

### Does anyone want to run AI on a Pi?

**Yes, but not the way the PROPOSAL imagines.**

Real Pi AI use cases in 2025-2026:
- Object detection on camera feeds (YOLOv8, ~30 FPS on Pi 5 with AI HAT+)
- Voice control with Whisper-class models + small LLMs
- Privacy-first offline assistants
- Industrial monitoring and environmental sensing
- Smart retail (MediaTek Genio platform, no cloud)

These are **dedicated embedded applications**, not general-purpose development targets. Nobody is running a developer workflow on a Pi Zero. The Pi is an execution target for specific, pre-compiled tasks. Rail could fit here, but this is a very different pitch from "intelligence runtime."

PicoClaw (OpenClaw) does run AI agents on Pi Zero 2 W. But it is a specific product for a specific use case (robotic manipulation), not a general-purpose language runtime.

---

## 6. "One person can build and maintain this"

**Verdict: One person can build it. One person cannot sustain it as a product.**

### Solo language projects that stalled or burned out

**Elm** (Evan Czaplicki):
- Created by one person, maintained with BDFL model
- Community frustrated by slow development, locked discussions, opaque roadmap
- "It's easier to get info about future Apple products than to guess what's happening to Elm next"
- Culture Amp (a real company) **retired Elm from production** because: momentum stalled, TypeScript caught up, maintaining parallel implementations was unsustainable
- Key lesson: "If momentum stalls before the language fills your entire application, plan an exit strategy"

**Nim** (Andreas Rumpf):
- Solo BDFL, 15+ years of development
- Community raised succession plan concerns; Rumpf responded with political tangents that alienated contributors
- HN discussion: "the reasons for a foundation have nothing to do with what the main branch is called... they have to do with what happens when your BDFL hits himself with a bus"
- Despite technical excellence: niche adoption, lacking game frameworks, poor documentation, weak Stack Overflow presence
- Corporate backing identified as "absolutely essential for a new language to be taken seriously"

**Common failure patterns across niche languages (Nim, Crystal, D, Haxe)**:
- Strong community but niche adoption
- Smaller ecosystem, fewer large-scale industry examples
- Lack of corporate sponsorship
- Insufficient training data for AI coding assistants (the irony for Rail: AI assistants perform worse on languages with less training data, creating a chicken-and-egg problem)

### The bus factor
Research shows 85% of the most popular GitHub projects rely on a single developer for majority of commit-related discussions. This is a known risk. For a language that positions itself as infrastructure, single-maintainer risk is existential.

### What burned out solo maintainers
- Wearing dev + product + support + growth + community hats simultaneously
- No code review, no process, no one to correct gold-plating impulses
- The "tantalizing promise of relief while somehow leaving you thirstier and weaker"
- Initial energy fades within days to weeks; dedicated time drops to zero

### What succeeded despite solo origins

**Go** (Google): Started with Ken Thompson, Rob Pike, Robert Griesemer. But had **Google's backing** from day one. Comprehensive standard library reduced ecosystem dependency. Standalone binaries. Simplicity was the feature.

**Rust** (Mozilla): Started as Graydon Hoare's personal project. Succeeded because **Mozilla funded it**, then it grew a massive community, then it got a foundation. The personal project phase lasted ~3 years before institutional backing.

**Zig** (Andrew Kelley): Solo creator, but built a **foundation** and full-time team. C interop was the killer feature -- immediate access to every C library. Community grew around a specific pain point (replacing C build systems).

**The pattern**: Every language that succeeded as a product had institutional backing within 3-5 years of creation. The technical work can be solo. The ecosystem, community, documentation, and sustainability cannot.

---

## 7. BAML: The Real Competitor

BAML deserves its own section because it is the closest thing to Rail's vision that actually ships.

**What BAML does**:
- Domain-specific language for defining AI function calls
- Type-safe structured output from any LLM
- Rust core with bindings to Python, TypeScript, Ruby, Java, C#, Go
- VS Code playground with live prompt previews
- Schema-Aligned Parsing (SAP) -- novel research for parsing LLM outputs
- 2-4x faster than OpenAI function calling in benchmarks

**How it differs from Rail**:
- BAML is a DSL that integrates into existing projects. Rail is a standalone language.
- BAML works with any LLM (cloud or local). Rail assumes local-first.
- BAML has 7-language support. Rail has Rail.
- BAML is YC-backed with a team. Rail is solo.

**Why BAML matters**: A developer can add BAML to their Python project in 10 minutes and get structured AI output. To use Rail, they must learn a new language, port their logic, and trust a single-maintainer toolchain. The adoption barrier is incomparable.

**BAML's weakness**: It is a DSL for prompt engineering, not a general-purpose language. It cannot compile to native binaries. It cannot run on a Pi. It cannot self-host. These are real technical gaps that Rail fills -- but only if those gaps matter to paying customers.

---

## 8. The self-hosting story

**Verdict: Technically impressive. Commercially irrelevant.**

Does anyone BUY a product because the language is self-hosted? No. Not one documented case.

Self-hosting matters to:
- Language designers (it proves the language is capable enough to implement itself)
- Compiler nerds (it is intellectually satisfying)
- The bootstrapping community (it proves minimal dependency chains)

Self-hosting does NOT matter to:
- Enterprises evaluating languages (they care about hiring, libraries, support)
- Developers choosing tools (they care about documentation, community, IDE support)
- Investors evaluating language startups (they care about adoption metrics, revenue)

The Rust community celebrated self-hosting as a milestone. Nobody switched to Rust because of it. They switched because of memory safety guarantees, or because Mozilla backed it, or because it was faster than Go for their use case.

**How to use the self-hosting story**: It is a credibility signal for the technical community. It says "this language is real, not a toy." Use it for that. Do not expect it to close a deal or gain a user.

---

## 9. Languages that succeeded without an ecosystem

**What they did right**:

| Language | Initial ecosystem | What carried it |
|----------|------------------|-----------------|
| **Go** | Minimal, but comprehensive stdlib | Google backing. Standalone binaries. Goroutines solved a real concurrency pain point. |
| **Rust** | Near zero | Mozilla funding. Memory safety was a novel, provable advantage. "Fearless concurrency." |
| **Zig** | Tiny | Built-in C compiler. Can import .h files directly. Immediate access to all C libraries. Solved the "C build system is hell" pain point. |
| **TypeScript** | Piggyback on JS | Microsoft backing. Ran existing JS code. 94% of AI coding errors are type-related -- TS catches them. |

**Common thread**: Each solved ONE specific pain point that developers already felt. None of them pitched a grand vision. They pitched a solution to a problem.

- Go: "Concurrent servers without thread complexity"
- Rust: "C-speed without segfaults"
- Zig: "Better C with a sane build system"
- TypeScript: "JavaScript that catches errors"

**The question for Rail**: What is the one-sentence pain point? "A language for AI to write" is a feature, not a pain point. Who is in pain? What are they doing today that sucks? How does Rail make it not suck?

---

## 10. The market for "local AI tooling"

### Total Addressable Market

**Edge AI overall**: $25-36B in 2025, projected $119-386B by 2033-2034 (21-30% CAGR depending on source). This is a real, large, growing market.

**But**: This market is dominated by:
- Semiconductor companies (Qualcomm, Intel, AMD, MediaTek)
- Hardware accelerators (Coral, SAKURA-II, Hailo)
- Industrial platforms (smart retail, autonomous vehicles, manufacturing)
- Enterprise infrastructure (split inference architectures)

**Who pays**: Enterprises deploying AI at scale on edge devices. Not individual developers. Not hobbyists running models on a Mac Mini.

**The developer tooling slice**: AI developer tools market overall is $3-5B. The LOCAL AI developer tooling sub-segment is not separately measured, which itself is a data point -- it is too small to track independently.

**Ollama, LM Studio, llama.cpp** are the closest "local AI tools" with significant adoption, but they are free/open-source. The monetization model for local AI tooling is unclear.

---

## 11. The AI-writes-code problem

**The 2025 Stack Overflow survey reveals an inconvenient truth**:

> "AI assistants perform worse on languages with less training data"

This creates a vicious cycle for Rail:
1. Rail has minimal training data (dozens of files, not millions)
2. AI generates Rail poorly without fine-tuning
3. Fine-tuning requires a local model + LoRA adapter (the PROPOSAL plans for this)
4. But general-purpose models will ALWAYS generate Python/JS/Rust better because they have millions of training examples
5. A developer using Claude to write Python + pyinstaller gets 95% of Rail's value with 0% of the learning curve

**The counterargument**: Grammar-constrained decoding eliminates syntax errors at generation time. This is genuinely valuable. But syntax errors are the EASY part. Semantic errors -- wrong algorithm, incorrect logic, misunderstood requirements -- are where AI code generation actually fails, and grammar constraints do not help with those.

---

## 12. The hardest truths

### Truth 1: Rail is a project, not a product
A product has users, a feedback loop, and either revenue or a credible path to revenue. Rail has none of these yet. The PROPOSAL describes a technically beautiful system. It does not describe who pays for it, why, or how much.

### Truth 2: The "intelligence runtime" positioning is aspirational
Right now Rail is a self-hosting functional language with ARM64 compilation. That is impressive. But "intelligence runtime" implies AI integration that does not yet exist in the shipped product. The grammar-constrained generation, the compile-time AI, the model-as-toolchain -- these are proposals, not features.

### Truth 3: The timing problem
Mojo reaches 1.0 in H1 2026 and open-sources by end of 2026. BAML reaches 1.0 in 2026. Outlines has already rewritten in Rust and integrated into TGI. The window for "first AI-native language" is closing. If Rail ships its AI features in Month 3 of the build plan, that is ~June 2026. By then, the competitive landscape may have shifted fundamentally.

### Truth 4: The audience problem
The PROPOSAL never names the user. Who is the person who:
- Wants to run AI locally (not most developers)
- Wants to learn a new language (not most developers)
- Wants to deploy to ARM edge devices (a niche within a niche)
- Trusts a single-maintainer toolchain for production (almost nobody)
- Cannot achieve their goal with Python + Ollama + pyinstaller (unclear who)

### Truth 5: The ecosystem death spiral
A new language needs libraries. Libraries need users. Users need libraries. Every niche language (Nim, Crystal, D, Haxe, Elm) has hit this wall. The FFI escape hatch helps but adds complexity. The PROPOSAL's "20 FFI wrappers" plan is smart, but each wrapper is a maintenance burden for a solo developer.

### Truth 6: The AI training data chicken-and-egg
AI coding assistants work better on popular languages. Rail is not popular. Developers increasingly rely on AI assistants. AI assistants will generate bad Rail code. Developers will avoid Rail because the AI experience is poor. This is a structural disadvantage that grammar-constrained decoding mitigates but does not solve.

---

## What COULD make Rail a real product

Despite all of the above, there are paths forward. They require ruthless focus.

### Path A: The embedded AI toolkit
**Target**: Companies deploying AI inference on ARM edge devices.
**Pitch**: "Write your inference pipeline in Rail. 186KB binary, no runtime dependencies, cross-compiles from Mac to ARM Linux. Grammar-constrained code generation means your local model produces correct Rail on the first try."
**Revenue**: Consulting + tooling licenses for edge AI companies.
**Problem**: Competes with C/C++/Zig, which have vastly larger ecosystems.

### Path B: The AI teaching language
**Target**: Developers learning how compilers and AI work.
**Pitch**: "Rail is a complete language you can read in a weekend. Self-hosting compiler, ARM64 native code gen, GPU shaders, grammar-constrained AI generation. The entire system is ~3000 lines."
**Revenue**: Course/book/workshop. Modest but real.
**Problem**: Teaching languages rarely become production languages.

### Path C: The proof-of-concept that gets acquired
**Target**: A company building AI developer tools (Modular, Boundary, Sourcegraph, etc.)
**Pitch**: "I built a self-hosting language with grammar-constrained AI code generation, ARM64 cross-compilation, and GPU auto-dispatch. Solo. Hire me."
**Revenue**: Salary/equity.
**Problem**: Requires the right buyer at the right time.

### Path D: The open-source community play
**Target**: The small but growing local-first / edge AI developer community.
**Pitch**: Ship Rail as open source. Write the best documentation of any small language. Target one specific vertical (e.g., IoT sensor processing). Build a community around it.
**Revenue**: Sponsorship, donations, consulting. Long-term play.
**Problem**: Requires years of sustained community effort from a solo maintainer.

---

## Final assessment

Rail is technically real and intellectually honest. The self-hosting compiler, the ARM64 native code gen, the Mach-O binary output -- these are not vaporware. They work.

But the PROPOSAL conflates technical achievement with market opportunity. "First self-hosting language with grammar-constrained AI generation" is a cool sentence. It is not a business. The question is not "can this be built?" (it can, and largely has been). The question is "who needs this badly enough to switch from Python?"

The hardest truth: **the person most served by Rail today is its creator**. It is a vehicle for learning compilers, language design, AI integration, and systems programming at an extraordinary depth. That has real value -- career value, intellectual value, and portfolio value. Whether it has MARKET value depends entirely on finding the specific person in pain who cannot solve their problem with existing tools.

Find that person. Build for them. Everything else is engineering for engineering's sake.

---

## Sources

- [BAML - Boundary AI](https://boundaryml.com/)
- [BAML GitHub](https://github.com/BoundaryML/baml)
- [BAML on Y Combinator](https://www.ycombinator.com/companies/boundary)
- [BAML vs Instructor comparison](https://www.glukhov.org/post/2025/12/baml-vs-instruct-for-structured-output-llm-in-python/)
- [Mojo roadmap - Modular](https://docs.modular.com/mojo/roadmap/)
- [Mojo path to 1.0 - Modular](https://www.modular.com/blog/the-path-to-mojo-1-0)
- [HN: Mojo adoption discussion](https://news.ycombinator.com/item?id=45138008)
- [Outlines-core 0.1.0 release](https://huggingface.co/blog/outlines-core)
- [Outlines GitHub](https://github.com/dottxt-ai/outlines)
- [Instructor](https://python.useinstructor.com/)
- [TypeChat - Microsoft](https://github.com/microsoft/TypeChat)
- [Instill AI structured output benchmarks](https://www.instill-ai.com/blog/llm-structured-outputs)
- [Stack Overflow Developer Survey 2025](https://survey.stackoverflow.co/2025/ai/)
- [Stack Overflow Blog - 2025 Survey Results](https://stackoverflow.blog/2025/12/29/developers-remain-willing-but-reluctant-to-use-ai-the-2025-developer-survey-results-are-here/)
- [Cloud AI Market Report - Grand View Research](https://www.grandviewresearch.com/industry-analysis/cloud-ai-market-report)
- [Edge AI Market Report - Fortune Business Insights](https://www.fortunebusinessinsights.com/edge-ai-market-107023)
- [Edge AI Market Report - Grand View Research](https://www.grandviewresearch.com/industry-analysis/edge-ai-market-report)
- [Edge AI IoT mass market 2026](https://iottechnews.com/news/edge-ai-iot-devices-mass-market-inflection-2026/)
- [Deloitte 2026 TMT Predictions - AI compute](https://www.deloitte.com/us/en/insights/industry/technology/technology-media-and-telecom-predictions/2026/compute-power-ai.html)
- [AI coding statistics 2026 - Panto](https://www.getpanto.ai/blog/ai-coding-assistant-statistics)
- [Local-First Conf 2026](https://www.localfirstconf.com/)
- [FOSDEM 2026 Local-First Track](https://fosdem.org/2026/schedule/track/local-first/)
- [Local-first software - Ink & Switch](https://www.inkandswitch.com/essay/local-first/)
- [Why I'm leaving Elm](https://lukeplant.me.uk/blog/posts/why-im-leaving-elm/)
- [Culture Amp retired Elm](https://kevinyank.com/posts/on-endings-why-how-we-retired-elm-at-culture-amp/)
- [HN: Nim succession plan](https://news.ycombinator.com/item?id=36563796)
- [HN: Why did Nim not catch on](https://news.ycombinator.com/item?id=36475744)
- [Why I gave up on Nim](https://cxong.github.io/2022/07/why-i-gave-up-on-nim)
- [Goodbye Nim, and good luck](https://gradha.github.io/articles/2015/02/goodbye-nim-and-good-luck.html)
- [Why new languages struggle - Java Code Geeks](https://www.javacodegeeks.com/2025/11/adoption-and-decline-of-programming-languages-what-drives-programming-trends.html)
- [Cross-compiling Rust macOS to Pi](https://sebi.io/posts/2024-05-02-guide-cross-compiling-rust-from-macos-to-raspberry-pi-2024-apple-silicon/)
- [Tiny AI models for Raspberry Pi](https://www.kdnuggets.com/7-tiny-ai-models-for-raspberry-pi)
- [Running AI on $5 Raspberry Pi](https://medium.com/codrift/running-ai-on-a-5-raspberry-pi-impossible-or-just-painful-d9a94b66ad8e)
- [Raspberry Pi AI HAT+ 2](https://www.raspberrypi.com/news/when-and-why-you-might-need-the-raspberry-pi-ai-hat-plus-2/)
- [OpenClaw on Raspberry Pi](https://www.raspberrypi.com/news/turn-your-raspberry-pi-into-an-ai-agent-with-openclaw/)
- [Self-hosting compilers - DEV Community](https://dev.to/mortoray/what-is-self-hosting-and-is-there-value-in-it-2p9p)
- [Zig, the small language](https://zserge.com/posts/zig-the-small-language/)
- [JetBrains State of Developer Ecosystem 2024](https://www.jetbrains.com/lp/devecosystem-2024/)
- [IEEE Top Programming Languages 2025](https://spectrum.ieee.org/top-programming-languages-2025)
- [Solo developer burnout - Coding Horror](https://blog.codinghorror.com/in-programming-one-is-the-loneliest-number/)
- [Open source maintainer crisis](https://opensauced.pizza/blog/when-open-source-maintainers-leave)
- [Rust vs Go vs Zig](https://betterstack.com/community/guides/scaling-go/rust-vs-go-vs-zig/)
- [Slashdot: AI impacting language choice](https://developers.slashdot.org/story/26/02/23/0732245/is-ai-impacting-which-programming-language-projects-use)
