#!/usr/bin/env python3
# ============================================================================
# RUNG 26 — Foreign cross-language witness for Provably-Identical Tie-Break.
# ============================================================================
# A SEPARATE implementation (Python big-int) of the rung-26 sampling wall. It
# reads the signed ledger out/r26_chain.txt produced by the Rail trainer and:
#   1. recomputes the Q.24 softmax(temperature) from the committed logits
#      bit-for-bit (same truncating fxexp series);
#   2. reproduces TOP-K via repeated max_below with the SAME total order
#      (TIE_LOW: lower token_id wins exact ties) -> same membership set hash;
#   3. reproduces the NUCLEUS prefix the same way -> same set hash;
#   4. redraws the token stream from the SHA-256 counter-mode RNG -> same t_hex;
#   5. recomputes the Q.24 sample-entropy -> equals the committed H;
#   6. verifies the Ed25519 UTTER signature against the pinned pubkey;
#   7. FALSIFIERS (must all hold):
#      (F1) running the OPPOSITE tie-break (TIE_HIGH) on the engineered exact-tie
#           distribution yields a DIFFERENT nucleus membership -> the redrawn
#           stream diverges from the committed nuc_thex (prefix membership
#           differs, a token diverges, reject);
#      (F2) recomputing the entropy under a MISLABELED temperature (tau=1.0
#           instead of the committed tau=4.0) yields H != committed H;
#      (F3) a forged commitment (tie rule flipped) makes the recorded sig fail.
#
# Usage:  python3 rungs/r26/r26_foreign_check.py out/r26_chain.txt
# Exit 0 + last line "R26-FOREIGN PASS" iff every check holds.
# ============================================================================
import sys, hashlib

Q = 16777216  # 2^24

# ── Q.24 fixed-point exp: PROVEN range-reduced kernel, ported verbatim from the
#    trainer's bx_fixed.rail (bx4_fxexp). A naive Taylor series DIVERGES for the
#    large negative args low-temperature softmax produces; ln2 arg-reduction is
#    mandatory and is exactly what the Rail side computes. ───────────────────────
def _pow2(k):
    if k < 1:
        return 1
    acc = 1
    for _ in range(k):
        acc += acc
    return acc
def _exp_poly(fq):
    p = 416
    for c in (3329, 23302, 139810, 699051, 2796203, 8388608, 16777216, 16777216):
        p = c + (p * fq) // Q
    return p
def _exp_neg(ax):
    k = ax // 11629080
    fq = ax - k * 11629080
    ef = _exp_poly(fq)
    emf = 281474976710656 // ef
    if k >= 50:
        return 0
    p2 = _pow2(k)
    return (emf + p2 // 2) // p2
def _exp_pos(xq):
    k = xq // 11629080
    fq = xq - k * 11629080
    ef = _exp_poly(fq)
    if k >= 36:
        return ef * _pow2(35)
    return ef * _pow2(k)
def fxexp_q24(x):
    return _exp_neg(-x) if x < 0 else _exp_pos(x)

def softmax_t(logits, tau):
    ts = [(L * Q) // tau for L in logits]
    m = max(ts)
    es = [fxexp_q24(t - m) for t in ts]
    z = sum(es)
    return [(e * Q) // z for e in es]

# ── Q.24 ln + log2 (mirror r26_fxln / r26_log2) ──────────────────────────────
def fxln(x):
    if x < 1:
        return 0
    s = Q; s2 = 2 * s; k = 0; m = x
    while m < s:          # up-shift for x<1  (mirrors r26_ln_up: k decrements)
        m += m; k -= 1
    while m >= s2:        # down-shift for x>=2 (mirrors r26_ln_dn: k increments)
        m //= 2; k += 1
    num = (m - Q) * Q; den = m + Q
    t = num // den; t2 = (t * t) // Q
    a = t; tp = t
    for d in (3, 5, 7, 9):
        tp = (tp * t2) // Q
        a += tp // d
    mant = a + a
    return k * 11629080 + mant

def tdiv(a, b):
    # truncate toward zero (mirror Rail '/' == ARM64 sdiv), NOT Python's floor //.
    # log2(p<1) and p*log2(p) are NEGATIVE, where floor and trunc diverge by 1 ulp.
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q

def log2_q24(x):
    return tdiv(fxln(x) * 24204406, Q)

def entropy_q24(hist):
    total = sum(hist)
    if total <= 0:
        return 0
    acc = 0
    for c in hist:
        if c <= 0:
            continue
        p = (c * Q) // total
        lg = log2_q24(p)
        term = tdiv(p * lg, Q)
        acc -= term
    return acc

# ── the total order on (prob, token_id) ──────────────────────────────────────
# r26_gt: larger prob ranks higher; exact tie -> tie_low ? smaller id : larger id.
def gt(p_a, a, p_b, b, tie_low):
    if p_a > p_b:
        return True
    if p_a < p_b:
        return False
    return (a < b) if tie_low else (a > b)

def maxbelow(probs, ceilp, ceilid, tie_low):
    bestp, bestid = 0, -1
    for i, p in enumerate(probs):
        # keep only entries the ceiling ranks strictly ABOVE
        if not gt(ceilp, ceilid, p, i, tie_low):
            continue
        if bestid < 0 or gt(p, i, bestp, bestid, tie_low):
            bestp, bestid = p, i
    return bestp, bestid

INF_P = Q + 1  # strictly above any Q.24 prob (mirrors Rail 16777217)

def topk_ids(probs, k, tie_low=True):
    ceilp, ceilid = INF_P, -1
    out = []
    for _ in range(k):
        bp, bid = maxbelow(probs, ceilp, ceilid, tie_low)
        if bid < 0:
            break
        out.append(bid); ceilp, ceilid = bp, bid
    return out

def nucleus_ids(probs, pthr, tie_low=True):
    ceilp, ceilid = INF_P, -1
    cum = 0; out = []
    while cum < pthr:
        bp, bid = maxbelow(probs, ceilp, ceilid, tie_low)
        if bid < 0:
            break
        out.append(bid); cum += bp; ceilp, ceilid = bp, bid
    return out

# ── SHA-256 counter-mode RNG (rung 25): u_t = first 24 bits of SHA256(key,t) ──
def u_t(rng_key, t):
    d = hashlib.sha256((rng_key + "," + str(t)).encode("latin-1")).digest()
    return d[0] * 65536 + d[1] * 256 + d[2]

def draw_stream(probs, cand, rng_key, tcap):
    zc = sum(probs[i] for i in cand)
    ids = []
    for t in range(tcap):
        u = u_t(rng_key, t)
        up = (u * zc) // Q
        run = 0; pick = cand[-1] if cand else -1
        for i in cand:
            nxt = run + probs[i]
            if up < nxt:
                pick = i; break
            run = nxt
        ids.append(pick)
    return ids

def ids_canon(ids):
    return "".join(str(i) + "," for i in ids)

def set_canon(ids):
    return "".join(str(i) + "." for i in ids)

def hist_of(ids, v):
    h = [0] * v
    for i in ids:
        h[i] += 1
    return h

# ── Ed25519 verify via the repo's own RFC 8032 reference (pure python) ────────
# Minimal standalone Ed25519 verify (independent of the Rail impl) so the witness
# is genuinely cross-language. Curve25519 / Edwards, RFC 8032.
p_ed = 2**255 - 19
def _inv(x): return pow(x, p_ed - 2, p_ed)
d_ed = (-121665 * _inv(121666)) % p_ed
I_ed = pow(2, (p_ed - 1) // 4, p_ed)
def _xrecover(y):
    xx = (y*y - 1) * _inv(d_ed * y * y + 1)
    x = pow(xx, (p_ed + 3) // 8, p_ed)
    if (x*x - xx) % p_ed != 0:
        x = (x * I_ed) % p_ed
    if x % 2 != 0:
        x = p_ed - x
    return x
By = 4 * _inv(5) % p_ed
Bx = _xrecover(By)
B = [Bx % p_ed, By % p_ed, 1, (Bx*By) % p_ed]
def _edwards_add(P, Q_):
    x1,y1,z1,t1 = P; x2,y2,z2,t2 = Q_
    a = (y1-x1)*(y2-x2) % p_ed
    b = (y1+x1)*(y2+x2) % p_ed
    c = t1*2*d_ed*t2 % p_ed
    dd = z1*2*z2 % p_ed
    e = b-a; f = dd-c; g = dd+c; h = b+a
    return [e*f % p_ed, g*h % p_ed, f*g % p_ed, e*h % p_ed]
def _scalarmult(P, e):
    if e == 0: return [0,1,1,0]
    Qp = _scalarmult(P, e//2); Qp = _edwards_add(Qp, Qp)
    if e & 1: Qp = _edwards_add(Qp, P)
    return Qp
def _decodepoint(s):
    y = int.from_bytes(s, "little") & ((1<<255)-1)
    x = _xrecover(y)
    if x & 1 != (int.from_bytes(s,"little") >> 255) & 1:
        x = p_ed - x
    P = [x, y, 1, (x*y)%p_ed]
    return P
def _Hint(m):
    return int.from_bytes(hashlib.sha512(m).digest(), "little")
def ed25519_verify(pub, msg, sig):
    if len(sig) != 64 or len(pub) != 32:
        return False
    R = sig[:32]; S = int.from_bytes(sig[32:], "little")
    A = _decodepoint(pub)
    h = _Hint(R + pub + msg) % (2**252 + 27742317777372353535851937790883648493)
    sB = _scalarmult(B, S)
    Rp = _decodepoint(R)
    hA = _scalarmult(A, h)
    RhA = _edwards_add(Rp, hA)
    # compare sB == R + hA in projective coords
    x1,y1,z1,_ = sB; x2,y2,z2,_ = RhA
    return (x1*z2 - x2*z1) % p_ed == 0 and (y1*z2 - y2*z1) % p_ed == 0

# ── parse the ledger ─────────────────────────────────────────────────────────
def parse_kvline(line, prefix):
    body = line[len(prefix):].strip()
    toks = body.split()
    kv = {}
    pos = []
    for tk in toks:
        if "=" in tk:
            k, v = tk.split("=", 1); kv[k] = v
        else:
            pos.append(tk)
    return pos, kv

def main():
    ledger = sys.argv[1] if len(sys.argv) > 1 else "out/r26_chain.txt"
    with open(ledger) as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    hdr = lines[0]
    if not hdr.startswith("# R26v1"):
        print("R26-FOREIGN FAIL: bad header"); sys.exit(1)
    htoks = hdr.split()
    pubkey_hex = htoks[2]; genesis_hex = htoks[3]
    hkv = dict(t.split("=") for t in htoks[4:] if "=" in t)
    vsize = int(hkv["vsize"]); rng_key = hkv["rng"]

    logits = None; utter = None; sets = None
    for ln in lines[1:]:
        if ln.startswith("LOGITS "):
            logits = [int(x) for x in ln[len("LOGITS "):].split(",") if x != ""]
        elif ln.startswith("UTTER26 "):
            utter = ln
        elif ln.startswith("SETS "):
            sets = ln
    assert logits is not None and utter is not None, "missing LOGITS/UTTER26"

    pos, kv = parse_kvline(utter, "UTTER26 ")
    tie_rule = pos[0]                      # "TIE_LOW"
    kk = int(kv["k"]); pthr = int(kv["p"]); tau = int(kv["tau"])
    u_rng = kv["rng"]
    tk_set_hex = kv["tk_set"]; nuc_set_hex = kv["nuc_set"]
    tk_thex = kv["tk_thex"]; nuc_thex = kv["nuc_thex"]
    Htk_committed = int(kv["Htk"]); H_committed = int(kv["H"])
    ulink_hex = kv["ulink"]; usig_hex = kv["usig"]

    tie_low = (tie_rule == "TIE_LOW")
    tcap = 64

    # 1. recompute softmax(tau)
    probs = softmax_t(logits, tau)

    # exact-tie sanity: tokens 2 & 4 must be equal (load-bearing tie)
    tie_exists = (probs[2] == probs[4])

    # 2/3. reproduce top-k and nucleus membership under the SAME order
    tk = topk_ids(probs, kk, tie_low)
    nuc = nucleus_ids(probs, pthr, tie_low)
    tk_set_ok = (sha256_hex(set_canon(tk)) == tk_set_hex)
    nuc_set_ok = (sha256_hex(set_canon(nuc)) == nuc_set_hex)

    # 4. redraw both streams -> t_hex
    dTk = draw_stream(probs, tk, rng_key, tcap)
    dNuc = draw_stream(probs, nuc, rng_key, tcap)
    tk_thex_ok = (sha256_hex(ids_canon(dTk)) == tk_thex)
    nuc_thex_ok = (sha256_hex(ids_canon(dNuc)) == nuc_thex)

    # 5. recompute Q.24 sample-entropy: top-k diversity (Htk) + nucleus (H)
    Htk_recomputed = entropy_q24(hist_of(dTk, vsize))
    H_recomputed = entropy_q24(hist_of(dNuc, vsize))
    Htk_ok = (Htk_recomputed == Htk_committed)
    H_ok = (H_recomputed == H_committed)
    # diversity floor: the realized top-k draw spread exceeds 1 bit (Q.24).
    diversity_ok = (Htk_committed > Q)
    # knob moves: nucleus entropy at high tau strictly exceeds low-tau collapse.
    probs_lo = softmax_t(logits, 838860)        # tau = 0.05 (tau -> 0)
    nuc_lo = nucleus_ids(probs_lo, pthr, tie_low)
    dNuc_lo = draw_stream(probs_lo, nuc_lo, rng_key, tcap)
    H_lo = entropy_q24(hist_of(dNuc_lo, vsize))
    distinct_lo = sum(1 for c in hist_of(dNuc_lo, vsize) if c > 0)
    knob_ok = (H_committed > H_lo)
    collapse_ok = (distinct_lo == 1)

    # 6. verify the Ed25519 UTTER signature
    ulink_b = sha256_bytes_of(reconstruct_ulink(genesis_hex, tie_rule, kk, pthr, tau,
                                                rng_key, tk_set_hex, nuc_set_hex,
                                                tk_thex, nuc_thex, Htk_committed, H_committed))
    sig_ok = (ulink_b.hex() == ulink_hex) and ed25519_verify(bytes.fromhex(pubkey_hex),
                                                             ulink_b, bytes.fromhex(usig_hex))

    # 7a. F1 — OPPOSITE tie-break: nucleus membership differs -> draw diverges
    nuc_opp = nucleus_ids(probs, pthr, not tie_low)
    dNuc_opp = draw_stream(probs, nuc_opp, rng_key, tcap)
    opp_thex = sha256_hex(ids_canon(dNuc_opp))
    f1_diverges = (opp_thex != nuc_thex)

    # 7b. F2 — mislabeled temperature: entropy under tau=1.0 != committed H
    probs_mis = softmax_t(logits, Q)
    nuc_mis = nucleus_ids(probs_mis, pthr, tie_low)
    dNuc_mis = draw_stream(probs_mis, nuc_mis, rng_key, tcap)
    H_mis = entropy_q24(hist_of(dNuc_mis, vsize))
    f2_caught = (H_mis != H_committed)

    # 7c. F3 — forged commitment: flip tie rule, sig must fail
    forged_link = sha256_bytes_of(reconstruct_ulink(genesis_hex,
                        "TIE_HIGH" if tie_low else "TIE_LOW", kk, pthr, tau,
                        rng_key, tk_set_hex, nuc_set_hex, tk_thex, nuc_thex,
                        Htk_committed, H_committed))
    f3_rejected = not ed25519_verify(bytes.fromhex(pubkey_hex), forged_link,
                                     bytes.fromhex(usig_hex))

    checks = [
        ("exact tie load-bearing", tie_exists),
        ("top-k membership reproduced", tk_set_ok),
        ("nucleus membership reproduced", nuc_set_ok),
        ("top-k draw stream reproduced (t_hex)", tk_thex_ok),
        ("nucleus draw stream reproduced (t_hex)", nuc_thex_ok),
        ("top-k diversity entropy Htk reproduced", Htk_ok),
        ("sample-entropy H reproduced", H_ok),
        ("diversity floor (Htk > 1 bit)", diversity_ok),
        ("single-sequence collapse (tau->0)", collapse_ok),
        ("knob moves (H_high > H_low)", knob_ok),
        ("UTTER Ed25519 sig verifies", sig_ok),
        ("F1 opposite tie-break diverges", f1_diverges),
        ("F2 mislabeled-tau caught", f2_caught),
        ("F3 forged commitment rejected", f3_rejected),
    ]
    print("================ R26 FOREIGN WITNESS ================")
    print(f"vocab={vsize}  tie_rule={tie_rule}  k={kk}  p={pthr}  tau={tau}")
    print(f"probs (Q.24) = {probs}")
    print(f"top-k ids    = {tk}   nucleus ids = {nuc}   nucleus(opp) = {nuc_opp}")
    print(f"H committed={H_committed}  recomputed={H_recomputed}")
    ok = True
    for name, val in checks:
        print(f"  {name:42s} = {val}")
        ok = ok and val
    print("R26-FOREIGN PASS" if ok else "R26-FOREIGN FAIL")
    sys.exit(0 if ok else 1)

# ── small SHA helpers (kept after main; module-level so main can call) ────────
def sha256_hex(s):
    return hashlib.sha256(s.encode("latin-1")).hexdigest()

def sha256_bytes_of(s):
    return hashlib.sha256(s.encode("latin-1")).digest()

def reconstruct_ulink(genesis_hex, tie_rule, kk, pthr, tau, rng_key,
                      tk_set_hex, nuc_set_hex, tk_thex, nuc_thex, Htk, H):
    # MUST match the Rail ulink_str byte-for-byte.
    return (f"{genesis_hex}|UTTER26|{tie_rule}|k={kk}|p={pthr}"
            f"|tau={tau}|rng={rng_key}"
            f"|tk_set={tk_set_hex}|nuc_set={nuc_set_hex}"
            f"|tk_thex={tk_thex}|nuc_thex={nuc_thex}"
            f"|Htk={Htk}|H={H}")

if __name__ == "__main__":
    main()
