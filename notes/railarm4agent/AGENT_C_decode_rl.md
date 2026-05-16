# Agent C — constrained decode + DAPO RL (worktree-isolated brief)

You are Agent C in a 4-agent parallel build of Spur-arm. The overall
plan is in `notes/railarm4agent/README.md`; the research synthesis is
in `notes/railarm4agent/RESEARCH.md`. Read both before starting. Then
read THIS file end-to-end before writing any code.

You own grammar-constrained decoding and the reinforcement-learning
phase. You depend on Agent B's base SFT checkpoint. Your output is the
final Spur-arm-v1 model.

---

## Mission

Two deliverables:

1. **Grammar-constrained decoder** that makes syntactically-invalid DSL
   output literally impossible — the model can only sample valid Cmd
   sequences. This guarantees stage ≥ 1 (compile) for 100% of
   generations.

2. **DAPO RL phase** that lifts bench v0 single-shot by ≥ 2 prompts over
   Agent B's SFT baseline. Adoptable: DAPO (token-level loss, dynamic
   sampling, no KL), CodePRM-style process reward over our 4 stages,
   optional Absolute Zero self-play with corpus anchor.

Honest expectation: per Yang et al. NeurIPS 2025
([RESEARCH.md → RLVR → Threats to thesis]), RLVR amplifies base
behaviors but doesn't add new ones. SFT will be the headline; RL is
a smaller delta. Plan accordingly — don't oversell.

---

## Required reading before starting

1. `notes/railarm4agent/README.md`
2. `notes/railarm4agent/RESEARCH.md` — especially **RLVR / process reward**
3. `notes/railarm4agent/AGENT_B_train.md` — to understand checkpoint format
4. `stdlib/spurarm_model.rail` (Agent B's output) — model wrapper
5. `tools/robot/grader.rail` — the verifier
6. `stdlib/robot_arm.rail` — DSL whose grammar you'll FSM-walk
7. Memory: `chain_caught_five_wrong_leverage_swings` — propose chain
   entry with kill_target BEFORE swinging
8. Memory: `feedback_diagnostics_first` — counters before optimization
9. Memory: `inference_seed_segfault` — known: ~50% seeds crash at
   `--max 128 --k 10`; argmax (`--k 1`) is safe
10. Memory: `feedback_verify_removals` — if you remove the constrained
    decoder guard, write the falsifying smoke test FIRST

---

## Part 1: Grammar-constrained decoder

### The grammar (FSM)

The Cmd DSL is a small context-free grammar. Spelled out:

```
script   ::= "script" "=" "[" cmd_list "]"
cmd_list ::= cmd ("," cmd)*  | ε
cmd      ::= move | grip | wait | "Home"
move     ::= "MoveTo" int int int
grip     ::= "SetGrip" ("GripOpen" | "GripClose")
wait     ::= "Wait" int
int      ::= "0" | nonzero_digit digit*
nonzero_digit ::= "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9"
digit    ::= "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9"
```

For Spur-arm v0, `int` is further constrained to [0, 30] (workspace
cap). The decoder enforces this at integer-emission states.

### Files

```
tools/spurarm/decode/
├── README.md
├── grammar.rail           # the FSM: states, transitions, valid-next-token sets
├── grammar_smoke.rail     # smoke harness that exercises every transition
├── constrained_decode.rail # the decoder: takes (tokenizer, model, prompt_ids), emits valid Cmd sequence
├── decode_bench.rail      # bench-v0 evaluation with constrained decoding on
└── decode_compare.rail    # A/B compare: free decode vs constrained on N=100 prompts
```

### Algorithm (Synchromesh-style)

At each generation step:

1. The decoder maintains a `grammar_state` (the current FSM node).
2. Given the prompt + tokens-generated-so-far, the model produces
   logits over the full vocab.
3. From the current `grammar_state`, compute the set of token IDs that
   correspond to legal next-tokens (this set is precomputed per state).
4. Mask all other logits to -inf (or -1e9, large negative).
5. Apply softmax over the masked logits, sample (or argmax).
6. Advance `grammar_state` per the chosen token's transition.
7. If `grammar_state` is terminal (saw closing `]` + `<eos>`), stop.

Edge cases to handle correctly:
- Integers are multi-token in SentencePiece-1024 — the FSM must allow
  any digit at start, and any digit OR a separator/closer after the
  first digit, with [0,30] bound enforcement
- `MoveTo` requires exactly 3 integers separated by spaces (or by
  whatever tokenizer produces between them — verify in your tokenizer)
- Trailing comma before `]` is invalid — FSM rejects
- `<eos>` is only legal at the script-end state

### Pre-compute valid-token sets per state

To avoid recomputing at every step, build a table at startup:

```rail
-- valid_tokens : Map<grammar_state_id, list<token_id>>
```

For Spur-arm's tiny grammar (~30 states), this table is ~30 × ~50
tokens = ~1500 entries. Negligible.

### Compatibility with Agent B's inference

Hook into Agent B's inference path. Likely Agent B exposes a
`generate_next_token logits` function or similar; wrap it with the
constrained mask. If Agent B's inference is monolithic and doesn't
expose a hook, work with the integration session to refactor it —
the constrained decoder MUST be the production inference path.

### Acceptance test for Part 1

```bash
# Smoke: all FSM transitions reachable
./rail_native run tools/spurarm/decode/grammar_smoke.rail
# expects: "transitions_tested=<N> all_reachable=true"

# Compare: constrained vs free decoding on Agent B's best ckpt over bench v0
./rail_native run tools/spurarm/decode/decode_compare.rail
# expects:
#   free_decode_compile_rate >= <Agent B baseline>
#   constrained_decode_compile_rate == 100
#   constrained_decode_goal_reach >= free_decode_goal_reach - 1
```

**PASS** if constrained-decode compile rate is exactly 100% AND
goal-reach is within 1 of free-decode (i.e., constraints don't hurt
semantics).

**FAIL** if constraints suppress semantically-correct outputs (loss of
≥ 2 prompts in goal-reach) — the grammar is wrong or the FSM has bugs.

---

## Part 2: DAPO RL phase

### Files

```
tools/spurarm/rl/
├── README.md
├── rollout.rail              # group-sample N completions per prompt, returns (prompt, completions, grades)
├── dapo.rail                 # the DAPO trainer: token-level loss, dynamic sampling, no KL
├── process_reward.rail       # CodePRM-style auto-labeled process reward over 4 stages
├── shaped_advantage.rail     # combines stage-reward + group-relative advantage
├── azr_selfplay.rail         # opt-in: propose + solve loop with SPICE corpus anchor
├── train_loop.rail           # the actual driver, calls dapo.rail steps
└── rl_bench_eval.rail        # per-step bench evaluation
```

### DAPO recipe (the 2025 GRPO successor)

Drop-in changes vs vanilla GRPO:

1. **Decoupled clip range**: `clip_low = 0.2`, `clip_high = 0.28`
   (asymmetric; more room to increase preferred-action probability)
2. **Dynamic sampling**: after group-sampling N completions, if ALL
   pass or ALL fail, drop the entire group from the gradient step
   (zero advantage anyway). Re-sample fresh prompts.
3. **Token-level loss**: weight per-token, not per-sequence. Removes
   the short-answer bias. Concretely: loss is averaged over tokens
   in the rollout, not over sequences.
4. **No KL term**: remove the `β * KL(π || π_ref)` term entirely. KL
   was preventing reward hacking in alignment work, but for verifiable
   tasks it's just regularization slowing convergence.

### Hyperparameters

| Param | Value | Why |
|---|---|---|
| Initialize from | Agent B's `spurarm-base-v0_best.ckpt` | |
| Group size N | 8 | Lower than 16 to fit Studio memory; can lift if param-efficient |
| Prompts per batch | 8 | 8 × 8 = 64 rollouts per step |
| Learning rate | 1e-5 | An order of magnitude lower than SFT; RL is delicate |
| LR schedule | constant or cosine to 1e-6 | |
| Clip low | 0.2 | |
| Clip high | 0.28 | DAPO asymmetric |
| KL coefficient | 0.0 | DAPO |
| Steps | 500 | Watch metrics; can stop early |
| Eval every | 50 steps | bench v0 single-shot |
| Decoder | constrained (Part 1) | always |
| Sampling | temperature=0.9, top-k=50 | diversity for rollouts |

### Process reward (CodePRM-style)

Each completion gets a stage-ladder reward:
| Stage reached | Reward |
|---|---|
| 0 (no script defined, but grammar forced this can't happen) | -1.0 |
| 1 (compiles only) | 0.1 |
| 2 (parses, faults at runtime) | 0.25 |
| 3 (runs without fault, wrong final state) | 0.5 |
| 4 (goal reached) | 1.0 |

Process bonus at each Cmd-emit boundary: if the prefix-so-far would
have been a valid stage-≥3 script if terminated immediately,
+0.05/Cmd. (Encourages incremental correctness.)

This implements the math-shepherd auto-labeling pattern from CodePRM
(ACL 2025), simplified — we don't need a learned PRM head when the
verifier is this cheap.

### Advantage normalization (group-relative)

Within each prompt's group of N completions:
```
advantage_i = reward_i - mean(reward_group) / (std(reward_group) + 1e-6)
```

This is standard GRPO. DAPO doesn't change it.

### Dynamic sampling check

After grading the group:
- If `min(rewards) == max(rewards)`, drop the group (no signal).
- Re-sample a different prompt from the SFT corpus to replace.

### Acceptance test for Part 2

```bash
# Sanity: rollout returns properly-structured grades
./rail_native run tools/spurarm/rl/rollout.rail --n=8 --prompts=tools/robot/bench_v0.txt
# expects: 8 grades per prompt, schema-valid

# Training run, watch bench v0
./rail_native run tools/spurarm/rl/train_loop.rail --steps=500 --base=spurarm-base-v0_best.ckpt

# Final bench
./rail_native run tools/spurarm/rl/rl_bench_eval.rail --ckpt=training/checkpoints/spurarm-rl-v0_final.ckpt
# expects:
#   bench_v0_single_shot >= Agent B baseline + 2
#   compile_rate == 100 (constrained decoding maintained)
```

**PASS** if RL lifts single-shot bench v0 by ≥ 2 prompts AND
constrained-decode compile rate stays 100%.

**INCONCLUSIVE** if lift is +1: ship the RL ckpt but note honestly.

**FAIL** if RL drops bench v0 score from SFT baseline (reward hacking
or instability). Revert to SFT-only model; document RL failure on
chain with hypothesis for why.

---

## Part 3 (optional): AZR self-play

Run ONLY after Part 2 passes AND has plateaued. Off by default.

### Pattern (Absolute Zero, Zhao et al. NeurIPS 2025)

The model is trained in two modes that alternate:

1. **Propose**: model emits a new (NL prompt, expected world state)
   pair. Reward = "learnability": non-trivial pass rate at current
   policy (between 20% and 80% on N=8 rollouts).
2. **Solve**: same model emits a script for a generated prompt. Reward
   = stage-ladder grade.

**Critical**: corpus anchor. Per SPICE (arXiv 2510.24684), reserve
≥30% of rollouts on the SEEN corpus from Agent A. This prevents the
mode-collapse documented in "Can Large Reasoning Models Self-Train?"
(arXiv 2505.21444).

### Acceptance test for Part 3

```bash
# Only run if Part 2 passed AND post-DAPO bench plateaued for 2 consecutive 50-step intervals
./rail_native run tools/spurarm/rl/azr_selfplay.rail --steps=500 --base=spurarm-rl-v0_final.ckpt

# Bench
./rail_native run tools/spurarm/rl/rl_bench_eval.rail --ckpt=training/checkpoints/spurarm-azr-v0_final.ckpt
```

**PASS** if AZR lifts bench v0 by ≥ 1 prompt over Part 2.
**INCONCLUSIVE** if it's neutral. **FAIL** if it drops; ship Part 2's
ckpt as the final.

If Part 3 plateaus or collapses, it's a known risk per RESEARCH.md;
don't escalate, document.

---

## Chain entry

On completion (Part 1 + Part 2 done, Part 3 either done or skipped),
append chain entry with parent equal to Agent B's chain entry id.
cmd points to `tools/lab/watchers/spurarm_rl_c.sh`:

```
===RAIL_LAB_COUNTERS===
{"counter": "constrained_compile_rate_pct", "value": 100}
{"counter": "rl_bench_v0_single_shot", "value": <N>}
{"counter": "rl_bench_v0_lift_vs_sft", "value": <delta>}
{"counter": "rl_steps", "value": <N>}
{"counter": "azr_enabled", "value": <0|1>}
{"counter": "azr_bench_lift", "value": <delta or 0>}
===END===
===VERDICT=== <PASS|INCONCLUSIVE|FALSIFIED>
```

---

## Out of scope for Agent C

- Tokenizer (Agent B owns)
- Base model architecture (Agent B owns; you only fine-tune)
- Corpus generation (Agent A owns)
- MaxArm hardware (Agent D owns)
- Fixing `inference_seed_segfault` (work around with argmax; do not
  attempt to fix unless it actively blocks)
- Bench v1+ prompts (separate arc)
- Distillation back to substrate (separate arc)

---

## Discipline reminders

- **Constrained decode FIRST**: do Part 1 completely before Part 2.
  Otherwise RL trains against free-decode noise (the model emits
  invalid syntax, gets stage-0 reward, learns nothing). Constraints
  make every rollout meaningful.
- **Counter discipline**: emit per-step bench scores + reward
  distribution histograms BEFORE training. Watch them move.
- **Dynamic sampling validation**: log dropped-group rate. If it
  exceeds 30%, your model is too good (every prompt passes) or too
  weak (every prompt fails) — bench is wrong-shaped for the current
  policy.
- **No KL term means watch for reward hacking**: if RL drives val_loss
  up while bench improves, model is overfitting to the verifier in a
  surface way. Per memory `feedback_verify_removals`, write a
  falsifying smoke test BEFORE removing safety guards.
- **`chain_caught_five_wrong_leverage_swings`**: propose your chain
  entry's kill_target BEFORE the run, not after. The chain refuses
  fuzzy work for a reason.
- **`feedback_endurance_climb`**: tiny verifiable steps. 50-step RL
  runs first, then 200, then 500. Falling = run over.
- **No commits to main**: stage on `spurarm/C-decode-rl` branch.

---

## Estimated effort

8–10 hours. Bottlenecks:
- Grammar FSM + smoke harness (2–3h)
- Constrained decoder integration with Agent B's inference (1–2h)
- DAPO trainer (3–4h: rollout, advantage, loss, step loop)
- 500-step RL run + eval (1–2h wall-clock)
- AZR (optional) (2h additional if run)
- Chain entry + handoff (0.5h)

If you exceed 15 hours and Part 2 still fails, ship Part 1 alone (100%
compile rate is itself a win) and mark Part 2 INCONCLUSIVE.
