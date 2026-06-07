#!/usr/bin/env python3
# RUNG 36 FOREIGN (cross-language) re-verifier -- Bounded Recursive Self-Improvement.
#
# A SEPARATE IMPLEMENTATION IN A DIFFERENT LANGUAGE (Python big-integers) that independently
# re-derives the ENTIRE r36 RSI admission chain from the signed ledger and confirms, bit-for-bit:
#
#   * the FROZEN GATE record's signature verifies under the pinned pubkey, and its message is
#     H(prev | "GATE" | np | cap | margin_rule | "FUTUREPULSE" | commit_pulse_id) -- the gate M0
#     committed BEFORE M1 existed;
#   * each generation's training TRAJECTORY (exact-integer Adam-cell steps) re-runs, the Merkle root
#     re-derives, the rung-30 Fiat-Shamir challenges re-derive from the chain head, and the k<<N
#     challenged steps recompute consistently (succinct spot-check -- verify sublinear in N);
#   * each generation's held-out METRIC re-derives from the CERTIFIED final bias-power pow2 against
#     the FUTURE-pulse-seeded probe bands -- a quantity neither M0 nor M1 could overfit in advance;
#   * the acceptance MARGIN re-derives from the FUTURE pulse (id strictly > the gate-commit pulse),
#     and each admitted successor strictly beats its parent by >= that margin;
#   * the bounded monotone generation counter and chain-prev hold;
#   * every GEN record's Ed25519 signature verifies under the pinned pubkey;
#   * a FORGED successor (tampered trajectory) is independently caught by the full-audit spot-check;
#   * tampering the ledger (flip a metric, a margin, a sig byte) makes the verifier REJECT.
#
# This is the second of the "two independent witnesses": the Rail self-witness re-derives in-process;
# this party re-derives the SAME admission decisions in another language from only the signed ledger.
#
# LOCAL/DEV keys only (mirrors the trainer); never a prod / Pi-witness sign surface.
#
# Usage: python3 rungs/r36/r36_foreign_check.py [rungs/r36/out/r36_chain.txt]

import sys
import os
import hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BITEXACT = os.path.join(REPO, "tools", "bitexact")
sys.path.insert(0, BITEXACT)

# reuse the PROVEN cross-language crypto primitives (RFC 8032 Ed25519 + SHA-256), unchanged
from bx12_foreign_check import sha256_hex, ed25519_verify  # noqa: E402

# ---------- exact-integer transition constants (== r36_rsi_protocol.rail, byte-identical) ----------
S = 16777216
B1 = 15099494
B2 = 16760439
LR = 209715
EPS = 16777
GCLIP = 33554432
CONV_UNIT = 500000
BAND_MOD = 30


def tdiv(a, b):
    # Rail's exact-integer division == C truncate-toward-zero. Python // floors, so adjust for signs.
    q = a // b
    if (a % b != 0) and ((a < 0) != (b < 0)):
        q += 1
    return q


def r_abs(x):
    return -x if x < 0 else x


def r_grad(theta, ctx, tgt):
    return (tdiv(theta, 2048) + (ctx - tgt) * 65536) - tdiv(theta * 3, 1024)


def r_clip(g, clip_on):
    if clip_on == 0:
        return g
    if g > GCLIP:
        return GCLIP
    if g < -GCLIP:
        return -GCLIP
    return g


def r_isqrt(x):
    if x <= 0:
        return 0
    g = x + 1
    for _ in range(24):
        if g == 0:
            return 0
        g = tdiv(g + tdiv(x, g), 2)
    return g


def r30_step(state, ctx, tgt, clip_on):
    theta, m, v, pow1, pow2 = state
    g = r_clip(r_grad(theta, ctx, tgt), clip_on)
    nm = tdiv(m * B1 + g * (S - B1), S)
    nv = tdiv(v * B2 + tdiv(g * g, S) * (S - B2), S)
    np1 = tdiv(pow1 * B1, S)
    np2 = tdiv(pow2 * B2, S)
    bc1 = S - np1
    bc2 = S - np2
    mhat = tdiv(nm * S, bc1)
    vhat = tdiv(nv * S, bc2)
    denom = r_isqrt(vhat * S) + EPS
    upd = tdiv(LR * mhat, denom)
    nth = theta - upd
    return [nth, nm, nv, np1, np2]


def state_ser(st):
    return ",".join(str(x) for x in st)


# ---------- (ctx,tgt) schedule (== r30_ctx / r30_tgt with genseed) ----------
def r30_ctx(genseed, i):
    z = genseed + i * 7 + 3
    return z - tdiv(z, 17) * 17


def r30_tgt(genseed, i):
    z = genseed + i * 13 + 5
    return z - tdiv(z, 17) * 17


# ---------- Merkle DAG (== r30_leaf / r30_levels / r30_proof / r30_verify_path) ----------
def r30_leaf(i, ctx, tgt, st):
    return sha256_hex(f"LEAF|{i}|{ctx}|{tgt}|{state_ser(st)}")


def r30_pair_up(nodes):
    out = []
    j = 0
    n = len(nodes)
    while j < n:
        if j + 1 >= n:
            out.append(nodes[j])  # odd tail promotes (== Rail r30_pair_up)
            j += 1
        else:
            out.append(sha256_hex(f"NODE|{nodes[j]}|{nodes[j+1]}"))
            j += 2
    return out


def r30_levels(leaves):
    if not leaves:
        return [[sha256_hex("EMPTY")]]
    levels = [leaves]
    cur = leaves
    while len(cur) > 1:
        cur = r30_pair_up(cur)
        levels.append(cur)
    return levels


def r30_proof(levels, idx):
    path = []
    for lvl in range(len(levels) - 1):
        nodes = levels[lvl]
        isright = idx % 2
        sib_i = idx - 1 if isright == 1 else idx + 1
        sib = nodes[idx] if sib_i >= len(nodes) else nodes[sib_i]
        side = 0 if isright == 1 else 1  # 0 = sibling LEFT, 1 = sibling RIGHT
        path.append((sib, side))
        idx = idx // 2
    return path


def r30_verify_path(leaf, path, root):
    cur = leaf
    for sib, side in path:
        if side == 0:
            cur = sha256_hex(f"NODE|{sib}|{cur}")
        else:
            cur = sha256_hex(f"NODE|{cur}|{sib}")
    return cur == root


# ---------- Fiat-Shamir challenge derivation (== r30_chal, NO PRNG) ----------
def head48(s):
    return int(s[0:12], 16)


def r30_chal(root, chain_head, j, n):
    h = sha256_hex(f"{root}|{chain_head}|CHAL|{j}")
    return head48(h) % n


def r30_chal_list(root, chain_head, k, n):
    return [r30_chal(root, chain_head, j, n) for j in range(k)]


# ---------- run a generation's trajectory (== r36_run / r36_states) ----------
def gen_run(genseed, n, clip_on, poison_at):
    state = [0, 0, 0, S, S]
    states = []
    leaves = []
    for i in range(n):
        ctx = r30_ctx(genseed, i)
        tgt = r30_tgt(genseed, i)
        truepost = r30_step(state, ctx, tgt, clip_on)
        if i == poison_at:
            committed = [truepost[0], truepost[1], truepost[2] + 1, truepost[3], truepost[4]]
        else:
            committed = truepost
        leaves.append(r30_leaf(i, ctx, tgt, committed))
        states.append(committed)
        state = committed
    return state, states, leaves


# ---------- the rung-30 succinct spot-check (== r36_verify_chals) ----------
def spot_check(genseed, states, levels, root, chals):
    genesis_state = [0, 0, 0, S, S]
    ok = 1
    for idx in chals:
        pre = genesis_state if idx == 0 else states[idx - 1]
        ctx = r30_ctx(genseed, idx)
        tgt = r30_tgt(genseed, idx)
        recomputed = r30_step(pre, ctx, tgt, 1)
        committed = states[idx]
        step_ok = 1 if state_ser(recomputed) == state_ser(committed) else 0
        leaf = r30_leaf(idx, ctx, tgt, committed)
        path = r30_proof(levels, idx)
        merkle_ok = 1 if r30_verify_path(leaf, path, root) else 0
        ok = ok * step_ok * merkle_ok
    return ok


# ---------- the held-out metric (== r36_conv_level / r36_probe_band / r36_metric) ----------
def firstbyte(hexs):
    return int(hexs[0:2], 16)


def conv_level(finalpow2):
    c = tdiv(S - finalpow2, CONV_UNIT)
    if c < 0:
        return 0
    if c > 32:
        return 32
    return c


def probe_band(pulse_hex, j):
    b = firstbyte(sha256_hex(f"{pulse_hex}|PROBE_BAND|{j}"))
    return b % BAND_MOD


def metric(finalpow2, pulse_hex, np):
    conv = conv_level(finalpow2)
    return sum(1 for j in range(np) if conv >= probe_band(pulse_hex, j))


# ---------- the margin rule (== r36_derive_margin) ----------
def derive_margin(future_pulse_hex):
    fb = firstbyte(future_pulse_hex)
    return (fb % 2) + 1


# ---------- a full generation record: chain head + metric + spot-check (== r36_generation) ----------
def generation(genseed, n, k, prev_hex, pulse_hex, np, gen_idx, clip_on, poison_at):
    final_state, states, leaves = gen_run(genseed, n, clip_on, poison_at)
    final_pow2 = final_state[4]
    levels = r30_levels(leaves)
    root = levels[-1][0]
    met = metric(final_pow2, pulse_hex, np)
    link_str = f"{prev_hex}|GEN|{gen_idx}|{n}|{root}|metric={met}"
    chain_head = hashlib.sha256(link_str.encode()).hexdigest()
    chals = r30_chal_list(root, chain_head, k, n)
    spot_ok = spot_check(genseed, states, levels, root, chals)
    return {
        "final_pow2": final_pow2, "metric": met, "root": root, "chain_head": chain_head,
        "n": n, "k": k, "spot_ok": spot_ok, "link_b": hashlib.sha256(link_str.encode()).digest(),
        "states": states, "levels": levels,
    }


def parse_header(hdr_tokens):
    kv = {}
    for tok in hdr_tokens:
        if "=" in tok:
            key, val = tok.split("=", 1)
            kv[key] = val
    return kv


def fail(msg):
    print("R36-FOREIGN FAIL: " + msg)
    sys.exit(1)


def main():
    ledger = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "rungs/r36/out/r36_chain.txt")
    with open(ledger) as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    if not lines or not lines[0].startswith("# R36v1"):
        fail("missing/malformed ledger header")

    hdr = lines[0].split()
    pk_hex = hdr[2]
    gate_head_recorded = hdr[3]
    kv = parse_header(hdr)
    np = int(kv["np"]); cap = int(kv["cap"])
    margin_rule = kv["margin_rule"]
    commit_pulse_id = kv["commit_pulse_id"]
    m0_pulse_hex = kv["m0_pulse_hex"]
    future_pulse_id = kv["future_pulse_id"]
    future_pulse_hex = kv["future_pulse_hex"]
    future_pulse_hex2 = kv["future_pulse_hex2"]
    gate_sig_hex = kv["gate_sig"]
    pub = bytes.fromhex(pk_hex)

    # ---- 1. re-derive + verify the FROZEN GATE (committed by M0 before any successor existed) ----
    gate_link_str = (f"R36.GENESIS.dev|GATE|np={np}|cap={cap}|margin_rule={margin_rule}"
                     f"|FUTUREPULSE|commit_pulse_id={commit_pulse_id}")
    gate_link_b = hashlib.sha256(gate_link_str.encode()).digest()
    gate_head = gate_link_b.hex()
    if gate_head != gate_head_recorded:
        fail("gate head does not re-derive (gate message tampered)")
    if not ed25519_verify(pub, gate_link_b, bytes.fromhex(gate_sig_hex)):
        fail("FROZEN GATE signature does not verify under the pinned pubkey")
    if margin_rule != "first_byte_mod_2_plus_1":
        fail(f"unexpected margin_rule {margin_rule} (would change the frozen bar)")

    # ---- 2. the future pulse must be POSTERIOR to the gate-commit pulse (unforeseeable-in-advance) ----
    if not (int(future_pulse_id) > int(commit_pulse_id)):
        fail("future pulse id is NOT strictly greater than the gate-commit pulse id")
    margin1 = derive_margin(future_pulse_hex)
    margin2 = derive_margin(future_pulse_hex2)

    # ---- 3. re-derive every generation independently ----
    m0_genseed = firstbyte(m0_pulse_hex)
    gen_rows = [ln.split() for ln in lines[1:] if ln.startswith("GEN ")]
    if len(gen_rows) != 3:
        fail(f"expected 3 GEN records, found {len(gen_rows)}")

    # GEN 0 (M0 baseline): seeded by m0 pulse, scored on the FUTURE pulse for the comparison
    n0 = int(gen_rows[0][2]); k0 = 24
    g0 = generation(m0_genseed, n0, k0, gate_head, m0_pulse_hex, np, 0, 1, -1)
    metric0_future = metric(g0["final_pow2"], future_pulse_hex, np)

    n1 = int(gen_rows[1][2]); k1 = 46
    g1 = generation(m0_genseed, n1, k1, g0["chain_head"], future_pulse_hex, np, 1, 1, -1)

    n2 = int(gen_rows[2][2]); k2 = 90
    g2 = generation(m0_genseed, n2, k2, g1["chain_head"], future_pulse_hex2, np, 2, 1, -1)
    metric1_future2 = metric(g1["final_pow2"], future_pulse_hex2, np)

    # ---- 4. each GEN record's chain head + signature must re-derive/verify ----
    # ledger GEN row tokens: [GEN, idx, n, root, metric, metric_other, prev, head, sig]
    #                          0    1    2  3     4       5             6     7     8
    for tag, g, row in (("GEN0", g0, gen_rows[0]), ("GEN1", g1, gen_rows[1]), ("GEN2", g2, gen_rows[2])):
        if g["root"] != row[3]:
            fail(f"{tag} Merkle root does not re-derive (committed trajectory tampered)")
        # the COMMITTED metric (token[4]) must equal the metric we INDEPENDENTLY recompute from the
        # certified trajectory -- closes proxy-gaming: a bumped committed holdout that the model did
        # not actually earn is caught here (independent recompute != committed claim).
        if int(row[4]) != g["metric"]:
            fail(f"{tag} committed metric {row[4]} != independently recomputed metric {g['metric']} "
                 f"(proxy-gaming / claimed-improvement-not-earned)")
        if g["chain_head"] != row[7]:
            fail(f"{tag} chain head does not re-derive (committed root/metric tampered)")
        if not ed25519_verify(pub, g["link_b"], bytes.fromhex(row[8])):
            fail(f"{tag} signature does not verify under the pinned pubkey")
        if g["spot_ok"] != 1:
            fail(f"{tag} rung-30 succinct spot-check FAILED (trajectory inconsistent)")

    # ---- 5. the ADMISSION RULE re-checked independently for each successor ----
    # ADMIT M1 over M0: child.prev (gen_rows[1][6]) must equal parent.head (g0.chain_head)
    a1_improve = g1["metric"] >= (metric0_future + margin1)
    a1_counter = (1 == 0 + 1) and (1 <= cap)
    a1_chainprev = (gen_rows[1][6] == g0["chain_head"])
    if not a1_improve:
        fail(f"M1 does NOT beat M0 by the future-pulse margin ({g1['metric']} < {metric0_future}+{margin1})")
    if not (a1_counter and a1_chainprev and g1["spot_ok"] == 1):
        fail("M1 admission clauses (counter/chainprev/spot) do not hold")

    # ADMIT M2 over M1: child.prev (gen_rows[2][6]) must equal parent.head (g1.chain_head)
    a2_improve = g2["metric"] >= (metric1_future2 + margin2)
    a2_counter = (2 == 1 + 1) and (2 <= cap)
    a2_chainprev = (gen_rows[2][6] == g1["chain_head"])
    if not a2_improve:
        fail(f"M2 does NOT beat M1 by the future-pulse margin ({g2['metric']} < {metric1_future2}+{margin2})")
    if not (a2_counter and a2_chainprev and g2["spot_ok"] == 1):
        fail("M2 admission clauses (counter/chainprev/spot) do not hold")

    # ---- 6. monotone + bounded ----
    if not (g1["metric"] > metric0_future and g2["metric"] > metric1_future2):
        fail("held-out metric is not strictly monotone across the generation chain")
    if not (2 <= cap):
        fail("generation chain exceeded the committed cap")

    # ---- 7. independent falsifier: a FORGED (poisoned) trajectory must be caught by the full audit ----
    poison_at = (n1 // 2) + 1
    fstate, fstates, fleaves = gen_run(m0_genseed, n1, 1, poison_at)
    flevels = r30_levels(fleaves)
    froot = flevels[-1][0]
    full_audit = spot_check(m0_genseed, fstates, flevels, froot, list(range(n1)))
    if full_audit != 0:
        fail("a poisoned trajectory was NOT caught by the full audit (spot-check is cosmetic)")

    print("================ RUNG 36 FOREIGN RE-VERIFICATION (different language) ================")
    print(f"pinned pubkey                      = {pk_hex}")
    print(f"FROZEN GATE sig verifies           = True   (np={np} cap={cap} rule={margin_rule})")
    print(f"future pulse posterior to commit   = True   (id {future_pulse_id} > {commit_pulse_id}) "
          f"-> margins {margin1}/{margin2}")
    print(f"GEN0 held-out metric (future)      = {metric0_future}  spot_ok={g0['spot_ok']}")
    print(f"GEN1 held-out metric (future)      = {g1['metric']}  spot_ok={g1['spot_ok']}  "
          f"(spot-checked {k1}/{n1} steps)")
    print(f"GEN2 held-out metric (future2)     = {g2['metric']}  spot_ok={g2['spot_ok']}")
    print(f"all 4 signatures (GATE+3 GEN)      = verify under pinned pubkey")
    print(f"ADMIT M1 over M0                    = True   ({g1['metric']} >= {metric0_future}+{margin1})")
    print(f"ADMIT M2 over M1                    = True   ({g2['metric']} >= {metric1_future2}+{margin2})")
    print(f"monotone + bounded (<= cap {cap})       = True")
    print(f"forged trajectory caught (audit)   = True")
    print("R36-FOREIGN PASS: an independent language re-derived the entire RSI admission chain from "
          "the signed ledger -- the frozen gate, the future-pulse margins, each generation's succinct "
          "spot-check, the monotone held-out improvement, the bounded counter, and all four signatures "
          "-- and independently caught a forged trajectory. The successor was admitted ONLY because it "
          "genuinely, verifiably improved under a bar it could not foresee or relax.")
    sys.exit(0)


if __name__ == "__main__":
    main()
