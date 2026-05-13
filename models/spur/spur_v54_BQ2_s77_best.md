# Spur v54 BQ2 — back-quarter compile.rail × seed=77 × LR=0.01 (10/30 strip-graded)

Spur checkpoint, in-tree at `training/checkpoints_published/spur_v54_BQ2_s77_best-inference.tar.gz`.

## Architecture

| Field | Value |
|---|---|
| Hidden dim (d) | 256 |
| Vocab (V) | 93 |
| Blocks | 2 |
| Tensor count | 20 |
| Param count | 1729024 |
| Final step | 2800 |
| Best val_loss | 3.19085877150416 |

## Bundles

| File | Size | Contents |
|---|---|---|
| `spur_v54_BQ2_s77_best-inference.tar.gz` | 24 KB | weights + manifest + meta. Use for inference. |
| `spur_v54_BQ2_s77_best-resume.tar.gz` | (not built — run `MODE=resume tools/bucket/spur_bundle.sh spur_v54_BQ2_s77_best`) | weights + adam states + manifest + meta. Use to resume training. |

## Pickup

```bash
mkdir -p training/rail_native/checkpoints
tar xzf training/checkpoints_published/spur_v54_BQ2_s77_best-inference.tar.gz \
  -C training/rail_native/checkpoints
ls training/rail_native/checkpoints/spur_v54_BQ2_s77_best.committed   # sanity-check
```

## Bench scores

| Mode | Score | Notes |
|---|---:|---|
| Single-ckpt, strip-graded | **10/30 (33%)** | `flywheel-local/bench_strip.rail`, N=20 compiler re-rank |
| Single-ckpt, canonical | 9/30 (30%) | `flywheel-local/bench_railnative_rerank.rail`, pre-strip patch |
| Spur portfolio ensemble | **24/30 (80%)** | per-prompt max-pass routing across 46 + 9 strip-graded ckpts (`tools/train/ensemble_ceiling.sh`) |

**Best single Spur ckpt to date.** Recipe: back-quarter (90 KB) of `tools/compile.rail` × d=256 × 3000 steps × seed=77 × LR=0.01. Different strength profile from Spur-v27 (full-corpus, Compiler band) and Spur-v43 (half-B, robust shipping).

The strip-graded score is honest — `flywheel-local/bench_strip.rail` truncates generation at the first `\n  0\n` sentinel before grading, which removes a class of post-program garbage that the canonical bench harness counts as a failure. See `~/.claude/projects/-Users-user/memory/strip_lever_validated_2026-05-04.md`.

## Recipe ladder (compile.rail-as-corpus, d=256, 3000 steps)

| Slice | Size | Best ckpt | Strip-bench | Notes |
|---|---:|---|---:|---|
| Full | 362 KB | Spur-v27 (s=12345) | 7/30 | Compiler band peak |
| Half-B | 180 KB | Spur-v43 (s=5555) | 7/30 | Most robust (zero collapses across 10 seeds) |
| Back-quarter | 90 KB | **Spur-v54 BQ2 (s=77, LR=0.01)** | **10/30** | Real Tools + Compiler bands, current peak |

## Inference (CPU substrate, deterministic)

```bash
touch tools/metal/.no_gpu
./rail_native run tools/train/lm_infer_cpu.rail \
  --prefix training/rail_native/checkpoints/spur_v54_BQ2_s77_best \
  --max 64 --k 10 --temp 0.8 --seed 100 --no-ws-first 16 \
  --prompt 'fact n = if n <= 1 then 1 else n * fact (n - 1)
main = '
```

## Bench reproduction

```bash
./rail_native run flywheel-local/bench_strip.rail \
  --prefix training/rail_native/checkpoints/spur_v54_BQ2_s77_best \
  --rerank-N 20
```
