# Agent B — tokenizer + base model + SFT trainer (worktree-isolated brief)

You are Agent B in a 4-agent parallel build of Spur-arm. The overall
plan is in `notes/railarm4agent/README.md`; the research synthesis is
in `notes/railarm4agent/RESEARCH.md`. Read both before starting. Then
read THIS file end-to-end before writing any code.

You own the tokenizer, the base model architecture, and the supervised
fine-tuning (SFT) phase. Your output unblocks Agent C (RL). You depend
on Agent A's corpus.

---

## Mission

Train a ~15M-parameter pure-Rail transformer (`Spur-arm-base-v0`) that
maps natural-language prompts to Rail DSL scripts. After SFT alone
(before any RL), it must hit ≥ 12/20 single-shot on bench v0. After
multi-seed fan + ensemble, ≥ 15/20.

You build on the existing Rail training stack: `stdlib/transformer.rail`,
`stdlib/autograd.rail`, `stdlib/optim.rail`, `stdlib/checkpoint.rail`,
`stdlib/bpe.rail`, and `tools/train/lm_transformer.rail`. Extend, don't
replace.

---

## Required reading before starting

1. `notes/railarm4agent/README.md` — overall plan
2. `notes/railarm4agent/RESEARCH.md` — especially **Small-model SoTA**
3. `notes/railarm4agent/AGENT_A_corpus.md` — corpus schema you'll consume
4. `stdlib/transformer.rail` — the existing transformer block
5. `stdlib/autograd.rail` — autodiff
6. `stdlib/optim.rail` — Adam / AdamW
7. `stdlib/checkpoint.rail` — atomic save/load with `.committed` sentinel
8. `stdlib/bpe.rail` — existing BPE; extend to SentencePiece-unigram
9. `tools/train/lm_transformer.rail` — current training driver pattern;
   has `run_segments` with resume + periodic checkpoint
10. Memory: `spur_lineage_archive` — what worked at what scale (d=256
    saturated, d=384 collapsed, d=512 NaN — but Spur was trained on
    compile.rail-only, you're training on a different corpus)
11. Memory: `feedback_blob_slice_fan_condense` — multi-seed fan pattern
12. Memory: `feedback_diagnostics_first` — emit val_loss, compile-rate,
    per-bench-band-score counters before training, not after
13. Memory: `bench_watcher_gotcha` — naive watchers exit prematurely;
    require empty+stable+log>10KB triple
14. Memory: `val_loss_underread` — read `.meta` val_loss FIRST before
    benching; v0.4d (3.25) beat v0.2 (3.59) on 10% vs 57% triples

---

## Architecture

```
                       ┌────────────────────────────────┐
                       │  spurarm_v0.jsonl from Agent A │
                       │  pretrain/sft/eval splits      │
                       └────────────────┬───────────────┘
                                        │
                ┌───────────────────────┼───────────────────────┐
                │                       │                       │
        ┌───────▼────────┐    ┌────────▼────────┐    ┌─────────▼─────────┐
        │ build_tokenizer│    │ pretrain.rail   │    │  bench_eval       │
        │  .rail         │    │  (warmup)       │    │  (single-shot     │
        │ SentencePiece- │    │ ─────────►      │    │   on bench v0,    │
        │ unigram        │    │ sft.rail        │    │   per ckpt)       │
        │ vocab=1024     │    │ (DSL-exact)     │    │                   │
        │                │    │                 │    │                   │
        └────────────────┘    └─────────────────┘    └───────────────────┘
                │                       │                       │
                └───────────────────────┼───────────────────────┘
                                        │
                       ┌────────────────▼───────────────┐
                       │  training/checkpoints/         │
                       │   spurarm-base-v0_seedN_step*  │
                       │   .ckpt + .meta + .committed   │
                       └────────────────────────────────┘
```

---

## Deliverables (every one of these is required)

### Files

```
stdlib/
└── spurarm_model.rail            # 6-layer / d=384 / 6-head / GQA(2) transformer config wrapper

tools/spurarm/train/
├── README.md                     # training reproducer
├── build_tokenizer.rail          # SentencePiece-unigram trainer
├── tokenize_corpus.rail          # apply trained tokenizer to corpus → .bin shards
├── pretrain.rail                 # phase 1: paraphrase prior on VH+ALFRED
├── sft.rail                      # phase 2: DSL-exact on substrate+seed
├── multi_seed_fan.sh             # spawn N parallel seeds, gather metrics
├── ensemble_bench.sh             # per-prompt max-pass across seeds (analog to tools/train/ensemble_ceiling.sh)
├── bench_eval.rail               # single-shot bench v0 grader for a ckpt
└── ckpt_card.rail                # emit .meta file: val_loss, bench_score, seed, recipe, sha

training/
├── tokenizer/
│   ├── spurarm_v0_sp1024.model   # the trained tokenizer
│   └── spurarm_v0_sp1024.vocab
├── corpora/
│   ├── spurarm_v0_pretrain.bin   # tokenized pretrain shard
│   └── spurarm_v0_sft.bin        # tokenized sft shard
└── checkpoints/
    ├── spurarm-base-v0_seed42_pretrain_step10000.ckpt
    ├── spurarm-base-v0_seed42_pretrain_step10000.ckpt.meta
    ├── spurarm-base-v0_seed42_pretrain_step10000.ckpt.committed
    ├── ...  (one set per seed, per phase, per N steps)
    └── spurarm-base-v0_best.ckpt -> <symlink to highest-bench-scoring ckpt>
```

### Model config (frozen for v0; do NOT change without escalating)

```rail
spurarm_v0_config = {
  d_model      = 384,
  n_layers     = 6,
  n_heads      = 6,
  n_kv_heads   = 2,                -- GQA: 6:2 ratio
  d_ff         = 1536,             -- 4 * d_model
  max_seq_len  = 256,              -- prompts < 100 tok, scripts < 100 tok, +safety
  vocab_size   = 1024,
  norm_type    = "rmsnorm",
  pos_enc      = "rope",
  attn_dropout = 0.0,              -- small corpora, dropout hurts
  resid_dropout= 0.0,
  init         = "kaiming-scaled", -- sqrt(2/fan_in), per memory: init_matters
  precision    = "fp32",           -- fp16 mixed comes later if needed; correctness first
}
```

Total params at this config: approximately 14.7M. Within budget.

### Tokenizer requirements

- **Type**: SentencePiece-unigram (extend `stdlib/bpe.rail` if needed
  or write `stdlib/sentencepiece.rail` from scratch as pure Rail)
- **Vocab size**: 1024
- **Trained on**: NL + DSL jointly from `spurarm_v0_pretrain.jsonl` +
  `spurarm_v0_sft.jsonl` (NOT eval — eval is held out)
- **Pinned tokens** (user-defined symbols guaranteed in vocab):
  `script`, `=`, `[`, `]`, `,`, `MoveTo`, `SetGrip`, `GripOpen`,
  `GripClose`, `Wait`, `Home`, `<bos>`, `<eos>`, `<pad>`, `<sep>`
- **Special tokens**: `<bos>` (id 0), `<pad>` (id 1), `<eos>` (id 2),
  `<sep>` (id 3) — separates NL prompt from DSL script in training pairs
- **Coverage**: each ASCII printable char must encode to ≤2 tokens.
  Verify on a held-out 100-pair sample.

If SentencePiece-unigram in pure Rail is too heavy a lift in this
session, the acceptable fallback is **byte-level BPE at vocab=512**.
Document the choice in `tools/spurarm/train/README.md`. Do NOT use a
GPT-style web-trained BPE.

---

## Training pipeline (two phases)

### Phase 1: pretrain (warmup, paraphrase + verb composition)

Corpus: `spurarm_v0_pretrain.jsonl` (~25k pairs from VH + ALFRED with
slot-substituted object names).

Each training example tokenizes as:
```
<bos> <NL prompt tokens> <sep> <script tokens> <eos> <pad>...
```

Loss: standard cross-entropy on the script tokens only (mask the
prompt tokens — don't waste capacity learning to predict the user's
phrasing).

Hyperparameters:
| Param | Value | Why |
|---|---|---|
| Batch size | 32 | Studio M1 Ultra 64 GB — comfortable |
| Sequence length | 256 | Covers all corpus pairs with margin |
| Learning rate | 3e-4 | warmup over 1000 steps then cosine to 1e-5 |
| Weight decay | 0.1 | AdamW |
| Adam betas | (0.9, 0.95) | |
| Adam eps | 1e-8 | |
| Steps | 10,000 | revisit if val_loss still dropping |
| Eval every | 500 steps | |
| Ckpt every | 1000 steps | atomic via `.committed` sentinel |
| Grad clip | 1.0 | |
| Init | kaiming-scaled (sqrt(2/fan_in)) | per `init_matters` memory |

Multi-seed fan: 5 seeds (`42, 77, 100, 200, 314`). Per
`feedback_blob_slice_fan_condense`. Run sequentially on Studio (GPU
contention).

**Phase 1 acceptance gate**: at least 3 of 5 seeds drop val_loss below
2.0 on the held-out eval split. If <3 seeds clear, the recipe is wrong
or the corpus is bad — escalate, don't push to phase 2.

### Phase 2: SFT (DSL-exact syntax)

Corpus: `spurarm_v0_sft.jsonl` (~5k substrate+seed pairs).

Initialize from each phase-1 seed's best ckpt. Continue training:
| Param | Value | Notes |
|---|---|---|
| Learning rate | 1e-4 | lower; we're refining, not pre-training |
| Steps | 3,000 | smaller corpus, faster convergence |
| Other params | same as phase 1 | |

**Critical**: per memory `oracle_metric_gotcha`, val_loss alone is not
a monotone signal — trivial outputs (e.g., always emitting `script =
[Home]`) compile cleanly and lower val_loss without learning.
Use **bench-v0 single-shot compile + goal-reach** as the gating metric,
read from `bench_eval.rail` every 500 steps.

Min-checkpoint rule: save ckpt only when BOTH val_loss decreases AND
bench-v0 goal-reach is non-decreasing. Per `gated_min_ckpt` pattern
from the 2026-05-01 scaffolds (but use your own implementation; the
2026-05-01 scaffolds had a grader bug, see `a1_grader_bug_2026-05-08`).

**Phase 2 acceptance gate**: at least 1 seed hits ≥ 12/20 single-shot
on bench v0. If best seed is below 8/20, the model is broken or the
corpus is wrong — escalate.

### Multi-seed fan

After 5-seed pretrain → 5-seed SFT:
- 5 final checkpoints
- `ensemble_bench.sh` does per-prompt max-pass routing (analog to
  `tools/train/ensemble_ceiling.sh`)
- Ensemble target: ≥ 15/20

Per memory `parallel_rerank_works`: parallel rerank is validated at
7.1× wall-clock at N=8. Use the same pattern.

---

## Bench evaluation

`bench_eval.rail`:
1. Loads a checkpoint
2. For each prompt in `tools/robot/bench_v0.txt`:
   - Tokenize: `<bos> <prompt> <sep>`
   - Generate up to 100 tokens with argmax (`--k 1`, NOT sampling, for
     reproducibility) — until `<eos>` or max_seq_len
   - Detokenize the generated section
   - Wrap in candidate template via `tools/robot/grader.rail` pattern
   - Compile + run sim + grade
3. Emit stage-counter sentinel block compatible with chain watcher

**Why argmax**: per `inference_seed_segfault` memory, `--max 128 --k 10`
crashes ~50% of seeds. Until that bug is fixed (Agent C may attempt or
defer), avoid sampling during eval. Argmax has a measurement caveat
(no diversity) but reproducibility is more valuable here.

---

## Acceptance test

Run from a clean clone after Agent A's corpus is in place:

```bash
# 1. Tokenizer trained and validated
test -f training/tokenizer/spurarm_v0_sp1024.model
./rail_native run tools/spurarm/train/build_tokenizer.rail --validate
# expects: "vocab_size=1024 ascii_coverage=>=99% pinned_tokens_present=yes"

# 2. Pretrain ran, val_loss dropped
./rail_native run tools/spurarm/train/multi_seed_fan.sh --phase=pretrain --seeds=42,77,100,200,314
# expects: at least 3 of 5 seeds with .meta val_loss < 2.0

# 3. SFT ran, best seed hits target
./rail_native run tools/spurarm/train/multi_seed_fan.sh --phase=sft --seeds=42,77,100,200,314
# expects: at least 1 ckpt with bench_v0_single_shot >= 12

# 4. Ensemble routing hits target
sh tools/spurarm/train/ensemble_bench.sh
# expects: ensemble goal_reach >= 15

# 5. Best ckpt symlink present
test -L training/checkpoints/spurarm-base-v0_best.ckpt
```

**PASS** if all 5 pass.

**INCONCLUSIVE** acceptable cases:
- Tokenizer falls back to byte-BPE at vocab=512 (documented in README)
- Phase 1 val_loss plateaus at 2.0–2.5 but phase 2 still clears 12/20
- `inference_seed_segfault` bites during eval — document, use argmax,
  proceed

**FAIL** if best seed is <8/20 single-shot post-SFT. Escalate: either
scale to d=512, retrain with different LR schedule, or surface a
corpus-quality issue back to Agent A.

---

## Chain entry

On completion, append chain entry with parent `66bb63f9`. cmd points
to `tools/lab/watchers/spurarm_base_b.sh`:

```
===RAIL_LAB_COUNTERS===
{"counter": "model_params_M", "value": 15}
{"counter": "tokenizer_vocab_size", "value": 1024}
{"counter": "pretrain_seeds_passed_val_loss_2", "value": <N>}
{"counter": "sft_best_bench_v0_single_shot", "value": <N>}
{"counter": "sft_best_seed", "value": <N>}
{"counter": "ensemble_bench_v0_goal_reach", "value": <N>}
{"counter": "wall_hours", "value": <N>}
===END===
===VERDICT=== PASS
```

---

## Out of scope for Agent B

- Constrained decoding (Agent C)
- RL / DAPO (Agent C)
- Self-play (Agent C)
- MaxArm protocol (Agent D)
- Bench v1+ (separate arc)
- Fixing `inference_seed_segfault` (work around with argmax; the bug is
  a separate arc unless it actually blocks the path)

If you discover the architecture is too small (d=384 caps below 8/20),
DO escalate before scaling to d=512 unilaterally — the user has
authority to redirect.

---

## Discipline reminders

- **Counter discipline before code**: write `bench_eval.rail` FIRST, run
  it on a random-weight model to verify it grades correctly (should
  give 0/20 or close), then begin training. Per `feedback_diagnostics_first`.
- **`val_loss_underread`**: always read `.meta` val_loss BEFORE
  benching. If val_loss hasn't moved, benching is wasted compute.
- **`bench_watcher_gotcha`**: use empty+stable+log>10KB triple gate for
  bench-process watchers.
- **`studio_panic_pattern`**: don't stack multi-seed training with
  other heavy workloads (e.g., Agent C running RL concurrently). Run
  serially on Studio.
- **`incremental_testing`**: never kick off 10000-step run without
  10→20→50→500 staged short tests first. Short runs flush buffered
  output too.
- **Bootstrap discipline (`rail_quirks` memory family)**: if you modify
  `stdlib/transformer.rail` or related runtime files, re-bootstrap 2
  cycles and verify 140/140 tests.
- **No mutations to existing files** except minimal extensions. The
  DSL (`stdlib/robot_arm.rail`), sim (`tools/robot/arm_sim.rail`), and
  grader (`tools/robot/grader.rail`) are FROZEN.
- **No commits to main**: stage on `spurarm/B-train` branch.
- **Bench-running window = file-write opportunity** per
  `feedback_bench_window_pattern`: while 5-seed training runs, write
  the docs, scaffolds, ckpt cards.

---

## Estimated effort

10–14 hours. Bottlenecks:
- SentencePiece-unigram in pure Rail (2–4h if from-scratch; 1h if
  byte-BPE fallback)
- 5-seed × 2-phase training wall-clock (4–6h, sequential on Studio)
- Bench evaluation + ensemble tuning (2–3h)
- Acceptance test + chain entry (1h)

If you exceed 18 hours and acceptance is still failing, escalate.
