#!/usr/bin/env bash
# ============================================================================
# RUNG 26 — Provably-Identical Tie-Break: Nucleus & Top-k  ·  VALIDATE GATE
# ============================================================================
# Run SERIALLY by the orchestrator (one shared compiler + one GPU + 24GB RAM).
# This rung is decoupled from the multi-GB lm10 training run: it validates the
# genuinely-new sampling wall (exact-tie total order + top-k + nucleus +
# Q.24 sample-entropy + chain-seeded RNG draw) on a fixed engineered Q.24
# distribution. Compile cost is small; RAIL_ARENA_MB=512 is plenty (no training).
#
# PASS criteria (all must hold):
#   1. Rail binary prints "PASS" and exits 0   (Rail self-witness: every gate +
#      falsifier holds inside the trainer);
#   2. the signed ledger out/r26_chain.txt is produced;
#   3. the FOREIGN cross-language witness reproduces top-k + nucleus membership,
#      both draw-stream t_hexes, the Q.24 entropy, verifies the Ed25519 sig, and
#      catches all three falsifiers -> "R26-FOREIGN PASS" exit 0;
#   4. the negative controls fail: a tampered t_hex AND a TIE_HIGH-built-but-
#      TIE_LOW-labeled ledger are both REJECTED by the foreign witness (exit 1).
# ============================================================================
set -u
cd "$(dirname "$0")/../.." || exit 2          # -> repo root (rail-reward)
ROOT="$(pwd)"
RAIL="${RAIL_NATIVE:-$ROOT/rail_native}"
SRC="rungs/r26/tiebreak_sampling.rail"
LEDGER="out/r26_chain.txt"
FCHK="rungs/r26/r26_foreign_check.py"
mkdir -p out

fail() { echo "R26 VALIDATE FAIL: $1"; exit 1; }

# ---- 1. compile the Rail trainer (isolated out-prefix; never /tmp/rail_out) ----
echo "[r26] compiling $SRC ..."
"$RAIL" --out-prefix out/r26_bin "$SRC" || fail "compile error"
[ -x out/r26_bin ] || fail "no out/r26_bin produced"

# ---- 2. run it (512MB arena is plenty: sampling only, no training) ----
echo "[r26] running self-witness ..."
RAIL_ARENA_MB=512 ./out/r26_bin > out/r26_run.log 2>&1
RC=$?
cat out/r26_run.log
[ $RC -eq 0 ] || fail "Rail binary exit $RC"
grep -q "^PASS" out/r26_run.log || fail "Rail self-witness did not PASS"
[ -f "$LEDGER" ] || fail "no signed ledger $LEDGER"

# ---- 3. foreign cross-language witness must reproduce + verify ----
echo "[r26] foreign cross-language witness ..."
python3 "$FCHK" "$LEDGER" || fail "foreign witness rejected the honest ledger"

# ---- 4. negative controls: falsifiers must be able to FAIL ----
echo "[r26] negative control A: tampered nuc_thex must be REJECTED ..."
python3 - "$LEDGER" <<'PY'
import sys,re
s=open(sys.argv[1]).read()
m=re.search(r'nuc_thex=([0-9a-f]{64})',s); h=m.group(1)
bad=('0' if h[0]!='0' else '1')+h[1:]
open("out/r26_neg_tamper.txt","w").write(s.replace("nuc_thex="+h,"nuc_thex="+bad))
PY
python3 "$FCHK" out/r26_neg_tamper.txt >/dev/null 2>&1 && fail "tampered ledger wrongly ACCEPTED"
echo "[r26]   tampered ledger correctly rejected."

echo "[r26] negative control B: TIE_HIGH-built / TIE_LOW-labeled must be REJECTED ..."
python3 rungs/r26/r26_neg_tiehigh.py out/r26_neg_tiehigh.txt || fail "neg-control B generator error"
python3 "$FCHK" out/r26_neg_tiehigh.txt >/dev/null 2>&1 && fail "tie-rule forgery wrongly ACCEPTED"
echo "[r26]   tie-rule forgery correctly rejected."

echo "R26 VALIDATE PASS"
exit 0
