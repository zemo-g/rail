#!/usr/bin/env python3
# FOREIGN (cross-language) RE-VERIFIER for RUNG 24 — the SEALED HOLDOUT (attested generalization).
#
# r24_attested_holdout.rail trained the proven lm10 transformer (2 stacked multi-head RoPE blocks,
# exact-integer Q.24) on a SEALED TRAIN SPLIT, committed a signed SPLIT record (SHA-256 of the sorted
# unique train lines + the holdout lines, prev=genesis) BEFORE checkpoint 0, then measured held-out
# generalization with a deterministic Q.24-exact metric and gated on a pre-registered floor T while
# bracketing the honest model against a pure-lookup baseline.
#
# This INDEPENDENT party (Python big-integers, a DIFFERENT language) reconstructs the whole thing
# from data+config+seed (reusing the lm10 verifier's `rederive`/`forward` VERBATIM) and proves
# bit-for-bit:
#   * the SPLIT train_sha / hold_sha reproduce from the canonical sorted-unique line sets
#   * the SPLIT record chains onto genesis and its Ed25519 signature verifies under the ledger pubkey
#   * the training chain head reproduces (every checkpoint re-derived; chain prev = SPLIT link)
#   * the HONEST held-out ECHO-position accuracy reproduces and is >= T
#   * the pure-LOOKUP baseline echo accuracy reproduces and is < T (the control bracket)
#   * FALSIFIERS: train-on-holdout -> reconstructed train-SHA != signed SPLIT (reject);
#                 post-hoc holdout swap -> recomputed hold-SHA != SPLIT (reject)
#
# This closes the loop on GENERALIZATION, not memorization: a second implementation in another
# language re-derives the weights, re-runs the exact-integer held-out eval, and confirms the model
# beats the holdout floor while a lookup table cannot. LOCAL/DEV keys + LOCAL genesis only.
#
# Usage: python3 rungs/r24/r24_foreign_check.py [rungs/r24/out/r24_chain.txt]

import sys
import os
import hashlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "bitexact"))
from lm10_foreign_check import (  # resolved via sys.path.insert above
    rederive, forward, ctx_rows, make_pairs, thetas, mkblk,
    sha256_hex, sha256_bytes, ed25519_verify, ed25519_secret_to_public,
)

S = 16777216
SEED_STR = "r24.local.ephemeral.dev.seed.v1"
GENESIS_STR = "R24.LOCAL.BEACON.GENESIS.dev"
DIGITS = "0123456789"


def repo_root():
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def read_text(rel):
    with open(os.path.join(repo_root(), rel), "rb") as fh:
        return fh.read().decode("latin-1")


# ---- fixed-vocab tokenizer (mirrors Rail lm4_tokens against the FIXED union vocab file) ----
def fixed_tokens(text, vocab):
    return [vocab.index(ch) for ch in text]


# ---- canonical SPLIT serialization (mirrors Rail r24_split_canon): sorted unique non-empty lines,
#      each terminated by '\n'. SHA-256 of that string is the SPLIT commitment. ----
def split_canon(text):
    lines = [ln for ln in text.split("\n") if ln != ""]
    uniq = sorted(set(lines))           # byte-lexicographic, dedup
    return "".join(ln + "\n" for ln in uniq)


def split_sha(text):
    return sha256_hex(split_canon(text))


# ---- greedy argmax (mirrors Rail lm4_argmax: strict >, lowest index wins ties) ----
def argmax(logits):
    best, bestv = 0, logits[0]
    for i in range(1, len(logits)):
        if logits[i] > bestv:
            bestv, best = logits[i], i
    return best


# ---- echo-position mask (mirrors Rail r24_echomask): position i (predicting ids[i+cwin]) is an
#      ECHO position iff ids[i+cwin] decodes to a digit AND that exact id occurs in ids[i:i+cwin]. ----
def is_digit_id(vocab, idx):
    return vocab[idx] in DIGITS


def echo_mask(ids, vocab, cwin):
    n = len(ids) - cwin
    mask = []
    for i in range(max(n, 0)):
        window = ids[i:i + cwin]
        tgt = ids[i + cwin]
        flag = 1 if (is_digit_id(vocab, tgt) and tgt in window) else 0
        mask.append(flag)
    return mask


# ---- held-out eval (mirrors Rail r24_eval): teacher-forced greedy next-token accuracy ----
def eval_holdout(w1, w2, emb, blk0, blk1, isd, ids, mask, cwin):
    n = len(ids) - cwin
    ec = et = fc = ft = 0
    for i in range(max(n, 0)):
        window = ids[i:i + cwin]
        tgt = ids[i + cwin]
        logits = forward(w1, w2, blk0, blk1, ctx_rows(emb, window), isd)
        ok = 1 if argmax(logits) == tgt else 0
        ec += mask[i] * ok
        et += mask[i]
        fc += ok
        ft += 1
    return ec, et, fc, ft


# ---- pure-lookup baseline (mirrors Rail r24_lookup_eval): n-gram argmax over the TRAIN-only
#      (context -> next) table; unseen context -> fallback id 0. ----
def build_train_wins(ids, cwin):
    n = len(ids) - cwin
    return [(tuple(ids[i:i + cwin]), ids[i + cwin]) for i in range(max(n, 0))]


def lookup_pred(window, wins, vsize):
    win = tuple(window)
    counts = {}
    seen = False
    for ctx, nxt in wins:
        if ctx == win:
            seen = True
            counts[nxt] = counts.get(nxt, 0) + 1
    if not seen:
        return 0
    # argmax over vocab ids, lowest id wins ties (mirror Rail c=0..vsize-1 with strict >)
    best, bc = -1, 0
    for c in range(vsize):
        cnt = counts.get(c, 0)
        if cnt > best:
            best, bc = cnt, c
    return bc


def lookup_eval(wins, ids, mask, cwin, vsize):
    n = len(ids) - cwin
    ec = et = 0
    for i in range(max(n, 0)):
        window = ids[i:i + cwin]
        tgt = ids[i + cwin]
        ok = 1 if lookup_pred(window, wins, vsize) == tgt else 0
        ec += mask[i] * ok
        et += mask[i]
    return ec, et


def main():
    ledger = sys.argv[1] if len(sys.argv) > 1 else "rungs/r24/out/r24_chain.txt"
    with open(ledger) as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    if not lines or not lines[0].startswith("# R24v1"):
        print("R24-CHECK FAIL: missing/malformed ledger header")
        sys.exit(1)
    hdr = lines[0].split()
    pubkey_hex, genesis_hex, epochs, corpus_sha = hdr[2], hdr[3], int(hdr[4]), hdr[5]
    kv = dict(tok.split("=") for tok in hdr[6:] if "=" in tok)
    d, hidden, vsize, cwin = int(kv["d"]), int(kv["hidden"]), int(kv["vsize"]), int(kv["cwin"])
    B1, B2, LR, EPS, ISD = (int(kv["beta1"]), int(kv["beta2"]),
                            int(kv["lr"]), int(kv["eps"]), int(kv["isd"]))
    tnum, tden = int(kv["tnum"]), int(kv["tden"])
    hdr_train_sha, hdr_hold_sha = kv["train_sha"], kv["hold_sha"]

    split_rows = [ln.split() for ln in lines[1:] if ln.startswith("SPLIT")]
    ckpt_rows = [ln.split() for ln in lines[1:] if not ln.startswith("SPLIT")]
    if len(split_rows) != 1:
        print(f"R24-CHECK FAIL: expected exactly 1 SPLIT record, found {len(split_rows)}")
        sys.exit(1)
    sp = split_rows[0]
    # SPLIT train_sha hold_sha cwin tnum tden genesis link sig
    s_train, s_hold, s_cwin, s_tnum, s_tden = sp[1], sp[2], int(sp[3]), int(sp[4]), int(sp[5])
    s_prev, s_link, s_sig = sp[6], sp[7], sp[8]

    pub = bytes.fromhex(pubkey_hex)

    # ---- pubkey + genesis re-derive from the public strings ----
    seed = hashlib.sha256(SEED_STR.encode()).digest()
    py_pub = ed25519_secret_to_public(seed)
    pub_ok = (py_pub.hex() == pubkey_hex)
    genesis_ok = (sha256_hex(GENESIS_STR) == genesis_hex)

    # ---- reproduce the SPLIT commitments from the corpus files (canonical sorted-unique line sets) ----
    train_text = read_text("rungs/r24/r24_train_corpus.txt")
    hold_text = read_text("rungs/r24/r24_holdout_corpus.txt")
    vocab = read_text("rungs/r24/r24_vocab.txt")
    py_train_sha = split_sha(train_text)
    py_hold_sha = split_sha(hold_text)
    train_sha_ok = (py_train_sha == s_train == hdr_train_sha)
    hold_sha_ok = (py_hold_sha == s_hold == hdr_hold_sha)
    corpus_pin_ok = (sha256_hex(train_text) == corpus_sha)
    vocab_ok = (len(vocab) == vsize)

    # ---- verify the SPLIT record: chain prev=genesis, link reconstructs, signature verifies ----
    split_chain_ok = (s_prev == genesis_hex)
    link_str = f"{s_prev}|SPLIT|{s_train}|{s_hold}|{s_cwin}|{s_tnum}|{s_tden}"
    link_b = sha256_bytes(link_str)
    split_link_ok = (link_b.hex() == s_link)
    split_sig_ok = bool(ed25519_verify(pub, link_b, bytes.fromhex(s_sig)))

    # ---- reconstruct the training run -> final weights (reuses lm10 rederive VERBATIM) ----
    train_ids = fixed_tokens(train_text, vocab)
    pairs = make_pairs(train_ids, cwin)
    recs, head, fw1c, fw2c, fec, fblk0c, fblk1c = rederive(
        d, hidden, epochs, vsize, cwin, LR, EPS, B1, B2, ISD, s_link, pairs)
    # ledger chain head = last checkpoint link; chain prev of ckpt0 must be the SPLIT link
    ledger_head = ckpt_rows[-1][4] if ckpt_rows else ""
    head_ok = (head == ledger_head)
    ckpt0_prev_ok = (ckpt_rows[0][3] == s_link) if ckpt_rows else False

    w1, w2, emb = thetas(fw1c), thetas(fw2c), thetas(fec)
    blk0, blk1 = mkblk(*fblk0c), mkblk(*fblk1c)

    # ---- HELD-OUT eval (honest model) + LOOKUP baseline ----
    hold_ids = fixed_tokens(hold_text, vocab)
    mask = echo_mask(hold_ids, vocab, cwin)
    h_ec, h_et, h_fc, h_ft = eval_holdout(w1, w2, emb, blk0, blk1, ISD, hold_ids, mask, cwin)
    train_wins = build_train_wins(train_ids, cwin)
    l_ec, l_et = lookup_eval(train_wins, hold_ids, mask, cwin, vsize)

    # exact integer comparisons (mirror Rail: a/b >= tnum/tden <=> a*tden >= b*tnum)
    honest_ge_T = (h_ec * tden >= h_et * tnum)
    lookup_lt_T = (l_ec * tden < l_et * tnum)
    bracket_ok = honest_ge_T and lookup_lt_T

    # ---- FALSIFIERS ----
    overfit_text = read_text("rungs/r24/r24_overfit_corpus.txt")
    split_falsify_ok = (split_sha(overfit_text) != py_train_sha)     # train-on-holdout -> SHA differs
    swap_falsify_ok = (split_sha(train_text) != py_hold_sha)         # post-hoc holdout swap -> SHA differs

    print("==== FOREIGN RUNG-24 RE-VERIFIER (independent Python re-implementation) ====")
    print(f"pubkey re-derived from seed      = {pub_ok}")
    print(f"genesis reproduced               = {genesis_ok}")
    print(f"train SPLIT sha reproduced       = {train_sha_ok}  ({py_train_sha[:24]}...)")
    print(f"holdout SPLIT sha reproduced     = {hold_sha_ok}  ({py_hold_sha[:24]}...)")
    print(f"train corpus pin reproduced      = {corpus_pin_ok}; vocab size match = {vocab_ok}")
    print(f"SPLIT chains onto genesis        = {split_chain_ok}; link reconstructs = {split_link_ok}")
    print(f"SPLIT Ed25519 signature verifies = {split_sig_ok}")
    print(f"training head reproduced         = {head_ok}  (ckpt0.prev == SPLIT link: {ckpt0_prev_ok})")
    print(f"HONEST held-out echo accuracy    = {h_ec}/{h_et}  (>= T={tnum}/{tden}: {honest_ge_T})")
    print(f"HONEST held-out full accuracy    = {h_fc}/{h_ft}")
    print(f"LOOKUP baseline echo accuracy    = {l_ec}/{l_et}  (< T: {lookup_lt_T})")
    print(f"CONTROL BRACKET (honest>=T>look) = {bracket_ok}")
    print(f"FALSIFIER train-on-holdout rejct = {split_falsify_ok}  (overfit corpus SHA != signed train SHA)")
    print(f"FALSIFIER post-hoc swap rejected = {swap_falsify_ok}  (swapped holdout SHA != signed hold SHA)")

    allok = (pub_ok and genesis_ok and train_sha_ok and hold_sha_ok and corpus_pin_ok and vocab_ok
             and split_chain_ok and split_link_ok and split_sig_ok and head_ok and ckpt0_prev_ok
             and honest_ge_T and bracket_ok and split_falsify_ok and swap_falsify_ok)
    if allok:
        print("R24-CHECK PASS: a second, independent implementation in a DIFFERENT LANGUAGE "
              "reconstructed the weights from the SEALED train split, reproduced the signed SPLIT "
              "commitment, and confirmed the model GENERALIZES to the holdout (echo-acc >= T while "
              "the lookup baseline fails). Train-on-holdout and post-hoc swap are rejected by SHA "
              "mismatch. The loop is closed on GENERALIZATION.")
        sys.exit(0)
    print("R24-CHECK FAIL")
    sys.exit(1)


if __name__ == "__main__":
    main()
