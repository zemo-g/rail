# Published Spur checkpoints (in-tree bucket)

Tarballs of inference-ready Spur ckpts. Committed to git; reachable from
any clone. See `models/spur/` for per-ckpt model cards.

## Format

Each `<name>-inference.tar.gz` contains:

- `<name>.committed`  — atomic-write sentinel
- `<name>.manifest`   — N tensors, one shape per line
- `<name>.meta`       — `step=` + `best_val_loss=`
- `<name>.<i>.f32`    — weight tensor i (i in 0..N-1, no adam state)

## Pickup

```bash
mkdir -p training/rail_native/checkpoints
tar xzf training/checkpoints_published/<ckpt>-inference.tar.gz \
  -C training/rail_native/checkpoints
```

After extraction, `/tmp/rail_infer_cpu --prefix training/rail_native/checkpoints/<ckpt> ...`
reads the ckpt directly.

## Building bundles

`tools/bucket/spur_bundle.sh <ckpt_name>` (output lands here).

For a resume bundle (adds adam states): `MODE=resume tools/bucket/spur_bundle.sh <ckpt_name>`.
