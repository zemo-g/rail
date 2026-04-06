#!/usr/bin/env python3
"""Build v4 corpus = old curated tokens + Claude-generated programs.

The Claude programs are HIGH QUALITY (compile-verified, varied, multi-function).
We REPEAT them 5x to give them prominence in the loss budget — they're rare
but high-signal.
"""
import json, struct
from pathlib import Path
from tokenizers import Tokenizer

REPO = Path("/Users/ledaticempire/projects/rail")
OLD = REPO / "training" / "railml_data_curated"
CLAUDE_JSONL = REPO / "training" / "claude_rail.jsonl"
OUT = REPO / "training" / "railml_data_v4"
TOK = REPO / "training" / "tokenizer.json"
EOT = 1
REPEAT = 5  # repeat Claude programs to weight them up

OUT.mkdir(parents=True, exist_ok=True)
tok = Tokenizer.from_file(str(TOK))

def load_bin(path):
    with open(path, "rb") as f:
        data = f.read()
    return list(struct.unpack(f"<{len(data)//2}H", data))

# Load old corpus
old_train = load_bin(OLD / "train.bin")
old_val = load_bin(OLD / "val.bin")
print(f"  old train: {len(old_train):,} tokens")

# Load Claude programs
claude_progs = []
with open(CLAUDE_JSONL) as f:
    for line in f:
        try:
            obj = json.loads(line)
            if "source" in obj:
                claude_progs.append(obj["source"])
        except json.JSONDecodeError:
            pass
print(f"  claude programs: {len(claude_progs)}")

# Tokenize Claude programs once
claude_tokens = []
for p in claude_progs:
    claude_tokens.extend(tok.encode(p).ids)
    claude_tokens.append(EOT)
print(f"  claude tokens (1x): {len(claude_tokens):,}")

# Hold out 5% of Claude programs for val
n_val = max(1, len(claude_progs) // 20)
val_progs = claude_progs[-n_val:]
train_progs = claude_progs[:-n_val] if n_val > 0 else claude_progs

# Build claude train tokens with repeat
claude_train = []
for _ in range(REPEAT):
    for p in train_progs:
        claude_train.extend(tok.encode(p).ids)
        claude_train.append(EOT)

claude_val = []
for p in val_progs:
    claude_val.extend(tok.encode(p).ids)
    claude_val.append(EOT)

# Combined
combined_train = old_train + claude_train
combined_val = old_val + claude_val

print(f"  claude train (×{REPEAT}): {len(claude_train):,}")
print(f"  claude val: {len(claude_val):,}")
print(f"  combined train: {len(combined_train):,} ({len(combined_train)*2/1e6:.1f}MB)")
print(f"  combined val:   {len(combined_val):,}")
print(f"  expansion: {len(combined_train) / len(old_train):.2f}x")

with open(OUT / "train.bin", "wb") as f:
    f.write(struct.pack(f"<{len(combined_train)}H", *combined_train))
with open(OUT / "val.bin", "wb") as f:
    f.write(struct.pack(f"<{len(combined_val)}H", *combined_val))
print(f"\n  saved → {OUT}")
