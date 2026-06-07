#!/usr/bin/env python3
# =====================================================================================
# RUNG 30 -- FOREIGN (cross-language) re-verifier for the SUCCINCT SPOT-CHECK transcript.
# =====================================================================================
# r30_protocol.rail produced a Fiat-Shamir-bound succinct training-trajectory proof: per-step
# FULL-state commitments Merkle-ized into a root, the root chained+signed, and challenge indices
# derived BY HASHING THE CHAIN HEAD (no PRNG). It claims an entire N-step trajectory is verified by
# recomputing only k<<N challenged steps.
#
# This INDEPENDENT party, in a DIFFERENT LANGUAGE (Python big-integers), reads the signed transcript
# and proves -- bit-for-bit -- that:
#   * the per-step transition r30_step is reproduced exactly (Python re-derives committed[idx] from
#     committed[idx-1] for each challenged idx)
#   * the Merkle leaf / path / root reconstruct to the SAME root the prover committed
#   * the Fiat-Shamir challenge indices are reproduced from the chain head (the prover could not pick)
#   * the Ed25519 signature over the chain head verifies under the ledger pubkey
#   * a FORGED interior step (poisoned v-moment) is REJECTED when challenged
#   * verify work (k steps) is << train work (N steps): the SUBLINEARITY claim
#
# It re-derives everything from the transcript's CONFIG + the committed states list; it never trusts
# the prover's "ok" flags. This is the loop closing on succinct verification: an outside party
# confirms the whole trajectory while touching < 25% of it.  LOCAL/DEV keys only.
#
# Usage: python3 rungs/r30/r30_foreign_check.py rungs/r30/out/r30_transcript.txt
# =====================================================================================

import sys
import os
import hashlib

S = 16777216
B1 = 15099494
B2 = 16760439
LR = 209715
EPS = 16777
GCLIP = 524288   # MUST match r30_protocol.rail r30_gclip (clip is load-bearing below 2^20 max grad)


def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def head48(hexstr: str) -> int:
    # first 12 hex nibbles -> 48-bit value (matches Rail r_head48: 16-base Horner)
    v = 0
    for c in hexstr[:12]:
        v = v * 16 + int(c, 16)
    return v


# ---- exact-int transition (mirrors Rail r30_step / r_grad / r_clip / r_isqrt) ----
def isqrt_newton(x: int) -> int:
    if x <= 0:
        return 0
    g = x + 1
    for _ in range(24):
        if g == 0:
            return 0
        g = (g + x // g) // 2
    return g


def grad(theta: int, ctx: int, tgt: int) -> int:
    return ((theta // 2048) + (ctx - tgt) * 65536) - (theta * 3) // 1024


def clip(g: int, clip_on: int) -> int:
    if clip_on == 0:
        return g
    if g > GCLIP:
        return GCLIP
    if g < -GCLIP:
        return -GCLIP
    return g


def trunc_div(a: int, b: int) -> int:
    # Rail integer division truncates toward zero; Python // floors. Match Rail.
    q = abs(a) // abs(b)
    if (a < 0) != (b < 0):
        q = -q
    return q


def step(state, ctx, tgt, clip_on):
    theta, m, v, pow1, pow2 = state
    g = clip(grad(theta, ctx, tgt), clip_on)
    nm = trunc_div(m * B1 + g * (S - B1), S)
    nv = trunc_div(v * B2 + trunc_div(g * g, S) * (S - B2), S)
    np1 = trunc_div(pow1 * B1, S)
    np2 = trunc_div(pow2 * B2, S)
    bc1 = S - np1
    bc2 = S - np2
    mhat = trunc_div(nm * S, bc1)
    vhat = trunc_div(nv * S, bc2)
    denom = isqrt_newton(vhat * S) + EPS
    upd = trunc_div(LR * mhat, denom)
    nth = theta - upd
    return [nth, nm, nv, np1, np2]


def state_ser(st) -> str:
    return ",".join(str(x) for x in st)


def ctx_of(i: int) -> int:
    return (i * 7 + 3) - (i * 7 + 3) // 17 * 17


def tgt_of(i: int) -> int:
    return (i * 13 + 5) - (i * 13 + 5) // 17 * 17


def leaf_of(i, ctx, tgt, st) -> str:
    return sha256_hex(f"LEAF|{i}|{ctx}|{tgt}|{state_ser(st)}")


# ---- Merkle (mirrors r30_pair_up / r30_levels / r30_proof / r30_path_fold) ----
def pair_up(nodes):
    out = []
    i = 0
    while i < len(nodes):
        if i + 1 >= len(nodes):
            out.append(nodes[i])  # odd tail promotes
            i += 1
        else:
            out.append(sha256_hex(f"NODE|{nodes[i]}|{nodes[i+1]}"))
            i += 2
    return out


def levels_of(leaves):
    if not leaves:
        return [[sha256_hex("EMPTY")]]
    lv = [leaves]
    while len(lv[-1]) > 1:
        lv.append(pair_up(lv[-1]))
    return lv


def root_of(levels):
    return levels[-1][0]


def proof_of(levels, idx):
    path = []
    for lvl in range(len(levels) - 1):
        nodes = levels[lvl]
        isright = idx % 2
        sib_i = idx - 1 if isright == 1 else idx + 1
        sib = nodes[idx] if sib_i >= len(nodes) else nodes[sib_i]
        side = 0 if isright == 1 else 1   # 0 = sibling LEFT, 1 = sibling RIGHT
        path.append((sib, side))
        idx = idx // 2
    return path


def path_fold(leaf, path):
    cur = leaf
    for sib, side in path:
        if side == 0:
            cur = sha256_hex(f"NODE|{sib}|{cur}")
        else:
            cur = sha256_hex(f"NODE|{cur}|{sib}")
    return cur


# ---- Fiat-Shamir challenge derivation (mirrors r30_chal / r30_chal_list) ----
def challenges(root, chain_head, k, n):
    out = []
    for j in range(k):
        h = sha256_hex(f"{root}|{chain_head}|CHAL|{j}")
        out.append(head48(h) % n)
    return out


# ---- Ed25519 verify: prefer PyNaCl, else a self-contained pure-Python verify ----
def ed25519_verify(pk_hex, msg_bytes, sig_hex):
    pk = bytes.fromhex(pk_hex)
    sig = bytes.fromhex(sig_hex)
    try:
        from nacl.signing import VerifyKey  # type: ignore
        VerifyKey(pk).verify(msg_bytes, sig)
        return True
    except ImportError:
        return _ed25519_verify_pure(pk, msg_bytes, sig)
    except Exception:
        return False


# minimal RFC 8032 Ed25519 verify (pure Python) -- used when PyNaCl is absent
def _ed25519_verify_pure(public, msg, signature):
    p = 2 ** 255 - 19
    L = 2 ** 252 + 27742317777372353535851937790883648493
    d = (-121665 * pow(121666, p - 2, p)) % p
    I = pow(2, (p - 1) // 4, p)

    def xrecover(y):
        xx = (y * y - 1) * pow(d * y * y + 1, p - 2, p)
        x = pow(xx, (p + 3) // 8, p)
        if (x * x - xx) % p != 0:
            x = (x * I) % p
        if x % 2 != 0:
            x = p - x
        return x

    By = (4 * pow(5, p - 2, p)) % p
    Bx = xrecover(By)
    B = [Bx % p, By % p]

    def edwards(P, Q):
        x1, y1 = P
        x2, y2 = Q
        x3 = (x1 * y2 + x2 * y1) * pow(1 + d * x1 * x2 * y1 * y2, p - 2, p)
        y3 = (y1 * y2 + x1 * x2) * pow(1 - d * x1 * x2 * y1 * y2, p - 2, p)
        return [x3 % p, y3 % p]

    def scalarmult(P, e):
        if e == 0:
            return [0, 1]
        Q = scalarmult(P, e // 2)
        Q = edwards(Q, Q)
        if e & 1:
            Q = edwards(Q, P)
        return Q

    def decodeint(s):
        return int.from_bytes(s, "little")

    def decodepoint(s):
        y = int.from_bytes(s, "little") & ((1 << 255) - 1)
        x = xrecover(y)
        if x & 1 != (int.from_bytes(s, "little") >> 255):
            x = p - x
        P = [x, y]
        return P

    if len(signature) != 64 or len(public) != 32:
        return False
    try:
        R = decodepoint(signature[:32])
        A = decodepoint(public)
    except Exception:
        return False
    S_ = decodeint(signature[32:])
    h = decodeint(hashlib.sha512(signature[:32] + public + msg).digest()) % L
    v1 = scalarmult(B, S_)
    v2 = edwards(R, scalarmult(A, h))
    return v1[0] % p == v2[0] % p and v1[1] % p == v2[1] % p


def fail(msg):
    print(f"R30-FOREIGN FAIL: {msg}")
    sys.exit(1)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "rungs/r30/out/r30_transcript.txt"
    if not os.path.exists(path):
        fail(f"transcript not found: {path}")
    with open(path) as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    hdr = {}
    states = []
    pubkey_hex = genesis = tag = None
    n = k = poison_at = clip_on = None
    chain_head = sig_hex = root_committed = None
    for ln in lines:
        parts = ln.split()
        key = parts[0]
        if key == "#R30TX":
            kv = dict(tok.split("=") for tok in parts[1:] if "=" in tok)
            pubkey_hex = kv["pubkey"]
            genesis = kv["genesis"]
            tag = kv["tag"]
            n = int(kv["n"])
            k = int(kv["k"])
            poison_at = int(kv["poison_at"])
            clip_on = int(kv["clip_on"])
        elif key == "ROOT":
            root_committed = parts[1]
        elif key == "HEAD":
            chain_head = parts[1]
        elif key == "SIG":
            sig_hex = parts[1]
        elif key == "STATE":
            # STATE <idx> <theta> <m> <v> <pow1> <pow2>
            idx = int(parts[1])
            st = [int(x) for x in parts[2:7]]
            states.append((idx, st))
    if n is None:
        fail("missing #R30TX header")
    states.sort(key=lambda t: t[0])
    if [t[0] for t in states] != list(range(n)):
        fail("committed STATE indices are not 0..n-1 contiguous")
    post = [t[1] for t in states]
    genesis_state = [0, 0, 0, S, S]

    # 1) recompute the Merkle root from the committed states (independent of the prover's ROOT line)
    leaves = [leaf_of(i, ctx_of(i), tgt_of(i), post[i]) for i in range(n)]
    levels = levels_of(leaves)
    root = root_of(levels)
    ok_root = (root == root_committed)

    # 2) re-derive the chain head from genesis + tag + n + root, and verify the signature
    link_str = f"{genesis}|R30|{tag}|{n}|{root}"
    link_b = hashlib.sha256(link_str.encode()).digest()
    head_re = link_b.hex()
    ok_head = (head_re == chain_head)
    ok_sig = ed25519_verify(pubkey_hex, link_b, sig_hex)

    # 3) re-derive the k Fiat-Shamir challenges from the chain head (the prover could NOT pick them)
    chals = challenges(root, chain_head, k, n)
    distinct = sorted(set(chals))
    ok_budget = (len(distinct) < n // 4)   # < 25% of steps touched

    # 4) recompute ONLY the challenged steps + verify their Merkle paths
    n_step_fail = 0
    n_merkle_fail = 0
    for idx in chals:
        pre = genesis_state if idx == 0 else post[idx - 1]
        recomputed = step(pre, ctx_of(idx), tgt_of(idx), 1)   # verifier assumes honest clip
        if state_ser(recomputed) != state_ser(post[idx]):
            n_step_fail += 1
        leaf = leaf_of(idx, ctx_of(idx), tgt_of(idx), post[idx])
        proof = proof_of(levels, idx)
        if path_fold(leaf, proof) != root:
            n_merkle_fail += 1

    is_honest = (poison_at < 0) and (clip_on == 1)
    hit_poison = (poison_at >= 0) and (poison_at in set(chals))

    print("================ RUNG 30 FOREIGN (cross-language) CHECK ================")
    print(f"transcript                = {path}")
    print(f"config                    = N={n} k={k} tag={tag} poison_at={poison_at} clip_on={clip_on}")
    print(f"Merkle root reproduced    = {ok_root}")
    print(f"chain head reproduced     = {ok_head}")
    print(f"Ed25519 sig verifies      = {ok_sig}")
    print(f"FS challenges (distinct)  = {len(distinct)} of N={n}  (< 25%: {ok_budget})")
    print(f"verify work               = {k} steps recomputed vs N={n} trained  (ratio {k/n:.3f})")
    print(f"challenged-step recompute mismatches = {n_step_fail}")
    print(f"challenged-step Merkle-path failures  = {n_merkle_fail}")

    if is_honest:
        # The SUCCINCT claim: the spot-check (k challenged steps) finds 0 mismatch + paths verify.
        succinct_ok = ok_root and ok_head and ok_sig and ok_budget and n_step_fail == 0 and n_merkle_fail == 0
        # SOUNDNESS belt: a full audit (recompute ALL steps) must ALSO find 0 mismatch. This is what
        # makes the gate able to FAIL on a tampered honest transcript even when the FS sampling missed
        # the tampered step -- the meta-falsifier in validate.sh relies on it. (The succinct verdict is
        # reported separately so the sublinear claim stands on its own; the full audit is the gate's
        # tamper-evidence, run here only because the gate must be falsifiable, not because verification
        # needs it at scale.)
        full_fail = 0
        for idx in range(n):
            pre = genesis_state if idx == 0 else post[idx - 1]
            if state_ser(step(pre, ctx_of(idx), tgt_of(idx), 1)) != state_ser(post[idx]):
                full_fail += 1
        ok = succinct_ok and full_fail == 0
        print(f"succinct spot-check verdict = {succinct_ok}  ({k} of {n} steps; {100*k/n:.1f}%)")
        print(f"full-audit tamper-check     = {full_fail} mismatches (must be 0 for an honest chain)")
        print(f"honest verdict            = {ok}")
        if ok:
            print("PASS: foreign party verified the whole N-step trajectory by recomputing only "
                  f"{k} Fiat-Shamir-challenged steps ({100*k/n:.1f}% of N); Merkle paths + signature check. "
                  "Full audit confirms zero tampering.")
            sys.exit(0)
        fail("honest transcript did not fully reproduce (succinct or full-audit mismatch)")
    else:
        # forged transcript: the Merkle root + chain head + sig still reproduce (the forger committed a
        # CONSISTENT Merkle tree of his FORGED states), but a challenge that HIT the poisoned step MUST
        # produce a step-recompute mismatch -> REJECT. If the challenge missed it, the round is
        # (honestly) inconclusive -- the rung-30 claim is amplification across rounds + the full audit.
        if hit_poison:
            ok = (n_step_fail >= 1)
            print(f"FORGED + challenge HIT poison_at={poison_at}: detected = {ok}")
            if ok:
                print("PASS (falsifier): the poisoned interior step was challenged and REJECTED by "
                      "independent recomputation. A cheaper-than-retrain forgery is caught.")
                sys.exit(0)
            fail("poisoned step was challenged but NOT detected -- soundness broken")
        else:
            print(f"FORGED but challenge MISSED poison_at={poison_at} this round (n_step_fail={n_step_fail}).")
            # full audit: recompute EVERY step -> the forgery MUST be found somewhere (guaranteed)
            full_fail = 0
            for idx in range(n):
                pre = genesis_state if idx == 0 else post[idx - 1]
                if state_ser(step(pre, ctx_of(idx), tgt_of(idx), 1)) != state_ser(post[idx]):
                    full_fail += 1
            print(f"full-audit recompute mismatches = {full_fail} (guaranteed third-party fraud-proof)")
            if full_fail >= 1:
                print("PASS (falsifier, full audit): the forgery is opened by the guaranteed full re-run "
                      "even when this round's sampling missed it.")
                sys.exit(0)
            fail("forged transcript passed even the full audit -- soundness broken")


if __name__ == "__main__":
    main()
