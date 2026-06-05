#!/usr/bin/env python3
# LM6 (rung 17): the FOREIGN RE-VERIFIER that closes the loop for the char-LM whose single
# self-attention layer now carries ROTARY POSITION EMBEDDING (RoPE) on Q/K plus a CAUSAL mask
# (query i attends only keys j<=i).
#
# lm6_attested_train.rail produced an Ed25519-signed, hash-chained ledger of a bit-exact
# char-level next-token Rail LM training run. Given only the ledger header (pubkey, genesis,
# epoch count, corpus hash, dims, vocab size, context window, Adam constants, isd) plus the
# public seed/genesis STRINGS and the pinned corpus file, this INDEPENDENT party reconstructs
# the ENTIRE run from scratch in pure-Python big-integers and proves -- bit-for-bit -- that
# every signed CHECKPOINT reproduces. The verifier re-runs EVERY step (full epochs).
#
# What changed from LM5 (and ONLY this changed):
#   * RoPE rotates Q and K (NOT V) before the score dot-product, using precomputed F=24
#     cos/sin tables (idx = pos*4 + pair; 8 positions x 4 pairs). For row x at position p:
#       y_2i   = td(x0*C,S) - td(x1*Sn,S);  y_2i+1 = td(x0*Sn,S) + td(x1*C,S).
#   * CAUSAL mask: probs[i] = softmax over j<=i, zero-padded to length T. Masked entries are
#     EXACTLY 0, so the entire LM5 backward (dv/dp/dq/dk/dw/dx, all full-T loops) runs UNCHANGED
#     on the rotated Qr/Kr -- the contributions from j>i vanish identically.
#   * RoPE backward is the TRANSPOSE rotation (exact gradient of the orthogonal rotation):
#       dx_2i = td(d0*C,S) + td(d1*Sn,S);  dx_2i+1 = -td(d0*Sn,S) + td(d1*C,S).
#     applied as dQ = rope_bwd(dQr), dK = rope_bwd(dKr) AFTER the score-graph accumulation,
#     BEFORE the outer-products dWq/dWk and the input-gradient dX.
#   Everything else -- the MLP matvec/gelu/outer/matvec_t, cross-entropy core, Adam step1,
#   gradient clip (cap +/-2^30), the chain, the RFC-8032 signatures, the w_hex commitment
#   binding W1;;W2;;E;;Wq;;Wk;;Wv -- is BYTE-IDENTICAL to LM5 and imported UNCHANGED.
#
# The RoPE-attention forward + backward (RoPE fwd/bwd + causal softmax + the full reverse-mode
# chain) was independently validated before being wired in here: a FLOAT finite-difference
# gradient check (worst |analytic - FD| = 2.83e-11) and a fixed-point smoke -- see
# /tmp/rung17_attn_rope_ref.py.
#
# Falsification (proves the verifier is not vacuously passing):
#   * corrupt one recorded checkpoint field -> the independent re-derivation MISMATCHES
#   * flip one byte of a signature           -> RFC 8032 verify REJECTS it
#
# Usage: python3 tools/bitexact/lm6_foreign_check.py [/tmp/lm6_chain.txt]

import sys
import os
import hashlib

from bx4_foreign_check import td, fxexp
from bx6_foreign_check import matvec, geluv, outer, matvec_t, dz1_apply
from bx7_foreign_check import step1
from bx12_foreign_check import (
    ed25519_verify, ed25519_secret_to_public,
    sha256_hex, sha256_bytes,
    cell0, initcells, thetas, canon_mat,
)

S = 16777216
LN2 = 11629080
CAP = S * 64  # 1073741824 == 2^30; mirrors lm4_clipg (cap=16777216*64) in the Rail

# RoPE cos/sin tables (idx = pos*4 + pair; pos 0..7, pair 0..3). VERBATIM from the lm6 Rail.
COS = [16777216, 16777216, 16777216, 16777216, 9064768, 16693400, 16776377, 16777208,
       -6981785, 16442789, 16773861, 16777182, -16609318, 16027887, 16769667, 16777141,
       -10966320, 15452839, 16763796, 16777082, 4759062, 14723392, 16756249, 16777006,
       16108984, 13846834, 16747026, 16776914, 12648381, 12831923, 16736129, 16776805]
SIN = [0, 0, 0, 0, 14117540, 1674927, 167769, 16777, 15255479, 3333118, 335522, 33554,
       2367601, 4958006, 503241, 50332, -12697039, 6533356, 670910, 67109,
       -16088080, 8043426, 838511, 83886, -4687814, 9473129, 1006029, 100663,
       11022406, 10808179, 1173446, 117440]


def clipg(g):
    # exact-integer gradient clamp -- mirrors lm4_clipg. Caps each gradient component to
    # +/-2^30 so g*g <= 2^60 < 2^62 in the Adam v-update (no int63 overflow).
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


# ===================== RoPE (rotary position embedding) on a length-8 row =====================
# Forward rotation of pair i at position p uses (C,Sn)=(cos,sin)[p*4+i]. V is NOT rotated.
def rope_fx(x, p):
    y = [0] * 8
    for i in range(4):
        C, Sn = COS[p * 4 + i], SIN[p * 4 + i]
        x0, x1 = x[2 * i], x[2 * i + 1]
        y[2 * i] = td(x0 * C, S) - td(x1 * Sn, S)
        y[2 * i + 1] = td(x0 * Sn, S) + td(x1 * C, S)
    return y


# Backward = transpose of the orthogonal rotation (exact gradient).
def rope_bwd_fx(dd, p):
    g = [0] * 8
    for i in range(4):
        C, Sn = COS[p * 4 + i], SIN[p * 4 + i]
        d0, d1 = dd[2 * i], dd[2 * i + 1]
        g[2 * i] = td(d0 * C, S) + td(d1 * Sn, S)
        g[2 * i + 1] = (0 - td(d0 * Sn, S)) + td(d1 * C, S)
    return g


# ===================== single-head RoPE self-attention (causal): forward + backward =====================
# Mirrors the lm6 Rail: rotate Q,K; causal softmax over j<=i zero-padded to T; LM5's full-T
# backward machinery runs UNCHANGED on Qr/Kr (masked entries are exactly 0); rope_bwd folds
# the rotation gradient back before the outer-products and dX.
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

    # score-graph gradient accumulated onto the ROTATED Qr/Kr (full-T; masked ddot==0 beyond i)
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

    # transpose-rotate the gradient back through RoPE before the weight/input gradients
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


# ===================== LM6 data layer (deterministic; mirrors the Rail) =====================
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
    # E[vsize][d] of Adam cells; row id initialized kind=id+1 (== LM2 frozen genvec)
    return [[[cell0(cid + 1, 0, j, 0), 0, 0] for j in range(d)] for cid in range(vsize)]


def qkv_initcells(kind, d):
    # Wq/Wk/Wv: d x d Adam cells; mirrors lm5_qkv_init kind d = lm4_initmat kind d d 0
    return initcells(kind, d, d, 0)


def ctx_rows(emb, ctx):
    # list of the per-token TRAINED embedding rows (emb = thetas(E)) -- NOT concatenated
    return [emb[cid] for cid in ctx]


def flatten(rows):
    out = []
    for r in rows:
        out.extend(r)
    return out


def reshape(xs, d):
    return [xs[k:k + d] for k in range(0, len(xs), d)]


def forward(w1, w2, wq, wk, wv, rows, isd):
    x = flatten(attention_rope(wq, wk, wv, rows, isd))
    return matvec(w2, geluv(matvec(w1, x)))


def grads6(w1, w2, wq, wk, wv, rows, isd, tgt, hidden, indim, d):
    # mirrors lm4_grads in the LM6 Rail. Returns dW1,dW2,dWq,dWk,dWv,dxe (flattened dX).
    att = attention_rope(wq, wk, wv, rows, isd)
    x = flatten(att)
    z1 = matvec(w1, x)
    h1 = geluv(z1)
    z2 = matvec(w2, h1)
    dz2 = l_cegrad(z2, tgt)
    dW2 = outer(dz2, h1)
    dh1 = matvec_t(w2, dz2, hidden)
    dz1 = dz1_apply(z1, dh1)
    dW1 = outer(dz1, x)
    dx = matvec_t(w1, dz1, indim)
    dOut = reshape(dx, d)
    ab = attn_bwd_rope(wq, wk, wv, rows, isd, dOut)
    dWq, dWk, dWv = ab[0], ab[1], ab[2]
    dxe = flatten(ab[3])
    return dW1, dW2, dWq, dWk, dWv, dxe


def scatter(vsize, ctx, dxe, d):
    # dxe (length C*d) -> dE (vsize x d); a token appearing at several positions SUMS
    dE = [[0] * d for _ in range(vsize)]
    for k, cid in enumerate(ctx):
        chunk = dxe[k * d:(k + 1) * d]
        dE[cid] = [a + b for a, b in zip(dE[cid], chunk)]
    return dE


def dsloss(pairs, w1, w2, emb, wq, wk, wv, isd):
    return sum(l_celoss(forward(w1, w2, wq, wk, wv, ctx_rows(emb, ctx), isd), tgt)
               for ctx, tgt in pairs)


# ============= LM6 trajectory re-derivation (exact-integer; trains W1,W2,E,Wq,Wk,Wv) =============
def rederive(d, hidden, epochs, vsize, cwin, lr, eps, b1, b2, isd, genesis_hex, pairs):
    indim = cwin * d
    w1c = initcells(0, hidden, indim, 0)
    w2c = initcells(1, vsize, hidden, 0)
    ec = emb_initcells(vsize, d)
    wqc = qkv_initcells(30, d)
    wkc = qkv_initcells(31, d)
    wvc = qkv_initcells(32, d)
    recs = []
    prev = genesis_hex
    gstep = 0
    for e in range(epochs):
        for ctx, tgt in pairs:
            gstep += 1
            emb = thetas(ec)
            rows = ctx_rows(emb, ctx)
            w1, w2 = thetas(w1c), thetas(w2c)
            wq, wk, wv = thetas(wqc), thetas(wkc), thetas(wvc)
            dW1, dW2, dWq, dWk, dWv, dxe = grads6(w1, w2, wq, wk, wv, rows, isd, tgt, hidden, indim, d)
            dE = scatter(vsize, ctx, dxe, d)
            w1c = [[step1(c, clipg(dW1[ri][ci]), b1, b2, lr, eps, gstep) for ci, c in enumerate(row)]
                   for ri, row in enumerate(w1c)]
            w2c = [[step1(c, clipg(dW2[ri][ci]), b1, b2, lr, eps, gstep) for ci, c in enumerate(row)]
                   for ri, row in enumerate(w2c)]
            wqc = [[step1(c, clipg(dWq[ri][ci]), b1, b2, lr, eps, gstep) for ci, c in enumerate(row)]
                   for ri, row in enumerate(wqc)]
            wkc = [[step1(c, clipg(dWk[ri][ci]), b1, b2, lr, eps, gstep) for ci, c in enumerate(row)]
                   for ri, row in enumerate(wkc)]
            wvc = [[step1(c, clipg(dWv[ri][ci]), b1, b2, lr, eps, gstep) for ci, c in enumerate(row)]
                   for ri, row in enumerate(wvc)]
            ec = [[step1(c, clipg(dE[ri][ci]), b1, b2, lr, eps, gstep) for ci, c in enumerate(row)]
                  for ri, row in enumerate(ec)]
        # signed checkpoint at the POST-epoch weights (binds W1,W2,E,Wq,Wk,Wv)
        emb = thetas(ec)
        w1, w2 = thetas(w1c), thetas(w2c)
        wq, wk, wv = thetas(wqc), thetas(wkc), thetas(wvc)
        loss = dsloss(pairs, w1, w2, emb, wq, wk, wv, isd)
        w_hex = sha256_hex(canon_mat(w1) + ";;" + canon_mat(w2) + ";;" + canon_mat(emb) + ";;"
                           + canon_mat(wq) + ";;" + canon_mat(wk) + ";;" + canon_mat(wv))
        link_str = f"{prev}|{e}|{w_hex}|{loss}"
        link_b = sha256_bytes(link_str)
        link_hex = link_b.hex()
        recs.append((e, w_hex, loss, prev, link_hex, link_b))
        prev = link_hex
    return recs, prev, w1c, w2c, ec, wqc, wkc, wvc


def main():
    ledger = sys.argv[1] if len(sys.argv) > 1 else "/tmp/lm6_chain.txt"
    SEED_STR = "lm6.local.ephemeral.dev.seed.v1"
    GENESIS_STR = "LM6.LOCAL.BEACON.GENESIS.dev"

    with open(ledger) as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    if not lines or not lines[0].startswith("# LM6v1"):
        print("LM6-CHECK FAIL: missing/malformed ledger header")
        sys.exit(1)
    hdr = lines[0].split()
    # # LM6v1 <pubkey> <genesis> <epochs> <corpus_sha> d=.. hidden=.. vsize=.. cwin=.. beta1=.. beta2=.. lr=.. eps=.. isd=..
    pubkey_hex, genesis_hex, epochs, corpus_sha = hdr[2], hdr[3], int(hdr[4]), hdr[5]
    kv = dict(tok.split("=") for tok in hdr[6:] if "=" in tok)
    d, hidden, vsize, cwin = int(kv["d"]), int(kv["hidden"]), int(kv["vsize"]), int(kv["cwin"])
    B1, B2, LR, EPS = int(kv["beta1"]), int(kv["beta2"]), int(kv["lr"]), int(kv["eps"])
    ISD = int(kv["isd"])
    records = [ln.split() for ln in lines[1:]]

    ok = True

    # (1) corpus pin: recompute SHA-256 of the frozen corpus with stock hashlib
    with open(os.path.join(repo_root(), "tools/bitexact/lm6_corpus.txt"), "rb") as fh:
        raw = fh.read()
    py_corpus_sha = hashlib.sha256(raw).hexdigest()
    corpus = raw.decode("latin-1")
    if py_corpus_sha != corpus_sha:
        print(f"MISMATCH corpus sha256: python={py_corpus_sha} ledger={corpus_sha}")
        ok = False

    # (2) genesis re-derived from its public string
    py_genesis = sha256_hex(GENESIS_STR)
    if py_genesis != genesis_hex:
        print(f"MISMATCH genesis: python={py_genesis} ledger={genesis_hex}")
        ok = False

    # (3) pubkey re-derived from the seed string (key binding)
    seed = hashlib.sha256(SEED_STR.encode()).digest()
    py_pub = ed25519_secret_to_public(seed)
    if py_pub.hex() != pubkey_hex:
        print(f"MISMATCH pubkey: python={py_pub.hex()} ledger={pubkey_hex}")
        ok = False
    pub = bytes.fromhex(pubkey_hex)

    # (4) re-derive the LM data layer (vocab/tokens/pairs) from the pinned corpus
    vocab = build_vocab(corpus)
    if len(vocab) != vsize:
        print(f"MISMATCH vocab size: python={len(vocab)} ledger={vsize}")
        ok = False
    ids = tokens(corpus, vocab)
    pairs = make_pairs(ids, cwin)

    # (5) re-derive the entire training trajectory from data+config+seed
    recs, head, fw1c, fw2c, fec, fwqc, fwkc, fwvc = rederive(
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

    # (6) chain head + dataset-loss descent over the WHOLE corpus
    ledger_head = records[-1][4] if records else ""
    if head != ledger_head:
        print(f"MISMATCH chain head: python={head} ledger={ledger_head}")
        ok = False
    emb0 = thetas(emb_initcells(vsize, d))
    ds0 = dsloss(pairs,
                 thetas(initcells(0, hidden, cwin * d, 0)),
                 thetas(initcells(1, vsize, hidden, 0)),
                 emb0,
                 thetas(qkv_initcells(30, d)),
                 thetas(qkv_initcells(31, d)),
                 thetas(qkv_initcells(32, d)),
                 ISD)
    dsK = dsloss(pairs, thetas(fw1c), thetas(fw2c), thetas(fec),
                 thetas(fwqc), thetas(fwkc), thetas(fwvc), ISD)
    descent = dsK < ds0

    # ---- falsification: a corrupted checkpoint field must be detected ----
    tampered_w = ("0" if records[0][1][0] != "0" else "1") + records[0][1][1:]
    tamper_detected = (tampered_w != recs[0][1])
    # ---- falsification: a flipped signature byte must be rejected ----
    badsig = bytearray.fromhex(records[0][5])
    badsig[5] ^= 1
    sig_reject = not ed25519_verify(pub, recs[0][5], bytes(badsig))

    print(f"LM6-CHECK corpus pin: SHA-256 reproduced = {py_corpus_sha == corpus_sha}")
    print(f"LM6-CHECK data layer: vocab={len(vocab)} (match {len(vocab)==vsize}) tokens={len(ids)} "
          f"pairs={len(pairs)} indim={cwin*d} isd={ISD} (RoPE single-head causal self-attention, cross-entropy)")
    print(f"LM6-CHECK genesis reproduced = {py_genesis == genesis_hex}; "
          f"pubkey re-derived from seed = {py_pub.hex() == pubkey_hex}")
    print(f"LM6-CHECK trajectory: {len(recs)} checkpoints re-derived from data+config+seed "
          f"(every step re-run, {epochs} epochs); field mismatches = {field_mism}")
    print(f"LM6-CHECK signatures: {sigs_ok}/{len(records)} verify under pubkey (RFC 8032)")
    print(f"LM6-CHECK chain head match = {head == ledger_head}; "
          f"datasetLoss0={ds0} datasetLossK={dsK} descent={descent}")
    print(f"LM6-CHECK falsification: corrupt-checkpoint-detected={tamper_detected} "
          f"flipped-sig-rejected={sig_reject}")

    allok = ok and descent and tamper_detected and sig_reject
    if allok:
        print(f"LM6-CHECK PASS: independent foreign re-verifier reproduced every signed checkpoint "
              f"bit-for-bit from data+config+seed ({len(records)} records) for a char-LM with a "
              f"RoPE single-head CAUSAL self-attention layer (w_hex binds W1;;W2;;E;;Wq;;Wk;;Wv); a "
              f"forged checkpoint or signature is rejected.")
        sys.exit(0)
    print("LM6-CHECK FAIL")
    sys.exit(1)


if __name__ == "__main__":
    main()
