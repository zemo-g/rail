#!/usr/bin/env python3
# B6 — Foreign (Python) verifier of the r37 committed artifact.
# Demonstrates artifact-attestation: an independent implementation re-derives the SHA-256 commitment
# of the Q.24-quantized weights WITHOUT reproducing the float training trajectory. This is the whole
# point of artifact-attestation — you attest the *artifact* (the signed Q.24 weights), not the process.
#
# Usage: python3 r37_foreign_check.py <expected_sha_from_rail>
# (A full verifier also re-runs the exact-int forward on these weights to reproduce the held-out
#  echo metric cross-platform — the same pattern as rungs/r24/r24_foreign_check.py. The Q.24 weights
#  in r37_weights_q24.txt are integers, so that eval is bit-exact and platform-independent.)
import hashlib, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
ser_path = os.path.join(HERE, "r37_weights_q24.txt")

with open(ser_path, "rb") as f:
    ser = f.read()

# Parse the Q.24 integer weights (comma-separated) — proves they are exact integers (no float
# ambiguity), hence the downstream exact-int eval is cross-platform reproducible.
vals = [int(x) for x in ser.decode().rstrip(",\n").split(",") if x.strip() != ""]
recomputed = hashlib.sha256(ser).hexdigest()

print(f"R37 foreign: parsed {len(vals)} Q.24 integer weights")
print(f"R37 foreign: recomputed SHA-256 = {recomputed}")

if len(sys.argv) > 1:
    expected = sys.argv[1].strip()
    if recomputed == expected:
        print("R37-CHECK PASS  (committed artifact re-derived bit-for-bit in a foreign language)")
        sys.exit(0)
    else:
        print(f"R37-CHECK FAIL  (expected {expected})")
        sys.exit(1)
else:
    print("(no expected SHA passed — integrity hash printed above)")
