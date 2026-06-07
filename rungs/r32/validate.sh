#!/usr/bin/env bash
# RUNG 32 -- Compile-Bound Utterance: validate to a green gate.
#
# Builds the compile-bound-utterance harness, runs it (it trains the lm10 transformer, has the model
# SPEAK a runnable Rail program, invokes the PINNED rail_native to compile + run it, and binds
# compiled=1 + src_hex + out_hex + compiler-identity + the prompt-derived stdout property into its
# Ed25519 chain), then runs the FOREIGN (Python) cross-language re-verifier which re-derives the
# weights, re-decodes the source, RE-COMPILES with the pinned compiler, RE-RUNS to identical out_hex,
# and verifies the attestation. Green gate = BOTH the Rail "PASS" line and the foreign "CBU-CHECK PASS".
#
# MUST be run from the repo root (so corpus + rail_native + stdlib imports resolve, matching the
# trainer's cwd). RAIL_ARENA_MB is REQUIRED: lm10 needs a multi-GB arena or it GC-thrashes forever.
#
# Usage:  bash rungs/r32/validate.sh
set -u
cd "$(dirname "$0")/../.." || exit 2          # -> repo root
ROOT="$(pwd)"
HARNESS="rungs/r32/compile_bound_utterance.rail"
BIN="out/cbutter_bin"
CHAIN="out/cbutter_chain.txt"
FCHK="rungs/r32/cbutter_foreign_check.py"

mkdir -p out

echo "== [1/3] build the compile-bound-utterance harness =="
./rail_native --out-prefix "$BIN" "$HARNESS" 2>&1 | tail -4
if [ ! -x "$BIN" ]; then
  echo "VALIDATE FAIL: harness did not build ($BIN missing)"; exit 1
fi

echo "== [2/3] run: train -> speak -> compile -> run -> attest (RAIL_ARENA_MB=8192) =="
RAIL_ARENA_MB=8192 "./$BIN"
RC=$?
if [ $RC -ne 0 ]; then
  echo "VALIDATE FAIL: harness exited $RC (Rail self-gates did not all pass)"; exit 1
fi
if [ ! -f "$CHAIN" ]; then
  echo "VALIDATE FAIL: signed ledger $CHAIN not written"; exit 1
fi

echo "== [3/3] foreign cross-language re-verification =="
python3 "$FCHK" "$CHAIN"
FRC=$?
if [ $FRC -ne 0 ]; then
  echo "VALIDATE FAIL: foreign verifier rejected the compile-bound attestation"; exit 1
fi

echo "VALIDATE PASS: rung 32 -- the model's spoken Rail COMPILES + RUNS, attested, and an "
echo "independent cross-language party re-compiled + re-ran it to the identical committed stdout."
exit 0
