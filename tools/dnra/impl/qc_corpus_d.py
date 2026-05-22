#!/usr/bin/env python3
"""Quality-control gate for the Deductive panelist training corpus.

Enforces the three discipline rules from FINETUNE_DEDUCTIVE Section 2.5:
  1. Every target cites a section number (Cite: ... line OR section
     substring in prose).
  2. <= 2 pairs per source document.
  3. ~half of pairs invert the obvious answer (>= 40% floor).

Plus sanity checks that catch the most common curator failures:
  - duplicate id
  - duplicate prompt
  - target too short (< 200 chars typically signals a one-line answer
    with no derivation - which is what we DO NOT want)
  - missing 'Cite:' marker (the convention used in the spec sample pairs)

Usage:
    python3 tools/dnra/impl/qc_corpus_d.py [path/to/corpus_d_v0a.jsonl]
    (defaults to tools/dnra/sets/corpus_d_v0a.jsonl)

Exit code 0 if corpus passes; non-zero otherwise (per-rule details to stdout).
"""

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

DEFAULT_PATH = Path("tools/dnra/sets/corpus_d_v0a.jsonl")
MIN_TARGET_CHARS = 200
SOURCE_DOC_LIMIT = 2
INVERT_FLOOR = 0.40
INVERT_TARGET = 0.50


def load(path: Path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            out.append(json.loads(line))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path", nargs="?", default=str(DEFAULT_PATH))
    args = ap.parse_args()

    path = Path(args.path)
    if not path.exists():
        print(f"ERROR: corpus missing at {path}", file=sys.stderr)
        return 3

    pairs = load(path)
    if not pairs:
        print(f"ERROR: corpus at {path} is empty", file=sys.stderr)
        return 3
    print(f"loaded {len(pairs)} pairs from {path}")
    print()

    failures = []

    # ── Rule 1: every target cites the section number ─────────────
    for p in pairs:
        first_chunk = p["section"].split(";")[0].strip()
        if first_chunk not in p["target"]:
            failures.append(
                f"  [R1 cite] {p['id']}: section '{first_chunk}' not in target"
            )

    # Spec convention: every target ends with a 'Cite:' line.  Enforced
    # because the LoRA template is learning to emit that exact marker.
    for p in pairs:
        if "Cite:" not in p["target"]:
            failures.append(f"  [R1 cite] {p['id']}: target missing 'Cite:' marker")

    # ── Rule 2: <= 2 pairs per source document ────────────────────
    src_counts = Counter(p["source"] for p in pairs)
    for src, n in src_counts.items():
        if n > SOURCE_DOC_LIMIT:
            failures.append(
                f"  [R2 breadth] source '{src}' has {n} pairs (limit {SOURCE_DOC_LIMIT})"
            )

    # ── Rule 3: polarity balance ─────────────────────────────────
    pol_counts = Counter(p["polarity"] for p in pairs)
    invert_n = pol_counts.get("invert", 0)
    invert_pct = invert_n / len(pairs)
    if invert_pct < INVERT_FLOOR:
        failures.append(
            f"  [R3 polarity] inverted {invert_n}/{len(pairs)} ({invert_pct:.0%}) "
            f"below floor {INVERT_FLOOR:.0%}"
        )

    # ── Sanity: duplicate ids ────────────────────────────────────
    id_counts = Counter(p["id"] for p in pairs)
    for pid, n in id_counts.items():
        if n > 1:
            failures.append(f"  [sanity] duplicate id '{pid}' ({n} occurrences)")

    # ── Sanity: duplicate prompts ────────────────────────────────
    prompt_counts = Counter(p["prompt"] for p in pairs)
    for prom, n in prompt_counts.items():
        if n > 1:
            failures.append(f"  [sanity] duplicate prompt occurs {n} times: {prom[:80]}...")

    # ── Sanity: target length ────────────────────────────────────
    for p in pairs:
        if len(p["target"]) < MIN_TARGET_CHARS:
            failures.append(
                f"  [sanity] {p['id']}: target len {len(p['target'])} < "
                f"{MIN_TARGET_CHARS}; probably missing derivation"
            )

    # ── Report ───────────────────────────────────────────────────
    print("Per-source counts:")
    for src, n in sorted(src_counts.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"  {n}  {src}")
    print()
    print("Polarity distribution:")
    for pol, n in sorted(pol_counts.items()):
        print(f"  {n}  {pol} ({n/len(pairs):.0%})")
    print()
    print(f"Target length: min={min(len(p['target']) for p in pairs)}  "
          f"max={max(len(p['target']) for p in pairs)}  "
          f"mean={sum(len(p['target']) for p in pairs)//len(pairs)}")
    print()

    if failures:
        print(f"==== {len(failures)} FAIL ====")
        for f in failures:
            print(f)
        return 1
    if invert_pct < INVERT_TARGET:
        print(f"==== PASS (invert {invert_pct:.0%} >= {INVERT_FLOOR:.0%} floor; "
              f"below {INVERT_TARGET:.0%} target; add more inversions in next batch) ====")
    else:
        print(f"==== PASS (invert {invert_pct:.0%} >= {INVERT_TARGET:.0%} target) ====")
    return 0


if __name__ == "__main__":
    sys.exit(main())
