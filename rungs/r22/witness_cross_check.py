#!/usr/bin/env python3
# RUNG 22 - FOREIGN HARD-EDGE CROSS-CHECK
# ===================================================================================
# Independently (a third language, big-int, EXPLICIT truncate-toward-zero) re-derives the
# two cross-ISA arithmetic hazards the ladder requires the run to exercise:
#   (1) >=1 readout dot whose EXACT accumulator exceeds 2^53   (the f64-mantissa hazard:
#       any ISA that reinterpreted the accumulator as f64 would silently drop bits here)
#   (2) >=1 NEGATIVE truncate-divide                            (negative-rounding differs
#       ARM<->x86 if a compiler used floor or round-half-up instead of truncate-toward-zero)
#
# It reuses the proven rung-21 foreign re-derivation (lm10_foreign_check.rederive) to get
# the EXACT final weights from data+config+seed, then re-runs the readout forward on every
# training pair, recomputing the raw (pre-truncation) accumulator with Python big-ints and
# bx4_foreign_check.td (truncate-toward-zero). It then asserts:
#   - max |accumulator|  matches the Rail-emitted bigacc  (and > 2^53)
#   - count(negative numerators) matches the Rail-emitted negtd  (and >= 1)
#
# Matching the Rail witness from a DIFFERENT implementation is the point: a pass certifies
# the hard edges were genuinely exercised, not that the run stayed small.
#
# Usage: python3 witness_cross_check.py out/utterance_chain.txt out/cross_isa_witness.txt
import sys, os, hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
BITEXACT = os.path.normpath(os.path.join(HERE, "..", "..", "tools", "bitexact"))
sys.path.insert(0, BITEXACT)

from lm10_foreign_check import (        # proven rung-21 re-derivation
    rederive, build_vocab, tokens, make_pairs, thetas, mkblk,
    block_fwd, flatten, ctx_rows, geluv, repo_root,
)
from bx4_foreign_check import td        # truncate-toward-zero (NOT Python //)

S = 16777216
TWO53 = 9007199254740992


def raw_dot(row, x):
    """exact raw accumulator (pre-truncation), big-int."""
    acc = 0
    for a, b in zip(row, x):
        acc += a * b
    return acc


def scan(W, x):
    """returns (max|raw acc|, #negative numerators) over the rows of W . x."""
    mx, nc = 0, 0
    for row in W:
        a = raw_dot(row, x)
        if abs(a) > mx:
            mx = abs(a)
        if a < 0:
            nc += 1
    return mx, nc


def main():
    chain = sys.argv[1] if len(sys.argv) > 1 else "out/utterance_chain.txt"
    wit = sys.argv[2] if len(sys.argv) > 2 else "out/cross_isa_witness.txt"

    with open(chain) as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    hdr = lines[0].split()
    genesis_hex, epochs, corpus_sha = hdr[3], int(hdr[4]), hdr[5]
    kv = dict(t.split("=") for t in hdr[6:] if "=" in t)
    d, hidden, vsize, cwin = int(kv["d"]), int(kv["hidden"]), int(kv["vsize"]), int(kv["cwin"])
    B1, B2, LR, EPS, ISD = (int(kv["beta1"]), int(kv["beta2"]), int(kv["lr"]),
                            int(kv["eps"]), int(kv["isd"]))

    with open(os.path.join(repo_root(), "tools/bitexact/lm10_corpus.txt"), "rb") as fh:
        raw = fh.read()
    assert hashlib.sha256(raw).hexdigest() == corpus_sha, "corpus pin mismatch"
    corpus = raw.decode("latin-1")
    vocab = build_vocab(corpus)
    ids = tokens(corpus, vocab)
    pairs = make_pairs(ids, cwin)

    recs, head, fw1c, fw2c, fec, fblk0c, fblk1c = rederive(
        d, hidden, epochs, vsize, cwin, LR, EPS, B1, B2, ISD, genesis_hex, pairs)
    w1, w2, emb = thetas(fw1c), thetas(fw2c), thetas(fec)
    blk0, blk1 = mkblk(*fblk0c), mkblk(*fblk1c)

    big, neg = 0, 0
    for ctx, _tgt in pairs:
        rows = ctx_rows(emb, ctx)
        b0 = block_fwd(blk0, rows, ISD)
        b1 = block_fwd(blk1, b0, ISD)
        x = flatten(b1)
        m1, n1 = scan(w1, x)
        h1 = geluv([td(a, S) for a in [raw_dot(r, x) for r in w1]])
        m2, n2 = scan(w2, h1)
        big = max(big, m1, m2)
        neg += n1 + n2

    # read the Rail-emitted witness
    wv = {}
    with open(wit) as fh:
        for ln in fh:
            if "=" in ln:
                k, v = ln.strip().split("=", 1)
                wv[k] = v
    rail_big = int(wv.get("bigacc", "-1"))
    rail_neg = int(wv.get("negtd", "-1"))

    print("==== FOREIGN HARD-EDGE CROSS-CHECK (Python big-int, truncate-toward-zero) ====")
    print(f"max readout accumulator  foreign={big}  rail={rail_big}  match={big == rail_big}")
    print(f"  exceeds 2^53 ({TWO53}) = {big > TWO53}")
    print(f"negative truncate-divides foreign={neg}  rail={rail_neg}  match={neg == rail_neg}")
    print(f"  at least one          = {neg >= 1}")

    ok = (big == rail_big and rail_big > TWO53 and neg == rail_neg and neg >= 1)
    if ok:
        print("HARD-EDGE CROSS-CHECK PASS: an independent big-int implementation reproduced "
              "BOTH cross-ISA hazards (acc>2^53 AND >=1 negative truncate-divide). The pass "
              "certifies the hard edges, not smallness.")
        sys.exit(0)
    print("HARD-EDGE CROSS-CHECK FAIL")
    sys.exit(1)


if __name__ == "__main__":
    main()
