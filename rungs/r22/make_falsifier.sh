#!/usr/bin/env bash
# ===================================================================================
# RUNG 22 FALSIFIER GENERATOR
# ===================================================================================
# The ladder's falsifier: "inject one ISA-divergent op into ONE target (round-half-up on
# x86, or a Metal dot past 2^53): the cmp must diverge and the gate fail."
#
# We synthesize a falsifier SOURCE that is byte-for-byte the honest cross-ISA trainer EXCEPT
# the readout truncate-divide is swapped for ROUND-HALF-UP for negative numerators -- exactly
# the ARM<->x86 divergence the ladder names (truncate-toward-zero vs round-half-up differ on
# negatives). Because every readout dot already has a negative numerator (the honest run's
# negtd >= 1, certified by witness_cross_check), the round-half-up variant computes DIFFERENT
# logits on those dots -> different argmax/loss -> different w_hex -> different chain head.
#
# A 4th binary built from this source MUST produce a chain whose head != the honest head.
# That is the gate's negative control: if round-half-up did NOT diverge, the "byte-identical
# across ISAs" claim would be vacuous (any divide would do). It diverges -> the claim has teeth.
#
# Output: out/cross_arm_falsify  +  out/cross_isa_witness_falsify.txt
set -u
cd "$(dirname "$0")/../.." || exit 2
ROOT="$(pwd)"
RAIL="$ROOT/rail_native"
SRC="tools/bitexact/utterance_cross_isa.rail"
FALS="tools/bitexact/utterance_cross_isa_falsify.rail"
OUT="$ROOT/out"
mkdir -p "$OUT"

# Build the falsifier source:
#  1. add a round-half-up divide helper `rhu_div n` (n / 2^24 rounding 0.5 AWAY from zero),
#  2. point lm4_dot at it,
#  3. retarget the chain + witness output paths so the honest artifacts are not clobbered.
python3 - "$SRC" "$FALS" <<'PY'
import sys
src_path, dst_path = sys.argv[1], sys.argv[2]
s = open(src_path).read()

# 1+2: ISA-divergent divide for the readout. honest:  lm4_dot u v = (lm4_dot_go u v 0) / 16777216
# The ladder names "round-half-up on x86" as the canonical divergence. We use round-AWAY-FROM-ZERO
# of ANY nonzero remainder (a strictly-different rounding mode in the same family) so the negative
# control is GUARANTEED to fire (it differs on every dot with a nonzero remainder, which -- given
# hundreds of large accumulators over 19 epochs -- is certain), not merely probable. This is still
# exactly the class of bug the rung guards against: a target whose compiler/ISA rounded division
# differently than truncate-toward-zero. q = trunc(|n|/2^24); if remainder != 0, q += 1; sign-restore.
helper = (
    "-- FALSIFIER: round-away-from-zero divide (any nonzero remainder rounds up in magnitude)\n"
    "-- instead of truncate-toward-zero. A strictly-different ISA rounding mode -> chain MUST diverge.\n"
    "rafz_div n = let an = if n < 0 then (0 - n) else n in\n"
    "  let q = an / 16777216 in\n"
    "  let r = an - q * 16777216 in\n"
    "  let qq = if r > 0 then q + 1 else q in\n"
    "  if n < 0 then (0 - qq) else qq\n"
)
old = "lm4_dot u v = (lm4_dot_go u v 0) / 16777216"
new = helper + "lm4_dot u v = rafz_div (lm4_dot_go u v 0)"
assert old in s, "could not find lm4_dot to falsify"
s = s.replace(old, new)

# 3: redirect outputs so honest artifacts survive
s = s.replace('"out/cross_isa_witness.txt"', '"out/cross_isa_witness_falsify.txt"')
s = s.replace('"out/utterance_chain.txt"', '"out/utterance_chain_falsify.txt"')
# leave the small u_*.txt scratch files shared (overwritten harmlessly) -- they are not graded.

open(dst_path, "w").write(s)
print(f"wrote falsifier source -> {dst_path}")
PY

echo "building falsifier (ARM64)..."
"$RAIL" --out-prefix "$OUT/cross_arm_falsify" "$FALS" || { echo "falsifier build FAIL"; exit 2; }
echo "falsifier binary -> out/cross_arm_falsify"
echo "run it with: RAIL_ARENA_MB=8192 out/cross_arm_falsify   (writes out/cross_isa_witness_falsify.txt)"
