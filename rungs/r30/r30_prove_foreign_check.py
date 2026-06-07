#!/usr/bin/env python3
# =====================================================================================
# RUNG 30 (r30_prove) -- FOREIGN re-verifier of the lm10-BOUND succinct spot-check.
# =====================================================================================
# An INDEPENDENT party, in a DIFFERENT LANGUAGE (Python), re-derives the entire
# CRYPTOGRAPHIC succinct-proof envelope that rungs/r30/r30_prove.rail signed over the
# REAL lm10 trajectory, reading only:
#   - the signed transcript  rungs/r30/out/r30_prove_transcript.txt
#   - the persisted per-step states  rungs/r30/out/lm_states/<i>.wp  + <i>.pw
#   - the training corpus  tools/bitexact/lm10_corpus.txt
#
# It independently checks ALL of:
#   1. the corpus pin (sha256(corpus) == transcript corpus_sha) -> same (ctx,tgt) pairs;
#   2. reconstructs every per-step LEAF (LEAF|gstep|ctx_ids.|tgt|<.wp bytes>|pow1|pow2),
#      builds the Merkle tree (DUPLICATE-LAST), and reproduces the signed root;
#   3. recomputes the chain head (sha256 over genesis|root|steps|corpus) == transcript;
#   4. verifies the Ed25519 signature over the head under the ledger pubkey;
#   5. re-derives the Fiat-Shamir challenges off (root, chain_head) == transcript;
#   6. verifies each challenged leaf's Merkle path to the signed root;
#   7. FALSIFIER: tampering one persisted state flips its leaf -> the recomputed root
#      no longer matches the signed root (rejected).
#
# SCOPE (honest): this proves the cryptographic binding of the persisted trajectory in
# a second language. It does NOT recompute the transformer TRANSITION
# (state[i] == lm4_step(state[i-1], pair[i])) -- that bit-exact check is the Rail
# self-gate's job (r30_prove.rail), proven against the broader bit-exact ladder. A full
# Python port of lm4_step would let the foreign party also re-run the transitions; that
# is the remaining follow-up.
#
# Usage:  python3 rungs/r30/r30_prove_foreign_check.py
#   exit 0 + "R30-PROVE-FOREIGN PASS" iff the whole envelope reproduces + falsifier fires.
# =====================================================================================
import sys, os, hashlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TRANSCRIPT = os.path.join(ROOT, "rungs/r30/out/r30_prove_transcript.txt")
STATES = os.path.join(ROOT, "rungs/r30/out/lm_states")
CORPUS = os.path.join(ROOT, "tools/bitexact/lm10_corpus.txt")


def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def head48(hexstr: str) -> int:
    # first 12 hex nibbles -> 48-bit value (matches Rail r_head48: base-16 Horner)
    v = 0
    for c in hexstr[:12]:
        v = v * 16 + int(c, 16)
    return v


def pair_up(nodes):
    # DUPLICATE-LAST: a lone odd node is hashed with ITSELF (matches the fixed Rail
    # p_pair_up, consistent with p_proof_lv's self-hash for out-of-range siblings).
    out, i = [], 0
    while i < len(nodes):
        if i + 1 >= len(nodes):
            out.append(sha256_hex(f"NODE|{nodes[i]}|{nodes[i]}"))
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


def proof_of(levels, idx):
    path = []
    for lvl in range(len(levels) - 1):
        nodes = levels[lvl]
        isright = idx % 2
        sib_i = idx - 1 if isright == 1 else idx + 1
        sib = nodes[idx] if sib_i >= len(nodes) else nodes[sib_i]
        side = 0 if isright == 1 else 1
        path.append((sib, side))
        idx //= 2
    return path


def path_fold(leaf, path):
    cur = leaf
    for sib, side in path:
        cur = sha256_hex(f"NODE|{sib}|{cur}") if side == 0 else sha256_hex(f"NODE|{cur}|{sib}")
    return cur


def challenges(root, chain_head, k, n):
    return [head48(sha256_hex(f"{root}|{chain_head}|CHAL|{j}")) % n for j in range(k)]


def ed25519_verify(pk_hex, msg_bytes, sig_hex):
    pk, sig = bytes.fromhex(pk_hex), bytes.fromhex(sig_hex)
    try:
        from nacl.signing import VerifyKey  # type: ignore
        VerifyKey(pk).verify(msg_bytes, sig)
        return True
    except ImportError:
        return _ed25519_verify_pure(pk, msg_bytes, sig)
    except Exception:
        return False


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
    B = [xrecover(By) % p, By % p]

    def edwards(P, Q):
        x1, y1 = P; x2, y2 = Q
        x3 = (x1 * y2 + x2 * y1) * pow(1 + d * x1 * x2 * y1 * y2, p - 2, p)
        y3 = (y1 * y2 + x1 * x2) * pow(1 - d * x1 * x2 * y1 * y2, p - 2, p)
        return [x3 % p, y3 % p]

    def scalarmult(P, e):
        if e == 0:
            return [0, 1]
        Q = scalarmult(P, e // 2); Q = edwards(Q, Q)
        return edwards(Q, P) if e & 1 else Q

    if len(signature) != 64 or len(public) != 32:
        return False
    try:
        def decodepoint(s):
            y = int.from_bytes(s, "little") & ((1 << 255) - 1)
            x = xrecover(y)
            if x & 1 != (int.from_bytes(s, "little") >> 255):
                x = p - x
            return [x, y]
        R, A = decodepoint(signature[:32]), decodepoint(public)
    except Exception:
        return False
    S_ = int.from_bytes(signature[32:], "little")
    h = int.from_bytes(hashlib.sha512(signature[:32] + public + msg).digest(), "little") % L
    v1 = scalarmult(B, S_)
    v2 = edwards(R, scalarmult(A, h))
    return v1[0] % p == v2[0] % p and v1[1] % p == v2[1] % p


def fail(msg):
    print(f"R30-PROVE-FOREIGN FAIL: {msg}")
    sys.exit(1)


def read_kv(path):
    kv = {}
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("#") or "=" not in line:
            continue
        # the config line "d=8 hidden=64 ..." packs several k=v on one line
        for tok in line.split(" "):
            if "=" in tok:
                k, v = tok.split("=", 1)
                kv[k] = v
    return kv


def leaf_of(i, ctx, tgt, wp_bytes, pow1, pow2):
    ctx_ser = "".join(f"{c}." for c in ctx)  # r30lm_ctx_ser: "id0.id1.....idN."
    return sha256_hex(f"LEAF|{i}|{ctx_ser}|{tgt}|{wp_bytes}|{pow1}|{pow2}")


def main():
    if not os.path.exists(TRANSCRIPT):
        fail(f"no transcript at {TRANSCRIPT} (run rungs/r30/out/r30_prove_bin first)")
    kv = read_kv(TRANSCRIPT)
    pk = kv["pk"]; genesis = kv["genesis"]; corpus_sha = kv["corpus_sha"]
    cwin = int(kv["cwin"]); nsteps = int(kv["nsteps"]); k = int(kv["k"])
    root_t = kv["root"]; chain_head_t = kv["chain_head"]; head_sig = kv["head_sig"]
    chals_t = [int(x) for x in kv["challenges"].split(".") if x != ""]

    # 1. corpus pin -> reconstruct the (ctx,tgt) pairs exactly as Rail did
    corpus_bytes = open(CORPUS, "rb").read()
    if sha256_hex(corpus_bytes.decode("utf-8")) != corpus_sha:
        fail("corpus sha mismatch (foreign read != committed corpus_sha)")
    text = corpus_bytes.decode("utf-8")
    vocab = []
    for ch in text:
        if ch not in vocab:
            vocab.append(ch)
    ids = [vocab.index(ch) for ch in text]
    pairs = [(ids[i:i + cwin], ids[i + cwin]) for i in range(len(ids) - cwin)]
    npairs = len(pairs)
    if npairs == 0:
        fail("no training pairs reconstructed")

    # 2. reconstruct every leaf from the persisted states + Merkle root
    leaves = []
    for i in range(nsteps):
        wp = open(os.path.join(STATES, f"{i}.wp"), encoding="utf-8").read()
        pwline = open(os.path.join(STATES, f"{i}.pw"), encoding="utf-8").read().strip()
        pow1, pow2 = pwline.split(" ")
        ctx, tgt = pairs[i % npairs]
        leaves.append(leaf_of(i, ctx, tgt, wp, pow1, pow2))
    levels = levels_of(leaves)
    root_r = levels[-1][0]
    if root_r != root_t:
        fail(f"Merkle root mismatch: recomputed {root_r[:16]} != signed {root_t[:16]}")

    # 3. recompute the chain head
    head_pre = f"{genesis}|R30LM|root={root_t}|steps={nsteps}|corpus={corpus_sha}"
    head_b = hashlib.sha256(head_pre.encode("utf-8")).digest()
    chain_head_r = head_b.hex()
    if chain_head_r != chain_head_t:
        fail(f"chain head mismatch: {chain_head_r[:16]} != {chain_head_t[:16]}")

    # 4. Ed25519 signature over the head
    sig_ok = ed25519_verify(pk, head_b, head_sig)
    if not sig_ok:
        fail("Ed25519 signature over the chain head does NOT verify")

    # 5. re-derive the Fiat-Shamir challenges
    chals_r = challenges(root_t, chain_head_t, k, nsteps)
    if chals_r != chals_t:
        fail(f"FS challenges mismatch: recomputed {chals_r} != transcript {chals_t}")

    # 6. verify each challenged leaf's Merkle path
    for idx in chals_t:
        if path_fold(leaves[idx], proof_of(levels, idx)) != root_t:
            fail(f"Merkle path for challenged step {idx} does NOT reach the signed root")

    # 7. FALSIFIER: tamper one persisted state -> its leaf flips -> root diverges
    fidx = chals_t[0]
    tampered = list(leaves)
    wp = open(os.path.join(STATES, f"{fidx}.wp"), encoding="utf-8").read()
    ctx, tgt = pairs[fidx % npairs]
    pw = open(os.path.join(STATES, f"{fidx}.pw"), encoding="utf-8").read().strip().split(" ")
    tampered[fidx] = leaf_of(fidx, ctx, tgt, "9" + wp, pw[0], pw[1])  # one byte changed
    if levels_of(tampered)[-1][0] == root_t:
        fail("FALSIFIER did NOT fire: tampered state still produced the signed root")

    print("================ R30-PROVE FOREIGN RE-VERIFIER (independent Python) ================")
    print(f"steps={nsteps}  challenges(k={k})={chals_t}")
    print(f"corpus pin reproduced           = True  (sha256(corpus) == committed)")
    print(f"Merkle root reproduced          = True  ({root_r[:24]}...)")
    print(f"chain head reproduced           = True  ({chain_head_r[:24]}...)")
    print(f"Ed25519 head signature verifies = True")
    print(f"Fiat-Shamir challenges re-derived= True  (k={k} of {nsteps}, sublinear)")
    print(f"all challenged Merkle paths      = True")
    print(f"falsifier (tampered state caught)= True")
    print("R30-PROVE-FOREIGN PASS: an independent Python implementation reproduced the signed")
    print("Merkle commitment over the REAL lm10 trajectory, re-derived the FS challenges, verified")
    print("the Ed25519 signature, and confirmed every challenged path -- the whole succinct-proof")
    print("envelope, in a different language. (Transition recompute = the Rail self-gate.)")
    sys.exit(0)


if __name__ == "__main__":
    main()
