#!/usr/bin/env python3
"""Independent float32 reference for SmolLM2-135M (LlamaForCausalLM), numpy only.

It shares no code with the Rail engine: it reads the public bf16 safetensors itself,
widens bf16 to f32 exactly (a 16-bit shift), and runs the textbook Llama forward
(RMSNorm, rotate-half RoPE with theta 1e5, grouped-query attention 9/3, SwiGLU, tied
embeddings). The Rail engine is judged against it on greedy tokens and on logit
closeness; bit equality with numpy is NOT claimed (different summation orders).

  ref.py tokenize "<text>"            -> ids, one line
  ref.py greedy <ids-file> N          -> N greedy token ids, one line
  ref.py logits <ids-file> <out.npy>  -> float32 logits for every row
  ref.py decode <ids-file>            -> text
"""
import json
import os
import struct
import sys

import numpy as np

SNAP = os.environ.get("SMOL_SNAP") or os.path.expanduser(
    "~/.cache/huggingface/hub/models--HuggingFaceTB--SmolLM2-135M/snapshots")
if os.path.isdir(SNAP) and not os.path.exists(os.path.join(SNAP, "config.json")):
    SNAP = os.path.join(SNAP, min(os.listdir(SNAP)))

D, H, KVH, HD, FF, L, V, EPS, THETA = 576, 9, 3, 64, 1536, 30, 49152, 1e-5, 100000.0


def load():
    path = os.path.join(SNAP, "model.safetensors")
    raw = np.fromfile(path, dtype=np.uint8)
    n = struct.unpack("<Q", raw[:8].tobytes())[0]
    hdr = json.loads(raw[8:8 + n].tobytes())
    base = 8 + n
    w = {}
    for k, v in hdr.items():
        if k == "__metadata__":
            continue
        s, e = v["data_offsets"]
        bits = raw[base + s:base + e].view(np.uint16).astype(np.uint32) << 16
        w[k] = bits.view(np.float32).reshape(v["shape"])
    return w


def rms(x, g):
    return (x * (1.0 / np.sqrt((x * x).mean(-1, keepdims=True) + EPS))) * g


def rope(x, pos):
    inv = 1.0 / (THETA ** (np.arange(0, HD, 2, dtype=np.float64) / HD))
    ang = pos[:, None].astype(np.float64) * inv[None, :]
    c = np.cos(ang).astype(np.float32)
    s = np.sin(ang).astype(np.float32)
    x1, x2 = x[..., :HD // 2], x[..., HD // 2:]
    return np.concatenate([x1 * c[:, None, :] - x2 * s[:, None, :],
                           x2 * c[:, None, :] + x1 * s[:, None, :]], axis=-1)


def forward(w, ids):
    T = len(ids)
    pos = np.arange(T)
    x = w["model.embed_tokens.weight"][np.array(ids)]
    mask = np.triu(np.full((T, T), -np.inf, dtype=np.float32), 1)
    for li in range(L):
        p = f"model.layers.{li}."
        h = rms(x, w[p + "input_layernorm.weight"])
        q = (h @ w[p + "self_attn.q_proj.weight"].T).reshape(T, H, HD)
        k = (h @ w[p + "self_attn.k_proj.weight"].T).reshape(T, KVH, HD)
        v = (h @ w[p + "self_attn.v_proj.weight"].T).reshape(T, KVH, HD)
        q, k = rope(q, pos), rope(k, pos)
        k = np.repeat(k, H // KVH, axis=1)
        v = np.repeat(v, H // KVH, axis=1)
        sc = np.einsum("thd,shd->hts", q, k) * np.float32(0.125) + mask
        sc = sc - sc.max(-1, keepdims=True)
        pr = np.exp(sc)
        pr = pr / pr.sum(-1, keepdims=True)
        a = np.einsum("hts,shd->thd", pr, v).reshape(T, D)
        x = x + a @ w[p + "self_attn.o_proj.weight"].T
        h = rms(x, w[p + "post_attention_layernorm.weight"])
        g = h @ w[p + "mlp.gate_proj.weight"].T
        u = h @ w[p + "mlp.up_proj.weight"].T
        x = x + ((g / (1.0 + np.exp(-g))) * u) @ w[p + "mlp.down_proj.weight"].T
    return rms(x, w["model.norm.weight"]) @ w["model.embed_tokens.weight"].T


def read_ids(path):
    return [int(t) for t in open(path).read().split()]


def tok():
    from tokenizers import Tokenizer
    return Tokenizer.from_file(os.path.join(SNAP, "tokenizer.json"))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "tokenize":
        print(" ".join(str(i) for i in tok().encode(sys.argv[2]).ids))
    elif cmd == "decode":
        print(tok().decode(read_ids(sys.argv[2])))
    elif cmd == "greedy":
        w = load()
        ids = read_ids(sys.argv[2])
        out = []
        for _ in range(int(sys.argv[3])):
            nxt = int(np.argmax(forward(w, ids + out)[-1]))
            out.append(nxt)
        print(" ".join(str(i) for i in out))
    elif cmd == "logits":
        w = load()
        np.save(sys.argv[3], forward(w, read_ids(sys.argv[2])).astype(np.float32))
    else:
        sys.exit(__doc__)
