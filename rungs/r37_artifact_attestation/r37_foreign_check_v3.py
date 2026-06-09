#!/usr/bin/env python3
"""r37 FOREIGN VERIFIER v3 -- exact-integer eval (`eval=xint-q24-v1`).

v2 closed the gate with a numpy-float64 forward that matches Rail's float
forward *empirically* (argmax robust to cross-stack float noise ON THIS
artifact) but not *provably* -- a different libm/BLAS could flip a borderline
argmax. v3 removes float from the verification path entirely: the metric is a
deterministic INTEGER function of (committed weights, committed splits,
r37_xint_spec.md). Any implementation of the spec, any language, any machine,
produces the bit-identical metric. No numpy; stdlib + the proven bitexact
mirrors only.

Inherited primitive semantics (Rail<->Python bit-exactness already proven on
rungs 22-36): td/fxexp from bx4_foreign_check, fxsqrt from bx7_foreign_check.
sin/cos/reduce2pi are ported HERE from tools/bitexact/bx_fixed.rail (bx4_sin /
bx4_cos / bx4_reduce2pi) -- td everywhere, because the Horner intermediates go
negative and Python's // floors where Rail's / truncates.

Overflow audit: tracks the max |dividend| of every truncating divide and a
sum-of-|terms| bound on every exact-sum accumulator (a bound on every partial
sum, hence on every Rail intermediate). FAILS if >= 2^62 -- proving Rail's
63-bit tagged ints cannot have wrapped for THIS artifact + holdout.

Usage:
  python3 r37_foreign_check_v3.py --forward-only   # compute + print the
                                                   # exact-int metric (no record)
  python3 r37_foreign_check_v3.py                  # full verify vs
                                                   # out/r37_attestation_v3.txt
"""
import hashlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "tools", "bitexact"))
from bx4_foreign_check import td, fxexp  # noqa: E402  (proven mirrors)
from bx7_foreign_check import fxsqrt     # noqa: E402

OUT = os.path.join(HERE, "out")
V, D, DFF = 27, 64, 256
S = 16777216                  # 2^24
LN10000_q = 154526885         # round(ln 10000 * S)
LNEPS_q = 168                 # round(1e-5 * S)
ISD_q = 2097152               # S/8 exactly (1/sqrt(64))
HALF_PI_q = 26353589
QUARTER_PI_q = 13176795
TWO_PI_q = 105414357
TWO_PI_48 = 1768559438007110
T_CORRECTED = 55
LOOKUP_BASELINE = 48
ORDER = ("w_e,w_o,wq1,wk1,wv1,wf11,wf21,wq2,wk2,wv2,wf12,wf22,ln_g,ln_b"
         .split(","))

# ---------- overflow tracking ----------
MAX_ABS = 0


def track(v):
    global MAX_ABS
    if v < 0:
        v = -v
    if v > MAX_ABS:
        MAX_ABS = v


def tdt(a, b):
    """td with dividend-magnitude tracking."""
    global MAX_ABS
    aa = -a if a < 0 else a
    if aa > MAX_ABS:
        MAX_ABS = aa
    return td(a, b)


# ---------- sin/cos/reduce2pi, ported from bx_fixed.rail ----------
def sin_unit(aq):              # sin(a)*S for a in [0, pi/4]
    u = td(aq * aq, S)
    p3 = td(46 * u, S) - 3329
    p2 = td(p3 * u, S) + 139810
    p1 = td(p2 * u, S) - 2796203
    p0 = td(p1 * u, S) + 16777216
    return td(aq * p0, S)


def cos_unit(aq):              # cos(a)*S for a in [0, pi/4]
    u = td(aq * aq, S)
    q4 = td(-5 * u, S) + 416
    q3 = td(q4 * u, S) - 23302
    q2 = td(q3 * u, S) + 699051
    q1 = td(q2 * u, S) - 8388608
    return td(q1 * u, S) + 16777216


def _octant(th):
    oc = td(th, HALF_PI_q)
    rq = th - oc * HALF_PI_q
    useco = 1 if rq > QUARTER_PI_q else 0
    a = HALF_PI_q - rq if useco == 1 else rq
    s, c = sin_unit(a), cos_unit(a)
    sh = c if useco == 1 else s
    ch = s if useco == 1 else c
    return oc, sh, ch


def sinq(th):                  # th in [0, 2pi*S); mirrors bx4_sin's if-chain
    oc, sh, ch = _octant(th)
    if oc == 0:
        return sh
    if oc == 1:
        return ch
    if oc == 2:
        return -sh
    return -ch


def cosq(th):                  # mirrors bx4_cos's if-chain
    oc, sh, ch = _octant(th)
    if oc == 0:
        return ch
    if oc == 1:
        return -sh
    if oc == 2:
        return -ch
    return sh


def reduce2pi(th):             # exact two-limb reduction, th < 16384*S
    k = td(th, TWO_PI_q)
    r48 = th * S - k * TWO_PI_48
    track(r48)
    r0 = td(r48, S)
    r1 = r0 + TWO_PI_q if r0 < 0 else r0
    return r1 - TWO_PI_q if r1 >= TWO_PI_q else r1


# ---------- exact-integer forward (the spec, executable) ----------
def build_tables(T):
    """Integer-derived RoPE tables: pure function of the spec, nothing committed."""
    thetas = []
    for j in range(D // 2):
        xj = td(j * LN10000_q, 32)       # (2j/d)*ln10000 in Q.24
        thetas.append(fxexp(-xj))        # 10000^(-2j/d); THETA_0 == S exactly
    CT, ST = [], []
    for p in range(T):
        ct, st = [], []
        for th in thetas:
            ang = reduce2pi(p * th)      # p*th <= 207*S << 16384*S: in-domain
            ct.append(cosq(ang))
            st.append(sinq(ang))
        CT.append(ct)
        ST.append(st)
    return CT, ST


def matvec(x, WT):
    """out_c = td(sum_i x_i * W[i][c], S) -- exact sum, ONE truncation.
    WT is the transpose (list of columns). sa = sum|terms| bounds every
    partial sum of the accumulator."""
    out = []
    for col in WT:
        s = 0
        sa = 0
        for xi, wi in zip(x, col):
            p = xi * wi
            s += p
            sa += p if p >= 0 else -p
        track(sa)
        out.append(td(s, S))
    return out


def lnorm(x):
    """Integer layernorm, gamma=S beta=0 (checked at load; td(y*S,S)==y exactly)."""
    s = 0
    sa = 0
    for v in x:
        s += v
        sa += v if v >= 0 else -v
    track(sa)
    mu = td(s, D)
    dx = [v - mu for v in x]
    s2 = 0
    for v in dx:
        p = v * v
        track(p)
        s2 += td(p, S)
    track(s2)                            # terms nonneg: partials <= final
    var = td(s2, D)
    arg = var + LNEPS_q                  # >= LNEPS_q > 0, so den > 0
    track(arg * S)                       # fxsqrt computes isqrt(arg*S)
    den = fxsqrt(arg)
    return [tdt(v * S, den) for v in dx]


def rope_row(x, ct, st):
    y = [0] * D
    for j in range(D // 2):
        x0, x1 = x[2 * j], x[2 * j + 1]
        c, sn = ct[j], st[j]
        y[2 * j] = tdt(x0 * c, S) - tdt(x1 * sn, S)
        y[2 * j + 1] = tdt(x0 * sn, S) + tdt(x1 * c, S)
    return y


def block(h, W, blk, CT, ST):
    T = len(h)
    ln1 = [lnorm(r) for r in h]
    Q = [rope_row(matvec(r, W[f"wq{blk}"]), CT[p], ST[p])
         for p, r in enumerate(ln1)]
    K = [rope_row(matvec(r, W[f"wk{blk}"]), CT[p], ST[p])
         for p, r in enumerate(ln1)]
    Vv = [matvec(r, W[f"wv{blk}"]) for r in ln1]
    for i in range(T):
        qi = Q[i]
        sc = []
        for j in range(i + 1):           # causal: prefix only
            s = 0
            sa = 0
            for a, b in zip(qi, K[j]):
                p = a * b
                s += p
                sa += p if p >= 0 else -p
            track(sa)
            sc.append(tdt(td(s, S) * ISD_q, S))
        m = max(sc)
        es = [fxexp(v - m) for v in sc]  # args <= 0; exp_neg k>=50 -> 0
        z = 0
        for e in es:
            z += e                       # nonneg; z >= fxexp(0) == S > 0
        track(z)
        w = [tdt(e * S, z) for e in es]
        o = [0] * D
        oa = [0] * D
        for j in range(i + 1):
            wj = w[j]
            vj = Vv[j]
            for c in range(D):
                t = tdt(wj * vj[c], S)   # lm10 per-term form
                o[c] += t
                oa[c] += t if t >= 0 else -t
        for v in oa:
            track(v)
        hi = h[i]
        for c in range(D):
            hi[c] += o[c]                # residual, exact
    ln2 = [lnorm(r) for r in h]
    for i in range(T):
        f1 = matvec(ln2[i], W[f"wf1{blk}"])
        f1 = [v if v > 0 else 0 for v in f1]            # relu
        f2 = matvec(f1, W[f"wf2{blk}"])
        hi = h[i]
        for c in range(D):
            hi[c] += f2[c]               # residual, exact
    return h


def run_forward(W, train_text, hold_text):
    vocab = []
    for c in train_text[:2000]:
        if c not in vocab:
            vocab.append(c)
    assert len(vocab) == V, f"vocab {len(vocab)} != {V}"
    cid = {c: i for i, c in enumerate(vocab)}
    ids = [cid[c] for c in hold_text]
    T = len(ids) - 1
    CT, ST = build_tables(T)
    h = [list(W["w_e_rows"][ids[p]]) for p in range(T)]  # row select, exact
    h = block(h, W, 1, CT, ST)
    h = block(h, W, 2, CT, ST)
    pred = []
    for r in h:
        logits = matvec(r, W["w_o"])
        best = 0
        for c in range(1, V):
            if logits[c] > logits[best]:                 # first max wins
                best = c
        pred.append(vocab[best])
    pred = "".join(pred)
    score = 0
    for mm in re.finditer(r"-- ", hold_text):
        m = mm.start()
        if m + 6 < len(pred):
            score += sum(pred[m + 2 + k] == hold_text[m + 3 + k]
                         for k in range(4))
    return score, T, pred


# ---------- weight loading (raw Q.24 ints, used as-is) ----------
def load_weights(full_p, order):
    shapes = {"w_e": (V, D), "w_o": (D, V), "ln_g": (D,), "ln_b": (D,)}
    for blk in ("1", "2"):
        shapes[f"wq{blk}"] = (D, D)
        shapes[f"wk{blk}"] = (D, D)
        shapes[f"wv{blk}"] = (D, D)
        shapes[f"wf1{blk}"] = (D, DFF)
        shapes[f"wf2{blk}"] = (DFF, D)
    ints = [int(t) for t in open(full_p).read().split(",") if t.strip()]
    assert len(ints) == 93696, f"weight count {len(ints)} != 93696"
    W = {}
    pos = 0
    for nm in order:
        shp = shapes[nm]
        n = shp[0] * (shp[1] if len(shp) == 2 else 1)
        flat = ints[pos:pos + n]
        pos += n
        if len(shp) == 1:
            W[nm] = flat
        else:
            rows = [flat[i * shp[1]:(i + 1) * shp[1]] for i in range(shp[0])]
            if nm == "w_e":
                W["w_e_rows"] = rows     # row-select form
            else:
                W[nm] = [[rows[i][c] for i in range(shp[0])]
                         for c in range(shp[1])]         # transpose: columns
    assert pos == len(ints), "weights not fully consumed"
    assert all(g == S for g in W["ln_g"]), "ln_g != S (gamma must be 1.0)"
    assert all(b == 0 for b in W["ln_b"]), "ln_b != 0"
    return W


def sha_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


# ---------- main ----------
def main():
    forward_only = "--forward-only" in sys.argv
    train_p = os.path.join(REPO, "rungs/r24/force_train_4d.txt")
    hold_p = os.path.join(REPO, "rungs/r24/force_holdout_4d.txt")
    full_p = os.path.join(OUT, "r37_force_weights_q24_full.txt")

    if forward_only:
        W = load_weights(full_p, ORDER)
        score, T, pred = run_forward(W, open(train_p).read(),
                                     open(hold_p).read())
        bits = MAX_ABS.bit_length()
        print(f"R37_XINT_METRIC={score}/64 T={T} max_acc_bits={bits} "
              f"(T'={T_CORRECTED}, lookup={LOOKUP_BASELINE})")
        print("R37_XINT_PRED_SHA="
              + hashlib.sha256(pred.encode()).hexdigest())
        if bits >= 62:
            print("R37_XINT_OVERFLOW=FAIL (>= 2^62: Rail int63 unsafe)")
            sys.exit(1)
        sys.exit(0 if score >= T_CORRECTED else 2)

    fails = []

    def check(name, ok, detail=""):
        tag = "PASS" if ok else "FAIL"
        print(f"  [{tag}] {name}" + (f"  {detail}" if detail else ""))
        if not ok:
            fails.append(name)
        return ok

    from bx12_foreign_check import ed25519_verify  # RFC 8032, proven

    rec = {}
    with open(os.path.join(OUT, "r37_attestation_v3.txt")) as f:
        for line in f:
            if "=" in line and not line.startswith("#"):
                k, v = line.rstrip("\n").split("=", 1)
                rec[k] = v
    msg = rec["msg"]
    msg_b = hashlib.sha256(msg.encode()).digest()
    check("msg_sha matches record", msg_b.hex() == rec["msg_sha256"])
    check("Ed25519 signature (RFC 8032, foreign impl)",
          ed25519_verify(bytes.fromhex(rec["pk"]), msg_b,
                         bytes.fromhex(rec["sig"])))

    fields = dict(p.split("=", 1) for p in msg.split("|")[2:])
    check("eval semantics tag", fields.get("eval") == "xint-q24-v1",
          f"got {fields.get('eval')}")
    metric_signed = int(fields["metric"].split("/")[0])

    check("train split SHA", sha_file(train_p) == fields["train"])
    check("holdout split SHA", sha_file(hold_p) == fields["holdout"])
    check("FULL weight artifact SHA", sha_file(full_p) == fields["weights"])

    order = fields["order"].split(",")
    check("weight order matches spec", order == ORDER)
    W = load_weights(full_p, order)
    print("  ... exact-integer forward (pure int, no float anywhere) ...")
    score, T, pred = run_forward(W, open(train_p).read(), open(hold_p).read())
    bits = MAX_ABS.bit_length()
    pred_sha = hashlib.sha256(pred.encode()).hexdigest()
    print("  pred_sha=" + pred_sha
          + " (cross-impl witness: must equal the Rail evaluator's)")
    check("metric reproduced by EXACT-INT forward", score == metric_signed,
          f"xint={score}/64 signed={metric_signed}/64")
    check("pred SHA matches signed (full output trace)",
          fields.get("pred") == pred_sha,
          f"signed={fields.get('pred', 'MISSING')[:16]}… mine={pred_sha[:16]}…")
    check("bracket: lookup < T' <= metric",
          LOOKUP_BASELINE < T_CORRECTED <= score,
          f"lookup={LOOKUP_BASELINE} T'={T_CORRECTED} metric={score}")
    check("overflow audit: max_acc_bits < 62", bits < 62,
          f"max_acc_bits={bits} (Rail int63 cannot wrap)")
    if "max_acc_bits" in rec:
        check("max_acc_bits matches record", int(rec["max_acc_bits"]) == bits,
              f"mine={bits} record={rec['max_acc_bits']}")

    if fails:
        print(f"R37_FOREIGN_V3=FAIL ({len(fails)}: {', '.join(fails)})")
        sys.exit(1)
    print("R37_FOREIGN_V3=PASS (sig + splits + artifact + exact-int metric "
          "+ pred trace + bracket + overflow bound)")


if __name__ == "__main__":
    main()
