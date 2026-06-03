#!/usr/bin/env python3
# BX5 D3 foreign witness: a pure-Python big-integer re-implementation of the BX5 forward
# block. If it reproduces every output integer of the Rail oracle bit-for-bit, the whole
# forward pass (RMSNorm + attention + MLP + residuals, every reduction exact-integer, every
# transcendental a fixed algorithm) is foreign-reproducible -- the BX thesis at block level.
#
# Reuses BX4's exact fixed-point transcendentals (same file, same bits).
# Usage: python3 bx5_foreign_check.py /tmp/bx5_dump.txt

import sys
import math
from bx4_foreign_check import td, fxexp, gelu

S = 16777216
S2 = 281474976710656


def fxsqrt(xq):
    # floor(sqrt(xq/S)*S); math.isqrt is exact floor-sqrt -- matches the Rail digit-by-digit isqrt
    return math.isqrt(xq * S)


def fxrsqrt(xq):
    q = fxsqrt(xq)
    return 0 if q == 0 else td(S2, q)


# ---- deterministic fixed-point generator ----
def imod(a, b):
    return a - td(a, b) * b


def cell(kind, i, j):
    return (imod(kind * 101 + i * 5 + j * 3 + 7, 13) - 6) * 1398101


def genrow(kind, i, cols):
    return [cell(kind, i, j) for j in range(cols)]


def genmat(kind, rows, cols):
    return [genrow(kind, i, cols) for i in range(rows)]


def gammavec(kind, d):
    return [S + td(cell(kind, 0, j), 4) for j in range(d)]


# ---- exact integer vector ops (one truncation per dot) ----
def dot(u, v):
    return td(sum(a * b for a, b in zip(u, v)), S)


def vadd(u, v):
    return [a + b for a, b in zip(u, v)]


def scalevec(s, row):
    return [td(a * s, S) for a in row]


def matvec(rows, v):
    return [dot(r, v) for r in rows]


def proj(w, x):
    return [matvec(w, row) for row in x]


def addrows(a, b):
    return [vadd(ra, rb) for ra, rb in zip(a, b)]


# ---- RMSNorm ----
def sumsq(xs):
    return sum(td(a * a, S) for a in xs)


def normvec(row, d, gamma):
    meansq = td(sumsq(row), d)
    rms = fxsqrt(meansq + 1000)
    return [td(td(a * S, rms) * g, S) for a, g in zip(row, gamma)]


def normrows(x, d, gamma):
    return [normvec(r, d, gamma) for r in x]


# ---- softmax (stable) ----
def softmax(xs):
    m = max(xs)
    e = [fxexp(a - m) for a in xs]
    z = sum(e)
    return [td(a * S, z) for a in e]


# ---- single-head attention ----
def scores(q, k, invd):
    return [td(dot(q, krow) * invd, S) for krow in k]


def wsum(p, vmat, d):
    acc = [0] * d
    for pi, vrow in zip(p, vmat):
        acc = vadd(acc, scalevec(pi, vrow))
    return acc


def attn_all(qmat, kmat, vmat, d, invd):
    return [wsum(softmax(scores(q, kmat, invd)), vmat, d) for q in qmat]


# ---- MLP ----
def gelurows(a):
    return [[gelu(x) for x in row] for row in a]


# ---- full block ----
def block(x, d, hidden):
    wq, wk, wv, wo = genmat(0, d, d), genmat(1, d, d), genmat(2, d, d), genmat(3, d, d)
    w1, w2 = genmat(4, hidden, d), genmat(5, d, hidden)
    g1, g2 = gammavec(6, d), gammavec(7, d)
    invd = fxrsqrt(d * S)
    xn = normrows(x, d, g1)
    q, k, v = proj(wq, xn), proj(wk, xn), proj(wv, xn)
    a = attn_all(q, k, v, d, invd)
    h = addrows(x, proj(wo, a))
    hn = normrows(h, d, g2)
    m2 = proj(w2, gelurows(proj(w1, hn)))
    return addrows(h, m2)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/bx5_dump.txt"
    d, hidden, seq = 4, 8, 3
    y = block(genmat(8, seq, d), d, hidden)
    rail = []
    with open(path) as fh:
        for line in fh:
            parts = line.split()
            if parts:
                rail.append([int(p) for p in parts])
    bad = 0
    n = 0
    for t in range(seq):
        for j in range(d):
            n += 1
            if y[t][j] != rail[t][j]:
                bad += 1
                if bad <= 10:
                    print(f"MISMATCH pos {t} col {j}: python={y[t][j]} rail={rail[t][j]}")
    if bad == 0:
        print(f"BX5 D3 PASS: forward block reproduced bit-for-bit "
              f"({n} output integers, foreign Python == Rail)")
        sys.exit(0)
    print(f"BX5 D3 FAIL: {bad}/{n} integer mismatches")
    sys.exit(1)


if __name__ == "__main__":
    main()
