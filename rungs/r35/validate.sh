#!/bin/bash
# ============================================================================
# RUNG 35 — Self-Emission: read-only re-verifier of the produced + signed cert.
#
# The self-emission harness already ran to RUNG35_HARNESS PASS and sealed its
# certificate (sha256) into an Ed25519 SELFEMIT record on the emission chain.
# This script re-verifies — WITHOUT any heavy build — that:
#   (1) the cert verdict is PASS,
#   (2) sha256(emitted_source.rail) == the cert's committed emitted_src_sha256,
#   (3) the emitted line == compile.rail:11 at the pinned base commit (emitted==target),
#   (4) the honest fixed-point sha differs from the mutated-self-compile sha
#       (the mutation genuinely breaks the bootstrap -> the leaf is exercised),
#   (5) sha256(cert) == the cert_hex bound into the signed SELFEMIT chain record.
#
# Exit 0 == every binding holds. Seconds, no compiler invocation.
# ============================================================================
set -u
REW=/Users/ledaticempire/rail-reward
OUT=$REW/out
CERT=$OUT/selfemit_cert.txt
EMITTED=$OUT/emitted_source.rail
CHAIN=$OUT/selfemit_chain.txt
SRC=/Users/ledaticempire/projects/rail
BASE=e865138
LINE=11
fail(){ echo "FAIL: $*"; exit 1; }

[ -f "$CERT" ]    || fail "no cert at $CERT"
[ -f "$EMITTED" ] || fail "no emitted source at $EMITTED"
[ -f "$CHAIN" ]   || fail "no chain at $CHAIN"

# (1) cert verdict
grep -q "RUNG35_HARNESS      PASS" "$CERT" || fail "cert verdict is not PASS"
echo "ok (1) cert verdict = PASS"

# (2) emitted src hash binds the committed bytes
CERT_SRC_SHA=$(awk '/^emitted_src_sha256/{print $2}' "$CERT")
REAL_SRC_SHA=$(shasum -a 256 "$EMITTED" | awk '{print $1}')
[ "$CERT_SRC_SHA" = "$REAL_SRC_SHA" ] || fail "emitted_src_sha256 mismatch ($CERT_SRC_SHA != $REAL_SRC_SHA)"
echo "ok (2) sha256(emitted_source.rail) == cert emitted_src_sha256 = $REAL_SRC_SHA"

# (3) emitted == compile.rail:11 at the pinned base commit (emitted == target)
TARGET="$(git -C "$SRC" show "$BASE:tools/compile.rail" 2>/dev/null | sed -n "${LINE}p")"
EMIT="$(cat "$EMITTED")"
[ -n "$TARGET" ] || fail "could not read compile.rail:$LINE @ $BASE"
[ "$TARGET" = "$EMIT" ] || fail "emitted [$EMIT] != target compile.rail:$LINE [$TARGET]"
EMIT_OK=$(awk '/^emitted_eq_target/{print $2}' "$CERT")
[ "$EMIT_OK" = "1" ] || fail "cert emitted_eq_target != 1"
echo "ok (3) emitted == compile.rail:$LINE @ $BASE = [$EMIT]"

# (4) mutation genuinely breaks: honest FP sha != mutated self-compile sha
FP_SHA=$(awk '/^honest_fixed_point/{print $3}' "$CERT" | sed 's/sha256=//')
MUT_SHA=$(awk -F'sha256=' '/^mutation_breaks/{print $2}' "$CERT" | sed 's/)//')
MUT_OK=$(awk '/^mutation_breaks/{print $2}' "$CERT")
[ -n "$FP_SHA" ] && [ -n "$MUT_SHA" ] || fail "could not parse FP/mutation shas from cert"
[ "$FP_SHA" != "$MUT_SHA" ] || fail "honest FP sha == mutated sha (mutation did NOT break -> dead code)"
[ "$MUT_OK" = "1" ] || fail "cert mutation_breaks != 1"
echo "ok (4) honest FP $FP_SHA != mutated $MUT_SHA (mutation breaks self-compile -> leaf exercised)"

# (5) cert is Ed25519-bound: sha256(cert) == cert_hex in the SELFEMIT chain record
CERT_SHA=$(shasum -a 256 "$CERT" | awk '{print $1}')
CHAIN_CERT_HEX=$(grep "^SELFEMIT" "$CHAIN" | awk '{print $2}')
[ -n "$CHAIN_CERT_HEX" ] || fail "no SELFEMIT record in chain"
[ "$CERT_SHA" = "$CHAIN_CERT_HEX" ] || fail "sha256(cert) $CERT_SHA != SELFEMIT cert_hex $CHAIN_CERT_HEX"
echo "ok (5) sha256(cert) == signed SELFEMIT chain record cert_hex = $CERT_SHA"

echo "RUNG35_VALIDATE PASS"
exit 0
