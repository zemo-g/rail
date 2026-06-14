#!/usr/bin/env python3
# BX7 D3 foreign witness: a pure-Python big-integer re-implementation of the BX7 exact-integer
# Adam optimizer. Two checks:
#   (1) reproduce every theta/m/v integer after T steps bit-for-bit (the determinism thesis);
#   (2) confirm the fixed-point Adam tracks a REAL float Adam (correctness) -- so replacing
#       libm pow/sqrt with fixed algorithms did not change WHAT Adam computes, only made it exact.
#
# Reuses BX4's exact td; fxsqrt = math.isqrt(xq*S) (exact floor sqrt == Rail's digit-by-digit).
# Usage: python3 bx7_foreign_check.py /tmp/bx7_dump.txt

import sys
import math
from bx4_foreign_check import td

S = 16777216


def fxsqrt(xq):
    return math.isqrt(xq * S)


def powfx(base, t):
    acc = S
    for _ in range(t):
        acc = td(acc * base, S)
    return acc


# ---- deterministic generator (same formula as Rail) ----
def imod(a, b):
    return a - td(a, b) * b


def cell(kind, i, j):
    return (imod(kind * 101 + i * 5 + j * 3 + 7, 13) - 6) * 1398101


# ---- fixed-point Adam (mirrors bx7_step1 bit-for-bit) ----
def step1(st, g, b1, b2, lr, eps, t):
    th, m, v = st
    m2 = td(b1 * m, S) + td((S - b1) * g, S)
    g2 = td(g * g, S)
    v2 = td(b2 * v, S) + td((S - b2) * g2, S)
    bc1 = S - powfx(b1, t)
    bc2 = S - powfx(b2, t)
    mhat = td(m2 * S, bc1)
    vhat = td(v2 * S, bc2)
    denom = fxsqrt(vhat) + eps
    step = td(lr * mhat, denom)
    return [th - step, m2, v2]


def run_elem(th0, i, b1, b2, lr, eps, maxt):
    st = [th0, 0, 0]
    for t in range(1, maxt + 1):
        st = step1(st, cell(t, i, 0), b1, b2, lr, eps, t)
    return st


# ---- float Adam reference (same hyperparams, dequantized) ----
def run_elem_float(th0q, i, b1, b2, lr, eps, maxt):
    th, m, v = th0q / S, 0.0, 0.0
    rb1, rb2, rlr, reps = b1 / S, b2 / S, lr / S, eps / S
    for t in range(1, maxt + 1):
        g = cell(t, i, 0) / S
        m = rb1 * m + (1.0 - rb1) * g
        v = rb2 * v + (1.0 - rb2) * g * g
        mh = m / (1.0 - rb1 ** t)
        vh = v / (1.0 - rb2 ** t)
        th = th - rlr * mh / (math.sqrt(vh) + reps)
    return th


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/bx7_dump.txt"
    d, maxt = 4, 8
    b1, b2, lr, eps = 15099494, 16760439, 167772, 16777
    theta = [cell(8, 0, j) for j in range(d)]
    states = [run_elem(theta[i], i, b1, b2, lr, eps, maxt) for i in range(d)]
    th = [s[0] for s in states]
    mm = [s[1] for s in states]
    vv = [s[2] for s in states]
    py = [th, mm, vv]

    rail = []
    with open(path) as fh:
        for line in fh:
            parts = line.split()
            if parts:
                rail.append([int(p) for p in parts])

    bad = 0
    n = 0
    for r, (prow, rrow) in enumerate(zip(py, rail)):
        for c in range(len(prow)):
            n += 1
            if prow[c] != rrow[c]:
                bad += 1
                if bad <= 10:
                    print(f"MISMATCH row {r} col {c}: python={prow[c]} rail={rrow[c]}")

    # correctness vs float Adam
    worst = 0.0
    for i in range(d):
        thf = run_elem_float(theta[i], i, b1, b2, lr, eps, maxt)
        diff = abs(th[i] / S - thf)
        if diff > worst:
            worst = diff
    print(f"BX7 fixed-vs-float theta max abs diff: {worst:.3e}  "
          f"({'PASS' if worst < 0.01 else 'FAIL'})")

    if bad == 0:
        print(f"BX7 D3 PASS: Adam trajectory reproduced bit-for-bit "
              f"({n} integers: theta+m+v after {maxt} steps, foreign Python == Rail)")
        sys.exit(0 if worst < 0.01 else 1)
    print(f"BX7 D3 FAIL: {bad}/{n} integer mismatches")
    sys.exit(1)


if __name__ == "__main__":
    main()
