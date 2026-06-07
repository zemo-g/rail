#!/usr/bin/env bash
# RUNG 27 - REPLAY-FREE VERIFICATION OF THE SAYING - validation gate.
#
# Climbs from the proven attested-utterance floor: a verifier confirms the model said exactly the
# attested words from a signed weight bundle whose SHA-256 IS the ledger commitment w_hex, re-running
# ONLY the ~48 decode steps - never the training epochs.
#
# Stage A (one-time, heavy): the rung-27 trainer re-runs the proven training and ALSO ships the
#   weight bundle = the exact theta-only canon preimage of w_hex (so SHA-256(bundle) == w_hex).
#   It self-asserts okBundleBinds in its own gate. ~2-3 min; needs RAIL_ARENA_MB.
# Stage B (the rung's point - FAST): two independent witnesses (Rail + Python, different languages)
#   load the bundle, hash-check it against the ledger w_hex (REJECT AT LOAD on tamper), parse the
#   thetas, re-decode only the ~48 saying steps, reproduce t_hex, verify the sig - ZERO training.
#   The Python witness asserts wall-clock < 5s for the decode and that rederive() is never called.
#
# Falsifiers (each must make the gate FAIL when triggered, checked inside the verifiers):
#   1. tamper one bundle cell -> SHA != w_hex -> reject at load, before any decode
#   2. correct weights + a hand-edited t_hex tape -> redraw from real weights contradicts tape
#   3. forged signature byte -> RFC 8032 verify rejects
#
# Exit 0 + final line PASS == rung achieved.

set -u
cd "$(dirname "$0")/../.." || exit 2
ROOT="$(pwd)"
echo "rung27 validate: repo root = $ROOT"
RAIL="${RAIL_NATIVE:-./rail_native}"
ARENA="${RAIL_ARENA_MB:-8192}"

fail() { echo "RUNG27 VALIDATE FAIL: $1"; echo "FAIL"; exit 1; }

# ---- Stage A: build + run the rung-27 trainer to PRODUCE the signed ledger + weight bundle ----
# (skip the retrain if both artifacts already exist AND the bundle's SHA matches the ledger w_hex)
need_train=1
if [ -f out/utterance_chain.txt ] && [ -f out/weights_bundle.txt ]; then
  WHEX=$(grep '^UTTER ' out/utterance_chain.txt | awk '{print $5}')
  BSHA=$(shasum -a 256 out/weights_bundle.txt | awk '{print $1}')
  if [ "$WHEX" = "$BSHA" ]; then
    echo "rung27: existing bundle binds (SHA == ledger w_hex); skipping retrain."
    need_train=0
  fi
fi

if [ "$need_train" = "1" ]; then
  echo "rung27 Stage A: compiling trainer (rungs/r27/rung27_train.rail)..."
  $RAIL --out-prefix rungs/r27/r27t_bin rungs/r27/rung27_train.rail || fail "trainer compile failed"
  echo "rung27 Stage A: training + shipping bundle (RAIL_ARENA_MB=$ARENA, ~2-3 min)..."
  RAIL_ARENA_MB=$ARENA ./rungs/r27/r27t_bin || fail "trainer run failed (gate not PASS)"
fi

[ -f out/weights_bundle.txt ] || fail "out/weights_bundle.txt not produced"
[ -f out/utterance_chain.txt ] || fail "out/utterance_chain.txt missing"

# binding sanity from the shell (independent of the trainer's own self-assert)
WHEX=$(grep '^UTTER ' out/utterance_chain.txt | awk '{print $5}')
BSHA=$(shasum -a 256 out/weights_bundle.txt | awk '{print $1}')
echo "rung27: ledger w_hex = $WHEX"
echo "rung27: SHA(bundle)  = $BSHA"
[ "$WHEX" = "$BSHA" ] || fail "bundle SHA-256 != ledger w_hex (load==check binding broken)"

# ---- Stage B1: Rail replay-free self-witness (decode-only) ----
echo "rung27 Stage B1: compiling Rail replay-free verifier..."
$RAIL --out-prefix rungs/r27/r27v_bin rungs/r27/rung27_verify.rail || fail "verifier compile failed"
echo "rung27 Stage B1: Rail verify (decode-only, zero epochs)..."
RAIL_ARENA_MB=2048 ./rungs/r27/r27v_bin || fail "Rail replay-free verifier did not PASS"

# ---- Stage B2: foreign (Python) replay-free witness (decode-only, < 5s, no rederive) ----
echo "rung27 Stage B2: foreign Python replay-free verifier..."
python3 rungs/r27/rung27_foreign_check.py out/utterance_chain.txt out/weights_bundle.txt \
  || fail "foreign replay-free verifier did not PASS"

# ---- Stage B3: explicit FALSIFIER - tamper one byte of the bundle must FAIL the foreign load check ----
echo "rung27 Stage B3: falsifier - tampered bundle must be rejected at load..."
cp out/weights_bundle.txt /tmp/r27_tampered_bundle.txt
# flip the first character (cheap, deterministic): 0<->1 ; any change flips the SHA
python3 - <<'PY' || true
b=open('/tmp/r27_tampered_bundle.txt','rb').read()
b=(b'9' if b[:1]!=b'9' else b'8')+b[1:]
open('/tmp/r27_tampered_bundle.txt','wb').write(b)
PY
if python3 rungs/r27/rung27_foreign_check.py out/utterance_chain.txt /tmp/r27_tampered_bundle.txt >/dev/null 2>&1; then
  fail "tampered bundle was ACCEPTED (load-check is not sound)"
fi
echo "rung27 Stage B3: tampered bundle correctly REJECTED at load (exit non-zero)."

echo "rung27: Rail + Python independently verified the SAYING replay-free; tamper rejected."
echo "PASS"
