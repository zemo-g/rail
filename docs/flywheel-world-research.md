---
name: Flywheel — World Research + Next Phase Analysis
description: Academic evidence for self-improving code model decisions — retrain timing, Unsloth/GRPO, verification, data scaling, compiler limits, execution order (2026-03-20 16:50)
type: reference
---

## Self-Improving Code Models: Research + Decisions (2026-03-20)

**Why:** Maps our flywheel against global state of the art. Every major decision backed by published evidence.
**How to apply:** Reference when designing flywheel improvements. Check before making architectural changes.

---

### Our Architecture vs. The Field

**No published system has our exact architecture**: self-hosting compiler as oracle, model generates in the compiler's own language, compiler verifies both syntax AND semantics. Closest comparisons:

| System | Scale | Approach | Our advantage |
|--------|-------|----------|---------------|
| SelfCodeAlign (NeurIPS 2024) | 7B, 74K examples | Self-align + execution filter | Stronger oracle (compiler, not tests) |
| WizardCoder (ICLR 2024) | 3-15B, 80K examples | Evol-Instruct evolution | We can verify evolved outputs |
| STaR (NeurIPS 2022) | LLaMA-2 | Iterative rationalization | We do this with repair harvesting |
| StepCoder (ACL 2024) | Various | RL from compiler feedback | Maps to our GRPO path |
| phi-1 (Microsoft) | 1.3B, textbook data | Quality over quantity | Validates small-model approach |
| PSV (Dec 2025) | Self-play + formal verification | Propose-Solve-Verify | Model for our L11-25 fix |
| DeepSeek R1 | 7-70B | Pure RL (GRPO) with verifiable rewards | Same concept, different language |
| Sol-Ver (2025) | Code+test self-play | Joint code+test generation | Model for level 11-25 fix |

### The Three Hard Problems (Nobody Has Fully Solved)

1. **Model Collapse** — Training on own outputs kills diversity (Nature 2024). Even 1-in-1000 synthetic contamination prevents scaling (ICLR 2025). Fix: external verification filter (our compiler) + never discard seed data.
2. **Reward Hacking** — Models learn to game verification (EVILGENIE 2025). Our compile-only levels 11-25 are vulnerable.
3. **Diversity Collapse** — Self-training loops converge to same few programs. Fix: AST diversity, task shuffling, temperature variation.

---

### Decision 1: When to Retrain (Harvest-to-Retrain Ratio)

**Evidence:**
- **ReST-EM (ICLR 2024)**: For code, "most gains come from first iteration, more iterations regress." Repeated retraining on same data hurts.
- **PSV (2025)**: Scaling unique questions per iteration: 4K→32K = +47% pass@1. Unique data drives gains.
- **Data quality research (2024)**: 25% duplication = +0.87% accuracy. 100% duplication = -40% catastrophic.

**Rule:** Wait for ~5K unique verified examples before v4. Retrain when you have 50%+ new unique data since last training. Don't retrain on marginal gains.

### Decision 2: Unsloth Migration

**Evidence:**
- Unsloth: 2x speed, 70% less VRAM, no accuracy loss. Drop-in replacement.
- QLoRA seq 512→2048 on 8GB: memory goes 4.98→5.21 GB (negligible increase).
- GRPO on 4B with Unsloth fits in 8GB. Compiler is a perfect binary reward function.
- GRPO 4B beat LLaMA-3-8B in structural accuracy (89.7% vs 78.2%).

**Decision:** Yes. Migrate while waiting for data accumulation. Enables GRPO as v5 method. 2-4h task.

### Decision 3: Levels 11-25 Verification

**Evidence:**
- Property-based testing catches 18-23% of solutions that pass simple I/O checks.
- Removing verification = -51.5% relative drop in pass@1 (PSV).
- Property extraction misses 9-13% of constraints.

**Decision:** Use "must print OK" pattern with inline invariant checks. Each seed ends with assert checks + `print "OK"`. Not full PBT framework. Do BEFORE v4 training — every unverified harvest is potentially poisoned (1 in 5 may be wrong).

### Decision 4: Evol-Instruct (Seed Evolution)

**Evidence:**
- WizardCoder: 3 evolution rounds on 20K seeds → 80K examples → +48% HumanEval.
- Auto Evol-Instruct: LLM-designed evolution outperforms human-designed.
- But: evolution on already-complex seeds produces hallucinated outputs.

**Decision:** Implement AFTER Unsloth + seed verification. Priority 3. Self-training loop accumulates data organically meanwhile.

### Decision 5: Fix 65K Compiler Limit

**Evidence:**
- Multi-arena is the standard pattern (rustc, GHC).
- Current training examples are 10-80 lines. 65K limit doesn't constrain current curriculum.
- Multi-arena is ~1 week compiler rewrite with regression risk.

**Decision:** Work around it. Fix when benchmark scores show curriculum is bottlenecked by program complexity. That signal hasn't appeared yet.

---

### Execution Order (Next Phase)

| Priority | Task | Time | Why now |
|----------|------|------|---------|
| 1 | Add OK-pattern verification to L11-25 seeds | 4-6h | Stops poisoned data entering harvest |
| 2 | Migrate train_cuda to Unsloth | 2-4h | Enables GRPO + longer seq while waiting for data |
| 3 | Deploy v3 adapter for inference | 0h | Wait for training to finish |
| 4 | Accumulate to ~5K unique examples | Days | Self-training loop handles this |
| 5 | Train v4 SFT on ~5K via Unsloth | 4-6h | First clean full-pipeline training |
| 6 | Implement GRPO reward (compile + output) | 2-3h | Compiler is a perfect reward function |
| 7 | GRPO fine-tuning pass on v4 | 4-8h | RL signal >> SFT for code |
| 8 | Evol-Instruct seed evolution | 4-6h | Amplify data diversity |
| 9 | Fix compiler arena limit | 1 week | Not needed until curriculum bottleneck |

**Tasks 1 and 2 can run in parallel right now.**

---

### Bottleneck Solutions (from research)

**65K compiler limit** → Multi-arena with per-phase reset (standard in rustc, GHC). Or streaming codegen (gen_site.rail pattern). **Defer.**

**8GB VRAM ceiling** → Unsloth (70% VRAM reduction). Sequence packing (2-3x throughput on short examples). GRPO instead of PPO (half compute). Train smaller, distill up. **Do now.**

**Complex task verification (L11-25)** → Property-based invariant checks printing "OK". Differential testing (2 solutions at different temps, keep if they agree). Train 0.5B verifier on (correct, incorrect) pairs via DPO. **Do seeds now, verifier later.**

**Data efficiency (3,451 examples)** → Enough for QLoRA on 4B if diverse. Need ~5-10K for levels 6-10 coverage. LoRA dropout 0.05-0.1 prevents overfitting. Multiple epochs (3-5) with early stopping. Comments explaining WHY code works improve learning efficiency (phi-1 insight). **Accumulate organically.**

**Self-training collapse** → Compiler verification prevents collapse (ICLR 2025). Always mix gold + synthetic data. Monitor entropy. Temperature annealing (1.0→0.7 over rounds). Checkpoint rollback on bench regression. **Already mitigated by architecture.**

---

### Key Papers

| Paper | Year | Key finding |
|-------|------|-------------|
| Beyond Model Collapse | ICLR 2025 | External verification prevents collapse |
| ReST-EM | ICLR 2024 | Don't retrain repeatedly for code — regresses |
| SelfCodeAlign | NeurIPS 2024 | 7B beats 70B with execution filter |
| PSV | Dec 2025 | Verification removal = -51.5%. Unique questions scale linearly. |
| V-STaR | COLM 2024 | Train verifier on correct+incorrect pairs via DPO |
| StepCoder | ACL 2024 | Break code gen into completion subtasks |
| SPIN | ICML 2024 | Self-play against previous checkpoints prevents collapse |
| WizardCoder | ICLR 2024 | Evol-Instruct: 20K→80K, +48% HumanEval |
| phi-1 | Microsoft 2023 | 1.3B matches 5x larger with textbook-quality data |
| GRPO | DeepSeek 2025 | Half compute of PPO, custom reward functions |
| Sol-Ver | 2025 | Joint code+test self-play, +19.6% |
| ADARFT | 2025 | 2-3 round advancement optimal |
| Data Quality vs Quantity | 2024 | Quality > quantity for SLMs |
| SWE-RL | 2025 | Self-play bug injection/repair |
| Escaping Model Collapse | 2025 | Verified synthetic data doesn't cause collapse |
