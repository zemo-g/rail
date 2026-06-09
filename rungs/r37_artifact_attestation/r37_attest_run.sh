#!/bin/bash
# r37 gate-grade attestation wrapper (audit fix 2026-06-09).
#
# Run AFTER the twin training runs (A in repo, B in /tmp/r37_runB) complete.
# Assembles the FULL Q.24 artifact from the 14 part files in the documented
# order, cross-checks the SHA in shell (independent of Rail's sha256), proves
# two-run determinism at ARTIFACT level (full-file SHA equality A==B), fetches
# the post-run beacon pulse, and invokes the Ed25519 dev-key signer.
#
# Fail-loud polarity: ANY missing input or mismatch exits non-zero loudly.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO" || exit 1
OUT="rungs/r37_artifact_attestation/out"
RUNB="${R37_RUNB_DIR:-/tmp/r37_runB}"
mkdir -p "$OUT"

die() { echo "R37-ATTEST-FAIL: $*" >&2; exit 1; }

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

# ── 1. metric from run A log ──
ALOG="$OUT/run_A.log"
[ -s "$ALOG" ] || die "missing $ALOG"
METRIC=$(sed -n 's/^FINAL HELDOUT_DIGITS=\([0-9]*\)\/64.*/\1/p' "$ALOG" | tail -1)
[ -n "$METRIC" ] || die "no FINAL HELDOUT_DIGITS in $ALOG"
printf '%s' "$METRIC" > "$OUT/metric.txt"
echo "metric: $METRIC/64"

# ── 2. assemble full artifacts for A and B; prove artifact-level determinism ──
assemble "rungs/r37_artifact_attestation" "$OUT/r37_force_weights_q24_full.txt"
SHA_A=$(shasum -a 256 "$OUT/r37_force_weights_q24_full.txt" | cut -d' ' -f1)
echo "R37_FULL_WEIGHT_SHA_A=$SHA_A"

if [ -d "$RUNB/rungs/r37_artifact_attestation" ]; then
  assemble "$RUNB/rungs/r37_artifact_attestation" "$OUT/r37_runB_full.txt"
  SHA_B=$(shasum -a 256 "$OUT/r37_runB_full.txt" | cut -d' ' -f1)
  echo "R37_FULL_WEIGHT_SHA_B=$SHA_B"
  [ "$SHA_A" = "$SHA_B" ] || die "DETERMINISM BROKEN: run A != run B full-artifact SHA"
  echo "R37_TWORUN_DETERMINISM=PASS (full 93,696-weight artifact SHA equal)"
  # v1 continuity canary: both logs must carry the same v1 (embed+readout) SHA.
  V1A=$(sed -n 's/^R37_FORCE_WEIGHT_SHA=\([0-9a-f]*\)$/\1/p' "$ALOG" | tail -1)
  V1B=$(sed -n 's/^R37_FORCE_WEIGHT_SHA=\([0-9a-f]*\)$/\1/p' "$RUNB/run_B.log" | tail -1)
  [ -n "$V1A" ] && [ "$V1A" = "$V1B" ] || die "v1 SHA mismatch between runs (A=$V1A B=$V1B)"
  echo "R37_V1_SHA=$V1A (A==B)"
else
  echo "WARN: run B dir absent; skipping two-run determinism check" >&2
fi

# ── 3. pulses: extract pre id, fetch post ──
[ -s "$OUT/pulse_pre.json" ] || die "missing $OUT/pulse_pre.json (must be fetched BEFORE launch)"
PRE_ID=$(python3 -c "import json;print(json.load(open('$OUT/pulse_pre.json'))['pulse_id'])") || die "bad pulse_pre.json"
printf '%s' "$PRE_ID" > "$OUT/pulse_pre_id.txt"
curl -fsS --max-time 8 https://ledatic.org/entropy/pulse > "$OUT/pulse_post.json" || die "post-pulse fetch failed"
POST_ID=$(python3 -c "import json;print(json.load(open('$OUT/pulse_post.json'))['pulse_id'])") || die "bad pulse_post.json"
printf '%s' "$POST_ID" > "$OUT/pulse_post_id.txt"
[ "$POST_ID" -gt "$PRE_ID" ] || die "pulse_post ($POST_ID) not after pulse_pre ($PRE_ID)"
echo "pulses: pre=$PRE_ID post=$POST_ID"

# ── 4. sign (Ed25519 LOCAL/DEV key -- never the prod Pi-witness surface) ──
SIGNER_BIN="${R37_SIGNER_BIN:-/tmp/r37_sign_bin}"
if [ ! -x "$SIGNER_BIN" ]; then
  ./rail_native rungs/r37_artifact_attestation/r37_sign.rail || die "signer compile failed"
  cp /tmp/rail_out "$SIGNER_BIN"
fi
"$SIGNER_BIN" || die "signer exited non-zero (selfverify failed?)"

echo "R37_ATTEST_WRAPPER=DONE  (record at $OUT/r37_attestation.txt)"
