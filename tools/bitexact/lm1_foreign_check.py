#!/usr/bin/env python3
# LM1: the FOREIGN RE-VERIFIER that closes the generating-LM bit-exact loop.
#
# lm1_attested_train.rail produced an Ed25519-signed, hash-chained ledger of a
# bit-exact char-level next-token Rail LM training run. This is an INDEPENDENT party:
# given only the ledger header (pubkey, genesis, step count, corpus hash, koff, dims,
# vocab size, context window) plus the public seed/genesis STRINGS and the pinned
# corpus file, it reconstructs the ENTIRE run from scratch in pure-Python big-integers
# and proves -- bit-for-bit -- that every committed checkpoint reproduces. That is the
# thesis: "reproduce every checkpoint from data+config+seed" -- now for a GENERATING LM.
#
# The exact-integer atoms (truncating div, matvec/gelu/outer/matvec_t/dz1, Adam step,
# RFC 8032 Ed25519) are imported UNCHANGED from the sibling BX witnesses -- the same bits
# that verified BX10. Only the LM data layer is new here, and it is deterministic:
#   * vocab      = distinct chars of the corpus, first-appearance order
#   * tokens     = vocab index of each char
#   * pairs      = sliding (context[C], next) windows
#   * embeddings = FROZEN genvec(id+1, d, 0)            (never trained)
#   * context    = positional-weighted average (weight p+1), truncating-divided by C(C+1)/2
#   * objective  = MSE against one-hot(next)            (loss_fn imported from BX12)
# Forward / loss / grads / Adam are IMPORTED from BX12/BX7 -> identical to the trainer.
#
# Falsification (proves the verifier is not vacuously passing):
#   * corrupt one recorded checkpoint field -> the independent re-derivation MISMATCHES
#   * flip one byte of a signature           -> RFC 8032 verify REJECTS it
#
# Usage: python3 tools/bitexact/lm1_foreign_check.py [/tmp/lm1_chain.txt]

import sys
import os
import hashlib

from bx4_foreign_check import td
from bx7_foreign_check import step1
from bx12_foreign_check import (
    ed25519_verify, ed25519_secret_to_public,
    sha256_hex, sha256_bytes,
    imod, genvec, initcells, thetas, canon_mat, loss_fn, grads,
)

S = 16777216


def repo_root():
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


# ===================== LM1 data layer (deterministic; mirrors the Rail) =====================
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


def emb(cid, d):
    return genvec(cid + 1, d, 0)  # FROZEN embedding for a token id


def ctx_vec(ctx, d, c):
    acc = [0] * d
    for p, cid in enumerate(ctx):
        e = emb(cid, d)
        for k in range(d):
            acc[k] += (p + 1) * e[k]
    wtot = td(c * (c + 1), 2)
    return [td(acc[k], wtot) for k in range(d)]


def onehot(tgt, v):
    return [S if i == tgt else 0 for i in range(v)]


def dsloss(pairs, w1, w2, d, vsize, cwin):
    return sum(loss_fn(w1, w2, ctx_vec(ctx, d, cwin), onehot(tgt, vsize)) for ctx, tgt in pairs)


# ===================== LM1 trajectory re-derivation (exact-integer) =====================
def rederive(d, hidden, kk, koff, vsize, cwin, lr, eps, b1, b2, genesis_hex, pairs):
    npairs = len(pairs)
    w1c = initcells(0, hidden, d, koff)
    w2c = initcells(1, vsize, hidden, koff)
    recs = []
    prev = genesis_hex
    for i in range(kk):
        j = imod(i, npairs)
        ctx, tgt = pairs[j]
        x = ctx_vec(ctx, d, cwin)
        t = onehot(tgt, vsize)
        w1, w2 = thetas(w1c), thetas(w2c)
        loss = loss_fn(w1, w2, x, t)
        dW1, dW2 = grads(w1, w2, x, t, hidden)
        w_hex = sha256_hex(canon_mat(w1) + ";;" + canon_mat(w2))
        g_hex = sha256_hex(canon_mat(dW1) + ";;" + canon_mat(dW2))
        link_str = f"{prev}|{i}|{w_hex}|{g_hex}|{loss}"
        link_b = sha256_bytes(link_str)
        link_hex = link_b.hex()
        recs.append((i, w_hex, g_hex, loss, prev, link_hex, link_b))
        prev = link_hex
        w1c = [[step1(c, dW1[ri][ci], b1, b2, lr, eps, i + 1) for ci, c in enumerate(row)]
               for ri, row in enumerate(w1c)]
        w2c = [[step1(c, dW2[ri][ci], b1, b2, lr, eps, i + 1) for ci, c in enumerate(row)]
               for ri, row in enumerate(w2c)]
    return recs, prev, w1c, w2c


def main():
    ledger = sys.argv[1] if len(sys.argv) > 1 else "/tmp/lm1_chain.txt"
    # fixed config (must match lm1_attested_train.rail)
    LR, EPS, B1, B2 = 838861, 16777, 15099494, 16760439
    SEED_STR = "lm1.local.ephemeral.dev.seed.v1"
    GENESIS_STR = "LM1.LOCAL.BEACON.GENESIS.dev"

    with open(ledger) as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    if not lines or not lines[0].startswith("# LM1v1"):
        print("LM1-CHECK FAIL: missing/malformed ledger header")
        sys.exit(1)
    hdr = lines[0].split()
    # # LM1v1 <pubkey> <genesis> <kk> <corpus_sha> <koff> <d> <hidden> <vsize> <cwin>
    pubkey_hex, genesis_hex, kk = hdr[2], hdr[3], int(hdr[4])
    corpus_sha, koff, d, hidden = hdr[5], int(hdr[6]), int(hdr[7]), int(hdr[8])
    vsize, cwin = int(hdr[9]), int(hdr[10])
    records = [ln.split() for ln in lines[1:]]

    ok = True

    # (1) corpus pin: recompute SHA-256 of the frozen corpus with stock hashlib
    with open(os.path.join(repo_root(), "tools/bitexact/lm1_corpus.txt"), "rb") as fh:
        raw = fh.read()
    py_corpus_sha = hashlib.sha256(raw).hexdigest()
    corpus = raw.decode("latin-1")  # 1:1 byte->char (corpus is ASCII)
    if py_corpus_sha != corpus_sha:
        print(f"MISMATCH corpus sha256: python={py_corpus_sha} ledger={corpus_sha}")
        ok = False

    # (2) koff re-derived from the corpus hash
    py_koff = int(corpus_sha[:6], 16) % 7
    if py_koff != koff:
        print(f"MISMATCH koff: python={py_koff} ledger={koff}")
        ok = False

    # (3) genesis re-derived from its public string
    py_genesis = sha256_hex(GENESIS_STR)
    if py_genesis != genesis_hex:
        print(f"MISMATCH genesis: python={py_genesis} ledger={genesis_hex}")
        ok = False

    # (4) pubkey re-derived from the seed string (key binding)
    seed = hashlib.sha256(SEED_STR.encode()).digest()
    py_pub = ed25519_secret_to_public(seed)
    if py_pub.hex() != pubkey_hex:
        print(f"MISMATCH pubkey: python={py_pub.hex()} ledger={pubkey_hex}")
        ok = False
    pub = bytes.fromhex(pubkey_hex)

    # (5) re-derive the LM data layer (vocab/tokens/pairs) from the pinned corpus
    vocab = build_vocab(corpus)
    if len(vocab) != vsize:
        print(f"MISMATCH vocab size: python={len(vocab)} ledger={vsize}")
        ok = False
    ids = tokens(corpus, vocab)
    pairs = make_pairs(ids, cwin)

    # (6) re-derive the entire training trajectory from data+config+seed
    recs, head, fw1c, fw2c = rederive(d, hidden, kk, koff, vsize, cwin, LR, EPS, B1, B2, genesis_hex, pairs)

    if len(recs) != len(records):
        print(f"MISMATCH record count: python={len(recs)} ledger={len(records)}")
        ok = False

    sigs_ok = 0
    field_mism = 0
    for (pi, pw, pg, ploss, pprev, plink, plink_b), row in zip(recs, records):
        r_step, r_w, r_g, r_loss, r_prev, r_link, r_sig = (
            int(row[0]), row[1], row[2], int(row[3]), row[4], row[5], row[6])
        if (pi, pw, pg, ploss, pprev, plink) != (r_step, r_w, r_g, r_loss, r_prev, r_link):
            field_mism += 1
            if field_mism <= 5:
                print(f"MISMATCH step {pi}: re-derived vs ledger differ "
                      f"(w {pw==r_w} g {pg==r_g} loss {ploss==r_loss} link {plink==r_link})")
        # (7) verify the recorded signature over the re-derived 32-byte link
        if ed25519_verify(pub, plink_b, bytes.fromhex(r_sig)):
            sigs_ok += 1
    if field_mism:
        ok = False
    if sigs_ok != len(records):
        print(f"MISMATCH signatures: {sigs_ok}/{len(records)} verify")
        ok = False

    # (8) chain head + dataset-loss descent over the WHOLE corpus
    ledger_head = records[-1][5] if records else ""
    if head != ledger_head:
        print(f"MISMATCH chain head: python={head} ledger={ledger_head}")
        ok = False
    ds0 = dsloss(pairs, thetas(initcells(0, hidden, d, koff)), thetas(initcells(1, vsize, hidden, koff)), d, vsize, cwin)
    dsK = dsloss(pairs, thetas(fw1c), thetas(fw2c), d, vsize, cwin)
    descent = dsK < ds0

    # ---- falsification: a corrupted checkpoint field must be detected ----
    tampered_w = ("0" if records[0][1][0] != "0" else "1") + records[0][1][1:]
    tamper_detected = (tampered_w != recs[0][1])
    # ---- falsification: a flipped signature byte must be rejected ----
    badsig = bytearray.fromhex(records[0][6])
    badsig[5] ^= 1
    sig_reject = not ed25519_verify(pub, recs[0][6], bytes(badsig))

    print(f"LM1-CHECK corpus pin: SHA-256 reproduced = {py_corpus_sha == corpus_sha} (koff {py_koff == koff})")
    print(f"LM1-CHECK data layer: vocab={len(vocab)} (match {len(vocab)==vsize}) tokens={len(ids)} pairs={len(pairs)}")
    print(f"LM1-CHECK genesis reproduced = {py_genesis == genesis_hex}; "
          f"pubkey re-derived from seed = {py_pub.hex() == pubkey_hex}")
    print(f"LM1-CHECK trajectory: {len(recs)} checkpoints re-derived from data+config+seed; "
          f"field mismatches = {field_mism}")
    print(f"LM1-CHECK signatures: {sigs_ok}/{len(records)} verify under pubkey (RFC 8032)")
    print(f"LM1-CHECK chain head match = {head == ledger_head}; "
          f"datasetLoss0={ds0} datasetLossK={dsK} descent={descent}")
    print(f"LM1-CHECK falsification: corrupt-checkpoint-detected={tamper_detected} "
          f"flipped-sig-rejected={sig_reject}")

    allok = ok and descent and tamper_detected and sig_reject
    if allok:
        print(f"LM1-CHECK PASS: independent foreign re-verifier reproduced every signed checkpoint "
              f"bit-for-bit from data+config+seed ({len(records)} records) for a GENERATING char-LM; "
              f"a forged checkpoint or signature is rejected. The generating-LM bit-exact loop is closed.")
        sys.exit(0)
    print("LM1-CHECK FAIL")
    sys.exit(1)


if __name__ == "__main__":
    main()
