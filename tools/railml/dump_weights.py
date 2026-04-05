#!/usr/bin/env python3
"""dump_weights.py — Dump PyTorch model weights to Rail binary format.

Output format:
  Header: [n_layers:i32] [d_model:i32] [n_heads:i32] [vocab_size:i32]
  Per weight: [name_len:i32] [name:bytes] [ndim:i32] [shape:i32s] [data:f64s]

Usage:
  python3 dump_weights.py <checkpoint.pt> <output.bin>
  python3 dump_weights.py --tiny <output.bin>   # create tiny test model
"""
import struct, sys, os

def write_i32(f, v):
    f.write(struct.pack('<i', v))

def write_f64(f, v):
    f.write(struct.pack('<d', float(v)))

def dump_tiny_model(path):
    """Create a tiny 6-layer 64-dim model with random weights for testing."""
    import random
    random.seed(42)

    n_layers, d_model, n_heads, vocab_size = 6, 64, 4, 256
    head_dim = d_model // n_heads
    d_ff = d_model * 4

    weights = []

    # Embedding
    weights.append(("tok_emb.weight", [vocab_size, d_model]))

    # Per layer
    for i in range(n_layers):
        p = f"blocks.{i}"
        weights.append((f"{p}.ln1.weight", [d_model]))
        weights.append((f"{p}.ln1.bias", [d_model]))
        weights.append((f"{p}.attn.q_proj.weight", [d_model, d_model]))
        weights.append((f"{p}.attn.k_proj.weight", [d_model, d_model]))
        weights.append((f"{p}.attn.v_proj.weight", [d_model, d_model]))
        weights.append((f"{p}.attn.o_proj.weight", [d_model, d_model]))
        weights.append((f"{p}.ln2.weight", [d_model]))
        weights.append((f"{p}.ln2.bias", [d_model]))
        weights.append((f"{p}.ffn.w_gate.weight", [d_ff, d_model]))
        weights.append((f"{p}.ffn.w_up.weight", [d_ff, d_model]))
        weights.append((f"{p}.ffn.w_down.weight", [d_model, d_ff]))

    # Final norm + head
    weights.append(("ln_f.weight", [d_model]))
    weights.append(("ln_f.bias", [d_model]))
    weights.append(("lm_head.weight", [vocab_size, d_model]))

    total_params = sum(1 for _ in weights for _ in range(
        1 if len(weights[0]) == 1 else 0))  # placeholder

    with open(path, 'wb') as f:
        # Header
        write_i32(f, n_layers)
        write_i32(f, d_model)
        write_i32(f, n_heads)
        write_i32(f, vocab_size)

        total = 0
        for name, shape in weights:
            name_bytes = name.encode('utf-8')
            write_i32(f, len(name_bytes))
            f.write(name_bytes)
            write_i32(f, len(shape))
            for s in shape:
                write_i32(f, s)
            n_elements = 1
            for s in shape:
                n_elements *= s
            # Xavier-ish init: random uniform [-scale, scale]
            scale = (2.0 / (shape[0] + (shape[1] if len(shape) > 1 else shape[0]))) ** 0.5
            for _ in range(n_elements):
                write_f64(f, (random.random() * 2 - 1) * scale)
            total += n_elements

    size_mb = os.path.getsize(path) / 1024 / 1024
    print(f"Dumped tiny model: {n_layers}L/{d_model}d/{n_heads}h/{vocab_size}v")
    print(f"  {len(weights)} weight tensors, {total:,} params ({total*8/1024/1024:.1f}MB f64)")
    print(f"  File: {path} ({size_mb:.1f}MB)")

def dump_checkpoint(ckpt_path, out_path):
    """Dump a real PyTorch checkpoint."""
    import torch
    ckpt = torch.load(ckpt_path, map_location='cpu', weights_only=False)
    config = ckpt.get('config', {})
    sd = ckpt['model']

    n_layers = config.get('n_layers', 6)
    d_model = config.get('d_model', 64)
    n_heads = config.get('n_heads', 4)
    vocab_size = config.get('vocab_size', 256)

    # Skip non-parameter entries
    skip = {'rope_cos', 'rope_sin', 'causal_mask'}

    with open(out_path, 'wb') as f:
        write_i32(f, n_layers)
        write_i32(f, d_model)
        write_i32(f, n_heads)
        write_i32(f, vocab_size)

        total = 0
        for name, tensor in sd.items():
            if name in skip:
                continue
            name_bytes = name.encode('utf-8')
            write_i32(f, len(name_bytes))
            f.write(name_bytes)
            shape = list(tensor.shape)
            write_i32(f, len(shape))
            for s in shape:
                write_i32(f, s)
            data = tensor.float().numpy().flatten()
            for v in data:
                write_f64(f, v)
            total += len(data)
            print(f"  {name}: {shape} ({len(data):,} params)")

    size_mb = os.path.getsize(out_path) / 1024 / 1024
    print(f"\nDumped: {total:,} params ({size_mb:.1f}MB) → {out_path}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: dump_weights.py <checkpoint.pt|--tiny> <output.bin>")
        sys.exit(1)
    if sys.argv[1] == "--tiny":
        dump_tiny_model(sys.argv[2])
    else:
        dump_checkpoint(sys.argv[1], sys.argv[2])
