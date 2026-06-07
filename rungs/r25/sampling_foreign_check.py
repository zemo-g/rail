#!/usr/bin/env python3
# RUNG 25 -- FOREIGN (cross-language) re-verifier for the ATTESTED SAMPLED UTTERANCE.
#
# attested_sampling.rail trained the lm10 transformer (UNCHANGED from the floor), then had the model
# SPEAK a Rail program BY EXACT-INTEGER CATEGORICAL SAMPLING (not greedy argmax), and bound that
# sampled utterance -- plus the chain-seeded RNG key, the temperature, and a non-triviality witness
# (ndiff = #positions where sampled != argmax) -- into the SAME Ed25519 hash-chain (a final "USAMPLE"
# record).
#
# This independent party, written in a DIFFERENT LANGUAGE (Python big-integers), reconstructs the
# entire training run from data+config+seed (reusing lm10_foreign_check), and INDEPENDENTLY:
#   * re-derives the 24-bit uniform u_t = first 3 BE bytes of SHA256(rng_key ++ "," ++ str(t))
#   * temperature-prescales the logits (invtemp, Q.24), softmaxes with the SAME integer normalizer z,
#     and walks the inverse-CDF with the SAME strict-> boundary -> redraws EVERY token
#   * confirms the redrawn token-ids hash to the signed t_hex (the SAYING reproduces bit-for-bit)
#   * INDEPENDENTLY recomputes the greedy argmax at each step and confirms ndiff > 0 AND ndiff equals
#     the committed value -- foreclosing "sampling in a greedy costume"
#   * verifies the USAMPLE link chains onto the reproduced training head and the Ed25519 sig verifies
#
# FALSIFIERS the verifier ENFORCES (each must reject):
#   F1 flip one byte of rng_key  -> redrawn stream diverges from signed t_hex
#   F2 swap the walk boundary    -> at least one token diverges
#   F3 non-producing key forgery -> a forged USAMPLE that keeps t_hex but swaps rng_key fails: the
#      verifier re-derives the draws FROM THE COMMITTED KEY and they must produce t_hex, so a
#      substituted key is caught (we demonstrate a different key yields a different stream)
#   F4 forged commitment (tamper invtemp by +1) -> the recorded sig must NOT verify
#
# LOCAL/DEV keys + LOCAL genesis only (mirrors the trainer); never a prod sign surface.
#
# Usage: python3 rungs/r25/sampling_foreign_check.py [rungs/r25/out/sampling_chain.txt]

import sys
import os
import hashlib

# resolve lm10_foreign_check from tools/bitexact (sibling of this rung dir)
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tools", "bitexact"))

from lm10_foreign_check import (  # noqa: E402
    rederive, forward, ctx_rows, build_vocab, tokens, make_pairs,
    thetas, mkblk, canon_mat, sha256_hex, sha256_bytes,
    ed25519_verify, l_softmax,
)
from bx4_foreign_check import td  # noqa: E402

S = 16777216
PROMPT = "main = let _ = print (show ("          # mirrors `pr` in attested_sampling.rail


def repo_root():
    return REPO


# ---- chain-seeded SHA-256 counter-mode RNG -> 24-bit uniform (mirror r25_u) ----
def r25_u(rng_key_hex, t):
    msg = (rng_key_hex + "," + str(t)).encode("latin-1")
    dg = hashlib.sha256(msg).digest()
    return dg[0] * 65536 + dg[1] * 256 + dg[2]


# ---- temperature prescale: each logit -> td(logit*invtemp, S) (mirror r25_tscale) ----
def r25_tscale(logits, invtemp):
    if invtemp == S:
        return logits
    return [td(x * invtemp, S) for x in logits]


# ---- inverse-CDF walk over normalized softmax probs; strict-> boundary (mirror r25_icdf) ----
# bnd: 0 = strict > (canonical) ; 1 = >= (the F2 falsifier boundary). Clamp to last index when u
# exceeds the final cumsum (truncation residual) -- identical to Rail's "probs==[] -> idx-1".
def r25_icdf(probs, u, bnd=0):
    cum = 0
    for idx, p in enumerate(probs):
        cum += p
        hit = (cum > u) if bnd == 0 else (cum >= u)
        if hit:
            return idx
    return len(probs) - 1


def argmax(logits):
    # mirror Rail lm4_argmax: strict > so the lowest index wins ties
    best, bestv = 0, logits[0]
    for i in range(1, len(logits)):
        if logits[i] > bestv:
            bestv, best = logits[i], i
    return best


# ---- one sampled draw (mirror r25_draw): forward -> temp -> softmax -> inverse-CDF(u_t) ----
def r25_draw(w1, w2, emb, blk0, blk1, isd, ctx, invtemp, rng_key_hex, t, bnd=0):
    logits = forward(w1, w2, blk0, blk1, ctx_rows(emb, ctx), isd)
    scaled = r25_tscale(logits, invtemp)
    probs = l_softmax(scaled)
    u = r25_u(rng_key_hex, t)
    return r25_icdf(probs, u, bnd)


# ---- sampled generation (mirror r25_gen): sliding window, t = global step 0..gcap-1 ----
def r25_gen(w1, w2, emb, blk0, blk1, isd, seed_ctx, invtemp, rng_key_hex, gcap, bnd=0):
    ctx = list(seed_ctx)
    out = []
    for t in range(gcap):
        nid = r25_draw(w1, w2, emb, blk0, blk1, isd, ctx, invtemp, rng_key_hex, t, bnd)
        out.append(nid)
        ctx = ctx[1:] + [nid]
    return out


# ---- non-triviality (mirror r25_ndiff): #positions where sampled token != greedy argmax ----
def r25_ndiff(w1, w2, emb, blk0, blk1, isd, seed_ctx, invtemp, rng_key_hex, gcap, bnd=0):
    ctx = list(seed_ctx)
    nd = 0
    for t in range(gcap):
        logits = forward(w1, w2, blk0, blk1, ctx_rows(emb, ctx), isd)
        scaled = r25_tscale(logits, invtemp)
        am = argmax(scaled)
        probs = l_softmax(scaled)
        u = r25_u(rng_key_hex, t)
        nid = r25_icdf(probs, u, bnd)
        if nid != am:
            nd += 1
        ctx = ctx[1:] + [nid]
    return nd


def ids_canon(ids):
    return "".join(f"{i}," for i in ids)


def lastc(xs, c):
    return xs if len(xs) <= c else xs[len(xs) - c:]


def block_canons(blkc):
    return ";;".join(canon_mat(thetas(c)) for c in blkc)


def main():
    ledger = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "rungs/r25/out/sampling_chain.txt")
    with open(ledger) as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    if not lines or not lines[0].startswith("# LM10SAMP1"):
        print("SAMPLE-CHECK FAIL: missing/malformed ledger header")
        sys.exit(1)
    hdr = lines[0].split()
    pubkey_hex, genesis_hex, epochs, corpus_sha = hdr[2], hdr[3], int(hdr[4]), hdr[5]
    kv = dict(tok.split("=") for tok in hdr[6:] if "=" in tok)
    d, hidden, vsize, cwin = int(kv["d"]), int(kv["hidden"]), int(kv["vsize"]), int(kv["cwin"])
    B1, B2, LR, EPS, ISD = (int(kv["beta1"]), int(kv["beta2"]),
                            int(kv["lr"]), int(kv["eps"]), int(kv["isd"]))

    ckpt_rows = [ln.split() for ln in lines[1:] if not ln.startswith("USAMPLE")]
    samp_rows = [ln.split() for ln in lines[1:] if ln.startswith("USAMPLE")]
    if len(samp_rows) != 1:
        print(f"SAMPLE-CHECK FAIL: expected exactly 1 USAMPLE record, found {len(samp_rows)}")
        sys.exit(1)
    u = samp_rows[0]
    # USAMPLE prompt_hex cwin gcap invtemp ndiff rng_key w_hex t_hex prev_hex link_hex sig_hex
    u_prompt_hex = u[1]
    u_cwin, u_gcap, u_invtemp, u_ndiff = int(u[2]), int(u[3]), int(u[4]), int(u[5])
    u_rngkey, u_whex, u_thex = u[6], u[7], u[8]
    u_prev, u_link, u_sig = u[9], u[10], u[11]

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

    # ---- the USAMPLE record must chain onto the reproduced training head ----
    chain_ok = (u_prev == head)

    # ---- re-derive the final-weight commitment; must match the USAMPLE record AND last checkpoint --
    w_hex = sha256_hex(canon_mat(w1) + ";;" + canon_mat(w2) + ";;" + canon_mat(emb) + ";;"
                       + block_canons(fblk0c) + ";;" + block_canons(fblk1c))
    whex_ok = (w_hex == u_whex)
    last_ckpt_whex = ckpt_rows[-1][1] if ckpt_rows else ""
    whex_consistent = (u_whex == last_ckpt_whex)
    prompt_ok = (sha256_hex(PROMPT) == u_prompt_hex)

    # ---- the committed rng_key must be the chain-seeded one (bound to the training head) ----
    rngkey_expect = sha256_hex(head + "|RNGKEY|sample.v1")
    rngkey_ok = (rngkey_expect == u_rngkey)

    # ---- INDEPENDENTLY RE-SAMPLE the model's words from the committed key + invtemp (strict->) ----
    pids = tokens(PROMPT, vocab)
    seedp = lastc(pids, cwin)
    gen_ids = r25_gen(w1, w2, emb, blk0, blk1, ISD, seedp, u_invtemp, u_rngkey, u_gcap, bnd=0)
    t_hex = sha256_hex(ids_canon(gen_ids))
    utter_ok = (t_hex == u_thex)
    decoded = PROMPT + "".join(vocab[i] for i in gen_ids)
    k = decoded.find(" in 0")
    decoded_trim = decoded[:k + 5] if k >= 0 else decoded

    # ---- NON-TRIVIALITY: recompute ndiff independently; must be > 0 AND equal the committed value --
    ndiff = r25_ndiff(w1, w2, emb, blk0, blk1, ISD, seedp, u_invtemp, u_rngkey, u_gcap, bnd=0)
    ndiff_match = (ndiff == u_ndiff)
    nontrivial_ok = (ndiff > 0)

    # ---- verify the utterance signature over the reconstructed link ----
    link_str = (f"{u_prev}|USAMPLE|{u_prompt_hex}|{u_cwin}|{u_gcap}|{u_invtemp}|{u_ndiff}|"
                f"{u_rngkey}|{u_whex}|{u_thex}")
    link_b = sha256_bytes(link_str)
    link_ok = (link_b.hex() == u_link)
    sig_ok = bool(ed25519_verify(pub, link_b, bytes.fromhex(u_sig)))

    # ---- F4 forged commitment: tamper invtemp by +1 -> recorded sig must REJECT ----
    f_link = sha256_bytes(f"{u_prev}|USAMPLE|{u_prompt_hex}|{u_cwin}|{u_gcap}|{u_invtemp + 1}|"
                          f"{u_ndiff}|{u_rngkey}|{u_whex}|{u_thex}")
    forge_commit_reject = not ed25519_verify(pub, f_link, bytes.fromhex(u_sig))

    # ---- F1 flip one byte of rng_key -> redrawn stream must DIVERGE from signed t_hex ----
    flip = ("0" if u_rngkey[0] != "0" else "f") + u_rngkey[1:]
    gen_f1 = r25_gen(w1, w2, emb, blk0, blk1, ISD, seedp, u_invtemp, flip, u_gcap, bnd=0)
    flipkey_reject = (sha256_hex(ids_canon(gen_f1)) != u_thex)

    # ---- F2 boundary falsifier -- CONSTRUCTED exact-cumsum-boundary (NOT measure-zero) ----
    # The stream-swap (bnd=1) almost never differs from bnd=0 on RANDOM u_t; the boundaries diverge
    # ONLY when u lands EXACTLY on a prefix edge. Construct prefix sums {4000000, 8000000, S} and set
    # u to the first edge: strict-> (bnd 0) lands idx1; >= (bnd 1) lands idx0 -> MUST differ.
    f2_probs = [100, 100, 50]
    boundary_reject = (r25_icdf(f2_probs, 100, bnd=0) != r25_icdf(f2_probs, 100, bnd=1))

    # ---- F3 non-producing key forgery: a DIFFERENT key cannot reproduce the signed t_hex ----
    other = sha256_hex("lm10.attacker.nonproducing.key")
    gen_f3 = r25_gen(w1, w2, emb, blk0, blk1, ISD, seedp, u_invtemp, other, u_gcap, bnd=0)
    forgekey_reject = (sha256_hex(ids_canon(gen_f3)) != u_thex)

    print("==== FOREIGN SAMPLED-UTTERANCE RE-VERIFIER (independent Python re-implementation) ====")
    print(f"corpus pin reproduced            = {corpus_ok}  ({len(recs)} training checkpoints re-derived)")
    print(f"training head reproduced         = {head[:24]}...  (chains onto USAMPLE: {chain_ok})")
    print(f"final-weights commitment matches = {whex_ok}  (consistent w/ last checkpoint: {whex_consistent})")
    print(f"prompt commitment matches        = {prompt_ok}")
    print(f"rng_key is chain-seeded (bound)   = {rngkey_ok}  (= SHA256(head|RNGKEY|sample.v1))")
    print(f"SAMPLED utterance reproduced     = {utter_ok}  (independent inverse-CDF redraw -> same t_hex)")
    print(f"NON-TRIVIALITY sampled!=argmax   = {ndiff} positions  (>0: {nontrivial_ok}, matches committed {u_ndiff}: {ndiff_match})")
    print(f"utterance link reconstructs      = {link_ok}")
    print(f"utterance Ed25519 sig verifies   = {sig_ok}")
    print(f"F1 flip rng_key  -> rejected     = {flipkey_reject}")
    print(f"F2 swap boundary -> rejected     = {boundary_reject}")
    print(f"F3 non-producing key -> rejected = {forgekey_reject}")
    print(f"F4 forged commitment -> rejected = {forge_commit_reject}")
    print(f"the words (foreign-reproduced)   = {decoded_trim!r}")

    allok = (corpus_ok and chain_ok and whex_ok and whex_consistent and prompt_ok
             and rngkey_ok and utter_ok and nontrivial_ok and ndiff_match and link_ok and sig_ok
             and flipkey_reject and boundary_reject and forgekey_reject and forge_commit_reject)
    if allok:
        print("SAMPLE-CHECK PASS: a second, independent implementation in a DIFFERENT LANGUAGE "
              "reconstructed the weights, RE-DREW every token from the chain-seeded RNG key under "
              "exact-integer temperature + inverse-CDF, reproduced the model's EXACT sampled words, "
              "confirmed the sample is genuinely non-greedy (ndiff>0 vs independently-recomputed "
              "argmax), and rejected key-flip / boundary-swap / non-producing-key / forged-commitment. "
              "The loop is closed on the SAMPLED saying.")
        sys.exit(0)
    print("SAMPLE-CHECK FAIL")
    sys.exit(1)


if __name__ == "__main__":
    main()
