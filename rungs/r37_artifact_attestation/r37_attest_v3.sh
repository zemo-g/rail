#!/bin/bash
# r37 v3 attestation wrapper — EXACT-INT eval (eval=xint-q24-v1; evolve 2026-06-09).
#
# v2 attested training (weights + float metric). v3 attests the EVAL itself:
# runs the exact-integer Q.24 forward in BOTH implementations (Rail evaluator +
# pure-int Python verifier), requires bit-identical metric AND full-output
# pred-SHA, brackets the run with beacon pulses, signs with the Ed25519
# LOCAL/DEV key, then re-verifies the record end-to-end with the foreign
# checker. Fail-loud polarity: ANY mismatch or missing input exits non-zero.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO" || exit 1
OUT="rungs/r37_artifact_attestation/out"
mkdir -p "$OUT"

die() { echo "R37-ATTEST-V3-FAIL: $*" >&2; exit 1; }

ORDER="00_w_e 01_w_o 02_wq1 03_wk1 04_wv1 05_wf11 06_wf21 07_wq2 08_wk2 09_wv2 10_wf12 11_wf22 12_ln_g 13_ln_b"

assemble() { # $1 = dir holding r37full_*.part, $2 = output file
  local dir="$1" out="$2" f
  : > "$out"
  for nm in $ORDER; do
    f="$dir/r37full_${nm}.part"
    [ -s "$f" ] || die "missing/empty part $f"
    cat "$f" >> "$out"
  done
  local n
  n=$(tr -cd ',' < "$out" | wc -c | tr -d ' ')
  [ "$n" = "93696" ] || die "assembled $out has $n ints, expected 93696"
}

# ── 0. inputs: committed splits + full Q.24 artifact (assemble from parts if absent) ──
[ -s "rungs/r24/force_train_4d.txt" ] || die "missing train split"
[ -s "rungs/r24/force_holdout_4d.txt" ] || die "missing holdout split"
FULL="$OUT/r37_force_weights_q24_full.txt"
if [ ! -s "$FULL" ]; then
  echo "full artifact absent; assembling from committed parts..."
  assemble "rungs/r37_artifact_attestation" "$FULL"
fi
echo "weights: $(shasum -a 256 "$FULL" | cut -d' ' -f1)"

# ── 1. pre-pulse (the sandwich brackets the EVAL, which is what v3 attests) ──
curl -fsS --max-time 8 https://ledatic.org/entropy/pulse > "$OUT/pulse_pre_v3.json" || die "pre-pulse fetch failed"
PRE_ID=$(python3 -c "import json;print(json.load(open('$OUT/pulse_pre_v3.json'))['pulse_id'])") || die "bad pulse_pre_v3.json"
printf '%s' "$PRE_ID" > "$OUT/pulse_pre_v3_id.txt"
echo "pulse_pre=$PRE_ID"

# ── 2. Rail exact-int evaluator ──
XINT_BIN="${R37_XINT_BIN:-/tmp/r37_xint_eval_bin}"
if [ ! -x "$XINT_BIN" ]; then
  ./rail_native rungs/r37_artifact_attestation/r37_xint_eval.rail || die "Rail evaluator compile failed"
  cp /tmp/rail_out "$XINT_BIN"
fi
"$XINT_BIN" > "$OUT/xint_eval_rail.log" 2>&1 || die "Rail evaluator exited non-zero (see $OUT/xint_eval_rail.log)"
RAIL_METRIC=$(sed -n 's|^R37_XINT_METRIC=\([0-9]*\)/64.*|\1|p' "$OUT/xint_eval_rail.log" | tail -1)
RAIL_PRED=$(sed -n 's|^R37_XINT_PRED_SHA=\([0-9a-f]*\)$|\1|p' "$OUT/xint_eval_rail.log" | tail -1)
[ -n "$RAIL_METRIC" ] || die "no R37_XINT_METRIC in Rail log"
[ -n "$RAIL_PRED" ] || die "no R37_XINT_PRED_SHA in Rail log"
echo "rail:   metric=$RAIL_METRIC/64 pred_sha=$RAIL_PRED"

# ── 3. Python pure-int verifier (forward-only) ──
python3 rungs/r37_artifact_attestation/r37_foreign_check_v3.py --forward-only > "$OUT/xint_eval_py.log" 2>&1 \
  || die "Python forward-only failed (see $OUT/xint_eval_py.log)"
PY_METRIC=$(sed -n 's|^R37_XINT_METRIC=\([0-9]*\)/64.*|\1|p' "$OUT/xint_eval_py.log" | tail -1)
PY_PRED=$(sed -n 's|^R37_XINT_PRED_SHA=\([0-9a-f]*\)$|\1|p' "$OUT/xint_eval_py.log" | tail -1)
MACC=$(sed -n 's|.*max_acc_bits=\([0-9]*\).*|\1|p' "$OUT/xint_eval_py.log" | tail -1)
[ -n "$PY_METRIC" ] && [ -n "$PY_PRED" ] && [ -n "$MACC" ] || die "Python log missing metric/pred/max_acc_bits"
echo "python: metric=$PY_METRIC/64 pred_sha=$PY_PRED max_acc_bits=$MACC"

# ── 4. cross-witness gate: both implementations must agree bit-for-bit ──
[ "$RAIL_METRIC" = "$PY_METRIC" ] || die "METRIC DISAGREES: rail=$RAIL_METRIC python=$PY_METRIC"
[ "$RAIL_PRED" = "$PY_PRED" ] || die "PRED SHA DISAGREES: rail=$RAIL_PRED python=$PY_PRED"
[ "$MACC" -lt 62 ] || die "overflow audit: max_acc_bits=$MACC >= 62"
echo "R37_XINT_CROSSWITNESS=PASS (Rail == Python: metric + full 559-char output trace)"
printf '%s' "$RAIL_METRIC" > "$OUT/metric_v3.txt"
printf '%s' "$RAIL_PRED" > "$OUT/pred_sha_v3.txt"
printf '%s' "$MACC" > "$OUT/max_acc_bits_v3.txt"

# ── 5. post-pulse ──
curl -fsS --max-time 8 https://ledatic.org/entropy/pulse > "$OUT/pulse_post_v3.json" || die "post-pulse fetch failed"
POST_ID=$(python3 -c "import json;print(json.load(open('$OUT/pulse_post_v3.json'))['pulse_id'])") || die "bad pulse_post_v3.json"
printf '%s' "$POST_ID" > "$OUT/pulse_post_v3_id.txt"
[ "$POST_ID" -gt "$PRE_ID" ] || die "pulse_post ($POST_ID) not after pulse_pre ($PRE_ID)"
echo "pulses: pre=$PRE_ID post=$POST_ID"

# ── 6. sign (Ed25519 LOCAL/DEV key -- never the prod Pi-witness surface) ──
SIGNER_BIN="${R37_SIGNER_V3_BIN:-/tmp/r37_sign_v3_bin}"
if [ ! -x "$SIGNER_BIN" ]; then
  ./rail_native rungs/r37_artifact_attestation/r37_sign_v3.rail || die "signer compile failed"
  cp /tmp/rail_out "$SIGNER_BIN"
fi
"$SIGNER_BIN" || die "signer exited non-zero (selfverify failed?)"

# ── 7. foreign verification of the fresh record (full mode) ──
python3 rungs/r37_artifact_attestation/r37_foreign_check_v3.py || die "foreign checker FAILED on the fresh v3 record"

echo "R37_ATTEST_V3_WRAPPER=DONE  (record at $OUT/r37_attestation_v3.txt)"
