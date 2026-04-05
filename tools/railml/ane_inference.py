#!/usr/bin/env python3
"""Load rustane checkpoint, run inference, generate Rail code.
Bridge between ANE training and the Rail compiler oracle."""
import struct, sys, os, math, random

def load_checkpoint(path):
    """Load RSTK checkpoint → config + weight dict."""
    with open(path, "rb") as f:
        magic = f.read(4)
        assert magic == b"RSTK", f"Bad magic: {magic}"
        version = struct.unpack("<I", f.read(4))[0]
        step = struct.unpack("<I", f.read(4))[0]
        dim = struct.unpack("<I", f.read(4))[0]
        nlayers = struct.unpack("<I", f.read(4))[0]
        vocab = struct.unpack("<I", f.read(4))[0]
        seq = struct.unpack("<I", f.read(4))[0]
        
        config = {"dim": dim, "nlayers": nlayers, "vocab": vocab, "seq": seq,
                  "step": step, "version": version}
        
        # Rest is f32 weights
        rest = f.read()
        n_floats = len(rest) // 4
        weights = struct.unpack(f"<{n_floats}f", rest)
        
    print(f"Loaded step {step}: dim={dim} layers={nlayers} vocab={vocab} seq={seq}")
    print(f"  {n_floats:,} weights ({len(rest)/1024/1024:.1f}MB)")
    return config, weights

def softmax(logits):
    mx = max(logits)
    exps = [math.exp(x - mx) for x in logits]
    s = sum(exps)
    return [e / s for e in exps]

def sample(probs, temperature=0.8):
    if temperature < 0.01:
        return probs.index(max(probs))
    # Temperature sampling
    logits = [math.log(max(p, 1e-10)) / temperature for p in probs]
    probs = softmax(logits)
    r = random.random()
    cumulative = 0
    for i, p in enumerate(probs):
        cumulative += p
        if r < cumulative:
            return i
    return len(probs) - 1

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: ane_inference.py <checkpoint.bin> [n_tokens] [temperature]")
        sys.exit(1)
    
    ckpt_path = sys.argv[1]
    n_tokens = int(sys.argv[2]) if len(sys.argv) > 2 else 200
    temp = float(sys.argv[3]) if len(sys.argv) > 3 else 0.8
    
    config, weights = load_checkpoint(ckpt_path)
    print(f"  Generating {n_tokens} tokens at temp={temp}")
    print(f"  (Note: full transformer inference TBD — this loads but can't forward yet)")
    print(f"  Checkpoint ready for conversion to MLX/safetensors for GPU inference")
