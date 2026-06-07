#!/usr/bin/env python3
# ============================================================================
# RUNG 26 fixture generator (TEST-ONLY). Produces an out/r26_chain.txt ledger
# computed by the SAME reference math as r26_foreign_check.py, signed with a
# reference Ed25519, so the foreign checker can be exercised end-to-end WITHOUT
# the multi-GB Rail build. This is a LOGIC fixture, not the attestation: the real
# cross-language proof is Rail-produces / Python-verifies at orchestrator time.
# The Rail trainer (tiebreak_sampling.rail) emits a byte-identical ledger.
#
# It deliberately reuses r26_foreign_check's own kernels (import) so the fixture
# and the verifier share one definition of softmax/order/draw/entropy -- the
# verifier is then a true reproduction check, and a SEPARATE Rail emit is what
# makes it cross-language.
# ============================================================================
import sys, os, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import r26_foreign_check as F
Q = F.Q

# ── reference Ed25519 SIGN (RFC 8032) to mint the fixture signature ──────────
p_ed = F.p_ed; B = F.B; d_ed = F.d_ed
L = 2**252 + 27742317777372353535851937790883648493
def _encodepoint(P):
    x, y, z = P[0], P[1], P[2]
    zi = pow(z, p_ed - 2, p_ed)
    x = (x * zi) % p_ed; y = (y * zi) % p_ed
    bits = [(y >> i) & 1 for i in range(255)] + [x & 1]
    return bytes(sum(bits[i*8+j] << j for j in range(8)) for i in range(32))
def _Hint(m):
    return int.from_bytes(hashlib.sha512(m).digest(), "little")
def ed25519_sign(seed32, msg):
    h = hashlib.sha512(seed32).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8; a |= (1 << 254)
    A = _encodepoint(F._scalarmult(B, a))
    r = _Hint(h[32:] + msg)
    R = _encodepoint(F._scalarmult(B, r))
    k = _Hint(R + A + msg)
    S = (r + k * a) % L
    return R + S.to_bytes(32, "little"), A
def pk_from_sk(seed32):
    h = hashlib.sha512(seed32).digest()
    a = int.from_bytes(h[:32], "little"); a &= (1 << 254) - 8; a |= (1 << 254)
    return _encodepoint(F._scalarmult(B, a))

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "out/r26_chain.txt"
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    vsize = 6
    logits = [50331648, 16777216, 33554432, 8388608, 33554432, 25165824]
    seed = hashlib.sha256(b"r26.local.ephemeral.dev.seed.v1").digest()
    pk = pk_from_sk(seed); pk_hex = pk.hex()
    genesis_hex = hashlib.sha256(b"R26.LOCAL.TIEBREAK.GENESIS.dev").hexdigest()
    rng_key = hashlib.sha256(b"r26.chain.seeded.rng.key.dev").hexdigest()

    tau = 67108864; kk = 4; pthr = 5313871; tcap = 64
    probs = F.softmax_t(logits, tau)
    tk = F.topk_ids(probs, kk, True)
    nuc = F.nucleus_ids(probs, pthr, True)
    nuc_opp = F.nucleus_ids(probs, pthr, False)
    dTk = F.draw_stream(probs, tk, rng_key, tcap)
    dNuc = F.draw_stream(probs, nuc, rng_key, tcap)
    thexTk = F.sha256_hex(F.ids_canon(dTk))
    thexNuc = F.sha256_hex(F.ids_canon(dNuc))
    tk_set_hex = F.sha256_hex(F.set_canon(tk))
    nuc_set_hex = F.sha256_hex(F.set_canon(nuc))
    Htk = F.entropy_q24(F.hist_of(dTk, vsize))
    H = F.entropy_q24(F.hist_of(dNuc, vsize))

    ulink = F.reconstruct_ulink(genesis_hex, "TIE_LOW", kk, pthr, tau, rng_key,
                                tk_set_hex, nuc_set_hex, thexTk, thexNuc, Htk, H)
    ulink_b = hashlib.sha256(ulink.encode("latin-1")).digest()
    sig, A = ed25519_sign(seed, ulink_b)
    assert A == pk, "pk mismatch in fixture"

    header = f"# R26v1 {pk_hex} {genesis_hex} vsize={vsize} rng={rng_key}\n"
    logits_line = "LOGITS " + F.ids_canon(logits) + "\n"
    sets_line = (f"SETS tk={F.set_canon(tk)} nuc={F.set_canon(nuc)} "
                 f"nuc_opp={F.set_canon(nuc_opp)}\n")
    utter_line = (f"UTTER26 TIE_LOW k={kk} p={pthr} tau={tau} rng={rng_key} "
                  f"tk_set={tk_set_hex} nuc_set={nuc_set_hex} "
                  f"tk_thex={thexTk} nuc_thex={thexNuc} "
                  f"Htk={Htk} H={H} ulink={ulink_b.hex()} usig={sig.hex()}\n")
    with open(out, "w") as fh:
        fh.write(header + logits_line + sets_line + utter_line)
    print(f"fixture written: {out}")
    print(f"  top-k {tk}  nucleus {nuc}  nucleus_opp {nuc_opp}")
    print(f"  Htk={Htk} ({Htk/Q:.4f} bits)  H={H} ({H/Q:.4f} bits)")

if __name__ == "__main__":
    main()
