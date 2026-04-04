#!/usr/bin/env python3
"""Convert PEFT LoRA adapter to MLX-compatible format.

PEFT saves: adapter_model.safetensors with keys like:
  base_model.model.model.layers.26.self_attn.q_proj.lora_A.weight

MLX server needs: adapters.safetensors with keys like:
  layers.26.self_attn.q_proj.lora_A.weight

Also handles the case where our train_cuda.py saves as adapters.safetensors
with PEFT-prefixed keys.

Usage:
  python3 convert_peft_to_mlx.py <input_dir> <output_file>
  python3 convert_peft_to_mlx.py ~/rail_training/adapters_g4_e4b/latest adapters_mlx.safetensors
"""
import sys, os

try:
    from safetensors.torch import load_file, save_file
except ImportError:
    from safetensors import safe_open
    import torch
    def load_file(path):
        result = {}
        with safe_open(path, framework="pt") as f:
            for k in f.keys():
                result[k] = f.get_tensor(k)
        return result
    from safetensors.torch import save_file

def convert(input_dir, output_path):
    # Find the safetensors file
    candidates = ["adapter_model.safetensors", "adapters.safetensors"]
    src = None
    for c in candidates:
        p = os.path.join(input_dir, c)
        if os.path.exists(p):
            src = p
            break
    if not src:
        print(f"No safetensors found in {input_dir}")
        sys.exit(1)

    print(f"Loading {src}...")
    weights = load_file(src)
    print(f"  {len(weights)} tensors")

    # Strip PEFT prefix
    converted = {}
    prefixes_to_strip = [
        "base_model.model.model.",  # PEFT standard
        "base_model.model.",         # PEFT alternate
    ]

    for key, tensor in weights.items():
        new_key = key
        for prefix in prefixes_to_strip:
            if new_key.startswith(prefix):
                new_key = new_key[len(prefix):]
                break
        converted[new_key] = tensor

    # Show sample keys
    sample = list(converted.keys())[:3]
    print(f"  Sample keys: {sample}")
    print(f"  Total params: {sum(t.numel() for t in converted.values()):,}")

    save_file(converted, output_path)
    size_mb = os.path.getsize(output_path) / 1024 / 1024
    print(f"  Saved {output_path} ({size_mb:.1f}MB)")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: convert_peft_to_mlx.py <input_dir> <output_file>")
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
