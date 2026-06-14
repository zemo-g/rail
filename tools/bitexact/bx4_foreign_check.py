#!/usr/bin/env python3
# BX4 D3 foreign witness.
#
# Re-implements the BX4 fixed-point transcendentals (sqrt/rsqrt are checked by
# bx3/their own path; here: exp / tanh / gelu) in pure Python big-integers and
# checks that EVERY integer output reproduces the Rail oracle's dump bit-for-bit.
#
# The whole point of BX4: a transcendental computed with a FIXED INTEGER algorithm
# is exact and associative, so an independent re-implementation on a different
# language/runtime yields BIT-IDENTICAL output. Python ints are arbitrary precision,
# so the only thing that can diverge is the DIVIDE rounding -- Rail uses ARM `sdiv`
# (truncate toward zero), which Python's `//` (floor) does NOT match for negatives.
# `td()` below is the truncating divide that makes them agree.
#
# Usage: python3 bx4_foreign_check.py /tmp/bx4_dump.txt
# Dump line format (from bx4_dump): "Xq fxexp(Xq) tanh(Xq) gelu(Xq)"

import sys

S = 16777216               # 2^24 fixed-point scale
S2 = 281474976710656       # 2^48
LN2_q = 11629080           # round(ln2 * S)


def td(a, b):
    # truncate toward zero (ARM sdiv), unlike Python // which floors
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def exp_poly(fq):
    p = 416
    p = 3329 + td(p * fq, S)
    p = 23302 + td(p * fq, S)
    p = 139810 + td(p * fq, S)
    p = 699051 + td(p * fq, S)
    p = 2796203 + td(p * fq, S)
    p = 8388608 + td(p * fq, S)
    p = 16777216 + td(p * fq, S)
    p = 16777216 + td(p * fq, S)
    return p


def pow2(k):
    if k < 1:
        return 1
    acc = 1
    for _ in range(k):
        acc = acc + acc
    return acc


def exp_neg(ax):
    k = td(ax, LN2_q)
    fq = ax - k * LN2_q
    ef = exp_poly(fq)
    emf = td(S2, ef)
    if k >= 50:
        return 0
    p2 = pow2(k)
    return td(emf + td(p2, 2), p2)


def exp_pos(xq):
    k = td(xq, LN2_q)
    fq = xq - k * LN2_q
    ef = exp_poly(fq)
    if k >= 36:
        return ef * pow2(35)
    return ef * pow2(k)


def fxexp(xq):
    if xq < 0:
        return exp_neg(0 - xq)
    return exp_pos(xq)


def tanh_pos(axq):
    em = fxexp(0 - (axq + axq))
    return td((S - em) * S, S + em)


def tanh(xq):
    if xq < 0:
        return 0 - tanh_pos(0 - xq)
    return tanh_pos(xq)


def gelu(xq):
    x2 = td(xq * xq, S)
    x3 = td(x2 * xq, S)
    ax3 = td(750194 * x3, S)
    inner0 = xq + ax3
    inner = td(13386610 * inner0, S)
    th = tanh(inner)
    onep = S + th
    return td(xq * onep, 2 * S)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/bx4_dump.txt"
    n = 0
    bad = 0
    with open(path) as fh:
        for line in fh:
            parts = line.split()
            if len(parts) < 4:
                continue
            xq, r_exp, r_tanh, r_gelu = (int(p) for p in parts[:4])
            n += 1
            for name, mine, theirs in (
                ("exp", fxexp(xq), r_exp),
                ("tanh", tanh(xq), r_tanh),
                ("gelu", gelu(xq), r_gelu),
            ):
                if mine != theirs:
                    bad += 1
                    if bad <= 10:
                        print(f"MISMATCH {name} xq={xq}: python={mine} rail={theirs}")
    if bad == 0:
        print(f"BX4 D3 PASS: {n} points x 3 fns reproduced bit-for-bit (foreign Python == Rail)")
        sys.exit(0)
    print(f"BX4 D3 FAIL: {bad} integer mismatches across {n} points")
    sys.exit(1)


if __name__ == "__main__":
    main()
