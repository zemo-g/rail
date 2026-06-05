#!/usr/bin/env python3
# LM3 (rung 14): the FOREIGN RE-VERIFIER that closes the loop for the char-LM with
# TRAINED token embeddings.
#
# lm3_attested_train.rail produced an Ed25519-signed, hash-chained ledger of a bit-exact
# char-level next-token Rail LM training run. Unlike LM2 (frozen embeddings), LM3 trains the
# token-embedding table E[vsize][d] jointly with W1/W2. This is an INDEPENDENT party: given
# only the ledger header (pubkey, genesis, epoch count, corpus hash, dims, vocab size, context
# window, Adam constants) plus the public seed/genesis STRINGS and the pinned corpus file, it
# reconstructs the ENTIRE run from scratch in pure-Python big-integers and proves -- bit-for-
# bit -- that every signed CHECKPOINT reproduces. The verifier re-runs EVERY step (full epochs).
#
# What changed from LM2 (and ONLY this changed):
#   * E is trainable. Forward x = concat(E[ctx[k]]); backward dx = W1^T . dz1; the embedding
#     gradient is dE[ctx[k]] += dx[k*d:(k+1)*d] (repeats SUM, associative), then E is Adam-
#     updated every step with the SAME bias-corrected step as W1/W2. E is INITIALIZED to LM2's
#     frozen values (cell0 kind=id+1), so step 0 is identical; the chain diverges as E learns.
#   * w_hex now binds E: w_hex = SHA256(canon W1 ";;" canon W2 ";;" canon E).
# The truncating div / matvec / gelu / outer / matvec_t / dz1 / Adam / RFC-8032 Ed25519 atoms
# are IMPORTED UNCHANGED from the sibling BX witnesses; grads3 just additionally returns dx
# (W1^T . dz1), and the embedding init/scatter are local mirrors of the Rail.
#
# Falsification (proves the verifier is not vacuously passing):
#   * corrupt one recorded checkpoint field -> the independent re-derivation MISMATCHES
#   * flip one byte of a signature           -> RFC 8032 verify REJECTS it
#
# Usage: python3 tools/bitexact/lm3_foreign_check.py [/tmp/lm3_chain.txt]

import sys
import os
import hashlib

from bx6_foreign_check import matvec, geluv, outer, matvec_t, dz1_apply
from bx7_foreign_check import step1
from bx12_foreign_check import (
    ed25519_verify, ed25519_secret_to_public,
    sha256_hex, sha256_bytes,
    cell0, initcells, thetas, canon_mat, loss_fn,
)

S = 16777216
CAP = S * 64  # 1073741824 == 2^30; mirrors lm3_clipg (cap=16777216*64) in the Rail


def clipg(g):
    # exact-integer gradient clamp -- mirrors lm3_clipg. Caps each gradient component to
    # +/-2^30 so g*g <= 2^60 < 2^62 in the Adam v-update (no int63 overflow). The embedding
    # gradient dx=W1^T.dz1 is the only one that hits this bound; W1/W2 grads pass through.
    if g > CAP:
        return CAP
    if g < -CAP:
        return -CAP
    return g


def repo_root():
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


# ===================== LM3 data layer (deterministic; mirrors the Rail) =====================
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


def ctx_vec(emb, ctx):
    # CONCATENATION of the per-token TRAINED embedding rows (emb = thetas(E))
    out = []
    for cid in ctx:
        out.extend(emb[cid])
    return out


def onehot(tgt, v):
    return [S if i == tgt else 0 for i in range(v)]


def grads3(w1, w2, x, t, hidden, indim):
    # MLP backward + dx = W1^T . dz1 (grad wrt the concat input) -- mirrors lm3_grads
    z1 = matvec(w1, x)
    h1 = geluv(z1)
    z2 = matvec(w2, h1)
    dz2 = [a - b for a, b in zip(z2, t)]
    dW2 = outer(dz2, h1)
    dh1 = matvec_t(w2, dz2, hidden)
    dz1 = dz1_apply(z1, dh1)
    dW1 = outer(dz1, x)
    dx = matvec_t(w1, dz1, indim)
    return dW1, dW2, dx


def scatter(vsize, ctx, dx, d):
    # dx (length C*d) -> dE (vsize x d); a token appearing at several positions SUMS
    dE = [[0] * d for _ in range(vsize)]
    for k, cid in enumerate(ctx):
        chunk = dx[k * d:(k + 1) * d]
        dE[cid] = [a + b for a, b in zip(dE[cid], chunk)]
    return dE


def dsloss(pairs, w1, w2, emb, vsize):
    return sum(loss_fn(w1, w2, ctx_vec(emb, ctx), onehot(tgt, vsize)) for ctx, tgt in pairs)


# ============= LM3 trajectory re-derivation (exact-integer, trains W1, W2 AND E) =============
def rederive(d, hidden, epochs, vsize, cwin, lr, eps, b1, b2, genesis_hex, pairs):
    indim = cwin * d
    w1c = initcells(0, hidden, indim, 0)   # koff = 0 (matches the Rail)
    w2c = initcells(1, vsize, hidden, 0)
    ec = emb_initcells(vsize, d)
    recs = []
    prev = genesis_hex
    gstep = 0  # CONTINUOUS global step counter (1-indexed when handed to step1)
    for e in range(epochs):
        for ctx, tgt in pairs:
            gstep += 1
            emb = thetas(ec)
            x = ctx_vec(emb, ctx)
            t = onehot(tgt, vsize)
            w1, w2 = thetas(w1c), thetas(w2c)
            dW1, dW2, dx = grads3(w1, w2, x, t, hidden, indim)
            dE = scatter(vsize, ctx, dx, d)
            w1c = [[step1(c, clipg(dW1[ri][ci]), b1, b2, lr, eps, gstep) for ci, c in enumerate(row)]
                   for ri, row in enumerate(w1c)]
            w2c = [[step1(c, clipg(dW2[ri][ci]), b1, b2, lr, eps, gstep) for ci, c in enumerate(row)]
                   for ri, row in enumerate(w2c)]
            ec = [[step1(c, clipg(dE[ri][ci]), b1, b2, lr, eps, gstep) for ci, c in enumerate(row)]
                  for ri, row in enumerate(ec)]
        # signed checkpoint at the POST-epoch weights (binds W1, W2 AND E)
        emb = thetas(ec)
        w1, w2 = thetas(w1c), thetas(w2c)
        loss = dsloss(pairs, w1, w2, emb, vsize)
        w_hex = sha256_hex(canon_mat(w1) + ";;" + canon_mat(w2) + ";;" + canon_mat(emb))
        link_str = f"{prev}|{e}|{w_hex}|{loss}"
        link_b = sha256_bytes(link_str)
        link_hex = link_b.hex()
        recs.append((e, w_hex, loss, prev, link_hex, link_b))
        prev = link_hex
    return recs, prev, w1c, w2c, ec


def main():
    ledger = sys.argv[1] if len(sys.argv) > 1 else "/tmp/lm3_chain.txt"
    SEED_STR = "lm3.local.ephemeral.dev.seed.v1"
    GENESIS_STR = "LM3.LOCAL.BEACON.GENESIS.dev"

    with open(ledger) as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    if not lines or not lines[0].startswith("# LM3v1"):
        print("LM3-CHECK FAIL: missing/malformed ledger header")
        sys.exit(1)
    hdr = lines[0].split()
    # # LM3v1 <pubkey> <genesis> <epochs> <corpus_sha> d=.. hidden=.. vsize=.. cwin=.. beta1=.. beta2=.. lr=.. eps=..
    pubkey_hex, genesis_hex, epochs, corpus_sha = hdr[2], hdr[3], int(hdr[4]), hdr[5]
    kv = dict(tok.split("=") for tok in hdr[6:] if "=" in tok)
    d, hidden, vsize, cwin = int(kv["d"]), int(kv["hidden"]), int(kv["vsize"]), int(kv["cwin"])
    B1, B2, LR, EPS = int(kv["beta1"]), int(kv["beta2"]), int(kv["lr"]), int(kv["eps"])
    records = [ln.split() for ln in lines[1:]]

    ok = True

    # (1) corpus pin: recompute SHA-256 of the frozen corpus with stock hashlib
    with open(os.path.join(repo_root(), "tools/bitexact/lm3_corpus.txt"), "rb") as fh:
        raw = fh.read()
    py_corpus_sha = hashlib.sha256(raw).hexdigest()
    corpus = raw.decode("latin-1")  # 1:1 byte->char (corpus is ASCII)
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
    recs, head, fw1c, fw2c, fec = rederive(d, hidden, epochs, vsize, cwin, LR, EPS, B1, B2, genesis_hex, pairs)

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
        # verify the recorded signature over the re-derived 32-byte link
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
    ds0 = dsloss(pairs, thetas(initcells(0, hidden, cwin * d, 0)), thetas(initcells(1, vsize, hidden, 0)), emb0, vsize)
    dsK = dsloss(pairs, thetas(fw1c), thetas(fw2c), thetas(fec), vsize)
    descent = dsK < ds0

    # ---- falsification: a corrupted checkpoint field must be detected ----
    tampered_w = ("0" if records[0][1][0] != "0" else "1") + records[0][1][1:]
    tamper_detected = (tampered_w != recs[0][1])
    # ---- falsification: a flipped signature byte must be rejected ----
    badsig = bytearray.fromhex(records[0][5])
    badsig[5] ^= 1
    sig_reject = not ed25519_verify(pub, recs[0][5], bytes(badsig))

    print(f"LM3-CHECK corpus pin: SHA-256 reproduced = {py_corpus_sha == corpus_sha}")
    print(f"LM3-CHECK data layer: vocab={len(vocab)} (match {len(vocab)==vsize}) tokens={len(ids)} "
          f"pairs={len(pairs)} indim={cwin*d} (TRAINED embeddings)")
    print(f"LM3-CHECK genesis reproduced = {py_genesis == genesis_hex}; "
          f"pubkey re-derived from seed = {py_pub.hex() == pubkey_hex}")
    print(f"LM3-CHECK trajectory: {len(recs)} checkpoints re-derived from data+config+seed "
          f"(every step re-run, {epochs} epochs); field mismatches = {field_mism}")
    print(f"LM3-CHECK signatures: {sigs_ok}/{len(records)} verify under pubkey (RFC 8032)")
    print(f"LM3-CHECK chain head match = {head == ledger_head}; "
          f"datasetLoss0={ds0} datasetLossK={dsK} descent={descent}")
    print(f"LM3-CHECK falsification: corrupt-checkpoint-detected={tamper_detected} "
          f"flipped-sig-rejected={sig_reject}")

    allok = ok and descent and tamper_detected and sig_reject
    if allok:
        print(f"LM3-CHECK PASS: independent foreign re-verifier reproduced every signed checkpoint "
              f"bit-for-bit from data+config+seed ({len(records)} records) for a char-LM with TRAINED "
              f"embeddings (w_hex binds W1;;W2;;E); a forged checkpoint or signature is rejected.")
        sys.exit(0)
    print("LM3-CHECK FAIL")
    sys.exit(1)


if __name__ == "__main__":
    main()
