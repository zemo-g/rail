#!/usr/bin/env python3
"""Convert the curated Deductive corpus into mlx_lm.lora-ready train/valid/test.

mlx_lm.lora expects a directory containing train.jsonl + valid.jsonl
(and optionally test.jsonl).  Each file is JSONL where each record is
{"text": "<single combined prompt+target string in chat-template form>"}.

We use the Llama 3.2 / Llama 3.1 chat template directly so the LoRA learns
the exact format it will encounter at inference time:

    <|begin_of_text|><|start_header_id|>user<|end_header_id|>

    {prompt}<|eot_id|><|start_header_id|>assistant<|end_header_id|>

    {target}<|eot_id|>

Split 80/10/10 with a fixed seed so the splits are stable across runs (the
edit-distance pre-gate uses the same prompts as both base and trained-D
probes; reproducibility matters more than randomness here).

Usage:
    python3 tools/dnra/impl/corpus_to_mlx.py
        [--in tools/dnra/sets/corpus_d_v0a.jsonl]
        [--out tools/dnra/sets/lora_d_v0a/]
        [--seed 42]
"""

import argparse
import json
import random
import sys
from pathlib import Path

CHAT_TEMPLATE = (
    "<|begin_of_text|>"
    "<|start_header_id|>user<|end_header_id|>\n\n"
    "{prompt}<|eot_id|>"
    "<|start_header_id|>assistant<|end_header_id|>\n\n"
    "{target}<|eot_id|>"
)

DEFAULT_IN = Path("tools/dnra/sets/corpus_d_v0a.jsonl")
DEFAULT_OUT = Path("tools/dnra/sets/lora_d_v0a/")


def load(path: Path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            out.append(json.loads(line))
    return out


def split(pairs, train_frac=0.80, valid_frac=0.10, seed=42):
    """Stable shuffle + 80/10/10 split.  Last bucket absorbs the remainder."""
    pairs = list(pairs)
    rng = random.Random(seed)
    rng.shuffle(pairs)
    n = len(pairs)
    n_train = int(n * train_frac)
    n_valid = max(1, int(n * valid_frac))
    n_test = max(1, n - n_train - n_valid)
    # Re-balance so we never leave train empty on tiny corpora.
    if n_train + n_valid + n_test > n:
        n_train = n - n_valid - n_test
    train = pairs[:n_train]
    valid = pairs[n_train:n_train + n_valid]
    test = pairs[n_train + n_valid:]
    return train, valid, test


def write_split(records, out_path: Path):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        for r in records:
            text = CHAT_TEMPLATE.format(prompt=r["prompt"], target=r["target"])
            f.write(json.dumps({"text": text}, separators=(",", ":")) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="in_path", default=str(DEFAULT_IN))
    ap.add_argument("--out", dest="out_dir", default=str(DEFAULT_OUT))
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    in_path = Path(args.in_path)
    out_dir = Path(args.out_dir)
    if not in_path.exists():
        print(f"ERROR: corpus not found at {in_path}", file=sys.stderr)
        return 1

    pairs = load(in_path)
    train, valid, test = split(pairs, seed=args.seed)
    print(f"loaded {len(pairs)} pairs; split {len(train)} train / {len(valid)} valid / {len(test)} test")

    write_split(train, out_dir / "train.jsonl")
    write_split(valid, out_dir / "valid.jsonl")
    write_split(test, out_dir / "test.jsonl")
    print(f"wrote {out_dir}/{{train,valid,test}}.jsonl")
    print(f"  chat template: Llama 3.2 (begin_of_text + start_header_id user/assistant + eot_id)")
    print()
    print("LoRA kickoff (per FINETUNE_DEDUCTIVE.md section 7):")
    print(
        f"  /opt/homebrew/bin/python3.11 -m mlx_lm lora --train \\\n"
        f"      --model mlx-community/Llama-3.2-1B-Instruct-4bit \\\n"
        f"      --data {out_dir} \\\n"
        f"      --iters 1500 --batch-size 4 \\\n"
        f"      --lora-rank 16 --lora-alpha 32 \\\n"
        f"      --learning-rate 1e-4 \\\n"
        f"      --adapter-path ~/projects/rail-training/adapters/d_v0a_smoke/"
    )
    print()
    print(
        "NOTE: v0.a is 19 pairs -- this configuration is a SMOKE TEST of the "
        "LoRA pipeline, NOT the production run.  Real run needs 1,500-3,000 "
        "pairs per spec.  Expected smoke outcome: minimal style shift, "
        "likely INCONCLUSIVE / MODE COLLAPSE on the edit-distance gate -- "
        "that is fine; it proves the loop closes."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
