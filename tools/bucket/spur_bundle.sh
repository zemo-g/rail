#!/bin/bash
# spur_bundle.sh — Bundle a Spur checkpoint into an inference-ready tarball.
#
# Output: training/checkpoints_published/<name>-inference.tar.gz containing:
#   <name>.committed
#   <name>.manifest
#   <name>.meta
#   <name>.<i>.f32  for i in 0..N-1   (weights only; no adam state)
#
# An optional "resume" bundle adds adam_m / adam_v files for resuming
# training. Pass MODE=resume to build it alongside the inference bundle.
#
# Bundles are committed to the rail repo and pushed via the standard
# Mini-proxied origin. They become reachable from any clone — no
# separate bucket repo or GitHub auth required.
#
# f32 weights gzip ~300:1 due to repeating init structure: a d=384
# 2-block ckpt's 15 MB raw weights bundle to ~50 KB. d=256 is ~25 KB.
#
# Usage:
#   tools/bucket/spur_bundle.sh <ckpt_name>
#   MODE=resume tools/bucket/spur_bundle.sh <ckpt_name>

set -e

CKPT="${1:?usage: spur_bundle.sh <ckpt_name>}"
MODE="${MODE:-inference}"
SRC="training/rail_native/checkpoints/${CKPT}"
OUT_DIR="training/checkpoints_published"
mkdir -p "$OUT_DIR"

if [ ! -f "${SRC}.committed" ]; then
  echo "ERROR: no committed checkpoint at ${SRC}" >&2
  exit 1
fi

INF_TGZ="${OUT_DIR}/${CKPT}-inference.tar.gz"
echo "Bundling inference assets for $CKPT ..."
tar czf "$INF_TGZ" \
  -C training/rail_native/checkpoints \
  "${CKPT}.committed" \
  "${CKPT}.manifest" \
  "${CKPT}.meta" \
  $(cd training/rail_native/checkpoints && ls "${CKPT}".*.f32 2>/dev/null | grep -v "adam")

inf_size=$(stat -f %z "$INF_TGZ")
echo "  → $INF_TGZ ($((inf_size / 1024)) KB)"

if [ "$MODE" = "resume" ]; then
  RES_TGZ="${OUT_DIR}/${CKPT}-resume.tar.gz"
  echo "Bundling resume assets for $CKPT ..."
  tar czf "$RES_TGZ" \
    -C training/rail_native/checkpoints \
    "${CKPT}.committed" \
    "${CKPT}.manifest" \
    "${CKPT}.meta" \
    $(cd training/rail_native/checkpoints && ls "${CKPT}".*.f32 2>/dev/null) \
    $(cd training/rail_native/checkpoints && ls "${CKPT}".adam.*.f32 2>/dev/null)
  res_size=$(stat -f %z "$RES_TGZ")
  echo "  → $RES_TGZ ($((res_size / 1024)) KB)"
fi
