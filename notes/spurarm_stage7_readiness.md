# Spur-arm Stage 7 push — readiness draft

Authored 2026-05-17 at Stage 6 close. Stage 6 chain entries `3fe12ce2`
(pre-probe, Cap E falsified inline), `b9cca3cc` (Cap F FALSIFIED),
`64b4445e` (Cap D FALSIFIED). User decision 2026-05-17: keep pushing the
own-model branch — "pure Rail + Rail ML controlling the arm is the goal."

## Stage 6 finding — restated

**val_loss ⊥ bench at single-block 2M params is robust.** Three caps
(B sampling, C d=128 scale, D RoPE) all moved val_loss without moving
bench. Cap D got val_loss 2.97 (lowest ever) and 0/20 bench. The cap is
not decoding, not EOS supervision, not positional architecture. After
the bench cleanup (commit `baf661b`), reference scripts still pass
20/20 so the bench itself is trustworthy.

Honest model-alone bench across all 7 d=64 single-block ckpts: **0/20**.

## The cap, now better-located

Two layers shifted up:

1. **Corpus distribution.** v1 corpus is 1500 examples, 56% procedural-
   template. Model learns this distribution well (val_loss 2.97) and
   that distribution does NOT induce compilable-Rail capability. See
   [[spurarm_recipe_cap_is_corpus_not_recipe_2026-05-16]].
2. **Model scale.** Single-block 2M params can fit the corpus but
   cannot compose multi-step DSL constructs. railarm4agent spec calls
   for 14.7M params at 6L d=384 — never trained.

Plus a third lever **never tested**:

3. **Decoding under grammar constraint.** Cap F tested no-repeat-3gram
   + min-gen on a degenerate token distribution. A grammar-walked
   decoder (parser as token filter — zero any token that violates Rail
   DSL grammar at the current parse state) sidesteps the degeneracy
   entirely: even a degenerate model can produce parseable output if
   non-parseable tokens are masked at decode time.

## The structural caps — three named candidates

### Cap G: substrate-bootstrapped corpus

The substrate-thesis pipeline (Qwen + 1KB Rail/arm spec) lands 30/30
on hard bench (chain `8f467ff0`, `66bb63f9`). That means the substrate
**can generate** the corpus distribution that v1 corpus lacks. Each
generated example is compile-verified + grader-verified before
inclusion, so the corpus is by-construction compile-clean.

Hypothesis: a 10K substrate-bootstrapped corpus, length-distribution
matched to eval (mean total_len 57-71, mixed pickup/move/multi-step
shapes), trained-on at any scale yields bench >> v1-corpus equivalent.

### Cap I: grammar-constrained decode (free probe)

Walk a Rail-DSL parser alongside the decoder. At each step:

- Take the model's next-token distribution
- Zero out tokens that would create an unparseable continuation given
  current parse state
- Argmax over the surviving distribution

Implementation: a small Rail grammar in `stdlib/rail_grammar.rail`
exposing a function `grammar_allowed_tokens(parse_state, V)` returning
a bitmask. `tools/spurarm/train/generate.rail` gains `--grammar` flag
that masks probs before argmax.

Hypothesis: grammar decode alone, on the EXISTING rope-v0 SFT
checkpoint (no retraining), lifts bench >= 4/20. The model has SOME
positional knowledge of valid DSL tokens (probe showed step 0 = MoveTo,
step 2 = rip = "Grip" partial); grammar walker should recover this.

### Cap H: scale + corpus + grammar (the railarm4agent spec)

Per `notes/railarm4agent/AGENT_B_train.md`:

```
d_model      = 384
n_layers     = 6
n_heads      = 6
d_ff         = 1536
seq_len      = 256
vocab        = 1024
total params ~ 14.7M
```

Trained on Cap G corpus (10K+ examples), pretrain ~3K steps + SFT
~1K steps, decoded with Cap I grammar walker, 5-seed fan.

Hypothesis: this combination lifts bench >= 6/20 single-seed-best,
>= 12/20 best-of-5-seed, >= 15/20 ensemble OR (per railarm4agent's
own kill targets).

## Free pre-Stage-7 probes — discriminate before training

Two free moves (no GPU, ~1 session each) gate the multi-day Cap H spend:

**Probe 1 (Cap G feasibility, ~1 session):** Build the substrate-corpus
generator. Generate 100 examples, audit by hand: do they look like the
eval set? Compile rate? Diversity? If feasible, scale to 10K.

**Probe 2 (Cap I feasibility, ~1 session):** Implement grammar walker.
Run on rope-v0 SFT. Result decides whether grammar alone is enough.

If Probe 1 succeeds AND Probe 2 hits >= 4/20: Cap H has strong priors.
If Probe 1 succeeds AND Probe 2 stays at 0-3/20: Cap H still likely
worth it because corpus is the dominant lever, but kill_target tightens.
If Probe 1 fails: substrate isn't generative enough; deeper audit needed.
If Probe 2 hits >= 6/20 alone: Cap H may be unnecessary at 14.7M — try
re-running grammar decode at 5-seed ensemble on existing 2M ckpts first.

## Pre-drafted kill_targets

### Cap G (substrate-bootstrapped corpus)

```
goal:        Stage 7 Cap G: substrate-generated corpus is compile-clean,
             shape-matched, and large enough to train on
hypothesis:  Qwen + 1KB Rail/arm spec (validated at 30/30 hard bench)
             generates 10K+ compile-verified arm-DSL examples whose
             length distribution and structure match the eval set.
kill_target: PASS if (a) >= 80% of generated examples pass tools/robot/
             grader.rail with goal_reach=1, AND (b) mean total_len within
             1 stddev of eval set, AND (c) template_fraction <= 20%.
             FALSIFIED if any one fails.
counters:    generated_count, compile_pass_count, grader_pass_count,
             mean_total_len_x10, eval_mean_total_len_x10,
             template_fraction_x100
cmd:         tools/lab/watchers/spurarm_stage7_cap_g_corpus.sh
parents:     64b4445e3729d50290932519d6d13f19023d40f471050e8f2f09ea0a900be28f
```

Implementation: `tools/spurarm/corpus/substrate_gen.rail` — loops over
diverse prompt seeds, calls substrate via tools/robot/talk.sh-style
plumbing, grades each output, accumulates passing examples into
`training/corpora/spurarm_v0_substrate.{jsonl,ids}`.

Cost: ~1 session, no GPU. LLM calls only (substrate uses cloud API or
local MLX per stdlib/mlx_client.rail).

### Cap I (grammar-constrained decode)

```
goal:        Stage 7 Cap I: grammar-walked decode lifts existing 2M
             rope-v0 SFT ckpt bench >= 4/20 (no retraining)
hypothesis:  Existing rope-v0 SFT ckpt produces degenerate token
             distributions that include compile-blocking tokens at most
             positions. A grammar walker that zeros tokens violating
             current parse state forces the decoder onto a manifold of
             syntactically valid Rail. The model's residual semantic
             knowledge (visible in probe: MoveTo, Grip partial) is
             sufficient to land >= 4/20 once syntactic constraints are
             enforced.
kill_target: PASS if grammar decode on spurarm-rope-v0_seed42_sft_final
             bench >= 4/20 (single-seed). FALSIFIED if <= 3/20.
counters:    bench_grammar, baseline_argmax_bench, grammar_tokens_zeroed_avg
cmd:         tools/lab/watchers/spurarm_stage7_cap_i_grammar.sh
parents:     64b4445e3729d50290932519d6d13f19023d40f471050e8f2f09ea0a900be28f
```

Implementation: `stdlib/rail_grammar.rail` exposing a tiny LL(1)-ish
parser state machine for the arm DSL. `tools/spurarm/train/generate.rail`
gains `--grammar=on` flag. Existing rope-v0 SFT ckpt used as-is.

Cost: ~1 session, no GPU.

### Cap H (scale + corpus + grammar — the real train)

```
goal:        Stage 7 Cap H: 14.7M-param 6L d=384 model on Cap G corpus
             with Cap I grammar decode lifts bench >= 6/20 single-seed
hypothesis:  At railarm4agent spec (6L d=384 d_ff=1536 vocab=1024 ~14.7M
             params), trained on the substrate-bootstrapped corpus from
             Cap G (10K+ compile-clean examples), decoded with the
             grammar walker from Cap I, single-best of 5 seeds hits
             bench >= 6/20 and the 5-seed ensemble OR hits >= 12/20.
kill_target: PASS if best-of-5 >= 6/20 AND ensemble OR >= 12/20.
             FALSIFIED if best-of-5 <= 4/20.
counters:    pretrain_steps, sft_steps, n_layers, d_model,
             best_seed_pretrain_val_x1000, best_seed_sft_val_x1000,
             best_seed_bench, ensemble_or_bench, seeds_above_4_20
cmd:         tools/lab/watchers/spurarm_stage7_cap_h_15m.sh
parents:     [Cap G entry id], [Cap I entry id]
```

Cost: **multi-day wall-clock** on Studio Metal. Estimate:
- Build: ~2-3 sessions for stdlib/spurarm_model_v1.rail config update,
  train_spurarm.rail multi-block forward+backward, GPU validation.
- Pretrain 5 seeds × ~3K steps × 14.7M params on Studio Metal:
  ~8-16h depending on attn impl efficiency.
- SFT 5 seeds × ~1K steps: ~3-6h.
- Bench 5 seeds: ~10 min × 5 = ~1h.
- Total wall: 1-2 days.

## Recommended Stage 7 order

1. **Cap G corpus probe first** (~1 session, no GPU). Free of cost.
   Generates the missing input. Chain entry on its own.

2. **Cap I grammar decode parallel** (~1 session, no GPU). Free of
   cost. Runs against existing rope-v0 SFT to test the grammar lever
   independently of training.

3. **Decision point.** Review both chain entries:
   - If both PASS: high prior for Cap H. Commit multi-day budget.
   - If only Cap G PASSES: still proceed with Cap H but tighten
     kill_target and run 1 seed first as a quick check.
   - If only Cap I PASSES: Cap H may be unnecessary; try ensemble of
     existing 2M ckpts under grammar decode first.
   - If neither PASSES: deeper audit of substrate generation; do not
     commit GPU budget yet.

4. **Cap H multi-day train.** Only after step 3.

5. **(Stretch) Stage 8 = DAPO RL** with open verifier — the structural
   advantage thesis lands here. Only meaningful if Cap H PASSES.

## Dependencies

```
Cap G (corpus probe, free)  ───────► input for Cap H
                                       │
Cap I (grammar decode, free) ──────────┤
                                       │
Cap H (15M train, multi-day) ◄─────────┘
                                       │
Stage 8 (RLVR DAPO) ◄──────────────────┘ if H PASSES
```

Caps G and I run in parallel — no shared files until Cap H integration.

## Honest priors

- **Cap G: high prior.** Substrate is validated at 30/30. Generation is
  the substrate's home turf.
- **Cap I: medium-high prior.** Grammar constraint addresses the exact
  failure mode visible in probes (degenerate token distribution with
  some valid tokens present). Risk: if Q,K,V projection collapses too
  hard, even valid tokens have probs near uniform and grammar walker
  picks essentially random parseable continuations.
- **Cap H: medium prior conditional on G passing.** 7x params + clean
  corpus is a big jump, but val_loss ⊥ bench bit us three times — can't
  rule out a fourth surprise. Hence requiring 5-seed fan with
  ensemble check as gate.

Prior strength: medium overall. Pre-probes meaningfully discriminate.

## What "finishing Stage 7" looks like

If Cap H lands best-of-5 >= 6/20 AND ensemble OR >= 12/20:
- Spur-arm becomes a working trained model. Own-model goal delivered.
- Chain has the receipts. Substrate-thesis + own-model both proven.
- Next: DAPO RL on the open verifier (the structural-advantage demo).

If all three Stage 7 caps FALSIFY:
- The architecture-spec gap holds at 14.7M + substrate corpus + grammar.
- The cap is genuinely beyond railarm4agent spec — Mamba/RWKV/50M+
  territory. User decision (Stage 8 architecture rethink).
- Substrate-thesis carries the strategic goal in the meantime.

## Files that need editing / creating (per cap)

| Cap | Files | LOC | Bootstrap? |
|---|---|---|---|
| G  | `tools/spurarm/corpus/substrate_gen.rail` (new) | ~250 | source-only |
|    | `tools/lab/watchers/spurarm_stage7_cap_g_corpus.sh` (new) | ~60 | n/a |
|    | `training/corpora/spurarm_v0_substrate.{jsonl,ids}` (output) | data | n/a |
| I  | `stdlib/rail_grammar.rail` (new) | ~200 | source-only |
|    | `tools/spurarm/train/generate.rail` (--grammar) | ~60 | source-only |
|    | `tools/lab/watchers/spurarm_stage7_cap_i_grammar.sh` (new) | ~50 | n/a |
| H  | `stdlib/spurarm_model_v1.rail` (new — 14.7M config) | ~80 | source-only |
|    | `tools/spurarm/train/train_spurarm_v1.rail` (multi-block) | ~400 | source-only |
|    | `tools/spurarm/train/multi_seed_fan.sh` (5-seed driver) | ~80 | n/a |
|    | `tools/lab/watchers/spurarm_stage7_cap_h_15m.sh` (new) | ~80 | n/a |

Cap H may require some attention-stack updates in `stdlib/transformer.rail`
for multi-head MQA (Agent B's plan calls for n_heads=6 grouped-query
with n_kv_heads=2). Could be source-only or could need bootstrap if any
new primitives.

## Pre-existing artifacts to reuse

- `notes/railarm4agent/` — 4-agent plan documents (Agent B is the
  trainer brief, Agent A the corpus brief). Stage 7 = Agent A + Agent B
  collapsed into chain-disciplined execution.
- `stdlib/transformer.rail` — RoPE + SiLU/SwiGLU available; multi-head
  attention may need adding.
- `tools/robot/talk.sh` — substrate pipeline; reuse for Cap G generation.
- `tools/robot/grader.rail` — post-cleanup, trustworthy. Used by Cap G
  for each generated example's compile-and-grade gate.
- bench v0 (cleaned `baf661b`) — 20-prompt benchmark with ball-position
  check, 20/20 reference passes.
- spurarm-rope-v0 ckpts at `training/checkpoints/` — used by Cap I as
  the test target.

## Quick decision rubric for next session

| Pre-probe shows | Then attempt |
|---|---|
| Cap G + Cap I both PASS | Commit Cap H multi-day train; high prior |
| Cap G PASS, Cap I FALSIFY | Commit Cap H with tighter kill (1 seed first) |
| Cap G FALSIFY, Cap I PASS | Cap H unnecessary at 14.7M; ensemble 2M under grammar |
| Both FALSIFY | Deeper audit before any GPU; surface user-decision |

## What this does NOT re-attempt

- Decoding regularization without grammar (Cap F, falsified `b9cca3cc`)
- Sampling (top-k) without grammar (Cap B, falsified `3069abbe`)
- Same-corpus retraining at larger scale (Cap C, falsified `ad65dd6c`)
- RoPE at 2M single-block (Cap D, falsified `64b4445e`)
- EOS supervision retrofit (Cap E, falsified inline by `3fe12ce2`)
- Architecture micro-changes (RMSNorm-only, SwiGLU-only): only meaningful
  combined with scale, which is Cap H.

All five falsifications stand. Stage 7 does not relitigate them.

Related: [[spurarm_stage6_readiness]] (predecessor), [[railarm4agent_plan]]
(architecture brief), [[bench_v0_fallback_contamination]] (bench fix),
[[comprehension_cracked_substrate]] (substrate-thesis upstream),
[[structural_advantage_thesis]] (Stage 8 framing).
