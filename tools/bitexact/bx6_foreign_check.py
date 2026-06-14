#!/usr/bin/env python3
# BX6 D3 foreign witness: a pure-Python big-integer re-implementation of the BX6 exact-integer
# BACKWARD pass. If it reproduces every gradient integer of the Rail oracle bit-for-bit, the whole
# reverse pass (dW = outer(grad,x), dx = W^T.grad, dz = gelu'(z).*upstream -- every reduction
# exact-integer, the gelu' derivative a fixed algorithm) is foreign-reproducible.
#
# Reuses BX4's exact fixed-point td/tanh/gelu (same file, same bits).
# Usage: python3 bx6_foreign_check.py /tmp/bx6_dump.txt

import sys
from bx4_foreign_check import td, tanh, gelu

S = 16777216


# ---- gelu'(x): fixed-point derivative, mirrors bx4_gelu_grad bit-for-bit ----
def gelu_grad(xq):
    x2 = td(xq * xq, S)
    x3 = td(x2 * xq, S)
    ax3 = td(750194 * x3, S)
    inner0 = xq + ax3
    u = td(13386610 * inner0, S)
    t = tanh(u)
    term1 = td(S + t, 2)
    sech2 = S - td(t * t, S)
    a3x2 = td(3 * (750194 * x2), S)
    inner1 = S + a3x2
    dudx = td(13386610 * inner1, S)
    p1 = td(xq * sech2, S)
    p2 = td(p1 * dudx, S)
    term2 = td(p2, 2)
    return term1 + term2


# ---- deterministic fixed-point generator (same formula as Rail/BX5) ----
def imod(a, b):
    return a - td(a, b) * b


def cell(kind, i, j):
    return (imod(kind * 101 + i * 5 + j * 3 + 7, 13) - 6) * 1398101


def genrow(kind, i, cols):
    return [cell(kind, i, j) for j in range(cols)]


def genmat(kind, rows, cols):
    return [genrow(kind, i, cols) for i in range(rows)]


# ---- exact integer ops (one truncation per output element) ----
def dot(u, v):
    return td(sum(a * b for a, b in zip(u, v)), S)


def matvec(rows, v):
    return [dot(r, v) for r in rows]


def geluv(z):
    return [gelu(a) for a in z]


def outer(u, w):
    return [[td(ui * wj, S) for wj in w] for ui in u]


def matvec_t(rows, v, cols):
    acc = [0] * cols
    for vi, r in zip(v, rows):
        acc = [a + vi * rj for a, rj in zip(acc, r)]
    return [td(a, S) for a in acc]


def dz1_apply(z1, dh1):
    return [td(gelu_grad(zi) * di, S) for zi, di in zip(z1, dh1)]


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/bx6_dump.txt"
    d, hidden = 4, 8
    w1 = genmat(0, hidden, d)
    w2 = genmat(1, d, hidden)
    x = genrow(8, 0, d)
    # forward primals
    z1 = matvec(w1, x)
    h1 = geluv(z1)
    # reverse
    dz2 = [S] * d
    dW2 = outer(dz2, h1)
    dh1 = matvec_t(w2, dz2, hidden)
    dz1 = dz1_apply(z1, dh1)
    dW1 = outer(dz1, x)
    dx = matvec_t(w1, dz1, d)

    py = [dx] + dW1 + dW2

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
    if bad == 0:
        print(f"BX6 D3 PASS: backward reproduced bit-for-bit "
              f"({n} gradient integers: dx + dW1 + dW2, foreign Python == Rail)")
        sys.exit(0)
    print(f"BX6 D3 FAIL: {bad}/{n} integer mismatches")
    sys.exit(1)


if __name__ == "__main__":
    main()
