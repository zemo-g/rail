#!/usr/bin/env python3
# LM9 (rung 20): the FOREIGN RE-VERIFIER that closes the loop for the char-LM whose transformer
# block is now MULTI-HEAD: (pre-norm RMSNorm -> H-head RoPE causal self-attention -> residual)
# THEN (pre-norm RMSNorm -> position-wise FFN -> residual), feeding the MLP head.
#
# lm9_attested_train.rail produced an Ed25519-signed, hash-chained ledger of a bit-exact
# char-level next-token Rail LM training run. Given only the ledger header (pubkey, genesis,
# epoch count, corpus hash, dims, vocab size, context window, Adam constants, isd) plus the
# public seed/genesis STRINGS and the pinned corpus file, this INDEPENDENT party reconstructs
# the ENTIRE run from scratch in pure-Python big-integers and proves -- bit-for-bit -- that
# every signed CHECKPOINT reproduces. The verifier re-runs EVERY step (full epochs).
#
# What changed from LM8 (and ONLY this changed): the single attention head becomes H=LM9_NH heads,
# packed as consecutive (dh x d) ROW-BLOCKS of the SAME d x d Wq/Wk/Wv (dh = d/H). Each head runs
# the EXISTING attention_rope/attn_bwd_rope VERBATIM on its dh-row block:
#   forward : O[i] = concat_h attention_rope(Wq[h*dh:(h+1)*dh], ...)[i]   (heads side-by-side -> d)
#   backward: split the d-wide dOut into H dh-col-slices; per head attn_bwd_rope on its slice;
#             VERTICAL-stack the per-head dWq/dWk/dWv blocks (head 0 on top) -> d x d grads;
#             SUM the H per-head dX (all heads read the same xn1) -> one d-wide dX.
# RoPE rotates pairs 0..dh/2-1 INSIDE each head. Because multi-head is a re-SLICING of Wq/Wk/Wv
# (not new weights), the commitment w_hex = SHA256(W1;;W2;;E;;Wq;;Wk;;Wv;;gamma;;gamma2;;Wff1;;Wff2),
# the ledger format, RMSNorm/FFN/MLP/cross-entropy/Adam/clip, the chain and the RFC-8032 signatures
# are ALL BYTE-IDENTICAL to LM8 and imported/reused UNCHANGED. First cut: d=8, H=2, dh=4.
#
# The multi-head forward/backward (mh_attn_fwd / mh_attn_bwd) mirrors the Rail mh_attn_* EXACTLY
# (same head order, same concat and vertical-stack/sum conventions), so the re-derivation matches
# the signed chain bit-for-bit. The per-head attention_rope/attn_bwd_rope are imported UNCHANGED.
#
# Falsification (proves the verifier is not vacuously passing):
#   * corrupt one recorded checkpoint field -> the independent re-derivation MISMATCHES
#   * flip one byte of a signature           -> RFC 8032 verify REJECTS it
#
# Usage: python3 tools/bitexact/lm9_foreign_check.py [/tmp/lm9_chain.txt]

import sys
import os
import hashlib

from bx4_foreign_check import td, fxexp
from bx6_foreign_check import matvec, geluv, outer, matvec_t, dz1_apply
from bx7_foreign_check import step1, fxsqrt
from bx12_foreign_check import (
    ed25519_verify, ed25519_secret_to_public,
    sha256_hex, sha256_bytes,
    cell0, initcells, thetas, canon_mat,
)

S = 16777216
LM9_NH = 2          # rung-20 heads; dh = d // LM9_NH (d=8 -> dh=4). Mirrors Rail lm9_nh.
LN2 = 11629080
CAP = S * 64  # 1073741824 == 2^30; mirrors lm4_clipg (cap=16777216*64) in the Rail
RMS_EPS = 16777     # ~0.001 in Q.24; mirrors rn_rms's hardcoded epsilon (NOT the Adam eps)
S2 = S * S          # 281474976710656 == 2^48; mirrors rn_bwd_row's invrms numerator

# RoPE cos/sin tables (idx = pos*4 + pair; pos 0..7, pair 0..3). VERBATIM from the lm7/lm8 Rail.
COS = [16777216, 16777216, 16777216, 16777216, 9064768, 16693400, 16776377, 16777208,
       -6981785, 16442789, 16773861, 16777182, -16609318, 16027887, 16769667, 16777141,
       -10966320, 15452839, 16763796, 16777082, 4759062, 14723392, 16756249, 16777006,
       16108984, 13846834, 16747026, 16776914, 12648381, 12831923, 16736129, 16776805]
SIN = [0, 0, 0, 0, 14117540, 1674927, 167769, 16777, 15255479, 3333118, 335522, 33554,
       2367601, 4958006, 503241, 50332, -12697039, 6533356, 670910, 67109,
       -16088080, 8043426, 838511, 83886, -4687814, 9473129, 1006029, 100663,
       11022406, 10808179, 1173446, 117440]


def clipg(g):
    if g > CAP:
        return CAP
    if g < -CAP:
        return -CAP
    return g


def repo_root():
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


# ===================== fixed-point natural log (validated vs golden LN table) =====================
def _ln_up(m, k, s):
    while m < s:
        m += m; k -= 1
    return k


def _ln_upm(m, s):
    while m < s:
        m += m
    return m


def _ln_dn(m, k, s2):
    while m >= s2:
        m = td(m, 2); k += 1
    return k


def _ln_dnm(m, s2):
    while m >= s2:
        m = td(m, 2)
    return m


def _ln_mant(m):
    num = (m - S) * S
    den = m + S
    t = td(num, den)
    t2 = td(t * t, S)
    a0 = t
    tp3 = td(t * t2, S);     a1 = a0 + td(tp3, 3)
    tp5 = td(tp3 * t2, S);   a2 = a1 + td(tp5, 5)
    tp7 = td(tp5 * t2, S);   a3 = a2 + td(tp7, 7)
    tp9 = td(tp7 * t2, S);   a4 = a3 + td(tp9, 9)
    tp11 = td(tp9 * t2, S);  a5 = a4 + td(tp11, 11)
    tp13 = td(tp11 * t2, S); a6 = a5 + td(tp13, 13)
    return a6 + a6


def fxln(x):
    if x < 1:
        return 0
    s, s2 = S, S + S
    k0 = _ln_up(x, 0, s)
    m0 = _ln_upm(x, s)
    k1 = _ln_dn(m0, k0, s2)
    m1 = _ln_dnm(m0, s2)
    return k1 * LN2 + _ln_mant(m1)


# ===================== softmax / cross-entropy / ce-grad (mirror sm_list.rail) =====================
def l_softmax(xs):
    m = max(xs)
    es = [fxexp(x - m) for x in xs]
    z = sum(es)
    return [td(e * S, z) for e in es]


def l_celoss(xs, tgt):
    m = max(xs)
    es = [fxexp(x - m) for x in xs]
    z = sum(es)
    return m + fxln(z) - xs[tgt]


def l_cegrad(xs, tgt):
    sm = l_softmax(xs)
    return [sm[i] - (S if i == tgt else 0) for i in range(len(sm))]


# ===================== RMSNorm (pre-norm; shared trainable gamma) =====================
def rms_of(x):
    d = len(x)
    mss = 0
    for xi in x:
        mss += td(xi * xi, S)
    ms = td(mss, d)
    return fxsqrt(ms + RMS_EPS)


def xhat_of(x, rms):
    return [td(xi * S, rms) for xi in x]


def rmsnorm_fwd_row(x, gamma):
    rms = rms_of(x)
    xhat = xhat_of(x, rms)
    return [td(xh * g, S) for xh, g in zip(xhat, gamma)]


def rmsnorm_fwd_rows(rows, gamma):
    return [rmsnorm_fwd_row(r, gamma) for r in rows]


def rmsnorm_bwd_row(x, gamma, dy):
    d = len(x)
    rms = rms_of(x)
    xhat = xhat_of(x, rms)
    invrms = td(S2, rms)
    dgamma = [td(dyi * xh, S) for dyi, xh in zip(dy, xhat)]
    bigG = 0
    for g, xh, dyi in zip(gamma, xhat, dy):
        bigG += td(td(g * xh, S) * dyi, S)
    gdr = td(td(bigG, d) * S, rms)
    dx = []
    for g, xh, dyi in zip(gamma, xhat, dy):
        term1 = td(td(g * invrms, S) * dyi, S)
        term2 = td(xh * gdr, S)
        dx.append(term1 - term2)
    return dx, dgamma


def vadd(a, b):
    return [x + y for x, y in zip(a, b)]


def residual(att, rows):
    return [vadd(a, r) for a, r in zip(att, rows)]


def rmsnorm_bwd_rows(rows, gamma, dXn, dH):
    d = len(rows[0])
    dgamma_acc = [0] * d
    dRows = []
    for r, dxn_i, dh_i in zip(rows, dXn, dH):
        dx_i, dg_i = rmsnorm_bwd_row(r, gamma, dxn_i)
        dRows.append(vadd(dx_i, dh_i))   # residual: dRows_i = dRn_i + dH_i
        dgamma_acc = vadd(dgamma_acc, dg_i)
    return dRows, dgamma_acc


# ===================== single-head RoPE self-attention (causal): forward + backward =====================
# rung-20: mirror Rail rope_row's l_nth (out-of-range -> 0). Per-head dh<8 vectors read
# indices >= dh as 0 and the row is always emitted 8-wide (trailing pairs rotate zeros -> 0).
# For single-head d=8 every index is in range, so behavior is byte-identical to lm8.
def _gi(x, k):
    return x[k] if k < len(x) else 0
def rope_fx(x, p):
    y = [0] * 8
    for i in range(4):
        C, Sn = COS[p * 4 + i], SIN[p * 4 + i]
        x0, x1 = _gi(x, 2 * i), _gi(x, 2 * i + 1)
        y[2 * i] = td(x0 * C, S) - td(x1 * Sn, S)
        y[2 * i + 1] = td(x0 * Sn, S) + td(x1 * C, S)
    return y


def rope_bwd_fx(dd, p):
    g = [0] * 8
    for i in range(4):
        C, Sn = COS[p * 4 + i], SIN[p * 4 + i]
        d0, d1 = _gi(dd, 2 * i), _gi(dd, 2 * i + 1)
        g[2 * i] = td(d0 * C, S) + td(d1 * Sn, S)
        g[2 * i + 1] = (0 - td(d0 * Sn, S)) + td(d1 * C, S)
    return g


def _adot(a, b):
    acc = 0
    for x, y in zip(a, b):
        acc += x * y
    return td(acc, S)


def _amatvec(W, x):
    return [_adot(row, x) for row in W]


def attention_rope(Wq, Wk, Wv, xs, isd):
    T = len(xs)
    Q = [_amatvec(Wq, x) for x in xs]
    K = [_amatvec(Wk, x) for x in xs]
    V = [_amatvec(Wv, x) for x in xs]
    Qr = [rope_fx(Q[i], i) for i in range(T)]
    Kr = [rope_fx(K[j], j) for j in range(T)]
    outs = []
    for i in range(T):
        sc = [td(_adot(Qr[i], Kr[j]) * isd, S) for j in range(i + 1)]
        probs = l_softmax(sc) + [0] * (T - (i + 1))  # causal: zero-padded to length T
        dk = len(V[0])
        o = [0] * dk
        for j in range(T):
            for c in range(dk):
                o[c] += td(probs[j] * V[j][c], S)
        outs.append(o)
    return outs


def attn_bwd_rope(Wq, Wk, Wv, xs, isd, dOut):
    T = len(xs)
    d = len(xs[0])
    Q = [_amatvec(Wq, x) for x in xs]
    K = [_amatvec(Wk, x) for x in xs]
    V = [_amatvec(Wv, x) for x in xs]
    Qr = [rope_fx(Q[i], i) for i in range(T)]
    Kr = [rope_fx(K[j], j) for j in range(T)]
    dk_dim = len(V[0])

    P = []
    for i in range(T):
        sc = [td(_adot(Qr[i], Kr[j]) * isd, S) for j in range(i + 1)]
        P.append(l_softmax(sc) + [0] * (T - (i + 1)))

    dV = [[0] * dk_dim for _ in range(T)]
    for j in range(T):
        for c in range(dk_dim):
            acc = 0
            for i in range(T):
                acc += td(P[i][j] * dOut[i][c], S)
            dV[j][c] = acc

    dP = [[0] * T for _ in range(T)]
    for i in range(T):
        for j in range(T):
            acc = 0
            for c in range(dk_dim):
                acc += td(dOut[i][c] * V[j][c], S)
            dP[i][j] = acc

    dQr = [[0] * len(Q[0]) for _ in range(T)]
    dKr = [[0] * len(K[0]) for _ in range(T)]
    for i in range(T):
        rowdot = 0
        for l in range(T):
            rowdot += td(P[i][l] * dP[i][l], S)
        ddot = [0] * T
        for j in range(T):
            dscore = td(P[i][j] * (dP[i][j] - rowdot), S)
            ddot[j] = td(dscore * isd, S)
        for c in range(len(Q[0])):
            acc = 0
            for j in range(T):
                acc += td(ddot[j] * Kr[j][c], S)
            dQr[i][c] = acc
        for j in range(T):
            for c in range(len(K[0])):
                dKr[j][c] += td(ddot[j] * Qr[i][c], S)

    dQ = [rope_bwd_fx(dQr[i], i) for i in range(T)]
    dKg = [rope_bwd_fx(dKr[j], j) for j in range(T)]

    def outer_acc(dU, dimA):
        M = [[0] * d for _ in range(dimA)]
        for i in range(T):
            for a in range(dimA):
                for b in range(d):
                    M[a][b] += td(dU[i][a] * xs[i][b], S)
        return M
    dWq = outer_acc(dQ, len(Q[0]))
    dWk = outer_acc(dKg, len(K[0]))
    dWv = outer_acc(dV, dk_dim)

    dX = [[0] * d for _ in range(T)]
    for i in range(T):
        for c in range(d):
            acc = 0
            for a in range(len(Q[0])):
                acc += td(dQ[i][a] * Wq[a][c], S)
            for a in range(len(K[0])):
                acc += td(dKg[i][a] * Wk[a][c], S)
            for a in range(dk_dim):
                acc += td(dV[i][a] * Wv[a][c], S)
            dX[i][c] = acc

    return [dWq, dWk, dWv, dX]


# ===================== rung-20 MULTI-HEAD wrappers (mirror lm9 Rail mh_attn_*) =====================
# H heads packed as (dh x d) row-blocks of the d x d Wq/Wk/Wv. Each head runs the EXISTING
# attention_rope/attn_bwd_rope verbatim on its dh-row block; forward concats per-head outputs along
# dh, backward vertical-stacks the per-head dW blocks (head 0 on top) and SUMS the per-head dX.
def mh_attn_fwd(Wq, Wk, Wv, xs, isd):
    d = len(xs[0]); dh = d // LM9_NH
    outs = None
    for h in range(LM9_NH):
        Wqh = Wq[h*dh:(h+1)*dh]; Wkh = Wk[h*dh:(h+1)*dh]; Wvh = Wv[h*dh:(h+1)*dh]
        Oh = attention_rope(Wqh, Wkh, Wvh, xs, isd)            # T rows x dh
        outs = [list(r) for r in Oh] if outs is None else [outs[i] + Oh[i] for i in range(len(Oh))]
    return outs


def mh_attn_bwd(Wq, Wk, Wv, xs, isd, dOut):
    T = len(xs); d = len(xs[0]); dh = d // LM9_NH
    dWq = []; dWk = []; dWv = []
    dX = [[0]*d for _ in range(T)]
    for h in range(LM9_NH):
        Wqh = Wq[h*dh:(h+1)*dh]; Wkh = Wk[h*dh:(h+1)*dh]; Wvh = Wv[h*dh:(h+1)*dh]
        dOh = [row[h*dh:(h+1)*dh] for row in dOut]             # T rows x dh col-slice
        abh = attn_bwd_rope(Wqh, Wkh, Wvh, xs, isd, dOh)
        dWq = dWq + abh[0]; dWk = dWk + abh[1]; dWv = dWv + abh[2]   # head 0 on top
        for i in range(T):
            for c in range(d):
                dX[i][c] += abh[3][i][c]                       # all heads read same xn1 -> sum
    return [dWq, dWk, dWv, dX]


# ===================== position-wise FFN: forward + backward =====================
# ffn_row x = Wff2 . gelu(Wff1 . x); applied per (already pre-normed) row. Mirrors lm8_ffn_* Rail.
def ffn_row(wff1, wff2, row):
    return matvec(wff2, geluv(matvec(wff1, row)))


def ffn_rows(wff1, wff2, rows):
    return [ffn_row(wff1, wff2, r) for r in rows]


def ffn_bwd(wff1, wff2, xns, dBs, ffh, d):
    # folded over rows; dWff1 (ffh x d) and dWff2 (d x ffh) accumulate, dXn2 collected per row.
    dWff1 = [[0] * d for _ in range(ffh)]
    dWff2 = [[0] * ffh for _ in range(d)]
    dXn2_list = []
    for xn2, dB in zip(xns, dBs):
        zf = matvec(wff1, xn2)          # length ffh
        hf = geluv(zf)
        dWff2_r = outer(dB, hf)         # d x ffh
        dhf = matvec_t(wff2, dB, ffh)   # length ffh
        dzf = dz1_apply(zf, dhf)
        dWff1_r = outer(dzf, xn2)       # ffh x d
        dXn2 = matvec_t(wff1, dzf, d)   # length d
        for a in range(ffh):
            row = dWff1[a]; rr = dWff1_r[a]
            for b in range(d):
                row[b] += rr[b]
        for a in range(d):
            row = dWff2[a]; rr = dWff2_r[a]
            for b in range(ffh):
                row[b] += rr[b]
        dXn2_list.append(dXn2)
    return dWff1, dWff2, dXn2_list


# ===================== LM8 data layer (deterministic; mirrors the Rail) =====================
def build_vocab(corpus):
    v = ""
    for ch in corpus:
        if ch not in v:
            v += ch
    return v


def tokens(corpus, vocab):
    return [vocab.index(ch) for ch in corpus]


def make_pairs(ids, c):
    return [(ids[i:i + c], ids[i + c]) for i in range(len(ids) - c)]


def emb_initcells(vsize, d):
    return [[[cell0(cid + 1, 0, j, 0), 0, 0] for j in range(d)] for cid in range(vsize)]


def qkv_initcells(kind, d):
    return initcells(kind, d, d, 0)


def gamma_initcells(d):
    # shared gamma as a 1 x d block of Adam cells; theta initialized to all-ones (== S in Q.24)
    return [[[S, 0, 0] for _ in range(d)]]


def wff_initcells(kind, nrows, ncols):
    return initcells(kind, nrows, ncols, 0)


def ctx_rows(emb, ctx):
    return [emb[cid] for cid in ctx]


def flatten(rows):
    out = []
    for r in rows:
        out.extend(r)
    return out


def reshape(xs, d):
    return [xs[k:k + d] for k in range(0, len(xs), d)]


# ============ rung-20: N=2 STACKED transformer blocks (each = 2x pre-norm + sublayer + residual) ============
# block bundle blk = [wq, wk, wv, gamma, gamma2, wff1, wff2] (gamma/gamma2 are length-d rows). Mirrors
# Rail lm4_block_fwd / lm4_block_bwd. block_bwd returns the 7 block grads PLUS dRows (grad w.r.t. its
# INPUT rows) as the 8th entry; block1's dRows IS block0's upstream dOut. Forward folds block0 -> block1
# -> readout; backward reverse-chains readout -> block1 -> block0 (each block recomputes its own forward).
def block_fwd(blk, rows, isd):
    wq, wk, wv, gamma, gamma2, wff1, wff2 = blk
    xn1 = rmsnorm_fwd_rows(rows, gamma)
    att = mh_attn_fwd(wq, wk, wv, xn1, isd)
    a = residual(att, rows)
    xn2 = rmsnorm_fwd_rows(a, gamma2)
    ff = ffn_rows(wff1, wff2, xn2)
    return residual(ff, a)


def block_bwd(blk, rows, isd, dOut, d):
    wq, wk, wv, gamma, gamma2, wff1, wff2 = blk
    xn1 = rmsnorm_fwd_rows(rows, gamma)
    att = mh_attn_fwd(wq, wk, wv, xn1, isd)
    a = residual(att, rows)
    xn2 = rmsnorm_fwd_rows(a, gamma2)
    dB = dOut                        # FFN-residual: grad flows to BOTH the FFN path and the a-skip
    ffh = len(wff1)
    dWff1, dWff2, dXn2 = ffn_bwd(wff1, wff2, xn2, dB, ffh, d)
    dA, dgamma2 = rmsnorm_bwd_rows(a, gamma2, dXn2, dB)
    ab = mh_attn_bwd(wq, wk, wv, xn1, isd, dA)
    dWq, dWk, dWv = ab[0], ab[1], ab[2]
    dXn1 = ab[3]
    # attn-residual: dA is the skip term -> dRows = rms-contribution + dA (grad w.r.t. this block's input)
    dRows, dgamma1 = rmsnorm_bwd_rows(rows, gamma, dXn1, dA)
    return [dWq, dWk, dWv, dgamma1, dgamma2, dWff1, dWff2, dRows]


def forward(w1, w2, blk0, blk1, rows, isd):
    b0 = block_fwd(blk0, rows, isd)
    b1 = block_fwd(blk1, b0, isd)
    x = flatten(b1)
    return matvec(w2, geluv(matvec(w1, x)))


def grads_n2(w1, w2, blk0, blk1, rows, isd, tgt, hidden, indim, d):
    b0 = block_fwd(blk0, rows, isd)
    b1 = block_fwd(blk1, b0, isd)
    x = flatten(b1)
    z1 = matvec(w1, x)
    h1 = geluv(z1)
    z2 = matvec(w2, h1)
    dz2 = l_cegrad(z2, tgt)
    dW2 = outer(dz2, h1)
    dh1 = matvec_t(w2, dz2, hidden)
    dz1 = dz1_apply(z1, dh1)
    dW1 = outer(dz1, x)
    dx = matvec_t(w1, dz1, indim)
    dB1 = reshape(dx, d)
    g1 = block_bwd(blk1, b0, isd, dB1, d)        # block1 input = b0
    dRows1 = g1[7]
    g0 = block_bwd(blk0, rows, isd, dRows1, d)   # block0 input = embedding rows
    dxe = flatten(g0[7])
    # order mirrors Rail lm4_grads: dW1, dW2, dxe, block0[7], block1[7]
    return [dW1, dW2, dxe,
            g0[0], g0[1], g0[2], g0[3], g0[4], g0[5], g0[6],
            g1[0], g1[1], g1[2], g1[3], g1[4], g1[5], g1[6]]


def scatter(vsize, ctx, dxe, d):
    dE = [[0] * d for _ in range(vsize)]
    for k, cid in enumerate(ctx):
        chunk = dxe[k * d:(k + 1) * d]
        dE[cid] = [a + b for a, b in zip(dE[cid], chunk)]
    return dE


def mkblk(wqc, wkc, wvc, gammac, gamma2c, wff1c, wff2c):
    # materialize a block bundle from its 7 Adam-cell configs (gamma/gamma2 -> length-d row via [0])
    return [thetas(wqc), thetas(wkc), thetas(wvc),
            thetas(gammac)[0], thetas(gamma2c)[0], thetas(wff1c), thetas(wff2c)]


def dsloss(pairs, w1, w2, emb, blk0, blk1, isd):
    return sum(l_celoss(forward(w1, w2, blk0, blk1, ctx_rows(emb, ctx), isd), tgt)
               for ctx, tgt in pairs)


# ===== LM9 N=2 trajectory re-derivation (trains W1,W2,E + block0[7] + block1[7] = 17 matrices) =====
# block0 seeds: qkv 30/31/32, wff 33/34. block1 seeds: qkv 35/36/37, wff 38/39. All 4 gammas = all-ones.
def rederive(d, hidden, epochs, vsize, cwin, lr, eps, b1, b2, isd, genesis_hex, pairs):
    indim = cwin * d
    ff = d * 4
    w1c = initcells(0, hidden, indim, 0)
    w2c = initcells(1, vsize, hidden, 0)
    ec = emb_initcells(vsize, d)
    # block0
    b0wqc = qkv_initcells(30, d); b0wkc = qkv_initcells(31, d); b0wvc = qkv_initcells(32, d)
    b0gammac = gamma_initcells(d); b0gamma2c = gamma_initcells(d)
    b0wff1c = wff_initcells(33, ff, d); b0wff2c = wff_initcells(34, d, ff)
    # block1
    b1wqc = qkv_initcells(35, d); b1wkc = qkv_initcells(36, d); b1wvc = qkv_initcells(37, d)
    b1gammac = gamma_initcells(d); b1gamma2c = gamma_initcells(d)
    b1wff1c = wff_initcells(38, ff, d); b1wff2c = wff_initcells(39, d, ff)
    recs = []
    prev = genesis_hex
    gstep = 0
    for e in range(epochs):
        for ctx, tgt in pairs:
            gstep += 1

            def upd(cells, grad):
                return [[step1(c, clipg(grad[ri][ci]), b1, b2, lr, eps, gstep)
                         for ci, c in enumerate(row)] for ri, row in enumerate(cells)]

            def updg(cells, gvec):   # 1-row gamma cell-set; grad is a length-d vector
                return [[step1(c, clipg(gvec[ci]), b1, b2, lr, eps, gstep)
                         for ci, c in enumerate(row)] for ri, row in enumerate(cells)]

            emb = thetas(ec)
            rows = ctx_rows(emb, ctx)
            w1, w2 = thetas(w1c), thetas(w2c)
            blk0 = mkblk(b0wqc, b0wkc, b0wvc, b0gammac, b0gamma2c, b0wff1c, b0wff2c)
            blk1 = mkblk(b1wqc, b1wkc, b1wvc, b1gammac, b1gamma2c, b1wff1c, b1wff2c)
            g = grads_n2(w1, w2, blk0, blk1, rows, isd, tgt, hidden, indim, d)
            dE = scatter(vsize, ctx, g[2], d)
            w1c = upd(w1c, g[0]); w2c = upd(w2c, g[1]); ec = upd(ec, dE)
            b0wqc = upd(b0wqc, g[3]); b0wkc = upd(b0wkc, g[4]); b0wvc = upd(b0wvc, g[5])
            b0gammac = updg(b0gammac, g[6]); b0gamma2c = updg(b0gamma2c, g[7])
            b0wff1c = upd(b0wff1c, g[8]); b0wff2c = upd(b0wff2c, g[9])
            b1wqc = upd(b1wqc, g[10]); b1wkc = upd(b1wkc, g[11]); b1wvc = upd(b1wvc, g[12])
            b1gammac = updg(b1gammac, g[13]); b1gamma2c = updg(b1gamma2c, g[14])
            b1wff1c = upd(b1wff1c, g[15]); b1wff2c = upd(b1wff2c, g[16])
        # signed checkpoint at the POST-epoch weights
        emb = thetas(ec)
        w1, w2 = thetas(w1c), thetas(w2c)
        blk0 = mkblk(b0wqc, b0wkc, b0wvc, b0gammac, b0gamma2c, b0wff1c, b0wff2c)
        blk1 = mkblk(b1wqc, b1wkc, b1wvc, b1gammac, b1gamma2c, b1wff1c, b1wff2c)
        loss = dsloss(pairs, w1, w2, emb, blk0, blk1, isd)
        # w_hex binds 17 matrices in Rail lm4_canon17 order: W1;;W2;;E ;; block0[7] ;; block1[7]
        w_hex = sha256_hex(canon_mat(w1) + ";;" + canon_mat(w2) + ";;" + canon_mat(emb) + ";;"
                           + canon_mat(thetas(b0wqc)) + ";;" + canon_mat(thetas(b0wkc)) + ";;"
                           + canon_mat(thetas(b0wvc)) + ";;" + canon_mat(thetas(b0gammac)) + ";;"
                           + canon_mat(thetas(b0gamma2c)) + ";;" + canon_mat(thetas(b0wff1c)) + ";;"
                           + canon_mat(thetas(b0wff2c)) + ";;"
                           + canon_mat(thetas(b1wqc)) + ";;" + canon_mat(thetas(b1wkc)) + ";;"
                           + canon_mat(thetas(b1wvc)) + ";;" + canon_mat(thetas(b1gammac)) + ";;"
                           + canon_mat(thetas(b1gamma2c)) + ";;" + canon_mat(thetas(b1wff1c)) + ";;"
                           + canon_mat(thetas(b1wff2c)))
        link_str = f"{prev}|{e}|{w_hex}|{loss}"
        link_b = sha256_bytes(link_str)
        link_hex = link_b.hex()
        recs.append((e, w_hex, loss, prev, link_hex, link_b))
        prev = link_hex
    fblk0c = (b0wqc, b0wkc, b0wvc, b0gammac, b0gamma2c, b0wff1c, b0wff2c)
    fblk1c = (b1wqc, b1wkc, b1wvc, b1gammac, b1gamma2c, b1wff1c, b1wff2c)
    return recs, prev, w1c, w2c, ec, fblk0c, fblk1c


def main():
    ledger = sys.argv[1] if len(sys.argv) > 1 else "/tmp/lm9_chain.txt"
    SEED_STR = "lm9.local.ephemeral.dev.seed.v1"
    GENESIS_STR = "LM9.LOCAL.BEACON.GENESIS.dev"

    with open(ledger) as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    if not lines or not lines[0].startswith("# LM9v1"):
        print("LM9-CHECK FAIL: missing/malformed ledger header")
        sys.exit(1)
    hdr = lines[0].split()
    pubkey_hex, genesis_hex, epochs, corpus_sha = hdr[2], hdr[3], int(hdr[4]), hdr[5]
    kv = dict(tok.split("=") for tok in hdr[6:] if "=" in tok)
    d, hidden, vsize, cwin = int(kv["d"]), int(kv["hidden"]), int(kv["vsize"]), int(kv["cwin"])
    B1, B2, LR, EPS = int(kv["beta1"]), int(kv["beta2"]), int(kv["lr"]), int(kv["eps"])
    ISD = int(kv["isd"])
    records = [ln.split() for ln in lines[1:]]
    ff = d * 4

    ok = True

    with open(os.path.join(repo_root(), "tools/bitexact/lm9_corpus.txt"), "rb") as fh:
        raw = fh.read()
    py_corpus_sha = hashlib.sha256(raw).hexdigest()
    corpus = raw.decode("latin-1")
    if py_corpus_sha != corpus_sha:
        print(f"MISMATCH corpus sha256: python={py_corpus_sha} ledger={corpus_sha}")
        ok = False

    py_genesis = sha256_hex(GENESIS_STR)
    if py_genesis != genesis_hex:
        print(f"MISMATCH genesis: python={py_genesis} ledger={genesis_hex}")
        ok = False

    seed = hashlib.sha256(SEED_STR.encode()).digest()
    py_pub = ed25519_secret_to_public(seed)
    if py_pub.hex() != pubkey_hex:
        print(f"MISMATCH pubkey: python={py_pub.hex()} ledger={pubkey_hex}")
        ok = False
    pub = bytes.fromhex(pubkey_hex)

    vocab = build_vocab(corpus)
    if len(vocab) != vsize:
        print(f"MISMATCH vocab size: python={len(vocab)} ledger={vsize}")
        ok = False
    ids = tokens(corpus, vocab)
    pairs = make_pairs(ids, cwin)

    recs, head, fw1c, fw2c, fec, fblk0c, fblk1c = rederive(
        d, hidden, epochs, vsize, cwin, LR, EPS, B1, B2, ISD, genesis_hex, pairs)

    if len(recs) != len(records):
        print(f"MISMATCH record count: python={len(recs)} ledger={len(records)}")
        ok = False

    sigs_ok = 0
    field_mism = 0
    for (pe, pw, ploss, pprev, plink, plink_b), row in zip(recs, records):
        r_ep, r_w, r_loss, r_prev, r_link, r_sig = (
            int(row[0]), row[1], int(row[2]), row[3], row[4], row[5])
        if (pe, pw, ploss, pprev, plink) != (r_ep, r_w, r_loss, r_prev, r_link):
            field_mism += 1
            if field_mism <= 5:
                print(f"MISMATCH checkpoint {pe}: re-derived vs ledger differ "
                      f"(w {pw==r_w} loss {ploss==r_loss} link {plink==r_link})")
        if ed25519_verify(pub, plink_b, bytes.fromhex(r_sig)):
            sigs_ok += 1
    if field_mism:
        ok = False
    if sigs_ok != len(records):
        print(f"MISMATCH signatures: {sigs_ok}/{len(records)} verify")
        ok = False

    ledger_head = records[-1][4] if records else ""
    if head != ledger_head:
        print(f"MISMATCH chain head: python={head} ledger={ledger_head}")
        ok = False
    emb0 = thetas(emb_initcells(vsize, d))
    blk0_0 = mkblk(qkv_initcells(30, d), qkv_initcells(31, d), qkv_initcells(32, d),
                   gamma_initcells(d), gamma_initcells(d),
                   wff_initcells(33, ff, d), wff_initcells(34, d, ff))
    blk1_0 = mkblk(qkv_initcells(35, d), qkv_initcells(36, d), qkv_initcells(37, d),
                   gamma_initcells(d), gamma_initcells(d),
                   wff_initcells(38, ff, d), wff_initcells(39, d, ff))
    ds0 = dsloss(pairs,
                 thetas(initcells(0, hidden, cwin * d, 0)),
                 thetas(initcells(1, vsize, hidden, 0)),
                 emb0, blk0_0, blk1_0, ISD)
    dsK = dsloss(pairs, thetas(fw1c), thetas(fw2c), thetas(fec),
                 mkblk(*fblk0c), mkblk(*fblk1c), ISD)
    descent = dsK < ds0

    tampered_w = ("0" if records[0][1][0] != "0" else "1") + records[0][1][1:]
    tamper_detected = (tampered_w != recs[0][1])
    badsig = bytearray.fromhex(records[0][5])
    badsig[5] ^= 1
    sig_reject = not ed25519_verify(pub, recs[0][5], bytes(badsig))

    print(f"LM9-CHECK corpus pin: SHA-256 reproduced = {py_corpus_sha == corpus_sha}")
    print(f"LM9-CHECK data layer: vocab={len(vocab)} (match {len(vocab)==vsize}) tokens={len(ids)} "
          f"pairs={len(pairs)} indim={cwin*d} ff={ff} isd={ISD} nheads={LM9_NH} nblocks=2 "
          f"(2 STACKED pre-norm transformer blocks: each RMSNorm+{LM9_NH}-head-RoPE-causal-attn"
          f"+residual, then RMSNorm+FFN+residual; cross-entropy)")
    print(f"LM9-CHECK genesis reproduced = {py_genesis == genesis_hex}; "
          f"pubkey re-derived from seed = {py_pub.hex() == pubkey_hex}")
    print(f"LM9-CHECK trajectory: {len(recs)} checkpoints re-derived from data+config+seed "
          f"(every step re-run, {epochs} epochs); field mismatches = {field_mism}")
    print(f"LM9-CHECK signatures: {sigs_ok}/{len(records)} verify under pubkey (RFC 8032)")
    print(f"LM9-CHECK chain head match = {head == ledger_head}; "
          f"datasetLoss0={ds0} datasetLossK={dsK} descent={descent}")
    print(f"LM9-CHECK falsification: corrupt-checkpoint-detected={tamper_detected} "
          f"flipped-sig-rejected={sig_reject}")

    allok = ok and descent and tamper_detected and sig_reject
    if allok:
        print(f"LM9-CHECK PASS: independent foreign re-verifier reproduced every signed checkpoint "
              f"bit-for-bit from data+config+seed ({len(records)} records) for a char-LM that is "
              f"{LM9_NH}-head attention over 2 STACKED pre-norm transformer blocks (each "
              f"RMSNorm+RoPE-causal-attention+residual then RMSNorm+position-wise-FFN+residual; "
              f"independent weights per block) -- w_hex binds 17 matrices "
              f"W1;;W2;;E ;; block0[Wq;;Wk;;Wv;;gamma;;gamma2;;Wff1;;Wff2] ;; block1[same 7]; "
              f"a forged checkpoint or signature is rejected.")
        sys.exit(0)
    print("LM9-CHECK FAIL")
    sys.exit(1)


if __name__ == "__main__":
    main()
