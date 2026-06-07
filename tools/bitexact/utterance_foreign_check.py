#!/usr/bin/env python3
# FOREIGN (cross-language) re-verifier for the ATTESTED UTTERANCE.
#
# attested_utterance.rail trained a bit-exact char-LM transformer (2 stacked multi-head RoPE
# blocks), then had the model SPEAK a Rail program by deterministic greedy decode, and bound that
# utterance into the SAME Ed25519 hash-chain as the training checkpoints (a final "UTTER" record).
#
# This independent party, written in a DIFFERENT LANGUAGE (Python big-integers), reconstructs the
# entire training run from data+config+seed (reusing lm10_foreign_check), reproduces the model's
# greedy decode itself, and proves -- bit-for-bit -- that the signed UTTER record reproduces:
#   * the utterance tokens (t_hex) match an INDEPENDENT re-generation from the re-derived weights
#   * the utterance is bound to the re-derived final-weights commitment (w_hex) and the prompt
#   * the UTTER record chains onto the reproduced training head (prev == head)
#   * the Ed25519 signature over the reconstructed link verifies under the ledger pubkey
#   * a forged utterance (tampered t_hex) is REJECTED
#
# This is the loop closing on the UTTERANCE, not just the gradients: you can verify the SAYING.
# LOCAL/DEV keys + LOCAL genesis only (mirrors the trainer); never a prod sign surface.
#
# Usage: python3 tools/bitexact/utterance_foreign_check.py [out/utterance_chain.txt]

import sys
import os
import hashlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lm10_foreign_check import (  # resolved at runtime via the sys.path.insert above
    rederive, forward, ctx_rows, build_vocab, tokens, make_pairs,
    thetas, mkblk, canon_mat, sha256_hex, sha256_bytes,
    ed25519_verify, repo_root,
)

S = 16777216
PROMPT = "main = let _ = print (show ("          # mirrors `pr` in attested_utterance.rail
SEED_STR = "lm10.local.ephemeral.dev.seed.v1"
GENESIS_STR = "LM10.LOCAL.BEACON.GENESIS.dev"


def argmax(logits):
    # mirrors Rail lm4_argmax: strict > so the lowest index wins ties
    best, bestv = 0, logits[0]
    for i in range(1, len(logits)):
        if logits[i] > bestv:
            bestv, best = logits[i], i
    return best


def generate(w1, w2, emb, blk0, blk1, isd, seed_ctx, gcap):
    # mirrors Rail lm4_gen: ctx = tail(snoc(ctx, nid)) -> fixed-length sliding window
    ctx = list(seed_ctx)
    out = []
    for _ in range(gcap):
        logits = forward(w1, w2, blk0, blk1, ctx_rows(emb, ctx), isd)
        nid = argmax(logits)
        out.append(nid)
        ctx = ctx[1:] + [nid]
    return out


def ids_canon(ids):
    # mirrors Rail utt_ids_canon: "id0,id1,...,idN," (trailing comma after each)
    return "".join(f"{i}," for i in ids)


def lastc(xs, c):
    return xs if len(xs) <= c else xs[len(xs) - c:]


def block_canons(blkc):
    # mirror lm4_canon17's per-block 7-matrix form: canon_mat(thetas(cell-config)) joined by ';;'
    return ";;".join(canon_mat(thetas(c)) for c in blkc)


def main():
    ledger = sys.argv[1] if len(sys.argv) > 1 else "out/utterance_chain.txt"
    with open(ledger) as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    if not lines or not lines[0].startswith("# LM10v1"):
        print("UTTER-CHECK FAIL: missing/malformed ledger header")
        sys.exit(1)
    hdr = lines[0].split()
    pubkey_hex, genesis_hex, epochs, corpus_sha = hdr[2], hdr[3], int(hdr[4]), hdr[5]
    kv = dict(tok.split("=") for tok in hdr[6:] if "=" in tok)
    d, hidden, vsize, cwin = int(kv["d"]), int(kv["hidden"]), int(kv["vsize"]), int(kv["cwin"])
    B1, B2, LR, EPS, ISD = (int(kv["beta1"]), int(kv["beta2"]),
                            int(kv["lr"]), int(kv["eps"]), int(kv["isd"]))

    ckpt_rows = [ln.split() for ln in lines[1:] if not ln.startswith("UTTER")]
    utter_rows = [ln.split() for ln in lines[1:] if ln.startswith("UTTER")]
    if len(utter_rows) != 1:
        print(f"UTTER-CHECK FAIL: expected exactly 1 UTTER record, found {len(utter_rows)}")
        sys.exit(1)
    u = utter_rows[0]
    # UTTER prompt_hex cwin gcap w_hex t_hex prev_hex link_hex sig_hex
    u_prompt_hex, u_cwin, u_gcap = u[1], int(u[2]), int(u[3])
    u_whex, u_thex, u_prev, u_link, u_sig = u[4], u[5], u[6], u[7], u[8]

    pub = bytes.fromhex(pubkey_hex)

    # ---- reconstruct the training run -> final weights, bit-for-bit (reuses lm10 verifier) ----
    with open(os.path.join(repo_root(), "tools/bitexact/lm10_corpus.txt"), "rb") as fh:
        raw = fh.read()
    corpus_ok = (hashlib.sha256(raw).hexdigest() == corpus_sha)
    corpus = raw.decode("latin-1")
    vocab = build_vocab(corpus)
    ids = tokens(corpus, vocab)
    pairs = make_pairs(ids, cwin)
    recs, head, fw1c, fw2c, fec, fblk0c, fblk1c = rederive(
        d, hidden, epochs, vsize, cwin, LR, EPS, B1, B2, ISD, genesis_hex, pairs)

    w1, w2, emb = thetas(fw1c), thetas(fw2c), thetas(fec)
    blk0, blk1 = mkblk(*fblk0c), mkblk(*fblk1c)

    # ---- the UTTER record must chain onto the reproduced training head ----
    chain_ok = (u_prev == head)

    # ---- re-derive the final-weight commitment; must match the UTTER record AND last checkpoint ----
    w_hex = sha256_hex(canon_mat(w1) + ";;" + canon_mat(w2) + ";;" + canon_mat(emb) + ";;"
                       + block_canons(fblk0c) + ";;" + block_canons(fblk1c))
    whex_ok = (w_hex == u_whex)
    last_ckpt_whex = ckpt_rows[-1][1] if ckpt_rows else ""
    whex_consistent = (u_whex == last_ckpt_whex)
    prompt_ok = (sha256_hex(PROMPT) == u_prompt_hex)

    # ---- INDEPENDENTLY RE-GENERATE the model's words (different language, same result) ----
    pids = tokens(PROMPT, vocab)
    seedp = lastc(pids, cwin)
    gen_ids = generate(w1, w2, emb, blk0, blk1, ISD, seedp, u_gcap)
    t_hex = sha256_hex(ids_canon(gen_ids))
    utter_ok = (t_hex == u_thex)
    decoded = PROMPT + "".join(vocab[i] for i in gen_ids)
    k = decoded.find(" in 0")
    decoded_trim = decoded[:k + 5] if k >= 0 else decoded

    # ---- verify the utterance signature over the reconstructed link ----
    link_str = f"{u_prev}|UTTER|{u_prompt_hex}|{u_cwin}|{u_gcap}|{u_whex}|{u_thex}"
    link_b = sha256_bytes(link_str)
    link_ok = (link_b.hex() == u_link)
    sig_ok = bool(ed25519_verify(pub, link_b, bytes.fromhex(u_sig)))

    # ---- forgery: tamper the utterance commitment -> recorded sig must REJECT ----
    forged_thex = ("0" if u_thex[0] != "0" else "1") + u_thex[1:]
    f_link = sha256_bytes(f"{u_prev}|UTTER|{u_prompt_hex}|{u_cwin}|{u_gcap}|{u_whex}|{forged_thex}")
    forge_reject = not ed25519_verify(pub, f_link, bytes.fromhex(u_sig))

    print("==== FOREIGN UTTERANCE RE-VERIFIER (independent Python re-implementation) ====")
    print(f"corpus pin reproduced            = {corpus_ok}  ({len(recs)} training checkpoints re-derived)")
    print(f"training head reproduced         = {head[:24]}...  (chains onto UTTER: {chain_ok})")
    print(f"final-weights commitment matches = {whex_ok}  (consistent w/ last checkpoint: {whex_consistent})")
    print(f"prompt commitment matches        = {prompt_ok}")
    print(f"UTTERANCE reproduced bit-for-bit = {utter_ok}  (independent greedy decode -> same t_hex)")
    print(f"utterance link reconstructs      = {link_ok}")
    print(f"utterance Ed25519 sig verifies   = {sig_ok}")
    print(f"forged utterance rejected        = {forge_reject}")
    print(f"the words (foreign-reproduced)   = {decoded_trim!r}")

    allok = (corpus_ok and chain_ok and whex_ok and whex_consistent and prompt_ok
             and utter_ok and link_ok and sig_ok and forge_reject)
    if allok:
        print("UTTER-CHECK PASS: a second, independent implementation in a DIFFERENT LANGUAGE "
              "reconstructed the weights from data+config+seed, reproduced the model's EXACT words, "
              "and verified the utterance attestation. The loop is closed on the SAYING.")
        sys.exit(0)
    print("UTTER-CHECK FAIL")
    sys.exit(1)


if __name__ == "__main__":
    main()
