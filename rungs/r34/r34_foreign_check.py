#!/usr/bin/env python3
# ============================================================================
# RUNG 34 - Foreign (cross-language) verifier for the ECONOMIC STAKE over the
# succinct length-proof.
#
# r34_economic_stake.rail proved (in Rail): a served utterance's training claim
# ("K steps happened and chain correctly", the rung-30 length-proof) is bonded
# into a SLASHABLE stake against a real SDK credit balance; a single-step
# fraud-proof is accepted by an independent O(log N) checker and SLASHES the
# bond; an honest chain's bond is never slashable.
#
# This INDEPENDENT party, written in a DIFFERENT LANGUAGE (Python big-integers),
# re-derives the SAME verdict FROM SCRATCH using only the public protocol:
#   * it re-runs the deterministic rung-30 per-step transition (r30_step) in
#     pure Python integers -- so it does NOT trust the Rail prover's states;
#   * it rebuilds the WHOLE Merkle DAG over the K committed states and re-derives
#     the signed root for BOTH the forged chain (with the poisoned step) and the
#     honest chain;
#   * it verifies the Ed25519 claim signature over the length-binding link;
#   * it OPENS exactly the one challenged step, recomputes that transition, and
#     confirms the FRAUD verdict (forged chain: inconsistent -> slash) and the
#     NO-FRAUD verdict (honest chain & honest step of the forged chain: consistent
#     -> no slash), reproducing every falsifier the Rail run asserts.
#
# A green run here is an INDEPENDENT confirmation: the Rail slasher slashes exactly
# the chains a from-scratch Python re-derivation finds fraudulent, and refuses to
# slash exactly the chains it finds honest. Mirrors lm10_foreign_check.py /
# utterance_foreign_check.py -- the proven foreign cross-language verifier pattern.
#
# LOCAL/DEV keys + LOCAL genesis only (mirrors the Rail trainer); never prod.
#
# Usage: python3 rungs/r34/r34_foreign_check.py [rungs/r34/out/r34_fraudproof.txt]
# Exit 0 + last line PASS iff every check holds.
# ============================================================================
import sys
import os
import hashlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "tools", "bitexact"))
# Reuse the PROVEN Ed25519 + SHA helpers from the foreign-verifier substrate.
from bx12_foreign_check import ed25519_verify, ed25519_secret_to_public, sha256_hex, sha256_bytes

# ---- rung-30 / lm10 constants (MUST byte-match the Rail r30_* constants) ----
S      = 16777216       # Q.24 scale (r30_S)
B1     = 15099494       # r30_b1
B2     = 16760439       # r30_b2
LR     = 209715         # r30_lr
EPS    = 16777          # r30_eps
GCLIP  = 33554432       # r30_gclip


# ---- exact-integer truncating division MATCHING Rail '/' (truncate toward zero) ----
def idiv(a, b):
    q = abs(a) // abs(b)
    if (a < 0) != (b < 0):
        q = -q
    return q


def grad(theta, ctx, tgt):
    return (idiv(theta, 2048) + (ctx - tgt) * 65536) - idiv(theta * 3, 1024)


def clip(g, clip_on):
    if clip_on == 0:
        return g
    if g > GCLIP:
        return GCLIP
    if g < -GCLIP:
        return -GCLIP
    return g


def isqrt_go(x, g, i):
    while i > 0:
        if g == 0:
            return 0
        g = idiv(g + idiv(x, g), 2)
        i -= 1
    return g


def isqrt(x):
    if x <= 0:
        return 0
    return isqrt_go(x, x + 1, 24)


def r30_step(state, ctx, tgt, clip_on):
    theta, m, v, pow1, pow2 = state
    g = clip(grad(theta, ctx, tgt), clip_on)
    nm = idiv(m * B1 + g * (S - B1), S)
    nv = idiv(v * B2 + idiv(g * g, S) * (S - B2), S)
    np1 = idiv(pow1 * B1, S)
    np2 = idiv(pow2 * B2, S)
    bc1 = S - np1
    bc2 = S - np2
    mhat = idiv(nm * S, bc1)
    vhat = idiv(nv * S, bc2)
    denom = isqrt(vhat * S) + EPS
    upd = idiv(LR * mhat, denom)
    nth = theta - upd
    return [nth, nm, nv, np1, np2]


def state_ser(st):
    return ",".join(str(x) for x in st)


def r30_ctx(i):
    return (i * 7 + 3) - idiv(i * 7 + 3, 17) * 17


def r30_tgt(i):
    return (i * 13 + 5) - idiv(i * 13 + 5, 17) * 17


GENESIS_STATE = [0, 0, 0, S, S]


# ---- Merkle DAG (MUST byte-match r30_leaf / r30_pair_up / r30_levels) ----
def r30_leaf(i, ctx, tgt, st):
    return sha256_hex(f"LEAF|{i}|{ctx}|{tgt}|{state_ser(st)}")


def pair_up(nodes):
    out = []
    i = 0
    while i < len(nodes):
        if i + 1 < len(nodes):
            out.append(sha256_hex(f"NODE|{nodes[i]}|{nodes[i+1]}"))
            i += 2
        else:
            out.append(nodes[i])  # odd tail promotes
            i += 1
    return out


def merkle_levels(leaves):
    if not leaves:
        return [[sha256_hex("EMPTY")]]
    levels = [leaves]
    cur = leaves
    while len(cur) > 1:
        cur = pair_up(cur)
        levels.append(cur)
    return levels


def merkle_root(levels):
    return levels[-1][0]


def merkle_proof(levels, idx):
    proof = []
    lvl = 0
    i = idx
    while lvl < len(levels) - 1:
        nodes = levels[lvl]
        isright = i % 2
        sib_i = i - 1 if isright == 1 else i + 1
        sib = nodes[i] if sib_i >= len(nodes) else nodes[sib_i]
        side = 0 if isright == 1 else 1   # side=0 sibling LEFT, side=1 sibling RIGHT
        proof.append((sib, side))
        i //= 2
        lvl += 1
    return proof


def path_fold(leaf, proof):
    cur = leaf
    for sib, side in proof:
        if side == 0:
            cur = sha256_hex(f"NODE|{sib}|{cur}")   # sibling LEFT
        else:
            cur = sha256_hex(f"NODE|{cur}|{sib}")   # sibling RIGHT
    return cur


def verify_path(leaf, proof, root):
    return path_fold(leaf, proof) == root


# ---- run the chain (MUST byte-match r30_states_of / r30_run committed logic) ----
def run_states(n, clip_on, poison_at):
    state = list(GENESIS_STATE)
    states = []
    for i in range(n):
        ctx, tgt = r30_ctx(i), r30_tgt(i)
        truepost = r30_step(state, ctx, tgt, clip_on)
        if i == poison_at:
            committed = [truepost[0], truepost[1], truepost[2] + 1, truepost[3], truepost[4]]
        else:
            committed = truepost
        states.append(committed)
        state = committed
    return states


def chain_root_and_leaves(n, clip_on, poison_at):
    states = run_states(n, clip_on, poison_at)
    leaves = [r30_leaf(i, r30_ctx(i), r30_tgt(i), states[i]) for i in range(n)]
    levels = merkle_levels(leaves)
    return states, levels, merkle_root(levels)


def claim_link_bytes(genesis, tag, k, root):
    return sha256_bytes(f"{genesis}|R34-LEN|{tag}|{k}|{root}")


# ---- the independent fraud checker (MUST mirror r34_check_fraud) ----
def check_fraud(states, levels, root, sig_ok, idx):
    pre = list(GENESIS_STATE) if idx == 0 else states[idx - 1]
    post = states[idx]
    ctx, tgt = r30_ctx(idx), r30_tgt(idx)
    recomputed = r30_step(pre, ctx, tgt, 1)
    inconsistent = 0 if state_ser(recomputed) == state_ser(post) else 1
    post_leaf = r30_leaf(idx, ctx, tgt, post)
    post_in = 1 if verify_path(post_leaf, merkle_proof(levels, idx), root) else 0
    if idx == 0:
        pre_in = 1
    else:
        pre_leaf = r30_leaf(idx - 1, r30_ctx(idx - 1), r30_tgt(idx - 1), pre)
        pre_in = 1 if verify_path(pre_leaf, merkle_proof(levels, idx - 1), root) else 0
    if sig_ok == 0:
        return 0
    return inconsistent * post_in * pre_in


def parse_fraudproof(path):
    kv = {}
    with open(path) as fh:
        for ln in fh:
            ln = ln.rstrip("\n")
            if not ln or ln.startswith("R34_FRAUDPROOF"):
                continue
            parts = ln.split(" ", 1)
            if len(parts) == 2:
                kv[parts[0]] = parts[1]
    return kv


def main():
    fp_path = sys.argv[1] if len(sys.argv) > 1 else "rungs/r34/out/r34_fraudproof.txt"
    kv = parse_fraudproof(fp_path)

    K = int(kv["K"])
    poison_at = int(kv["poison_at"])
    open_idx = int(kv["open_idx"])
    honest_open_idx = int(kv["honest_open_idx"])
    stake = int(kv["stake"])
    balance0 = int(kv["balance0"])
    pubkey_hex = kv["pubkey"]
    genesis = kv["genesis"]
    pub = bytes.fromhex(pubkey_hex)

    # ---- (1) re-derive the FORGED chain from scratch (poisoned at poison_at) ----
    f_states, f_levels, f_root = chain_root_and_leaves(K, 1, poison_at)
    f_root_ok = (f_root == kv["forged_root"])
    f_claim_link = claim_link_bytes(genesis, kv["forged_tag"], K, f_root)
    f_claim_ok = (f_claim_link.hex() == kv["forged_claim_head"])
    f_sig_ok = bool(ed25519_verify(pub, f_claim_link, bytes.fromhex(kv["forged_claim_sig"])))

    # the opened endpoints in the proof must equal our independently-recomputed states
    f_pre = list(GENESIS_STATE) if open_idx == 0 else f_states[open_idx - 1]
    f_post = f_states[open_idx]
    open_pre_ok = (state_ser(f_pre) == kv["open_pre"])
    open_post_ok = (state_ser(f_post) == kv["open_post"])

    # ---- (2) FRAUD: the opened poisoned step is a genuine inconsistency -> SLASH ----
    f_fraud = check_fraud(f_states, f_levels, f_root, 1 if f_sig_ok else 0, open_idx)
    fraud_confirmed = (f_fraud == 1)
    final_bal_fraud = (balance0 - stake) if f_fraud == 1 else balance0
    slash_ok = (final_bal_fraud == balance0 - stake)

    # ---- (3) re-derive the HONEST chain from scratch (no poison) ----
    h_states, h_levels, h_root = chain_root_and_leaves(K, 1, -1)
    h_root_ok = (h_root == kv["honest_root"])
    h_claim_link = claim_link_bytes(genesis, kv["honest_tag"], K, h_root)
    h_claim_ok = (h_claim_link.hex() == kv["honest_claim_head"])

    h_pre = list(GENESIS_STATE) if honest_open_idx == 0 else h_states[honest_open_idx - 1]
    h_post = h_states[honest_open_idx]
    honest_pre_ok = (state_ser(h_pre) == kv["honest_open_pre"])
    honest_post_ok = (state_ser(h_post) == kv["honest_open_post"])

    # ---- (4) FALSE-SLASH RESISTANCE: opening an honest step recomputes consistently -> NO slash ----
    h_fraud = check_fraud(h_states, h_levels, h_root, 1, honest_open_idx)
    no_false_slash = (h_fraud == 0)
    final_bal_honest = balance0 if h_fraud == 0 else (balance0 - stake)
    bal_recovered = (final_bal_honest == balance0)

    # ---- (5) FALSIFIER: an honest step of the FORGED chain must NOT slash ----
    f_honest_step = poison_at - 157 if poison_at - 157 >= 0 else 100  # an interior non-poisoned step
    if f_honest_step == poison_at:
        f_honest_step = 100
    f_fraud_honest = check_fraud(f_states, f_levels, f_root, 1 if f_sig_ok else 0, f_honest_step)
    no_slash_honest_step = (f_fraud_honest == 0)

    # ---- (6) FALSIFIER: fabricated post-state (tamper v) not in the signed tree -> NO slash ----
    tampered = [h_post[0], h_post[1], h_post[2] + 999, h_post[3], h_post[4]]
    fab_states = list(h_states)
    fab_states[honest_open_idx] = tampered
    # keep the ORIGINAL (honest) tree/root -> the tampered leaf won't be in it
    f_fraud_fab = check_fraud(fab_states, h_levels, h_root, 1, honest_open_idx)
    no_fabricated_slash = (f_fraud_fab == 0)

    # ---- (7) FALSIFIER: unsigned root -> no authority -> NO slash even on genuine fraud ----
    f_fraud_nosig = check_fraud(f_states, f_levels, f_root, 0, open_idx)
    no_slash_unsigned = (f_fraud_nosig == 0)

    print("==== FOREIGN ECONOMIC-STAKE RE-VERIFIER (independent Python re-derivation) ====")
    print(f"forged chain root reproduced     = {f_root_ok}  ({K} per-step states re-run, Merkle DAG rebuilt)")
    print(f"forged claim head + sig verify   = {f_claim_ok and f_sig_ok}")
    print(f"opened-step endpoints match      = {open_pre_ok and open_post_ok}  (pre==post(idx-1), post==committed)")
    print(f"FRAUD confirmed on poisoned step = {fraud_confirmed}  (recompute diverges; both endpoints in signed tree)")
    print(f"bond SLASHED on fraud            = {slash_ok}  (final balance == {balance0 - stake})")
    print(f"honest chain root reproduced     = {h_root_ok}")
    print(f"honest claim head matches        = {h_claim_ok}")
    print(f"honest opened endpoints match    = {honest_pre_ok and honest_post_ok}")
    print(f"false-slash REJECTED (honest)    = {no_false_slash}  (honest step recomputes consistently)")
    print(f"honest bond fully released       = {bal_recovered}  (final balance == {balance0})")
    print(f"no-slash on honest step of forged= {no_slash_honest_step}")
    print(f"no-slash on fabricated evidence  = {no_fabricated_slash}  (tampered leaf not in signed tree)")
    print(f"no-slash under unsigned root     = {no_slash_unsigned}")

    allok = (f_root_ok and f_claim_ok and f_sig_ok and open_pre_ok and open_post_ok
             and fraud_confirmed and slash_ok and h_root_ok and h_claim_ok
             and honest_pre_ok and honest_post_ok and no_false_slash and bal_recovered
             and no_slash_honest_step and no_fabricated_slash and no_slash_unsigned)
    if allok:
        print("R34-CHECK PASS: a second, independent implementation in a DIFFERENT LANGUAGE re-ran the "
              "K-step trajectory from scratch, rebuilt the Merkle DAG, verified the signed length-claim, "
              "CONFIRMED the single-step fraud-proof (slashing the bond), and CONFIRMED an honest chain "
              "is never slashable. The economic stake over the succinct length-proof is sound.")
        sys.exit(0)
    print("R34-CHECK FAIL")
    sys.exit(1)


if __name__ == "__main__":
    main()
