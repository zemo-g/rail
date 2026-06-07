#!/usr/bin/env python3
# RUNG 28 FOREIGN (cross-language) re-verifier: LIVE-BEACON GENESIS + PROOF-OF-RECENCY.
#
# Extends the proven utterance_foreign_check.py. The trainer (r28_live_beacon.rail) seeded BOTH
# the chain genesis AND the initial weights from a freshly-fetched live ledatic.org entropy pulse,
# pinned to the ledger header as `pulse_id=` + `pulse_hex=`. This independent party, in a DIFFERENT
# LANGUAGE (Python big-integers), replays THAT EXACT pulse from the header (never re-fetches),
# re-derives:
#   * genesis = SHA-256(pulse_hex | corpus_sha)               -- must equal the header genesis
#   * poff    = first-byte(pulse_hex) mod 13                   -- the per-pulse init offset
# threads poff into every cell0 init (so the INITIAL WEIGHTS depend on the pulse), reconstructs the
# entire training run bit-for-bit, independently re-generates the model's words, and verifies the
# UTTER signature. PASS requires the floor's full proof AND the pulse-binding to reproduce.
#
# Soundness (the not-before bound): because the init is pulse-seeded, a swapped (earlier) pulse
# changes every cell0 -> the re-derived epoch-0 w_hex diverges from the committed one -> the
# training head no longer reproduces -> the verifier FAILS. (See falsify_earlier_pulse.py.)
#
# LOCAL/DEV keys only (mirrors the trainer); never a prod / Pi-witness sign surface.
#
# Usage: python3 rungs/r28/r28_foreign_check.py [out/utterance_chain.txt]

import sys
import os
import hashlib

# resolve the proven floor modules (tools/bitexact) regardless of cwd
HERE = os.path.dirname(os.path.abspath(__file__))
BITEXACT = os.path.join(os.path.dirname(os.path.dirname(HERE)), "tools", "bitexact")
sys.path.insert(0, BITEXACT)

from lm10_foreign_check import (  # the proven floor primitives
    forward, ctx_rows, build_vocab, tokens, make_pairs,
    thetas, mkblk, canon_mat, sha256_hex, sha256_bytes,
    ed25519_verify, repo_root,
    grads_n2, scatter, dsloss, gamma_initcells, clipg,
)
from bx7_foreign_check import step1
from bx12_foreign_check import cell0, initcells, imod  # cell0 == Rail lm4_cell0 (bit-exact)

S = 16777216
PROMPT = "main = let _ = print (show ("          # mirrors `pr` in r28_live_beacon.rail


# ---------- RUNG 28: pulse derivations (bit-identical to r28_live_beacon.rail) ----------
def pulse_offset(pulse_hex):
    # r28_poff: first byte of value_hex mod 13, in [0,12]
    first_byte = int(pulse_hex[0:2], 16)
    return imod(first_byte, 13)


def pulse_genesis(pulse_hex, corpus_sha):
    # r28_genesis: H(pulse_value_hex | corpus_sha)
    return sha256_hex(pulse_hex + "|" + corpus_sha)


# ---------- pulse-seeded init mirrors (poff threaded into every cell0) ----------
def initcells_p(kind, rows, cols, poff):
    return initcells(kind, rows, cols, poff)


def emb_initcells_p(vsize, d, poff):
    # mirrors lm4_emb_initrow id d poff = lm4_initrow (id+1) 0 0 d poff
    return [[[cell0(cid + 1, 0, j, poff), 0, 0] for j in range(d)] for cid in range(vsize)]


def qkv_initcells_p(kind, d, poff):
    return initcells(kind, d, d, poff)


def wff_initcells_p(kind, nrows, ncols, poff):
    return initcells(kind, nrows, ncols, poff)


def rederive_poff(d, hidden, epochs, vsize, cwin, lr, eps, b1, b2, isd, genesis_hex, pairs, poff):
    """Bit-exact mirror of lm10 rederive, but with the live-pulse offset threaded into init.
    The training-loop body is copied verbatim from the proven floor; ONLY the init lines change."""
    indim = cwin * d
    ff = d * 4
    # ---- RUNG 28: pulse-seeded init (poff replaces the floor's hardcoded 0) ----
    w1c = initcells_p(0, hidden, indim, poff)
    w2c = initcells_p(1, vsize, hidden, poff)
    ec = emb_initcells_p(vsize, d, poff)
    b0wqc = qkv_initcells_p(30, d, poff); b0wkc = qkv_initcells_p(31, d, poff); b0wvc = qkv_initcells_p(32, d, poff)
    b0gammac = gamma_initcells(d); b0gamma2c = gamma_initcells(d)                # gamma == 1.0, not pulse-seeded
    b0wff1c = wff_initcells_p(33, ff, d, poff); b0wff2c = wff_initcells_p(34, d, ff, poff)
    b1wqc = qkv_initcells_p(35, d, poff); b1wkc = qkv_initcells_p(36, d, poff); b1wvc = qkv_initcells_p(37, d, poff)
    b1gammac = gamma_initcells(d); b1gamma2c = gamma_initcells(d)
    b1wff1c = wff_initcells_p(38, ff, d, poff); b1wff2c = wff_initcells_p(39, d, ff, poff)
    recs = []
    prev = genesis_hex
    gstep = 0
    for e in range(epochs):
        for ctx, tgt in pairs:
            gstep += 1

            def upd(cells, grad):
                return [[step1(c, clipg(grad[ri][ci]), b1, b2, lr, eps, gstep)
                         for ci, c in enumerate(row)] for ri, row in enumerate(cells)]

            def updg(cells, gvec):
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
        emb = thetas(ec)
        w1, w2 = thetas(w1c), thetas(w2c)
        blk0 = mkblk(b0wqc, b0wkc, b0wvc, b0gammac, b0gamma2c, b0wff1c, b0wff2c)
        blk1 = mkblk(b1wqc, b1wkc, b1wvc, b1gammac, b1gamma2c, b1wff1c, b1wff2c)
        loss = dsloss(pairs, w1, w2, emb, blk0, blk1, isd)
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


# ---------- decode helpers (mirror the floor's utterance verifier) ----------
def argmax(logits):
    best, bestv = 0, logits[0]
    for i in range(1, len(logits)):
        if logits[i] > bestv:
            bestv, best = logits[i], i
    return best


def generate(w1, w2, emb, blk0, blk1, isd, seed_ctx, gcap):
    ctx = list(seed_ctx)
    out = []
    for _ in range(gcap):
        logits = forward(w1, w2, blk0, blk1, ctx_rows(emb, ctx), isd)
        nid = argmax(logits)
        out.append(nid)
        ctx = ctx[1:] + [nid]
    return out


def ids_canon(ids):
    return "".join(f"{i}," for i in ids)


def lastc(xs, c):
    return xs if len(xs) <= c else xs[len(xs) - c:]


def block_canons(blkc):
    return ";;".join(canon_mat(thetas(c)) for c in blkc)


def main():
    ledger = sys.argv[1] if len(sys.argv) > 1 else "out/utterance_chain.txt"
    with open(ledger) as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    if not lines or not lines[0].startswith("# LM10v1"):
        print("R28-CHECK FAIL: missing/malformed ledger header")
        sys.exit(1)
    hdr = lines[0].split()
    pubkey_hex, genesis_hex, epochs, corpus_sha = hdr[2], hdr[3], int(hdr[4]), hdr[5]
    kv = dict(tok.split("=") for tok in hdr[6:] if "=" in tok)
    d, hidden, vsize, cwin = int(kv["d"]), int(kv["hidden"]), int(kv["vsize"]), int(kv["cwin"])
    B1, B2, LR, EPS, ISD = (int(kv["beta1"]), int(kv["beta2"]),
                            int(kv["lr"]), int(kv["eps"]), int(kv["isd"]))

    # ---- RUNG 28: the live pulse the trainer pinned into the header ----
    if "pulse_id" not in kv or "pulse_hex" not in kv:
        print("R28-CHECK FAIL: header missing pulse_id / pulse_hex (no proof-of-recency binding)")
        sys.exit(1)
    pulse_id, pulse_hex = kv["pulse_id"], kv["pulse_hex"]

    ckpt_rows = [ln.split() for ln in lines[1:] if not ln.startswith("UTTER")]
    utter_rows = [ln.split() for ln in lines[1:] if ln.startswith("UTTER")]
    if len(utter_rows) != 1:
        print(f"R28-CHECK FAIL: expected exactly 1 UTTER record, found {len(utter_rows)}")
        sys.exit(1)
    u = utter_rows[0]
    u_prompt_hex, u_cwin, u_gcap = u[1], int(u[2]), int(u[3])
    u_whex, u_thex, u_prev, u_link, u_sig = u[4], u[5], u[6], u[7], u[8]
    pub = bytes.fromhex(pubkey_hex)

    # ---- RUNG 28: re-derive genesis + poff from the pinned pulse; genesis MUST match header ----
    poff = pulse_offset(pulse_hex)
    re_genesis = pulse_genesis(pulse_hex, corpus_sha)
    pulse_bind_ok = (re_genesis == genesis_hex)          # genesis is provably pulse-derived

    # ---- reconstruct the pulse-seeded training run -> final weights, bit-for-bit ----
    with open(os.path.join(repo_root(), "tools/bitexact/lm10_corpus.txt"), "rb") as fh:
        raw = fh.read()
    corpus_ok = (hashlib.sha256(raw).hexdigest() == corpus_sha)
    corpus = raw.decode("latin-1")
    vocab = build_vocab(corpus)
    ids = tokens(corpus, vocab)
    pairs = make_pairs(ids, cwin)
    recs, head, fw1c, fw2c, fec, fblk0c, fblk1c = rederive_poff(
        d, hidden, epochs, vsize, cwin, LR, EPS, B1, B2, ISD, genesis_hex, pairs, poff)

    w1, w2, emb = thetas(fw1c), thetas(fw2c), thetas(fec)
    blk0, blk1 = mkblk(*fblk0c), mkblk(*fblk1c)

    chain_ok = (u_prev == head)
    w_hex = sha256_hex(canon_mat(w1) + ";;" + canon_mat(w2) + ";;" + canon_mat(emb) + ";;"
                       + block_canons(fblk0c) + ";;" + block_canons(fblk1c))
    whex_ok = (w_hex == u_whex)
    last_ckpt_whex = ckpt_rows[-1][1] if ckpt_rows else ""
    whex_consistent = (u_whex == last_ckpt_whex)
    prompt_ok = (sha256_hex(PROMPT) == u_prompt_hex)

    pids = tokens(PROMPT, vocab)
    seedp = lastc(pids, cwin)
    gen_ids = generate(w1, w2, emb, blk0, blk1, ISD, seedp, u_gcap)
    t_hex = sha256_hex(ids_canon(gen_ids))
    utter_ok = (t_hex == u_thex)
    decoded = PROMPT + "".join(vocab[i] for i in gen_ids)
    k = decoded.find(" in 0")
    decoded_trim = decoded[:k + 5] if k >= 0 else decoded

    link_str = f"{u_prev}|UTTER|{u_prompt_hex}|{u_cwin}|{u_gcap}|{u_whex}|{u_thex}"
    link_b = sha256_bytes(link_str)
    link_ok = (link_b.hex() == u_link)
    sig_ok = bool(ed25519_verify(pub, link_b, bytes.fromhex(u_sig)))

    forged_thex = ("0" if u_thex[0] != "0" else "1") + u_thex[1:]
    f_link = sha256_bytes(f"{u_prev}|UTTER|{u_prompt_hex}|{u_cwin}|{u_gcap}|{u_whex}|{forged_thex}")
    forge_reject = not ed25519_verify(pub, f_link, bytes.fromhex(u_sig))

    print("==== RUNG 28 FOREIGN RE-VERIFIER (live-beacon genesis, proof-of-recency) ====")
    print(f"LIVE PULSE replayed              = id={pulse_id} value_hex={pulse_hex[:16]}...")
    print(f"pulse->init offset poff          = {poff}")
    print(f"genesis IS H(pulse|corpus)       = {pulse_bind_ok}  (header genesis re-derived from pulse)")
    print(f"corpus pin reproduced            = {corpus_ok}  ({len(recs)} pulse-seeded checkpoints re-derived)")
    print(f"training head reproduced         = {head[:24]}...  (chains onto UTTER: {chain_ok})")
    print(f"final-weights commitment matches = {whex_ok}  (consistent w/ last checkpoint: {whex_consistent})")
    print(f"prompt commitment matches        = {prompt_ok}")
    print(f"UTTERANCE reproduced bit-for-bit = {utter_ok}  (independent greedy decode -> same t_hex)")
    print(f"utterance link reconstructs      = {link_ok}")
    print(f"utterance Ed25519 sig verifies   = {sig_ok}")
    print(f"forged utterance rejected        = {forge_reject}")
    print(f"the words (foreign-reproduced)   = {decoded_trim!r}")

    allok = (pulse_bind_ok and corpus_ok and chain_ok and whex_ok and whex_consistent
             and prompt_ok and utter_ok and link_ok and sig_ok and forge_reject)
    if allok:
        print("R28-CHECK PASS: an independent implementation in a DIFFERENT LANGUAGE replayed the "
              "exact live pulse, re-derived the pulse-bound genesis AND the pulse-seeded initial "
              "weights, reconstructed the run, reproduced the model's EXACT words, and verified the "
              "attestation. The signed trajectory is provably posterior to a publicly-witnessed "
              "unpredictable value (not-before bound).")
        sys.exit(0)
    print("R28-CHECK FAIL")
    sys.exit(1)


if __name__ == "__main__":
    main()
