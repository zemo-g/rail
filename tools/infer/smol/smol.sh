#!/usr/bin/env bash
# tools/infer/smol/smol.sh: SmolLM2-135M on Rail's Metal kernels, and exact one-pass
# verification of what it generates. Run from the repository root.
#
#   smol.sh gen "<prompt>" <n> <transcript>   produce n greedy tokens, print the text
#   smol.sh spec "<prompt>" <n> <transcript>  the same transcript, with n-gram speculation
#   smol.sh verify <transcript> [<i> <tok>]   check it in one pass (optionally forge token i)
#   smol.sh parity <transcript>               1-row vs 8-row vs all-at-once bit parity
#   smol.sh ref <transcript>                  the numpy reference's greedy tokens, compared
#
# Needs: macOS on Apple silicon, the public checkpoint (huggingface-cli download
# HuggingFaceTB/SmolLM2-135M model.safetensors tokenizer.json), and a python3 with
# numpy + tokenizers for tokenizing and for the independent reference (SMOL_PY).
set -uo pipefail

PIN=80521b40281d6ce74e35c9282c22539e75aa0ac8578892b2a59955ef78d55da1
HERE=tools/infer/smol
[ -x ./rail_native ] && [ -d "$HERE" ] || { echo "run from the rail repository root" >&2; exit 2; }

SNAP=${SMOL_SNAP:-$(ls -d "$HOME"/.cache/huggingface/hub/models--HuggingFaceTB--SmolLM2-135M/snapshots/*/ 2>/dev/null | head -1)}
MODEL="${SNAP%/}/model.safetensors"
[ -f "$MODEL" ] || { echo "no SmolLM2-135M checkpoint; set SMOL_SNAP to the snapshot directory" >&2; exit 2; }
got=$(shasum -a 256 "$MODEL" | cut -d' ' -f1)
[ "$got" = "$PIN" ] || { echo "model.safetensors sha256 is $got, not the pinned $PIN" >&2; exit 2; }
# The engine's loader reads raw tensor bytes through this path (tgl_fabuf_load_at).
ln -sf "$MODEL" /tmp/rail_fload.bin

PY=${SMOL_PY:-}
if [ -z "$PY" ]; then
  for c in python3 python3.12 python3.11; do
    if command -v "$c" >/dev/null && "$c" -c 'import numpy, tokenizers' 2>/dev/null; then PY=$c; break; fi
  done
fi
export SMOL_SNAP="$SNAP"
WORK=$(mktemp -d /tmp/smol.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

rail() { ./rail_native --out-prefix "$WORK/bin" run "$HERE/$1.rail" "${@:2}" 2>&1 | grep -vE '^\s+(as|ld): OK$|^Compiling |^\[tgl_init\]|^[0-9a-f]{16} [A-Z] '; return "${PIPESTATUS[0]}"; }
need_py() { [ -n "$PY" ] || { echo "no python3 with numpy + tokenizers (set SMOL_PY)" >&2; exit 2; }; }

case "${1:-}" in
  gen)
    need_py
    "$PY" "$HERE/ref.py" tokenize "$2" > "$WORK/prompt.ids"
    rail gen "$WORK/prompt.ids" "$3" "$4"
    (head -1 "$4"; sed -n 2p "$4") | tr '\n' ' ' > "$WORK/all.ids"
    echo "--- text ---"; "$PY" "$HERE/ref.py" decode "$WORK/all.ids" ;;
  spec)
    need_py
    "$PY" "$HERE/ref.py" tokenize "$2" > "$WORK/prompt.ids"
    rail spec "$WORK/prompt.ids" "$3" "$4" ;;
  verify)
    rail verify "${@:2}" ;;
  parity)
    (head -1 "$2"; sed -n 2p "$2") | tr '\n' ' ' > "$WORK/seq.ids"
    rail parity "$WORK/seq.ids" ;;
  ref)
    need_py
    head -1 "$2" > "$WORK/prompt.ids"
    n=$(sed -n 2p "$2" | wc -w | tr -d ' ')
    "$PY" "$HERE/ref.py" greedy "$WORK/prompt.ids" "$n" > "$WORK/ref.txt"
    if [ "$(tr -s ' \n' ' ' < "$WORK/ref.txt" | sed 's/ $//')" = "$(sed -n 2p "$2" | sed 's/ $//')" ]; then
      echo "numpy reference: the same $n greedy tokens"
    else
      echo "numpy reference DISAGREES:"; cat "$WORK/ref.txt"; exit 1
    fi ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
