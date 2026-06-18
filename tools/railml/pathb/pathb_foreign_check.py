#!/usr/bin/env python3
# tools/railml/pathb/pathb_foreign_check.py
#
# Path-B ATTEST D3 foreign witness. The independent leg of the attestation
# loop: it re-derives the SHA-256 of the raw artifact bytes and Ed25519-verifies
# the signature over the canonical attest message -- WITHOUT trusting any
# Rail-side claim. The only inputs it trusts are:
#   - the raw artifact bytes        (tools/railml/pathb/logits.txt)
#   - the witness public key         (~/.ledatic/witness/fleet0.pub.pem)
# Everything else in the attestation JSON (the claimed digest, sig, pulse_id,
# witnessed_at, value_hex) is treated as an *assertion to be checked*, never as
# ground truth. If the JSON lies about the digest, the recompute catches it; if
# it lies about the signature/message, the Ed25519 verify catches it.
#
# Mirrors the bx*_foreign_check.py pattern (pure-Python re-implementation, no
# wrapper around the same code path Rail used). Ed25519 verification is a pure-
# Python RFC-8032 implementation here so it does not even trust a shared crypto
# library that Rail might also call. If `cryptography` is importable it is run
# as an *additional* cross-check, but the pass/fail decision is the pure-Python
# verifier's.
#
# Usage:
#   python3 pathb_foreign_check.py [artifact] [attestation.json] [pubkey.pem]
# Defaults:
#   artifact         = tools/railml/pathb/logits.txt   (relative to this file)
#   attestation.json = <artifact>.attestation.json
#   pubkey.pem       = ~/.ledatic/witness/fleet0.pub.pem
#
# Exit 0 + "PATHB ATTEST D3 PASS" iff:
#   (1) recomputed SHA-256(artifact) == witness.digest_sha256 in the JSON, AND
#   (2) Ed25519_verify(pubkey, "attest|v1|<digest>|<pulse>|<vhex>|<ts>", sig) ok.
# Nonzero exit + reason on any mismatch.

import base64
import hashlib
import json
import os
import sys

# ----------------------------------------------------------------------------
# Pure-Python Ed25519 verify (RFC 8032, curve25519 / edwards25519). No deps.
# Standard reference construction; kept self-contained so the foreign witness
# does not import the same crypto another component used.
# ----------------------------------------------------------------------------
_P = 2 ** 255 - 19
_L = 2 ** 252 + 27742317777372353535851937790883648493
_D = (-121665 * pow(121666, _P - 2, _P)) % _P
_I = pow(2, (_P - 1) // 4, _P)


def _xrecover(y):
    xx = (y * y - 1) * pow(_D * y * y + 1, _P - 2, _P)
    x = pow(xx, (_P + 3) // 8, _P)
    if (x * x - xx) % _P != 0:
        x = (x * _I) % _P
    if x % 2 != 0:
        x = _P - x
    return x


_By = (4 * pow(5, _P - 2, _P)) % _P
_Bx = _xrecover(_By)
_B = (_Bx % _P, _By % _P, 1, (_Bx * _By) % _P)  # extended coords (X, Y, Z, T)


def _edwards_add(p, q):
    x1, y1, z1, t1 = p
    x2, y2, z2, t2 = q
    a = ((y1 - x1) * (y2 - x2)) % _P
    b = ((y1 + x1) * (y2 + x2)) % _P
    c = (t1 * 2 * _D * t2) % _P
    dd = (z1 * 2 * z2) % _P
    e = b - a
    f = dd - c
    g = dd + c
    h = b + a
    x3 = (e * f) % _P
    y3 = (g * h) % _P
    t3 = (e * h) % _P
    z3 = (f * g) % _P
    return (x3, y3, z3, t3)


def _scalarmult(p, e):
    q = (0, 1, 1, 0)  # neutral
    while e > 0:
        if e & 1:
            q = _edwards_add(q, p)
        p = _edwards_add(p, p)
        e >>= 1
    return q


def _decodepoint(s):
    if len(s) != 32:
        raise ValueError("bad point length")
    y = int.from_bytes(s, "little") & ((1 << 255) - 1)
    sign = (s[31] >> 7) & 1
    x = _xrecover(y)
    if (x & 1) != sign:
        x = _P - x
    p = (x % _P, y % _P, 1, (x * y) % _P)
    # on-curve check
    xx, yy, zz, tt = p
    if (xx * yy - zz * tt) % _P != 0:
        raise ValueError("point not on curve (T)")
    if (-xx * xx + yy * yy - zz * zz - _D * tt * tt) % _P != 0:
        raise ValueError("point not on curve")
    return p


def _to_affine(p):
    x, y, z, _t = p
    zi = pow(z, _P - 2, _P)
    return ((x * zi) % _P, (y * zi) % _P)


def ed25519_verify_pure(public_key32, message, signature64):
    """Pure-Python Ed25519 verify. Returns True iff the signature is valid."""
    if len(signature64) != 64:
        return False
    if len(public_key32) != 32:
        return False
    r_bytes = signature64[:32]
    s = int.from_bytes(signature64[32:], "little")
    if s >= _L:
        return False
    a = _decodepoint(public_key32)
    h = hashlib.sha512(r_bytes + public_key32 + message).digest()
    k = int.from_bytes(h, "little") % _L
    # Check [s]B == R + [k]A
    sb = _scalarmult(_B, s)
    r_pt = _decodepoint(r_bytes)
    ka = _scalarmult(a, k)
    rhs = _edwards_add(r_pt, ka)
    return _to_affine(sb) == _to_affine(rhs)


# ----------------------------------------------------------------------------
# PEM -> raw 32-byte Ed25519 public key (SubjectPublicKeyInfo: 12-byte prefix
# + 32-byte raw key). We take the trailing 32 bytes of the DER body, matching
# the Rail verifier's pem_extract_pubkey.
# ----------------------------------------------------------------------------
def load_ed25519_pub_from_pem(path):
    with open(path) as fh:
        text = fh.read()
    body = "".join(
        line for line in text.splitlines() if line and "-----" not in line
    )
    der = base64.b64decode(body)
    if len(der) < 32:
        raise ValueError("PEM DER too short for Ed25519 SPKI")
    return der[-32:]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    artifact = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "logits.txt")
    att_path = sys.argv[2] if len(sys.argv) > 2 else artifact + ".attestation.json"
    pub_path = (
        sys.argv[3]
        if len(sys.argv) > 3
        else os.path.expanduser("~/.ledatic/witness/fleet0.pub.pem")
    )

    # ---- (1) re-derive the digest from the RAW artifact bytes ----
    with open(artifact, "rb") as fh:
        raw = fh.read()
    have_digest = hashlib.sha256(raw).hexdigest()

    # ---- read the attestation (assertions; not trusted until checked) ----
    with open(att_path) as fh:
        att = json.load(fh)
    witness = att["witness"]
    claimed_digest = witness["digest_sha256"]
    pulse_id = witness["pulse_id"]
    value_hex = witness["value_hex"]
    witnessed_at = witness["witnessed_at"]
    sig_b64 = witness["sig"]
    pk_fp = witness.get("pk_fp", "?")

    print(f"artifact       : {artifact}  ({len(raw)} bytes)")
    print(f"recomputed sha : {have_digest}")
    print(f"claimed sha    : {claimed_digest}")

    # The artifact's own size/sha in the outer object is ALSO just a claim;
    # cross-check it against the recompute so a lie anywhere is caught.
    outer_sha = att.get("artifact", {}).get("sha256")
    if have_digest != claimed_digest:
        print("PATHB ATTEST D3 FAIL: recomputed sha256 != witness.digest_sha256")
        sys.exit(2)
    if outer_sha is not None and outer_sha != have_digest:
        print("PATHB ATTEST D3 FAIL: outer artifact.sha256 != recomputed sha256")
        sys.exit(2)

    # ---- (2) rebuild the canonical message + Ed25519-verify ----
    msg = f"attest|v1|{have_digest}|{pulse_id}|{value_hex}|{witnessed_at}".encode()
    pub = load_ed25519_pub_from_pem(pub_path)
    sig = base64.b64decode(sig_b64)

    print(f"pubkey         : {pub_path}  pk_fp(att)={pk_fp}")
    print(f"canonical msg  : {msg.decode()}")

    ok_pure = ed25519_verify_pure(pub, msg, sig)
    print(f"ed25519 (pure-python) verify : {'OK' if ok_pure else 'BAD'}")

    # Optional independent cross-check via `cryptography`, if available. This
    # does NOT decide pass/fail (the pure-python verifier does) -- it is a
    # second foreign witness on top of the first.
    cross = "skipped (cryptography not importable)"
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import (
            Ed25519PublicKey,
        )
        from cryptography.exceptions import InvalidSignature

        key = Ed25519PublicKey.from_public_bytes(pub)
        try:
            key.verify(sig, msg)
            cross = "OK"
        except InvalidSignature:
            cross = "BAD"
    except Exception as e:  # ImportError or anything else: leave as skipped/note
        cross = f"skipped ({type(e).__name__})"
    print(f"ed25519 (cryptography) verify: {cross}")

    if not ok_pure:
        print("PATHB ATTEST D3 FAIL: Ed25519 signature does not verify")
        sys.exit(3)
    if cross == "BAD":
        print("PATHB ATTEST D3 FAIL: cross-check (cryptography) disagrees")
        sys.exit(4)

    print(
        "PATHB ATTEST D3 PASS: artifact sha256 re-derived bit-for-bit AND "
        "witness Ed25519 signature verifies over the canonical message "
        "(no Rail-side claim trusted)."
    )
    sys.exit(0)


if __name__ == "__main__":
    main()
