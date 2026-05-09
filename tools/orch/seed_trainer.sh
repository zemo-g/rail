#!/bin/bash
# seed_trainer.sh — clone a trainer template with new seed + ckpt prefix.
#
# The Spur trainers hardcode seed at `let rng = lcg_state_new <N>` and ckpt
# paths at `let ckpt_best = "training/rail_native/checkpoints/<prefix>_best"`
# (and matching `_step3000`). This script does an exact textual substitution
# so each orchestrator arm gets its own trainer.rail with isolated ckpt
# output, without touching the source trainers.
#
# Usage:
#   seed_trainer.sh <template.rail> <new_seed> <new_ckpt_prefix_path> <output.rail>
#
# Where <new_ckpt_prefix_path> is the absolute or repo-relative path-without-suffix
# (e.g. "runs/bq_s200/checkpoints/bq_s200" — _best and _step3000 will be appended
# by the trainer).
#
# Failures are loud: any unmatched substitution exits nonzero.

set -euo pipefail

if [ $# -ne 4 ]; then
  echo "usage: $0 <template.rail> <new_seed> <new_ckpt_prefix_path> <output.rail>" >&2
  exit 1
fi

TEMPLATE=$1
NEW_SEED=$2
NEW_CKPT_PREFIX=$3
OUT=$4

if [ ! -f "$TEMPLATE" ]; then
  echo "error: template not found: $TEMPLATE" >&2
  exit 2
fi

# 1. Find old seed: `let rng = lcg_state_new <N>`
OLD_SEED_LINE=$(grep -nE 'let[[:space:]]+rng[[:space:]]*=[[:space:]]*lcg_state_new[[:space:]]+[0-9]+' "$TEMPLATE" | head -1)
if [ -z "$OLD_SEED_LINE" ]; then
  echo "error: no 'let rng = lcg_state_new N' line found in $TEMPLATE" >&2
  exit 3
fi
OLD_SEED=$(echo "$OLD_SEED_LINE" | grep -oE '[0-9]+$')

# 2. Find old ckpt prefix from `let ckpt_best = "..._best"`
OLD_CKPT_BEST=$(grep -E 'let[[:space:]]+ckpt_best[[:space:]]*=' "$TEMPLATE" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$OLD_CKPT_BEST" ]; then
  echo "error: no 'let ckpt_best = \"...\"' line found in $TEMPLATE" >&2
  exit 4
fi
OLD_CKPT_BASE="${OLD_CKPT_BEST%_best}"

# 3. Confirm a matching `let ckpt_final = "<base>_step3000"` exists
OLD_CKPT_FINAL="${OLD_CKPT_BASE}_step3000"
if ! grep -qF "\"${OLD_CKPT_FINAL}\"" "$TEMPLATE"; then
  echo "error: expected ckpt_final \"${OLD_CKPT_FINAL}\" not found in $TEMPLATE" >&2
  exit 5
fi

# 4. Substitute. Use | as sed delimiter since paths contain /.
# Anchor the seed substitution with ^...$ since macOS sed -E doesn't support
# \b. End-of-line anchor prevents partial-matching shorter prefixes (e.g.
# "77" prefix-matching "770") and matches the canonical line shape.
sed -E \
  -e "s|^([[:space:]]*)let rng = lcg_state_new ${OLD_SEED}[[:space:]]*\$|\\1let rng = lcg_state_new ${NEW_SEED}|g" \
  -e "s|${OLD_CKPT_BASE}|${NEW_CKPT_PREFIX}|g" \
  "$TEMPLATE" > "$OUT"

# 5. Verify substitutions actually landed.
NEW_SEED_HITS=$(grep -cE "^[[:space:]]*let rng = lcg_state_new ${NEW_SEED}[[:space:]]*\$" "$OUT" || true)
OLD_SEED_HITS=$(grep -cE "^[[:space:]]*let rng = lcg_state_new ${OLD_SEED}[[:space:]]*\$" "$OUT" || true)
NEW_CKPT_HITS=$(grep -cF "${NEW_CKPT_PREFIX}_best" "$OUT" || true)
OLD_CKPT_HITS=$(grep -cF "${OLD_CKPT_BASE}_best" "$OUT" || true)

if [ "${NEW_SEED_HITS:-0}" -lt 1 ] || [ "${OLD_SEED_HITS:-0}" -gt 0 ]; then
  echo "error: seed substitution failed (new=${NEW_SEED_HITS} old=${OLD_SEED_HITS})" >&2
  rm -f "$OUT"
  exit 6
fi
if [ "${NEW_CKPT_HITS:-0}" -lt 1 ] || [ "${OLD_CKPT_HITS:-0}" -gt 0 ]; then
  echo "error: ckpt substitution failed (new=${NEW_CKPT_HITS} old=${OLD_CKPT_HITS})" >&2
  rm -f "$OUT"
  exit 7
fi

echo "ok: ${TEMPLATE} → ${OUT} (seed ${OLD_SEED}→${NEW_SEED}, ckpt ${OLD_CKPT_BASE}→${NEW_CKPT_PREFIX})"
