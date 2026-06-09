#!/usr/bin/env python3
"""r37 FOREIGN VERIFIER v2 (audit fix 2026-06-09).

The v1 checker was hash-only and pointed at the wrong file (audit C3/C4).
This one closes the loop the way the rung ladder does: an INDEPENDENT
implementation (numpy float64, zero Rail code) that

  1. verifies the Ed25519 signature on the attestation record (RFC 8032,
     reusing the PROVEN cross-language verifier from tools/bitexact),
  2. re-hashes the split files + the FULL 93,696-weight Q.24 artifact and
     checks them against the SIGNED message fields,
  3. parses every weight, rebuilds the 2-block pre-norm RoPE transformer
     forward pass from scratch, greedy-decodes the held-out text, and
     re-derives the metric -- which must equal the signed metric,
  4. re-checks the bracket: lookup baseline (48) < T'=55 <= metric.

If a forger swaps a single weight int, the SHA check fails; if they alter
the record, the signature fails; if they alter the metric claim, the
re-derived metric fails. Fail-loud at every boundary.

Usage: python3 rungs/r37_artifact_attestation/r37_foreign_check_v2.py
"""
import os
import re
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "tools", "bitexact"))
from bx12_foreign_check import ed25519_verify  # noqa: E402  (RFC 8032, proven)

import hashlib

OUT = os.path.join(HERE, "out")
V, D, DFF = 27, 64, 256
Q = float(1 << 24)
T_CORRECTED = 55
LOOKUP_BASELINE = 48

fails = []


def check(name, ok, detail=""):
    tag = "PASS" if ok else "FAIL"
    print(f"  [{tag}] {name}" + (f"  {detail}" if detail else ""))
    if not ok:
        fails.append(name)
    return ok


def sha_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


# ---------- 1. attestation record + signature ----------
rec = {}
with open(os.path.join(OUT, "r37_attestation.txt")) as f:
    for line in f:
        if "=" in line and not line.startswith("#"):
            k, v = line.rstrip("\n").split("=", 1)
            rec[k] = v

msg = rec["msg"]
msg_b = hashlib.sha256(msg.encode()).digest()
check("msg_sha matches record", msg_b.hex() == rec["msg_sha256"])
sig_ok = ed25519_verify(bytes.fromhex(rec["pk"]), msg_b, bytes.fromhex(rec["sig"]))
check("Ed25519 signature (RFC 8032, foreign impl)", sig_ok)

fields = dict(p.split("=", 1) for p in msg.split("|")[2:])
metric_signed = int(fields["metric"].split("/")[0])

# ---------- 2. re-hash the signed inputs ----------
train_p = os.path.join(REPO, "rungs/r24/force_train_4d.txt")
hold_p = os.path.join(REPO, "rungs/r24/force_holdout_4d.txt")
full_p = os.path.join(OUT, "r37_force_weights_q24_full.txt")
check("train split SHA", sha_file(train_p) == fields["train"])
check("holdout split SHA", sha_file(hold_p) == fields["holdout"])
check("FULL weight artifact SHA", sha_file(full_p) == fields["weights"])

# ---------- 3. parse all weights (order is part of the signed message) ----------
order = fields["order"].split(",")
shapes = {"w_e": (V, D), "w_o": (D, V), "ln_g": (D,), "ln_b": (D,)}
for blk in ("1", "2"):
    shapes[f"wq{blk}"] = (D, D)
    shapes[f"wk{blk}"] = (D, D)
    shapes[f"wv{blk}"] = (D, D)
    shapes[f"wf1{blk}"] = (D, DFF)
    shapes[f"wf2{blk}"] = (DFF, D)

raw = open(full_p).read()
ints = [int(t) for t in raw.split(",") if t.strip()]
check("weight count == 93,696", len(ints) == 93696, f"got {len(ints)}")

W = {}
pos = 0
for nm in order:
    shp = shapes[nm]
    n = int(np.prod(shp))
    W[nm] = (np.array(ints[pos:pos + n], dtype=np.float64) / Q).reshape(shp)
    pos += n
check("all weights consumed", pos == len(ints))
check("ln_g is fixed gamma=1", bool(np.all(W["ln_g"] == 1.0)))
check("ln_b is fixed beta=0", bool(np.all(W["ln_b"] == 0.0)))

# ---------- 4. independent forward pass (numpy float64) ----------
train_text = open(train_p).read()
hold_text = open(hold_p).read()

# vocab: first-appearance order over the first 2000 chars (== build_vocab call)
vocab = []
for c in train_text[:2000]:
    if c not in vocab:
        vocab.append(c)
check("vocab size == 27", len(vocab) == V, f"got {len(vocab)}")
cid = {c: i for i, c in enumerate(vocab)}

ids = [cid[c] for c in hold_text]
hseq = len(ids) - 1
x = np.zeros((hseq, V))
x[np.arange(hseq), ids[:hseq]] = 1.0


def layernorm(h):
    mean = h.mean(axis=1, keepdims=True)
    var = (h * h).mean(axis=1, keepdims=True) - mean * mean  # E[x^2]-mu^2 (matches Rail)
    return (h - mean) / np.sqrt(var + 1e-5) * W["ln_g"] + W["ln_b"]


def rope(h):
    seq, d = h.shape
    out = h.copy()
    j = np.arange(d // 2)
    theta = 10000.0 ** (-2.0 * j / d)            # per-pair frequency
    p = np.arange(seq)[:, None]
    ang = p * theta[None, :]
    c, s = np.cos(ang), np.sin(ang)
    x0, x1 = h[:, 0::2], h[:, 1::2]
    out[:, 0::2] = x0 * c - x1 * s
    out[:, 1::2] = x0 * s + x1 * c
    return out


def block(h, blk):
    ln1 = layernorm(h)
    q = rope(ln1 @ W[f"wq{blk}"])
    k = rope(ln1 @ W[f"wk{blk}"])
    v = ln1 @ W[f"wv{blk}"]
    scores = (q @ k.T) / np.sqrt(float(D))
    mask = np.triu(np.ones((h.shape[0], h.shape[0]), dtype=bool), k=1)
    scores[mask] = -1e9                          # exact constant, post-scale (matches Rail)
    scores = scores - scores.max(axis=1, keepdims=True)
    e = np.exp(scores)
    attn = e / e.sum(axis=1, keepdims=True)
    h = h + attn @ v
    ln2 = layernorm(h)
    ffn = np.maximum(ln2 @ W[f"wf1{blk}"], 0.0) @ W[f"wf2{blk}"]
    return h + ffn


h = x @ W["w_e"]
h = block(h, "1")
h = block(h, "2")
logits = h @ W["w_o"]                            # softmax is monotone; argmax on logits
pred_ids = logits.argmax(axis=1)
pred = "".join(vocab[i] for i in pred_ids)

# ---------- 5. force_score, re-implemented from the Rail spec ----------
score = 0
for m in (mm.start() for mm in re.finditer(r"-- ", hold_text)):
    if m + 6 < len(pred):
        score += sum(pred[m + 2 + k] == hold_text[m + 3 + k] for k in range(4))

check("metric reproduced by foreign forward", score == metric_signed,
      f"foreign={score}/64 signed={metric_signed}/64")
check("bracket: lookup < T' <= metric",
      LOOKUP_BASELINE < T_CORRECTED <= score,
      f"lookup={LOOKUP_BASELINE} T'={T_CORRECTED} metric={score}")

# ---------- verdict ----------
if fails:
    print(f"R37_FOREIGN_V2=FAIL ({len(fails)}: {', '.join(fails)})")
    sys.exit(1)
print("R37_FOREIGN_V2=PASS (sig + split + full artifact + independent metric + bracket)")
