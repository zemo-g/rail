# Spur Revolution — 20-hour adaptive game plan
**Date:** 2026-05-06
**Trigger:** Naked Qwen-122B + 1KB Rail spec hit 29/30 compile in 2:23 wall, beating Spur ensemble (24/30 across 39+ ckpts). Substrate-thesis validated; old framing "Spur cracks the bench" is dead.
**Author:** session continuation from 325cb12 (grammar-walk climb).

---

## 1. The thesis update

**OLD Spur thesis:** A small Rail-trained model + open verifier should beat closed-verifier setups via compile-in-loop techniques.

**NEW thesis (post-substrate finding):** Rail's open compiler is a *substrate-level* structural advantage. Any sufficiently capable open-weight model + Rail's spec ≈ ceiling on the canonical bench. Spur's surviving role is the **small-scale RLVR research testbed** where techniques unique to owning the verifier — process rewards, parse-trace aux loss, GRPO on compile-pass, compile-in-loop sampling, grammar-walked curriculum — can be studied at fast iteration speed and without depending on closed-weight teachers.

**The publishable claim we're chasing:**
> On Rail, owning the verifier produces an X-point lift on compile rate at 1.7M params, irreducible to model scale, supervised data volume, or sampling budget. Demonstrated by ablation: same architecture, same data, same compute — only the verifier-coupling differs.

That's the single artifact this 20 hours should produce.

## 2. Floors to protect

- **24/30** ensemble compile-pass (`spur_ensemble_ceiling_24_of_30.md`)
- **10/30** v54 single-best strip-graded (`strip_lever_validated_2026-05-04.md`)
- **29/30** substrate-level via teacher + spec (this session)
- The 137-test compiler suite (`./rail_native test`)
- The 35M+ tokens of compile.rail-trained ckpts already in `training/checkpoints_published/`

Falling = run over (`feedback_endurance_climb.md`). Min-checkpoint at every new low (`min_checkpoint_lever.md`).

## 3. Phases

Each phase has explicit pass/fail signal. If a phase fails to clear its gate, **pivot** to the listed fallback. Don't sink time chasing a dead lever.

### Phase I (0-3h) — Close out tonight + ground-truth the substrate

**Goal:** Lock in the 29-30/30 substrate result, establish a *harder* benchmark so we have headroom.

- [ ] N=20 stability rerun of full-bench-teacher probe with extended spec. **Gate:** ≥28/30 mean across 3 runs. If <26, the spec is fragile, debug.
- [ ] Build `flywheel-local/bench_hard_30.rail` — 30 prompts harvested from compile.rail's harder subgraphs (parser combinators, code emission, type checker passes). Should cause naked teacher to score <60%.
- [ ] Establish substrate ceiling on hard-bench (N=3, N=20).
- [ ] Save `comprehension_cracked_substrate.md` (DONE) + sibling `substrate_thesis_2026-05-06.md` capturing the publishable claim.

**Pivot if blocked:** if the teacher endpoint is unstable, fall back to per-prompt batched calls with retry; if hard-bench is too hard (teacher <10%), make it easier so we have signal.

### Phase II (3-9h) — Compile-graded distillation pipeline → Spur-v100

**Goal:** Manufacture training data for Spur using the substrate, train, prove distillation lifts Spur's bench ≥5pp.

The recipe leans on three findings from the morning's reading:
- **1-shot RLVR (arxiv 2504.20571):** policy gradient with verifiable rewards lifts dramatically; entropy bonus is critical.
- **SEAL (arxiv 2506.10943):** model-generated synthetic data + RL-on-self-edits, with catastrophic forgetting flagged.
- **MBTL (arxiv 2408.04498):** strategic task selection > exhaustive coverage; 5-50× efficiency.

For Phase II we use the substrate as the data engine:

- [ ] Generate ~500 prompts by **walking compile.rail's call graph** — pick a random function, mutate the body, mask out the body, ask teacher to refill.
- [ ] For each prompt, run teacher × N=20, compile-filter, keep all passes.
- [ ] Expected yield: 200-400 verified-pass programs (most prompts pass, some don't).
- [ ] Add to corpus: existing 90KB compile.rail back-quarter + 200KB distilled-pass corpus.
- [ ] Train Spur-v100 at d=256 × 2-block × 3000 steps × seed=77 (back-quarter recipe), keep min-ckpt.
- [ ] Bench against `bench_strip.rail` and `bench_hard_30.rail`.

**Gate:** Spur-v100 ≥15/30 on canonical bench (vs v54's 10/30). +5pp = distillation works.

**Pivot if blocked:**
- If Spur-v100 underperforms v54: filter logic is wrong (probably keeping near-duplicates) — switch to MBTL-style strategic selection (pick prompts that maximize per-prompt coverage diversity).
- If teacher times out / 8081 dies: switch teacher to `Qwen3-VL-30B` (also on 8081).
- If training NaNs (history says d=512 NaN'd; lower d): drop to d=192.

### Phase III (9-15h) — RLVR on Spur — GRPO-on-compile-pass

**Goal:** Land the headline experiment. Implement GRPO with compile-pass reward in the Rail trainer, run on Spur-v100, prove RLVR lift over the supervised baseline.

This is the experiment unique to owning the verifier — no closed-verifier setup can do this exact loop.

- [ ] Add GRPO loss head to `tools/train/lm_v07_d384_minckpt.rail` (or fork to `lm_v08_grpo.rail`):
    - Group of K=8 rollouts per prompt (fits CPU substrate per `cpu_inference_substrate.md`)
    - Per-rollout reward = compile-pass binary (0 or 1)
    - Group-relative advantage: $A_i = (r_i - \bar{r}) / \sigma$
    - Policy gradient loss: $-\log\pi(\text{tok}) \cdot A$
    - Entropy bonus: $+\beta \cdot H(\pi)$ (per One-Shot-RLVR; β to tune)
    - KL-to-base regularization to mitigate forgetting (per SEAL warning)
- [ ] Start with 1-shot RLVR replication: pick the single prompt that has highest variance (some seeds compile, some don't), run 50 GRPO steps with K=8.
- [ ] Bench every 25 steps.

**Gate:** Spur-v100-grpo ≥+3pp over Spur-v100 supervised baseline within first 100 steps.

**Pivot if blocked:**
- If GRPO doesn't show lift in 30 min training: swap to **ReST** (per SEAL) — simpler, supervised-on-rollout-passes, retrains every K rollouts. Faster to debug.
- If GRPO+ReST both flat: the lever is **process rewards** (per `structural_advantage_thesis.md`) — bin compile-pass by error type (parse vs type vs link), 8-bin granular grader.
- If all three flat: the lever is **parse-trace aux loss** (per `inline_parse_trace_falsified.md` — the inline form failed but two-channel might not).

### Phase IV (15-20h) — Capstone + write-up

**Goal:** Whichever lever from Phase III worked, scale it. Then write the thesis claim.

- [ ] Scale the winning lever: more prompts, more rollouts, more steps.
- [ ] Run **the ablation** that produces the claim: same data + same compute, with vs without verifier-coupling. Delta = structural advantage in numbers.
- [ ] Compile-in-loop sampling on top of best Spur ckpt — per parse-tier validation in `grammar_walk_climb_2026-05-05.md`. Bench compile-pass with verifier vs without.
- [ ] Draft `docs/plans/SUBSTRATE_THESIS_2026-05-06.md` capturing the claim, the ablation table, the recipe, and reproducibility notes.
- [ ] Update memory entries: `structural_advantage_thesis.md`, `comprehend_is_semantic.md` (now substrate-level falsified), `spur_ensemble_ceiling_24_of_30.md` (now framed as ensemble-only-claim).
- [ ] Write `2026-05-06-substrate-pivot.md` handoff for next agent.

**Gate:** A single artifact (the thesis doc) with one number, one ablation, one recipe.

## 4. Adaptation rules

1. **After each phase, re-rank remaining phases by what we learned.** If Phase II produces shocking lift (e.g., Spur-v100 = 22/30), Phase III's gate moves up; if Phase II crawls (Spur-v100 = 11/30), Phase III's first move is to investigate why distillation barely helped before piling on RL.
2. **Don't push a flat lever past its gate window.** 30 min of training without lift → pivot. Sunk-cost thinking is the enemy of an adaptive plan.
3. **Each pivot has a prepared fallback** — listed above for each phase. No improvising blind alleys.
4. **Continuous handoff log.** Every phase ends with a 5-line journal entry in `docs/plans/SPUR_REVOLUTION_LOG_2026-05-06.md` so that if the session is interrupted, the next agent picks up at the last gate.
5. **Protect the floors.** Min-checkpoint at every new bench low; don't overwrite v54 or v48; commit every artifact before iterating.
6. **The teacher is a tool, not a competitor.** Use it to manufacture data, generate candidates, validate ideas — but the *artifact* is Spur (open-weight, 1.7M, portable). Substrate sets the ceiling, Spur tells the story.

## 5. Risks + mitigations

| Risk | Mitigation |
|---|---|
| Teacher endpoint dies for hours | Cached rollouts on disk; fall back to smaller model on same server |
| GRPO numerically unstable at 1.7M params | Start at 1-shot RLVR scale; small LR (0.001), high KL coefficient |
| Distillation produces over-fitted near-duplicates | MBTL-style diversity selection, dedup by prefix-hash |
| Inference seed segfault recurs (`inference_seed_segfault.md`) | Per memory, drop arena_reset from gen_loop; seed-vary fixed already |
| Catastrophic forgetting during RL | KL-to-base regularization, every-50-step bench compare, min-ckpt protocol |
| Compiler bootstrap breaks | Don't edit `compile.rail` Phase II-IV unless absolutely necessary; route changes through forks of `lm_v07` |

## 6. The single number this 20 hours produces

A 2×2 ablation on a fixed Spur architecture + fixed compute:

| | Verifier in loop | Verifier off |
|---|:-:|:-:|
| Distilled corpus only | A | C |
| Distilled + RLVR | B | D |

Where:
- A − C = compile-in-loop sampling advantage (structural-A)
- B − A = RLVR-on-compile-pass advantage (structural-B)
- B − D = total structural advantage of owning the verifier
- D = the closed-verifier baseline upper bound at this scale

If B − D ≥ 5pp on canonical bench: thesis confirmed at small scale. That's the publishable claim.

## 7. What this is NOT

- Not a chase to crack 30/30. Substrate already does it; that game is over.
- Not a defense of the old "Spur as flagship" framing. Spur becomes the testbed; substrate becomes the flagship.
- Not a corpus-scaling exercise. Compile-zero-wall confirmed corpus mixing collapses (`compile_zero_wall.md`); levers are architectural and reward-shaped, not corpus-volume.
- Not a Spur-only experiment. The substrate finding *is* a Spur finding too — both serve the same Rail-on-Rail mission.
