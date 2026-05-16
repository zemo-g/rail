# RESEARCH.md — synthesized findings for the Spur-arm arc

Compiled from 4 parallel research agents in session 83a8fbc2 (2026-05-16).
This file consolidates what the literature says about each axis of the
build so the fresh session does not need to re-research. Citations and
URLs are preserved — use them when designing each agent's deliverables.

---

## Bottom-line takeaways (read this section even if you skim the rest)

1. **Credible model size: ~15M params** (6 layers / d=384 / 6 heads / GQA),
   NOT 1M. TinyStories sets the ~1M floor for narrow constrained-grammar
   tasks but Spur-arm's *input* side is open-domain NL, which needs
   more capacity.

2. **Tokenizer**: SentencePiece-unigram, vocab=1024, trained jointly on
   NL prompts + DSL outputs, **with the 14 DSL keywords forced into the
   vocab as user-defined symbols**. Do not reuse a GPT-style web BPE.

3. **Grammar-constrained decoding makes invalid output literally impossible.**
   FSM-walked decoding over the Cmd grammar masks invalid next-tokens to
   -inf. The model only needs to learn semantics, not syntax. This is
   Spur-arm's biggest single lever.

4. **Recipe sequence: pre-train → SFT → DAPO RL → optional AZR self-play.**
   Skipping pre-train wastes the MIT-licensed paraphrase corpora
   (VirtualHome + ALFRED). Each stage's gain attaches to the prior stage,
   so order matters.

5. **The structural-advantage thesis is right but understated.** Open
   executors (Python exec, compilers) are commoditized in 2025–2026.
   The real moat is *4-stage graded verifier + <100 ms latency +
   co-designed corpus*. Lead with that framing.

---

## Prior art — landscape of LLM-emits-code-for-robot

### The three most adoptable systems

**1. Robo-Instruct** (Hsiung et al., UT Austin AMRL, 2024) —
[paper](https://amrl.cs.utexas.edu/robo-instruct/) /
[GitHub](https://github.com/ut-amrl/robo-instruct) /
[arXiv 2405.20179](https://arxiv.org/abs/2405.20179)
- Closest published template to Spur-arm's exact problem
- Self-Instruct loop augmented by a task-agnostic simulator ("RoboSim")
  during data generation, then fine-tune an open-weight code LM
- Fine-tuned ~7B class beats GPT-3.5 and Gemini-Pro on their robot DSL
- **What to copy:** the RoboSim + InstAlign loop. Our `arm_sim.rail` +
  `grader.rail` are the analog of their RoboSim. The InstAlign step
  filters substrate-generated (prompt, script) pairs through the
  simulator before adding to corpus — Agent A should mirror this.

**2. Code-as-Policies + ProgPrompt** (pair) —
- CaP ([paper](https://arxiv.org/abs/2209.07753) / [site](https://code-as-policies.github.io/)):
  prompt structure for LLM-emits-Python-that-calls-perception-and-control.
  No fine-tune, foundation-model-only. Useful for SFT-prompt shape +
  bench format.
- ProgPrompt ([paper](https://arxiv.org/abs/2209.11302)): assertion /
  precondition discipline in the emitted program. Useful when the
  model needs to *verify* a precondition before executing a Cmd
  (e.g., grip is open before close). Not in scope for bench v0 but
  worth knowing for bench v1+.

**3. Ro-SLM + TinyAgent** (pair) — distill-to-small proofs
- Ro-SLM ([arXiv 2604.10929](https://arxiv.org/abs/2604.10929)): distills
  LLM knowledge into a ~8B small LM for onboard UAV code-gen using
  LLM-aided reward + synthetic dataset. Goes from "incapable" to
  LLM-parity. The closest published "distill big to small for robot
  code" recipe.
- TinyAgent ([BAIR 2024](https://bair.berkeley.edu/blog/2024/05/29/tiny-agent/)):
  1.1B function-calling agent, LoRA-tuned, hits 78.9% — beats
  GPT-4-Turbo on structured emission. Parameter-class proof that small
  models can hit production accuracy.
- **What to copy:** Ro-SLM's LLM-aided reward design (use substrate's
  judgment as auxiliary signal beyond the grader's binary), and
  TinyAgent's LoRA-only-needed if base model is well-chosen.

### Systems to NOT copy

- SayCan, Inner Monologue: plan-level only, not code emission
- RT-1/RT-2/RT-X/OpenVLA/Octo/π0: emit *action tokens* directly, not a
  DSL — different abstraction entirely. (Octo-Small at 27M is the
  closest parameter match; ignore for our DSL goal, useful if you ever
  pivot to direct end-effector token regression.)
- VoxPoser: code emit OK but value-map intermediate is heavier than
  needed
- OK-Robot: system-integration paper, not a code-emit recipe
- LATTE: trajectory output, not DSL

### Honest gap

**No published work hits Spur-arm's exact spec** (NL → custom DSL → arm,
≤50M params, owned everything, no closed-model dependency). Below ~1B
for DSL emission is original territory. The 122B substrate is the right
anchor; Robo-Instruct's data-gen loop + Ro-SLM's distill scaffold are
the recipes worth lifting, but the ~15M end is the team's to discover.

### Full system list (skim)

CaP / ProgPrompt / SayCan / Inner Monologue / RT-1 / RT-2 / RT-X /
OpenVLA / Octo / π0 / VoxPoser / OK-Robot / LATTE / RoboCodeX /
Demo2Code / Instruct2Act / Lang2LTL / Robo-Instruct / Ro-SLM /
TinyAgent. Awesome-LLM-Robotics index:
https://github.com/GT-RIPL/Awesome-LLM-Robotics

---

## Small-model SoTA — what works at sub-50M params

### Architecture floor

**TinyStories** (Eldan & Li, 2023, [arXiv 2305.07759](https://arxiv.org/abs/2305.07759)):
transformers <10M params (some configs ~1M, single block) produce
coherent text when corpus is narrow and synthetic. Floor for "coherent
output on narrow domain": ~1M. Below that, collapses.

For NL→constrained-DSL with grammar decoder, the credible operating
point is **6 layers / d=384 / 6 heads / GQA / ~15M params**. Going
smaller (1M / d=128 / 4-layer) is too narrow for NL comprehension on
the input side, regardless of how constrained the output grammar is.

Concrete production points to mirror:
- **SmolLM** (135M / 360M / 1.7B): decoder-only, GQA, runs in-browser at 135M
- **SmolLM3** (3B): GQA + NoPE every 4th layer
- **Phi-3-mini** (3.8B): 3.3T tokens, two-phase, *synthetic textbook-quality data* was the decisive lever

### Grammar-constrained decoding

This is Spur-arm's biggest lever. Papers/recipes:

- **Synchromesh** (NeurIPS 2022)
- **IterGen** (ICLR 2025)
- **Grammar-Aligned Decoding / ASAp** (2024)
- Survey: https://github.com/Saibo-creator/Awesome-LLM-Constrained-Decoding

The mechanic: at each generation step, walk the DSL's CFG/regex state
machine to compute the set of currently-valid next-tokens. Mask all
other-token logits to -inf before softmax. Result: every sampled
sequence is syntactically valid by construction.

For Spur-arm's tiny DSL (~14 keywords, 4 Cmd variants, integer literals
in [0,30]), the FSM is small enough to bake as a Rail data structure.
Agent C owns this.

### Distillation large→small

- **Phi-3 technical report** ([arXiv 2404.14219](https://arxiv.org/html/2404.14219v1)):
  the decisive lever is *synthetic textbook-quality data* generated by
  a stronger model and human-reviewed for correctness. Quality of teacher
  generations >> raw scale.
- **Distilling Step-by-Step** (Google): smaller models match larger ones
  with *less* data when teacher emits rationales, not just answers.
- **Symmetry-Aware Code Generation** (2025): distill *pseudocode-style
  reasoning traces* (not raw code) into small students.
- **ThinkPRM** (2025): strong process verifier trained on 1% of the
  labels needed by discriminative PRMs.

For Spur-arm's 300-pair seed corpus: synthesize aggressively from
substrate, filter every generation through `grader.rail` (already
exists), aim for 10–100K SFT pairs.

### Tokenizer at this scale

For vocab <2K with 4 Cmds + ~10 keywords:

- **SentencePiece-unigram at vocab=1024**, jointly trained on NL+DSL,
  with DSL keywords pinned as user-defined symbols — the recommended
  choice. Handles NL side well, keeps DSL keywords as single tokens,
  no fragmenting.
- **Character / byte-level** also attractive (50–200 entry vocab,
  embedding table ~50 KB) — DNABERT-2 ablation showed char beats BPE in
  narrow domains. Acceptable fallback if SentencePiece-unigram
  implementation effort blocks.
- **AVOID GPT-style web BPE** — wastes tokens on irrelevant merges and
  fragments DSL keywords.

### Three concrete patterns Agent B should adopt

1. **Synthetic-corpus bootstrap, Phi-3 / TinyStories style.** Use the
   122B substrate to expand 300 → 10K–100K (prompt, script) pairs.
   Filter every pair through `grader.rail` — discard non-passing. Add
   *rationale traces* in teacher generations ("first parse intent,
   choose Cmd, fill args"); train student to emit rationale → DSL.

2. **GRPO/DAPO with compiler-as-verifier + process reward at Cmd
   boundaries.** Skip PPO (no critic = half memory). Sample N=8–16
   completions per prompt, grade each via grader, group-relative
   advantage. Add CodePRM-style step rewards at each Cmd-emit boundary —
   partial credit when prefix compilable, full credit when whole
   script reaches goal.

3. **Grammar-constrained decoding with the Cmd CFG +
   SentencePiece-1024.** Implement Synchromesh-style FSM-walked
   decoding. Combined with vocab=1024 where the 14 DSL keywords are
   pinned, a 6-layer / d=384 / ~15M-param model should clear >90%
   compile rate long before saturating substrate teacher.

Key URLs:
- TinyStories: https://arxiv.org/abs/2305.07759
- DeepSeek-R1 / GRPO: https://arxiv.org/html/2501.12948v1
- Phi-3: https://arxiv.org/html/2404.14219v1
- Constrained Decoding survey: https://github.com/Saibo-creator/Awesome-LLM-Constrained-Decoding
- DT-Fixup (deeper transformers on small datasets, text-to-SQL):
  https://aclanthology.org/2021.acl-long.163.pdf

---

## Datasets — what's publicly usable

### Tier A: NL already paired with discrete symbolic action

These are the only datasets directly usable without re-annotation.

**VirtualHome ActivityPrograms** —
[GitHub](https://github.com/xavierpuigf/virtualhome)
- ~5,193 NL descriptions → action scripts (~11.6 steps avg)
- MIT license (code); data on official server
- Action shape: `<char0> [Walk] <salmon> (1)` / `[Grab]` / `[PutBack]` —
  bracketed verb + object ID, closest in spirit to Rail DSL
- Extraction: drop char tag and object ID, map `[Walk] <X>` →
  `MoveTo(X)`, `[Grab]` → `SetGrip GripClose`, `[PutBack]` → composite
  `MoveTo + SetGrip GripOpen`. Filter to pick-and-place verbs.
- Expected after filter: **~3,000–4,000 NL→DSL pairs**

**ALFRED high-level PDDL plans (text-only slice)** —
[GitHub](https://github.com/askforalfred/alfred)
- ~25,000 language directives over ~8,000 expert trajectories
- MIT license
- Extract from `traj_data.json::plan.high_pddl`, ignore THOR pixels
  entirely
- Action shape: `GotoLocation`, `PickupObjectInReceptacle`,
  `PutObjectInReceptacle`, `CleanObject`, ...
- Remap: `GotoLocation` → `MoveTo`, `PickupObject*` → `SetGrip
  GripClose`, `PutObject*` → `SetGrip GripOpen`, drop `CleanObject`
  (out of DSL)
- Includes 3 NL paraphrases per trajectory — adds paraphrase robustness

**SayCan v0** — [HuggingFace](https://huggingface.co/datasets/chiayewken/saycan)
- 99 instruction → numbered skill plans
- CC-BY 4.0
- Tiny but exact-shape, Google-curated — useful as held-out eval +
  few-shot exemplar bank

### Tier B: NL+trajectory (not directly usable, vision-bound)

LIBERO (130 tasks, ~6500 demos, MIT) / BridgeData v2 (60k, CC-BY) /
Open X-Embodiment (RT-X, 160k tasks, CC-BY) / DROID (76k, CC-BY) /
CALVIN (20k directives, MIT) / RoboTurk / AgiBotWorld (NC-SA, not
commercial) / RH20T-P (not yet released).

All have NL but action is EEF deltas — would need re-annotation to
collapse to symbolic primitives, which is a separate annotation
project, not a drop-in.

### Tier C: text-world (analogous, different domain)

- **TextWorld** (Microsoft, MIT): generator for parser-IF games;
  unlimited NL→action-sequence pairs in fixed verb-object grammar
- **BabyAI**: 19 levels with formal "Baby Language" grammar; cleanest
  compositional NL→action benchmark; tiny action vocab (`go`,
  `pickup`, `open`, `put next to`) — useful for compositional
  generalization pre-training
- **Jericho**: 50+ human-written IF games

Domain gap from IF to physical pick-and-place is large. Use only as
compositional/parsing pre-training, not as transfer source.

### The recommended sequence (from Agent 3)

**Pre-train on VirtualHome + ALFRED high-level** (paraphrase + verb
composition prior) → **SFT on substrate-synthesized DSL-exact + seed
pairs**. Do BOTH, in this order. Pre-train alone won't get DSL syntax
right; SFT alone wastes the 30k MIT-licensed paraphrase coverage.

For Spur-arm's specific DSL syntax (`MoveTo(x,y,z)` etc), substrate
synthesis is mandatory — VH/ALFRED won't produce on-spec syntax.

---

## RLVR / process reward — 2024–2026 state

### Post-DeepSeek-R1 algorithm landscape

**DeepSeek-R1** ([Nature 2025](https://www.nature.com/articles/s41586-025-09422-z))
cemented **GRPO + binary rule-based reward** as the default RLVR recipe:
group-sample N completions, reward = compiler/test pass,
group-relative advantage normalization, no value network.

**DAPO** (ByteDance, [arXiv 2503.14476](https://arxiv.org/abs/2503.14476))
is GRPO with three drop-in improvements:
- **Decoupled clip range** (clip_high > clip_low)
- **Dynamic sampling** — drop groups where all rollouts pass or all fail
  (zero advantage anyway)
- **Token-level loss** instead of sequence-level — kills short-answer bias
- **No KL term** — KL regularization isn't doing useful work here

DAPO landed AIME 30→50 on Qwen2.5-32B at half DeepSeek-R1-Zero's
training steps. These changes are drop-in for any GRPO loop and the
most-cited 2025 improvement. **Agent C should adopt DAPO over vanilla
GRPO.**

Other 2025 GRPO successors worth knowing:
- **Dr. GRPO** — fixes GRPO's length and difficulty biases
- **VinePPO** — credit assignment with MC rollouts at intermediate states

### Process-reward models (PRM)

Modern recipe (consistent across CodePRM, FunPRM, ThinkPRM):

1. Sample many trajectories from current policy on training problems
2. Decompose each trajectory into steps (functions, lines, or
   thought-units — function-as-step is the FunPRM convention for code)
3. **Auto-label each step by MC rollout**: from step k, sample M
   continuations, label step k with empirical pass-rate (the
   "math-shepherd" pattern)
4. Train PRM as regression / classification head over step embeddings
5. During RL: use PRM scores to shape per-step advantage; during inference:
   re-rank beams

**For Spur-arm's 4-stage ladder, no thought-step segmentation is
needed — each Cmd-emit boundary is a natural step.** Auto-label each
prefix with empirical "fraction of completions reaching stage k+1".

Papers:
- **CodePRM** ([ACL 2025 findings](https://aclanthology.org/2025.findings-acl.428/)):
  PRM ingests *execution feedback* per thought-step inside a
  Generate-Verify-Refine loop
- **FunPRM** ([arXiv 2601.22249](https://arxiv.org/html/2601.22249v1)):
  treats each function as the reasoning step
- **ThinkPRM** ([arXiv 2504.16828](https://arxiv.org/abs/2504.16828)):
  verbalized PRM emits verification CoT — more data-efficient

### Compile-in-loop sampling

- **S\*** ([ACL 2025](https://aclanthology.org/2025.findings-emnlp/865)):
  iterative debug between rounds via public test execution
- **LLMloop** ([arXiv 2603.23613](https://arxiv.org/abs/2603.23613)):
  largest gain comes from the compile loop itself, not the test loop
- **Rejection sampling fine-tuning (RAFT)** ([arXiv 2504.11343](https://arxiv.org/html/2504.11343v1)):
  sample N, keep only compilers, SFT on those — shockingly competitive
  with full GRPO at small budgets. Strong cheap baseline for Agent C.

### Self-improvement loops

- **Absolute Zero / AZR** (LeapLab Tsinghua, NeurIPS 2025,
  [arXiv 2505.03335](https://arxiv.org/abs/2505.03335) /
  [GitHub](https://github.com/LeapLabTHU/Absolute-Zero-Reasoner)):
  Single model PROPOSES new tasks AND SOLVES them. Code executor is
  ONLY ground truth. Most direct architectural analog to Spur-arm —
  substitute robot-arm DSL execution for Python exec and the recipe
  transfers.
- **CURE** ([arXiv 2506.03136](https://arxiv.org/abs/2506.03136) /
  [GitHub](https://github.com/Gen-Verse/CURE)): coder and unit-tester
  co-evolve, no ground-truth code

**Collapse risk** documented in:
- **SPICE** ([arXiv 2510.24684](https://arxiv.org/pdf/2510.24684))
- "Can Large Reasoning Models Self-Train?" ([arXiv 2505.21444](https://arxiv.org/pdf/2505.21444))

Both document mode collapse in prolonged self-rewarding. Reward-hacking
spike correlates with accuracy collapse. Mitigations: corpus grounding
(SPICE), early stopping, fixed-teacher anchor, consistency regularization,
difficulty filtering. **Agent C should ship AZR as opt-in with
SPICE-style corpus anchor.**

### Frameworks

- **PrimeIntellect `verifiers`** (Will Brown, 2025,
  [GitHub](https://github.com/PrimeIntellect-ai/verifiers)): explicitly
  designed for environment-based RL with arbitrary verifier functions.
  Trainer-agnostic; pairs with `prime-rl` for async rollout. **Closest
  fit to Spur-arm's "I own a <100 ms grader."**
- **VeRL** (ByteDance), **OpenRLHF**: in-process rollout via Ray
  placement groups. Both support custom reward fns.
- **TRL/TRLX**: GRPO/DPO/PPO trainers; easiest entry, less optimized
  for high-throughput custom verifiers.

For Spur-arm (pure Rail), do NOT reuse these directly — but study
PrimeIntellect's verifier interface as a design template.

### Threats to thesis (call out honestly)

1. **Open executors are commoditized.** AZR, CURE, SWE-RL all use
   Python exec as ground truth. The "open verifier" framing is
   underspecified — Spur-arm's actual moat is **4 graded stages + <100 ms
   latency + co-designed corpus**. Frame it that way externally.

2. **Yang et al. NeurIPS 2025** ([arXiv 2504.13837](https://arxiv.org/abs/2504.13837)):
   "Does Reinforcement Learning Really Incentivize Reasoning Capacity?"
   shows RLVR amplifies base-model behaviors, doesn't add new ones —
   base model dominates RL'd model at pass@256. For small DSL with
   limited base coverage, real ceiling. Distillation may matter more
   than RL.

3. Promptfoo essay: "RLVR makes models faster, not smarter."

**Net for Agent C**: don't oversell RL. SFT will be the headline. RL
gain is a smaller delta on top.

### Three concrete recipes Agent C should adopt

1. **DAPO loss + sampling tweaks** — Yu et al. ByteDance, arXiv 2503.14476.
   Token-level loss, decoupled clip-high, dynamic sampling that drops
   all-pass/all-fail groups, drop KL. Drop-in changes to any GRPO loop.

2. **Math-Shepherd-style auto-labeled PRM over 4 stages** — CodePRM,
   ACL 2025 findings 428. For each generation, MC-rollout from each
   prefix, label each prefix with "fraction of completions reaching
   stage k+1", train PRM head, shape per-token advantage during DAPO
   with PRM scores.

3. **AZR PROPOSE/SOLVE with executor-as-truth + SPICE corpus anchor** —
   Zhao et al. LeapLab Tsinghua, arXiv 2505.03335. Opt-in self-play
   loop, off by default. Run only after SFT + DAPO plateau.
