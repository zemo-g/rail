# Session handoff — 2026-04-24 (cold-start)

**Purpose:** drop-in next-session context. Read this, `MEMORY.md`, and `docs/plans/PHASE_5E_RERANK_LANDED.md` — you have everything.

**HEAD at handoff time:** end of 2026-04-23. Multiple commits including `64423af` (Spur-Fix v0.2 training file) and the latest Phase 5 + Spur-Fix docs.

## The mission — cleared

Rail-on-Rail in Rail, proof of concept. `bench_railnative ≥ 5/30` and one closed flywheel round by **2026-04-27**.

**Deadline cleared 2026-04-23** at **25/30 (83%)** on Spur-0.1 with 20-sample compiler re-rank at `--k 50`. Cleared by 20 passes.

## Spur-0.1 — the flagship

**Identity:**
- d=256 × 2-block × HalfTensor, 1.74M parameters
- 3000 steps on 544K-char Rail stdlib
- 84 min training on M1 Ultra
- Checkpoint: `training/rail_native/checkpoints/d256_half_step3000.*`

**Numbers:**
- Held-out eval @ 3000: 3.49 ± 0.18
- Single-sample bench @ `--k 10 --temp 0.8`: 13/30
- Single-sample bench @ `--k 50`: 14/30
- **20-sample compiler re-rank @ `--k 50`: 25/30 (83%)**
- Variance: ±0-1 across seeds (verified by ablation at seed-base +1000)

**Band breakdown at 25/30:** Fund 5/5, IO 5/5, Tools 5/5, Compiler 5/5, Advanced 5/5, Comprehend 0/5.

**Reproduction:**
```bash
git checkout 255b279
./rail_native run tools/train/lm_v3_chunked_d256_half.rail
./rail_native run flywheel-local/bench_railnative_rerank.rail \
  --prefix training/rail_native/checkpoints/d256_half_step3000 \
  --max 128 --k 50 --temp 0.7
# (with rerank_n=20 in the bench file)
```

## What the full day shipped (session arc, 2026-04-22 → 2026-04-23)

| commit | summary |
|---|---|
| `9a018ce` | Session 2 result + Session 3 prompt |
| `c091d7e` | stdlib save_half_model + v3 infer harness |
| `255b279` | Spur-0.1 training file with lr_mult=0.3 + checkpoint save |
| `baf3671` | Phase 5 result bundle + Session 4 ranking |
| `7218806` | 4-block deeper variant (side-experiment) |
| `03941ec` | Generic N-block infer harness |
| `620142c` | Phase 5b result — 4-block didn't help |
| `f704345` | 6k training variant (side-experiment) |
| `5865ed6` | Resume CLI + scaling position doc |
| `b7ad6a8` | Compiler re-rank design doc |
| `18e7c6a` | Whitespace-filter in infer harness |
| `f3a4b92` | Phase 5d — first 12/30 result |
| `e12b6b4` | Ablation: 2-block beats 4-block, Spur-0.1 named |
| `3fcf9e5` | DIAGNOSTIC_CORPUS.md + mutate.rail + diagnose.rail |
| `23dcca5` | gen_triples orchestrator |
| `32c60f6` | Phase 5e — 25/30 with compiler re-rank (flagship) |
| `1dc4a99` | Triples v1 corpus + Spur-Fix v0.1 training file |
| `64423af` | Spur-Fix v0.2 training file (mixed corpus) |

## The three key innovations (ranked by impact)

1. **Compiler re-rank** — Spur-0.1 at `--k 50 × N=20` scores 25/30. Compiler-in-the-loop inference-time search, ~50ms per compile grade. The unique Rail advantage: no scraping-LM project has comparable latency or self-hosted compiler integration.

2. **Top-k sampling at inference** — `--k 1` argmax → `--k 50` single-sample = 1/30 → 14/30. The model's 1% tail contains valid Rail; argmax collapses it.

3. **Diagnostic-corpus training (Spur-Fix)** — attempted, produced honest negative results. Infrastructure shipped (mutate, diagnose, gen_triples, lm_v3_mixed, bench_railnative_fix). Research direction valid in principle; needs ~10-100× more training data than today's 247 triples.

## Open items (not blocking deadline)

### Spur-Fix v0.3 — if someone takes it up

Best next attempt:
- Expand `mutate.rail` with 10+ additional operators (wrong arity, missing import, type mismatch, unclosed string, bracket mismatch).
- Model-in-the-loop triple generation: use Spur-0.1 to generate candidates for bench-like prompts; compile; harvest triples from (garbage, diag, hand-fixed) pairs. Requires human fix labels OR the teacher-Qwen model on port 8081.
- Target ≥5,000 triples.
- Add loss masking: compute training loss only on `<FIXED>` tokens, not `<BROKEN>` or `<DIAG>`. This forces the gradient signal onto fix quality.
- Train 3000 steps on mixed corpus OR fine-tune Spur-0.1 for 500 steps on triples-only.
- Target result: ≥1/5 on Comprehend band, which would validate the thesis.

### Closed flywheel round — Task #14 from the deadline punch-list

`self_train.rail` has primitives (`harvest_snapshot`, `harvest_rollback`, `harvest_ab_gate`). Needs wiring: after training, bench → compare against prior-round score → gate accept/rollback. ~3h of engineering once the private `rail-training` flywheel dir is synced from Mini.

### `PHASE_4C_MODEL_CARD.md` polish

Already at 25/30 flagship. Remaining: replication steps are slightly messy, external-facing prose could be tightened. ~1h for a copy-edit pass.

## Machine state at handoff

- Studio RAM: 64 GB. Currently ~20 GB free (clean after 27B MLX was killed yesterday; should `sudo purge` to drain swap when you're at the machine).
- Qwen 3.6 35B MLX on port 8081 (pid 12810) still running. Available for teacher-model triple generation if you take up Spur-Fix v0.3.
- Qwen 3.5 27B MLX on port 8080 was unloaded 2026-04-22; restore with `launchctl load ~/Library/LaunchAgents/com.ledatic.mlx_studio.plist` when needed.

## What NOT to do

- Don't re-run the sweep that landed 25/30 — it took 6h40m and the number is locked.
- Don't restart Spur-Fix v0.1 or v0.2 — they're settled negative results. Document, move on.
- Don't train more 4-block variants — session 4/6/7 all scored at or below the 2-block. Capacity is not the bottleneck at this corpus size.

## The publishable claim (current, defensible)

> A 1.74M-parameter self-hosted Rail transformer, trained for 84 minutes on 544K characters of Rail stdlib corpus, scores 25/30 (83%) on a 30-task Rail benchmark under 20-sample compiler re-rank at `--k 50` sampling. Five of six bands pinned at 5/5 compile-pass. The compiler that grades each candidate in ~50ms during the re-rank is the same Rail compiler that compiled the training loop, self-hosted in 5,000 lines of Rail with a 729K ARM64 seed binary and zero C runtime dependencies. Compile-in-the-loop inference at this latency is structurally unavailable to projects that do not own their target language's compiler.

Ship that. It holds up.
