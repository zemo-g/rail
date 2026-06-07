#!/usr/bin/env python3
# ============================================================================
# RUNG 26 negative control B: build a ledger whose NUCLEUS membership and draws
# were computed with the OPPOSITE tie-break (TIE_HIGH) but LABEL it TIE_LOW, and
# sign it with the real key. A correct foreign witness that enforces the tie rule
# must REJECT it: its TIE_LOW reproduction yields nucleus {0,2}, not the {0,4} in
# the ledger, so nucleus membership + draw-stream t_hex both fail to reproduce.
# This proves the tie-break rule is genuinely load-bearing (a verifier ignoring
# it would wrongly accept this forgery).
# ============================================================================
import sys, os, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import r26_foreign_check as F
import r26_fixture_gen as G
Q = F.Q

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "out/r26_neg_tiehigh.txt"
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    vsize = 6
    logits = [50331648, 16777216, 33554432, 8388608, 33554432, 25165824]
    seed = hashlib.sha256(b"r26.local.ephemeral.dev.seed.v1").digest()
    pk = G.pk_from_sk(seed)
    genesis = hashlib.sha256(b"R26.LOCAL.TIEBREAK.GENESIS.dev").hexdigest()
    rng = hashlib.sha256(b"r26.chain.seeded.rng.key.dev").hexdigest()
    tau = 67108864; kk = 4; pthr = 5313871; tcap = 64
    probs = F.softmax_t(logits, tau)
    tk = F.topk_ids(probs, kk, True)
    # FORGE: nucleus + its draws use TIE_HIGH, but the record is labeled TIE_LOW
    nuc_h = F.nucleus_ids(probs, pthr, False)
    dNuc = F.draw_stream(probs, nuc_h, rng, tcap)
    dTk = F.draw_stream(probs, tk, rng, tcap)
    thexTk = F.sha256_hex(F.ids_canon(dTk)); thexNuc = F.sha256_hex(F.ids_canon(dNuc))
    tk_set = F.sha256_hex(F.set_canon(tk)); nuc_set = F.sha256_hex(F.set_canon(nuc_h))
    Htk = F.entropy_q24(F.hist_of(dTk, vsize)); H = F.entropy_q24(F.hist_of(dNuc, vsize))
    ul = F.reconstruct_ulink(genesis, "TIE_LOW", kk, pthr, tau, rng,
                             tk_set, nuc_set, thexTk, thexNuc, Htk, H)
    ulb = hashlib.sha256(ul.encode("latin-1")).digest()
    sig, _ = G.ed25519_sign(seed, ulb)
    hdr = f"# R26v1 {pk.hex()} {genesis} vsize={vsize} rng={rng}\n"
    lg = "LOGITS " + F.ids_canon(logits) + "\n"
    st = (f"SETS tk={F.set_canon(tk)} nuc={F.set_canon(nuc_h)} "
          f"nuc_opp={F.set_canon(F.nucleus_ids(probs, pthr, True))}\n")
    ut = (f"UTTER26 TIE_LOW k={kk} p={pthr} tau={tau} rng={rng} "
          f"tk_set={tk_set} nuc_set={nuc_set} tk_thex={thexTk} nuc_thex={thexNuc} "
          f"Htk={Htk} H={H} ulink={ulb.hex()} usig={sig.hex()}\n")
    with open(out, "w") as fh:
        fh.write(hdr + lg + st + ut)
    print(f"neg-control B (TIE_HIGH-as-TIE_LOW) written: {out}  (nucleus used = {nuc_h})")

if __name__ == "__main__":
    main()
