# Spur v0.7 FINAL — d=384 + min-ckpt (step 3000)

Spur checkpoint, in-tree at `training/checkpoints_published/spur_v07_d384_step3000-inference.tar.gz`.

## Architecture

| Field | Value |
|---|---|
| Hidden dim (d) | 384 |
| Vocab (V) | 130 |
| Blocks | 2 |
| Tensor count | 20 |
| Param count | 3885696 |
| Final step | 3000 |
| Best val_loss | 3.3920775114761 |

## Bundles

| File | Size | Contents |
|---|---|---|
| `spur_v07_d384_step3000-inference.tar.gz` | 50 KB | weights + manifest + meta. Use for inference. |
| `spur_v07_d384_step3000-resume.tar.gz` | (not built — run `MODE=resume tools/bucket/spur_bundle.sh spur_v07_d384_step3000`) | weights + adam states + manifest + meta. Use to resume training. |

## Pickup

```bash
mkdir -p training/rail_native/checkpoints
tar xzf training/checkpoints_published/spur_v07_d384_step3000-inference.tar.gz \
  -C training/rail_native/checkpoints
ls training/rail_native/checkpoints/spur_v07_d384_step3000.committed   # sanity-check
```

## Inference (CPU substrate, deterministic)

```bash
touch tools/metal/.no_gpu
./rail_native run tools/train/lm_infer_cpu.rail \
  --prefix training/rail_native/checkpoints/spur_v07_d384_step3000 \
  --max 64 --k 10 --temp 0.8 --seed 100 --no-ws-first 16 \
  --prompt 'fact n = if n <= 1 then 1 else n * fact (n - 1)
main = '
```
