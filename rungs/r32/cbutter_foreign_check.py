#!/usr/bin/env python3
# FOREIGN (cross-language) re-verifier for the RUNG-32 COMPILE-BOUND UTTERANCE.
#
# compile_bound_utterance.rail trained a bit-exact char-LM transformer (2 stacked multi-head RoPE
# blocks, exact-integer Q.24), then had the model SPEAK a COMPLETE, RUNNABLE Rail program by
# deterministic greedy decode, invoked the PINNED `rail_native` compiler on that source, RAN the
# produced binary, and bound -- into the SAME Ed25519 hash-chain -- a final "UTTER" record that
# commits:  compiled (0/1), src_hex (SHA256 of the spoken source), out_hex (SHA256 of the program's
# stdout), cc_hex (SHA256 of the WHOLE rail_native binary = compiler-identity pin), and prop_hex
# (SHA256 of the required prompt-derived stdout property "7" = the dead-output guard).
#
# This independent party (Python big-integers) reconstructs the training run from data+config+seed
# (reusing lm10_foreign_check), reproduces the model's greedy decode itself, and then INDEPENDENTLY:
#   * re-derives the spoken source from the re-generated tokens; checks SHA256 == committed src_hex
#   * confirms cc_hex == hashlib.sha256(open(rail_native,'rb').read())   (compiler-identity pin)
#       -- if the pinned compiler hash does NOT match the local binary, ABORT before trusting verdict
#   * RE-INVOKES the pinned compiler on the re-derived source, reproduces compiled=1
#   * RUNS the produced binary, hashes its stdout, checks == committed out_hex (bit-for-bit)
#   * checks the program's stripped stdout hashes to prop_hex (non-trivial prompt-derived value)
#   * verifies the Ed25519 sig over the reconstructed link; rejects a 1-nibble-tampered out_hex
#
# This closes the loop on "the saying COMPILES AND RUNS", not just on the words.
# LOCAL/DEV keys + LOCAL genesis only (mirrors the trainer); never a prod sign surface.
#
# Usage: python3 rungs/r32/cbutter_foreign_check.py [out/cbutter_chain.txt]
#   Run from the repo root (so corpus + rail_native resolve, matching the trainer's cwd).

import sys
import os
import hashlib
import subprocess
import tempfile

# reuse the proven lm10 re-derivation primitives (same dir as the lm10/utterance verifiers)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "tools", "bitexact"))
from lm10_foreign_check import (  # resolved at runtime via the sys.path.insert above
    rederive, forward, ctx_rows, build_vocab, tokens, make_pairs,
    thetas, mkblk, canon_mat, sha256_hex, sha256_bytes,
    ed25519_verify, repo_root,
)

S = 16777216
PROMPT = "main = let _ = print (show ("     # mirrors `pr` in compile_bound_utterance.rail
REQ_PROP = "7"                               # the required prompt-derived stdout property
SEED_STR = "lm10.local.ephemeral.dev.seed.v1"
GENESIS_STR = "LM10.LOCAL.BEACON.GENESIS.dev"
WS = (32, 10, 13, 9)                         # space, LF, CR, TAB -- mirror cbu_strip


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


def lm4_finish(full):
    # mirror Rail lm4_finish: cut after the first " in 0" and append "\n"; else return as-is
    k = full.find(" in 0")
    return (full[:k + 5] + "\n") if k >= 0 else full


def strip_ws(b):
    # mirror cbu_strip over RAW bytes: strip leading+trailing WS chars
    i, j = 0, len(b)
    while i < j and b[i] in WS:
        i += 1
    while j > i and b[j - 1] in WS:
        j -= 1
    return b[i:j]


def main():
    ledger = sys.argv[1] if len(sys.argv) > 1 else "out/cbutter_chain.txt"
    rr = repo_root()
    with open(ledger) as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    if not lines or not lines[0].startswith("# CBU32v1"):
        print("CBU-CHECK FAIL: missing/malformed ledger header (expected '# CBU32v1')")
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
        print(f"CBU-CHECK FAIL: expected exactly 1 UTTER record, found {len(utter_rows)}")
        sys.exit(1)
    u = utter_rows[0]
    # UTTER prompt_hex cwin gcap w_hex t_hex compiled src_hex out_hex cc_hex prop_hex prev link sig
    u_prompt_hex, u_cwin, u_gcap = u[1], int(u[2]), int(u[3])
    u_whex, u_thex = u[4], u[5]
    u_compiled = int(u[6])
    u_srchex, u_outhex, u_cchex, u_prophex = u[7], u[8], u[9], u[10]
    u_prev, u_link, u_sig = u[11], u[12], u[13]

    pub = bytes.fromhex(pubkey_hex)

    # ---- COMPILER IDENTITY PIN: the committed cc_hex MUST equal the local rail_native's true hash.
    #      If it does not, the pinned compiler is not the one in front of us -> ABORT (do not trust
    #      a verdict produced by an unknown compiler). This is falsifier (c).
    cc_path = os.path.join(rr, "rail_native")
    if not os.path.exists(cc_path):
        print(f"CBU-CHECK FAIL: pinned compiler not found at {cc_path}")
        sys.exit(1)
    with open(cc_path, "rb") as fh:
        local_cc = hashlib.sha256(fh.read()).hexdigest()
    cc_ok = (local_cc == u_cchex)
    if not cc_ok:
        print(f"CBU-CHECK ABORT: compiler-identity pin mismatch")
        print(f"  committed cc_hex = {u_cchex}")
        print(f"  local rail_native = {local_cc}")
        print("  refusing to trust a compile verdict from a non-pinned compiler.")
        sys.exit(1)

    # ---- reconstruct the training run -> final weights, bit-for-bit (reuses lm10 verifier) ----
    with open(os.path.join(rr, "tools/bitexact/cbutter_corpus.txt"), "rb") as fh:
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
    utter_text = lm4_finish(decoded)         # the spoken Rail source, mirror of the trainer
    src_hex = sha256_hex(utter_text)
    src_ok = (src_hex == u_srchex)

    # ---- RE-INVOKE the pinned compiler on the re-derived source, RUN it, hash its stdout ----
    #      proves compiled=1 + out_hex are REAL verdicts a foreign party reproduces, not asserted.
    compiled = 0
    run_out = b""
    with tempfile.TemporaryDirectory() as tmp:
        src_path = os.path.join(tmp, "cbutter_foreign.rail")
        bin_prefix = os.path.join(tmp, "cbutter_foreign_prog")
        with open(src_path, "w") as fh:
            fh.write(utter_text)
        cp = subprocess.run([cc_path, "--out-prefix", bin_prefix, src_path],
                            cwd=rr, capture_output=True, text=True)
        compile_out = (cp.stdout or "") + (cp.stderr or "")
        compiled = 1 if "ld: OK" in compile_out else 0
        if compiled == 1 and os.path.exists(bin_prefix):
            rp = subprocess.run([bin_prefix], cwd=rr, capture_output=True)
            run_out = rp.stdout
    out_hex = sha256_hex_bytes(run_out)
    compiled_ok = (compiled == 1) and (u_compiled == 1)
    outhex_ok = (out_hex == u_outhex)

    # ---- DEAD-OUTPUT GUARD: the program's stripped stdout must hash to the committed property ----
    prop_ok = (sha256_hex_bytes(strip_ws(run_out)) == u_prophex) and \
              (u_prophex == sha256_hex(REQ_PROP))

    # ---- verify the utterance signature over the reconstructed link ----
    link_str = (f"{u_prev}|UTTER|{u_prompt_hex}|{u_cwin}|{u_gcap}|{u_whex}|{u_thex}"
                f"|{u_compiled}|{u_srchex}|{u_outhex}|{u_cchex}|{u_prophex}")
    link_b = sha256_bytes(link_str)
    link_ok = (link_b.hex() == u_link)
    sig_ok = bool(ed25519_verify(pub, link_b, bytes.fromhex(u_sig)))

    # ---- forgery (falsifier a): tamper out_hex by 1 nibble -> recorded sig must REJECT ----
    forged_outhex = ("1" if u_outhex[0] == "0" else "0") + u_outhex[1:]
    f_link = sha256_bytes(
        f"{u_prev}|UTTER|{u_prompt_hex}|{u_cwin}|{u_gcap}|{u_whex}|{u_thex}"
        f"|{u_compiled}|{u_srchex}|{forged_outhex}|{u_cchex}|{u_prophex}")
    forge_reject = not ed25519_verify(pub, f_link, bytes.fromhex(u_sig))

    print("==== FOREIGN COMPILE-BOUND RE-VERIFIER (independent Python re-implementation) ====")
    print(f"compiler-identity pin matches    = {cc_ok}  (cc_hex == sha256(rail_native); aborts otherwise)")
    print(f"corpus pin reproduced            = {corpus_ok}  ({len(recs)} training checkpoints re-derived)")
    print(f"training head reproduced         = {head[:24]}...  (chains onto UTTER: {chain_ok})")
    print(f"final-weights commitment matches = {whex_ok}  (consistent w/ last checkpoint: {whex_consistent})")
    print(f"prompt commitment matches        = {prompt_ok}")
    print(f"UTTERANCE reproduced bit-for-bit = {utter_ok}  (independent greedy decode -> same t_hex)")
    print(f"source commit matches            = {src_ok}  (sha256 of re-derived source == src_hex)")
    print(f"COMPILES under pinned compiler    = {compiled_ok}  (foreign re-invoke reproduces compiled=1)")
    print(f"stdout commit matches            = {outhex_ok}  (foreign re-run -> identical out_hex)")
    print(f"stdout property (non-trivial)    = {prop_ok}  (stripped stdout hashes to prop_hex == sha256('{REQ_PROP}'))")
    print(f"utterance link reconstructs      = {link_ok}")
    print(f"utterance Ed25519 sig verifies   = {sig_ok}")
    print(f"forged out_hex rejected          = {forge_reject}")
    print(f"the program (foreign-reproduced) = {utter_text.strip()!r}")
    print(f"its stdout (foreign-reproduced)  = {run_out!r}")

    allok = (cc_ok and corpus_ok and chain_ok and whex_ok and whex_consistent and prompt_ok
             and utter_ok and src_ok and compiled_ok and outhex_ok and prop_ok
             and link_ok and sig_ok and forge_reject)
    if allok:
        print("CBU-CHECK PASS: a second, independent implementation in a DIFFERENT LANGUAGE "
              "reconstructed the weights, reproduced the model's EXACT spoken Rail program, "
              "RE-COMPILED it with the pinned compiler, RE-RAN it to identical stdout, and verified "
              "the compile-bound attestation. The saying COMPILES AND RUNS -- loop closed.")
        sys.exit(0)
    print("CBU-CHECK FAIL")
    sys.exit(1)


def sha256_hex_bytes(b):
    return hashlib.sha256(b).hexdigest()


if __name__ == "__main__":
    main()
