#!/usr/bin/env python3
# ============================================================================
# RUNG 31 - Foreign (cross-language) verifier for the Freivalds-succinct GEMM.
#
# Re-derives the ENTIRE succinct check independently of Rail, from the
# transcript the Rail trainer emits (rungs/r31/r31_transcript.txt: rows A,
# vector v, and the GPU pre-truncation accumulators S). It:
#   (1) re-derives the Fiat-Shamir challenge r by hashing (A, v, S) the SAME way
#       (SHA-256 over the canonical decimal encoding) - so r is a function of the
#       committed data; the prover could not have chosen A,v after seeing r;
#   (2) recomputes r^T S and (r^T A).v in EXACT Python bignum (no int63 ceiling)
#       and confirms equality - the Freivalds linear identity on the EXACT
#       pre-truncation accumulators;
#   (3) range-checks every truncation remainder ( |S - trunc(S)*2^24| < 2^24,
#       exact reconstruction ) AND every GPU lo limb in [0, 2^31);
#   (4) reproduces all five falsifier rejections.
#
# A green run here is an INDEPENDENT confirmation: the Rail succinct verifier
# accepts exactly the GEMMs a from-scratch Python re-derivation accepts, and
# rejects exactly the tampers. This mirrors lm10_foreign_check.py / the foreign
# cross-language verifier pattern in the proven pipeline.
#
# Usage: python3 rungs/r31/r31_foreign_check.py rungs/r31/r31_transcript.txt
# Exit 0 + last line PASS iff every check holds.
# ============================================================================
import sys, hashlib

S_SCALE = 16777216        # 2^24, the Q.24 fixed-point scale
BASE    = 2147483648      # 2^31, the GPU two-limb base (lo in [0, BASE))

def sha_hex(s): return hashlib.sha256(s.encode()).hexdigest()

# ---- canonical encodings (MUST byte-match the Rail r31_canon_* helpers) ----
def canon_ints(xs):  return "".join(f"{x}," for x in xs)
def canon_rows(rows): return "".join(canon_ints(r) + ";" for r in rows)
def transcript(rows, v, S):
    return sha_hex("R31|" + canon_rows(rows) + "#" + canon_ints(v) + "#" + canon_ints(S))

# ---- Fiat-Shamir challenge (MUST match r31_be16 / r31_fs_coeffs_from) ----
# Read a big-endian 16-bit value from the digest BYTES at byte offset off,
# mirroring Rail's hex_to_bytes(dg) + arr_get pairing.
def be16(B, off): return B[off] * 256 + B[off + 1]
def fs_coeffs(digest, m):
    out = []
    for i in range(m):
        blk = i // 16
        off = (i - blk * 16) * 2
        dg = digest if blk == 0 else sha_hex(digest + "|fs|" + str(blk))
        B = bytes.fromhex(dg)
        out.append(be16(B, off) + 1)                    # r_i in [1, 2^16]
    return out

# ---- Rail's truncate-TOWARD-ZERO divide ----
def rtrunc(s):
    q = abs(s) // S_SCALE
    return q if s >= 0 else -q
def rem(s): return s - rtrunc(s) * S_SCALE

def range_all(S):
    for s in S:
        rm = rem(s)
        if not (-S_SCALE < rm < S_SCALE): return 0
        if rtrunc(s) * S_SCALE + rm != s: return 0      # exact reconstruction
    return 1

def limb_range_all(lo_list):
    return 1 if all(0 <= lo < BASE for lo in lo_list) else 0

# ---- the succinct verifier (joint AND of three checks) ----
def verify(rows, v, S, lo_list=None):
    m = len(rows); k = len(v)
    digest = transcript(rows, v, S)
    rs = fs_coeffs(digest, m)
    lhs = sum(rs[i] * S[i] for i in range(m))                       # r^T S
    w   = [sum(rs[i] * rows[i][j] for i in range(m)) for j in range(k)]  # r^T A
    rhs = sum(w[j] * v[j] for j in range(k))                        # (r^T A).v
    freivalds_ok = 1 if lhs == rhs else 0
    range_ok = range_all(S)
    limb_ok = limb_range_all(lo_list) if lo_list is not None else 1
    return freivalds_ok * range_ok * limb_ok

def parse(path):
    rows = None; v = None; S = None; m = None; k = None
    for line in open(path):
        line = line.rstrip("\n")
        if line.startswith("m "): m = int(line[2:])
        elif line.startswith("k "): k = int(line[2:])
        elif line.startswith("v "):
            v = [int(x) for x in line[2:].split(",") if x != ""]
        elif line.startswith("A "):
            body = line[2:]
            rows = [[int(x) for x in r.split(",") if x != ""] for r in body.split(";") if r != ""]
        elif line.startswith("S "):
            S = [int(x) for x in line[2:].split(",") if x != ""]
    return rows, v, S, m, k

def main():
    if len(sys.argv) < 2:
        print("usage: r31_foreign_check.py <transcript>"); print("FAIL"); sys.exit(1)
    rows, v, S, m, k = parse(sys.argv[1])
    ok = True
    def gate(name, cond):
        nonlocal ok
        print(f"  {name}: {'PASS' if cond else 'FAIL'}")
        ok = ok and cond

    print(f"RUNG 31 foreign verifier  (m={m} rows x k={k}, Q.24, signed)")
    # shape sanity
    gate("shape m matches", len(rows) == m and len(S) == m)
    gate("shape k matches", len(v) == k and all(len(r) == k for r in rows))

    # CROSS-CHECK: re-derive S from (A, v) ourselves (the gx5a bridge invariant,
    # but in a foreign language) - the committed S must equal A.v exactly.
    S_redrv = [sum(rows[i][j] * v[j] for j in range(k)) for i in range(m)]
    gate("committed S == foreign A.v (exact)", S_redrv == S)

    # split S into honest GPU limbs (hi, lo) with lo in [0, 2^31) so we can drive
    # the limb-range falsifier (mirrors the Rail Hi/Lo arrays).
    lo_list = [s % BASE for s in S]   # Python floor-mod -> lo in [0, BASE)

    # GATE 1: honest GEMM passes
    gate("GATE 1 honest GEMM verifies", verify(rows, v, S, lo_list) == 1)
    # non-vacuity: signed case exercised
    neg = sum(1 for s in S if s < 0)
    gate(f"signed case exercised (neg={neg})", neg > 0)
    # non-vacuity: single-limb int63 would WRAP (two-limb load-bearing)
    digest = transcript(rows, v, S); rs = fs_coeffs(digest, m)
    lhs = sum(rs[i] * S[i] for i in range(m))
    gate(f"r^T S magnitude exceeds int63 (2^{abs(lhs).bit_length()} > 2^62)", abs(lhs).bit_length() > 62)

    # FALS(a): tamper one accumulator by +2^31
    Sa = S[:]; Sa[3] += BASE
    gate("FALS(a) S[3]+=2^31 rejected", verify(rows, v, Sa, [s % BASE for s in Sa]) == 0)
    # FALS(b): tamper by exactly +2^24 (range alone would MISS)
    Sb = S[:]; Sb[7] += S_SCALE
    rb_alone = 1 if (-S_SCALE < rem(Sb[7]) < S_SCALE) else 0
    gate("FALS(b) S[7]+=2^24 rejected", verify(rows, v, Sb, [s % BASE for s in Sb]) == 0)
    gate("FALS(b) range-check ALONE would MISS +2^24 (composition non-vacuous)", rb_alone == 1)
    # FALS(c): wrong weight row (A honest-claimed perturbed, S from honest A)
    Ac = [r[:] for r in rows]; Ac[5][0] += 100000
    gate("FALS(c) wrong weight row rejected", verify(Ac, v, S, lo_list) == 0)
    # FALS(d): sub-2^24 tamper
    Sd = S[:]; Sd[2] += 12345
    gate("FALS(d) sub-2^24 tamper rejected", verify(rows, v, Sd, [s % BASE for s in Sd]) == 0)
    # FALS(e): Freivalds-BLIND limb forge: lo+=2^31 (hi-=1) keeps reconstructed S
    #          identical but pushes lo out of [0,2^31); limb-range must catch.
    lo_e = lo_list[:]; lo_e[9] += BASE     # S unchanged (reconstruction same), lo out of range
    gate("FALS(e) Freivalds-blind limb forge rejected by limb-range",
         verify(rows, v, S, lo_e) == 0)

    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
