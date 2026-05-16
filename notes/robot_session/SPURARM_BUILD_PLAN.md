# Spur-arm v0 — research-informed 4-agent build plan (draft)

Draft of 2026-05-16, post 4-agent research sweep + MaxArm hardware identification.
Subject to user review before committing to worktree agents.

---

## What we learned from research

**Prior art** ([[research-agent-a797564f]]) — `Robo-Instruct` (UT Austin AMRL,
2024) is the closest template: simulator-augmented self-instruct to
synthesize (prompt, program) pairs, then SFT an open-weight code LM
emitting a custom robot DSL. Repo: `ut-amrl/robo-instruct`. **Honest gap:**
nothing published hits "<50M params + custom DSL + owned everything" — we
are in original territory below ~1B for DSL emission. Use Robo-Instruct's
data-gen loop + Ro-SLM's distill scaffold as scaffolding, but the size
ceiling is ours to discover.

**Small-model SoTA** ([[research-agent-ade5eec8]]) — The credible operating
point is **6 layers / d=384 / ~15M params**, NOT 1M/d=128 (too narrow for
the NL-comprehension side even with a tiny output grammar). Key levers:
**SentencePiece-unigram vocab=1024** with the 14 DSL keywords pinned as
user-defined tokens; **grammar-constrained decoding** (Synchromesh /
IterGen / ASAp) makes syntactically-invalid emission *impossible*, so the
model only learns semantics. TinyStories proves the ~1M floor for narrow
constrained-grammar tasks but our NL side is open-domain.

**Datasets** ([[research-agent-a01d21f9]]) — Two MIT-licensed corpora pair
cleanly with our DSL with simple verb-remap: **VirtualHome
ActivityPrograms (~5K pairs)** and **ALFRED high-level PDDL plans (~25K
pairs)**. Together: ~30K real NL→symbolic-plan pairs as pre-training for
paraphrase robustness. Then SFT on substrate-distilled pairs (10–50K) for
DSL-exact syntax. Recipe is **pre-train on VH+ALFRED → SFT on
substrate-synth → RL** in that order — don't skip the pre-train stage.

**RLVR / process reward** ([[research-agent-a61901a6]]) — Post-DeepSeek-R1
(Jan 2025) recipe is **DAPO** (GRPO with token-level loss, dynamic
sampling, no KL term — drop-in improvements to vanilla GRPO). Add
**CodePRM-style math-shepherd auto-labeling** for process reward: MC-rollout
from each prefix, label by empirical pass-rate, train a PRM head, shape
per-token advantage. Our 4-stage ladder gives natural step boundaries.
**Absolute Zero (AZR)** is the most direct architectural analog —
PROPOSE/SOLVE self-play with executor as the only ground truth. Honest
threat to thesis: Yang et al. NeurIPS 2025 shows RLVR amplifies base
capability, doesn't add new — the real moat is *4 stages + 100ms latency
+ co-designed corpus*, not just "open verifier".

**Hardware** — MaxArm (Hiwonder), 4-DOF, ESP32 over USB. Workspace:
290mm radius × 187mm above base + 111mm below; ±120° rotation; suction-cup
gripper (vacuum on/off, not finger-position). Bundled 3×3cm blocks make
the bench v0 setup physical-ready out of the box.

---

## Updated capability estimate (vs my initial guess)

| Dimension | My initial guess | Research-corrected |
|---|---|---|
| Model size | ~1–5M params | **~15M params** (d=384, 6L) |
| Tokenizer | BPE, vocab 512 | **SentencePiece-unigram vocab=1024** with pinned DSL tokens |
| Output validity | "compile-rate measures it" | **Grammar-constrained decoding** makes invalid output impossible |
| Training data | 5–20K substrate-synth pairs | **~30K pre-train (VH+ALFRED) + 10–50K substrate-synth SFT** |
| RL algorithm | "GRPO probably" | **DAPO** (GRPO + 2025 improvements) + CodePRM process reward |
| Self-improvement | "harvest passing generations" | **AZR PROPOSE/SOLVE** with corpus-grounding anchor (SPICE) to avoid collapse |
| Real ceiling | 18–19/20 on bench v0 | Same — bench v0 is saturated by recipe, not novel terrain |

Total effort estimate ticked up from 15–25h to **25–40h** focused work.
Tradeoff: better-informed components, lower risk of mid-arc dead ends.

---

## The 4-agent plan

Worktree-isolated per [[parallel_v0_workflow]]. Each agent owns one
quadrant with a clear interface contract. Agents A/B/C have a critical
path; D runs fully parallel.

### Agent A — Corpus pipeline

**Owns:** `tools/spurarm/corpus/`

**Deliverables:**
1. `extract_virtualhome.rail` — pulls VH ActivityPrograms, applies
   verb-remap (`[Walk] X` → `MoveTo(X)`, `[Grab]` → `SetGrip GripClose`,
   `[PutBack]` → `MoveTo target + SetGrip GripOpen`), filters to
   in-DSL verbs, emits JSONL.
2. `extract_alfred.rail` — reads ALFRED `traj_data.json::plan.high_pddl`,
   ignores THOR pixels, remaps to our Cmd ADT, expands across 3 NL
   paraphrases per trajectory.
3. `synthesize_substrate.rail` — paraphrase loop: for each existing pair,
   substrate emits 5–20 alternative NL phrasings + verifies the SAME
   script still compiles+passes. Already have 300 seed pairs.
4. `dedup_filter.rail` — script-equivalence canonicalization, NL
   near-dup detection, length cap (≤12 Cmds), grader pass filter.
5. Final corpus at `training/corpora/spurarm_v0.jsonl` with three
   splits (pretrain / sft / eval) and a counter sheet.

**Interface contract:**
- JSONL schema: `{"id": str, "nl": str, "script": str, "source": "vh|alfred|saycan|substrate|seed", "stages_passed": 1..4}`
- All `script` strings parse against the current `stdlib/robot_arm.rail`
- Eval split (200 pairs) held out, never seen by trainer

**Acceptance test:** `wc -l training/corpora/spurarm_v0.jsonl` ≥ 30,000.
Random 100 from each source pass `tools/robot/grader.rail` at stage ≥ 3.

**Estimated effort:** 6–8h. Bottleneck is VH/ALFRED licensing fetch + the
verb-remap edge cases.

### Agent B — Tokenizer + base model + SFT trainer

**Owns:** `stdlib/spurarm_*.rail` + `tools/spurarm/train/`

**Deliverables:**
1. `tools/spurarm/train/build_tokenizer.rail` — SentencePiece-unigram
   trainer in pure Rail (extend `stdlib/bpe.rail` if needed), vocab=1024,
   trained on the spurarm_v0.jsonl corpus. 14 DSL keywords pinned as
   user-defined tokens.
2. `stdlib/spurarm_model.rail` — 6-layer / d=384 / 6-head / GQA
   transformer wrapper over existing `stdlib/transformer.rail`. Config:
   `model_d=384, model_layers=6, model_heads=6, model_kv_heads=2`.
3. `tools/spurarm/train/sft.rail` — SFT trainer with:
   - Two-phase: pre-train on VH+ALFRED (paraphrase prior) → SFT on
     substrate-synth + seed (DSL-exact syntax)
   - Min-checkpoint on eval-set goal-reach
   - Multi-seed fan (5 seeds at d=128 first for sanity, then 5 at d=384)
4. `tools/spurarm/train/bench_v0.rail` — runs the bench v0 grader
   harness against any checkpoint at N=1 and N=20.

**Interface contract:**
- Tokenizer at `training/tokenizer/spurarm_v0_sp1024.model`
- Checkpoint format compatible with existing `stdlib/checkpoint.rail`
- Bench result emits a `[CHECKPOINT_GRADE]` block parseable by chain watcher

**Acceptance test:** First SFT model (no RL) hits ≥ 12/20 single-shot on
bench v0. Below 8/20 = data-quality or architecture issue, escalate.

**Estimated effort:** 10–14h. Bottleneck is bench tuning + multi-seed fan
wall-clock.

### Agent C — Grammar-constrained decoder + RLVR loop

**Owns:** `tools/spurarm/decode/` + `tools/spurarm/rl/`

**Deliverables:**
1. `tools/spurarm/decode/constrained_decode.rail` — FSM-walked decoder
   that consumes the Cmd grammar and at each token emits the set of
   valid next-tokens; sampling masks invalid logits to -inf.
   Synchromesh-style. Compatible with existing `lm_infer_cpu.rail`.
2. `tools/spurarm/rl/dapo.rail` — DAPO trainer:
   - Group sample N=16 completions per prompt
   - Dynamic sampling (drop all-pass / all-fail groups)
   - Token-level loss (not sequence-level)
   - No KL term
   - Uses `tools/robot/grader.rail` as the verifier
3. `tools/spurarm/rl/process_reward.rail` — CodePRM-style auto-labeled
   process reward at Cmd-emit boundaries. MC-rollout from each prefix
   during training. Stage-level rewards: 0.1 / 0.25 / 0.5 / 1.0 for
   stages 1 / 2 / 3 / 4.
4. `tools/spurarm/rl/azr_selfplay.rail` — opt-in PROPOSE/SOLVE loop
   with SPICE-style corpus-grounding (anchor a fraction of rollouts
   on seen-corpus prompts to prevent collapse). Off by default; ship
   the recipe, run it only after SFT+DAPO plateau.

**Interface contract:**
- Decoder takes `(tokenizer, model_state, prompt_ids)` → emits valid
  Cmd-stream token-by-token
- RL trainer emits stage-counter sentinel block readable by the chain
- Process reward implemented as a pluggable function (model can be
  swapped, e.g., learned PRM vs. rule-based)

**Acceptance test:** After 1 round of DAPO (post-SFT), bench v0 single-
shot lifts by ≥ 2 prompts from SFT baseline. Constrained-decode forces
100% compile rate (stage ≥ 1) on any output.

**Estimated effort:** 8–10h. Bottleneck is grammar-FSM correctness and
on-policy rollout speed.

### Agent D — MaxArm protocol driver + integration

**Owns:** `tools/robot/arm_real.rail` + `tools/robot/talk_arm.sh`

**Deliverables:**
1. `tools/robot/arm_real.rail` — pure-Rail USB-serial driver. Reads
   `/dev/cu.usbserial-*` (or whichever the MaxArm enumerates as), speaks
   the Hiwonder LX-bus protocol or the firmware's serial command set
   (research the exact protocol from the MaxArm SDK or sniff the
   official Python). Same `Cmd` interface as `arm_sim.rail` — drop-in
   replacement.
2. `tools/robot/coord_map.rail` — translates DSL ints (0..30 cm cube) to
   real arm joint targets via inverse kinematics. 4-DOF IK is tractable
   in closed form for an articulated arm.
3. `tools/robot/calibrate.rail` — one-time calibration routine: arm
   visits named points A–D, user confirms position, table is persisted.
4. `tools/robot/talk_arm.sh` — variant of `talk.sh` that uses
   `arm_real.rail` instead of `arm_sim.rail`. State tracking shifts from
   sim-state to live-arm-state (queried from arm or modeled from cmds).
5. `tools/robot/replay_cmd_log.sh` — replays a `/tmp/arm_commands.log`
   against the real arm. Smoke test for any prior talk.sh session.

**Interface contract:**
- `arm_real.rail` exports the same `run_sim_*` family of functions as
  `arm_sim.rail`, so the grader works unchanged
- Calibration table at `~/.robot/maxarm_calib.txt`
- Safety bounds enforced at the driver layer (workspace clip,
  velocity cap, e-stop)

**Acceptance test:** With MaxArm physically connected, `talk_arm.sh`
executes "grab the ball and put it at B" successfully — the suction-cup
gripper picks up the bundled 3×3cm block at one named point and
releases at another. Bench v0 end-to-end on hardware: ≥ 15/20.

**Estimated effort:** 6–10h. Bottleneck is whichever of (a) sniffing the
MaxArm serial protocol, (b) tuning IK for this specific 4-DOF geometry,
(c) USB device permissions on macOS. Can start in parallel with A/B/C
since the DSL is frozen.

---

## Critical path + dependencies

```
A (corpus) ─┐
            ├─► B (tokenizer+SFT) ─► C (decode+RL) ─┐
            │                                       ├─► integrated demo
D (MaxArm driver) ───────────────────────────────────┘
```

- A blocks B (need corpus to train tokenizer + first SFT)
- B blocks C (RL needs an SFT base policy)
- D is fully parallel — depends only on the frozen DSL + Cmd interface
- Integration is talk.sh swapping `call_substrate.sh` → trained-Spur-arm
  inference + `arm_sim.rail` → `arm_real.rail`

**Wall-clock estimate:** Without parallelism, ~30–42h. With 4 parallel
agents (worktrees), ~10–15h on the critical path A→B→C, with D
finishing inside that window. Add 2–3 sessions of integration + bench.

---

## Risks and honest unknowns

1. **Pre-train domain gap.** VirtualHome and ALFRED use different verb
   sets and object names than our DSL. The verb-remap is structural; the
   *object* references won't match (`<salmon>` not in our world).
   Mitigation: drop object names during pre-train, replace with a
   `<obj_N>` slot, fill from substrate during SFT.

2. **15M params may still be too small.** TinyStories sets the floor for
   narrow tasks but the NL side is open-domain. If first SFT lands
   below 10/20, scale to d=512 or 8 layers.

3. **MaxArm 4-DOF means no wrist roll.** Some bench prompts that imply
   orientation ("stack the block neatly") may not be expressible. Bench
   v0 was reachability-only — fine. Bench v1+ may need to constrain
   prompts to the arm's actual DOF.

4. **Suction-cup gripper has different semantics than finger gripper.**
   Vacuum on at correct position → object attaches. If misaligned by
   >1cm in real life, pickup fails. Need calibration tighter than the
   sim's 1cm tolerance.

5. **inference_seed_segfault.** Known unknown in Rail's lm_infer
   pipeline. May bite during inference deployment. Possibly forces a
   detour to fix the underlying compiler/runtime bug.

6. **RLVR may not lift above SFT.** Per Yang et al. NeurIPS 2025, RLVR
   amplifies but doesn't add. If SFT lands at 18/20, RL might gain 1
   prompt at best. Plan accordingly — don't overpromise the RL phase.

---

## First concrete step (low-cost commitment)

Harvest the existing N=20 rerank completions in
`/tmp/robot_completions_rerank/` into `training/corpora/spurarm_seed.jsonl`.
This is ~30 min of work and freezes the 300 substrate-graded pairs we
already accidentally generated. Doesn't commit to the rest of the arc.

After that: **stage VH + ALFRED downloads, build the corpus pipeline
(Agent A), and stop before training kicks off** for a user budget check.

---

## Related

[[mission]] — Rail-on-Rail is the only goal. This arc cashes it out
on a real downstream task.
[[structural_advantage_thesis]] — what makes Rail's owned-verifier RLVR
viable at small scale.
[[parallel_v0_workflow]] — the 4-agent worktree discipline.
[[robot_arm_flywheel_2026-05-16]] — the substrate baseline this builds on.
[[spur_lineage_archive]] — Spur's recipe history; d=384 is at the edge
of what's been stable.
[[feedback_blob_slice_fan_condense]] — the multi-seed fan + condense
pattern Agent B should use.
