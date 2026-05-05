# Spur lineage

In-tree checkpoints for the Spur model line. Bundles in
`training/checkpoints_published/`; full weights regenerable from
`training/rail_native/checkpoints/<name>.*` via `tools/bucket/spur_bundle.sh`.

## Lineage

| Card | Tag | d | params | val_loss | bench shape (CPU mini) | strip-bench (30) |
|---|---|---|---|---|---|---|
| [Spur-0.1](d256_half_step3000.md) | `d256_half_step3000` | 256 | 1.74M | 3.06 | 4/5 | — |
| [v0.5](spur_v05_distill_step3000.md) | `spur_v05_distill_step3000` | 256 | 1.74M | 3.59 | 5/5 | — |
| [v0.6](spur_v06_d384_step3000.md) | `spur_v06_d384_step3000` | 384 | 3.89M | 3.39 | 3/5 | — |
| [v0.7 FINAL](spur_v07_d384_step3000.md) | `spur_v07_d384_step3000` | 384 | 3.89M | 3.39 | 3/5 | — |
| [v0.7 BEST](spur_v07_d384_best.md) | `spur_v07_d384_best` | 384 | 3.89M | 3.50 | **5/5** | — |
| [Spur-v54 BQ2](spur_v54_BQ2_s77_best.md) ⭐ | `spur_v54_BQ2_s77_best` | 256 | 1.73M | 3.19 | — | **10/30** |

**Current peak — single ckpt:** Spur-v54 BQ2 = 10/30 (33%) strip-graded. Recipe: back-quarter compile.rail × seed=77 × LR=0.01.

**Current peak — portfolio ensemble:** **24/30 (80%)** via per-prompt max-pass routing across 46 + 9 strip-graded ckpts (`tools/train/ensemble_ceiling.sh`). 6 unsolved are the Comprehension band — structurally out of reach for compile.rail-only training at d=256-384.

The early lineage (Spur-0.1 → v0.7) used a CPU-mini "shape" bench (≥4
unique non-ws chars). Spur-v54 onward uses the proper strip-graded
30-prompt bench (`flywheel-local/bench_strip.rail`); see
`memory/strip_lever_validated_2026-05-04.md`.

## Bundle / unbundle

```bash
# Bundle a ckpt (output: training/checkpoints_published/<name>-inference.tar.gz):
tools/bucket/spur_bundle.sh <ckpt_name>

# Resume bundle adds adam_m / adam_v:
MODE=resume tools/bucket/spur_bundle.sh <ckpt_name>

# Generate / refresh a model card:
tools/bucket/spur_card.sh <ckpt_name> [<title>]

# Pickup on a fresh clone (or after deleting local ckpts):
mkdir -p training/rail_native/checkpoints
tar xzf training/checkpoints_published/<ckpt>-inference.tar.gz \
  -C training/rail_native/checkpoints
```

## Why in-tree

Bundles are tiny (26-52 KB each — f32 weights have repeating structure
and gzip ~300:1) so committing them costs little. Pushing via the
existing Mini-proxied origin makes them reachable from any clone with
no separate auth or external bucket service.
