#!/bin/bash
# spur_card.sh — Emit a model card for a Spur ckpt to models/spur/<ckpt>.md.
#
# Pulls .meta + manifest + bundle inventory and writes a markdown card
# documenting the architecture, training metadata, and pickup workflow.
# Cards live in tree alongside the bundles in training/checkpoints_published/.
#
# Usage:
#   tools/bucket/spur_card.sh <ckpt_name> [<title>]
#   tools/bucket/spur_card.sh spur_v07_d384_best "Spur v0.7 BEST — d=384 + min-ckpt"

set -e

CKPT="${1:?usage: spur_card.sh <ckpt_name> [<title>]}"
TITLE="${2:-$CKPT}"
SRC="training/rail_native/checkpoints/${CKPT}"
OUT="models/spur/${CKPT}.md"
mkdir -p models/spur

if [ ! -f "${SRC}.committed" ]; then
  echo "ERROR: no committed ckpt at ${SRC}" >&2
  exit 1
fi

step=""
val_loss=""
if [ -f "${SRC}.meta" ]; then
  step=$(grep "^step=" "${SRC}.meta" | cut -d= -f2 || true)
  val_loss=$(grep "^best_val_loss=" "${SRC}.meta" | cut -d= -f2 || true)
fi

n_tensors=""
embed_shape=""
V=""
d_hidden=""
n_blocks=""
param_count=0
if [ -f "${SRC}.manifest" ]; then
  n_tensors=$(head -1 "${SRC}.manifest" | tr -d ' ')
  embed_shape=$(sed -n '2p' "${SRC}.manifest")
  V=$(echo "$embed_shape" | awk '{print $2}')
  d_hidden=$(echo "$embed_shape" | awk '{print $3}')
  n_blocks=$(( (n_tensors - 2) / 9 ))
  param_count=$(awk 'NR>1 {
    rank = $1
    p = 1
    for (i=2; i<=rank+1; i++) p *= $i
    sum += p
  } END {print sum}' "${SRC}.manifest")
fi

inf_bundle="training/checkpoints_published/${CKPT}-inference.tar.gz"
res_bundle="training/checkpoints_published/${CKPT}-resume.tar.gz"
inf_kb="(not built — run \`tools/bucket/spur_bundle.sh ${CKPT}\`)"
res_kb="(not built — run \`MODE=resume tools/bucket/spur_bundle.sh ${CKPT}\`)"
[ -f "$inf_bundle" ] && inf_kb="$(($(stat -f %z "$inf_bundle") / 1024)) KB"
[ -f "$res_bundle" ] && res_kb="$(($(stat -f %z "$res_bundle") / 1024)) KB"

cat > "$OUT" <<EOF
# ${TITLE}

Spur checkpoint, in-tree at \`training/checkpoints_published/${CKPT}-inference.tar.gz\`.

## Architecture

| Field | Value |
|---|---|
| Hidden dim (d) | ${d_hidden} |
| Vocab (V) | ${V} |
| Blocks | ${n_blocks} |
| Tensor count | ${n_tensors} |
| Param count | ${param_count} |
| Final step | ${step} |
| Best val_loss | ${val_loss} |

## Bundles

| File | Size | Contents |
|---|---|---|
| \`${CKPT}-inference.tar.gz\` | ${inf_kb} | weights + manifest + meta. Use for inference. |
| \`${CKPT}-resume.tar.gz\` | ${res_kb} | weights + adam states + manifest + meta. Use to resume training. |

## Pickup

\`\`\`bash
mkdir -p training/rail_native/checkpoints
tar xzf training/checkpoints_published/${CKPT}-inference.tar.gz \\
  -C training/rail_native/checkpoints
ls training/rail_native/checkpoints/${CKPT}.committed   # sanity-check
\`\`\`

## Inference (CPU substrate, deterministic)

\`\`\`bash
touch tools/metal/.no_gpu
./rail_native run tools/train/lm_infer_cpu.rail \\
  --prefix training/rail_native/checkpoints/${CKPT} \\
  --max 64 --k 10 --temp 0.8 --seed 100 --no-ws-first 16 \\
  --prompt 'fact n = if n <= 1 then 1 else n * fact (n - 1)
main = '
\`\`\`
EOF

echo "wrote $OUT"
