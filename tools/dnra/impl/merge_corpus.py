#!/usr/bin/env python3
"""Merge all verified corpus_d_*.jsonl files into one canonical file.

Walks tools/dnra/sets/ for corpus_d_*.jsonl, concatenates with stable
de-duplication (key = (source, section, polarity)), assigns fresh
sequential ids of the form D-NNNN, and writes
tools/dnra/sets/corpus_d_canonical.jsonl.

Also reports per-source-family + per-polarity counts so we can see at
a glance how the corpus is balanced.
"""
import argparse
import json
from collections import Counter
from pathlib import Path

SETS_DIR = Path("tools/dnra/sets")
DEFAULT_OUT = SETS_DIR / "corpus_d_canonical.jsonl"
GLOB = "corpus_d_v*_verified.jsonl"


def load_jsonl(path: Path):
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
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    ap.add_argument("--include-v0a", action="store_true",
                    help="Include the hand-curated v0.a slice (has 3 known FAILs; off by default).")
    args = ap.parse_args()

    files = sorted(SETS_DIR.glob(GLOB))
    if args.include_v0a:
        files = [SETS_DIR / "corpus_d_v0a.jsonl"] + files
    print(f"merging {len(files)} input files:")
    for f in files:
        print(f"  - {f}")

    seen = {}
    order = []
    for f in files:
        for p in load_jsonl(f):
            key = (p.get("source", ""), p.get("section", ""), p.get("polarity", ""))
            if key in seen:
                continue
            seen[key] = p
            order.append(key)

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        for i, key in enumerate(order, start=1):
            p = dict(seen[key])
            p["id"] = f"D-{i:04d}"
            f.write(json.dumps(p, separators=(",", ":")) + "\n")
    print(f"\nwrote {len(order)} unique pairs to {out_path}")

    # Reporting
    src_family = Counter()
    polarity = Counter()
    for key in order:
        src, _sec, pol = key
        fam = "RFC" if src.startswith("RFC") else ("POSIX" if src.startswith("POSIX") else "OTHER")
        src_family[fam] += 1
        polarity[pol] += 1
    print("\nby source family:")
    for k, n in sorted(src_family.items()):
        print(f"  {k:<8} {n}")
    print("\nby polarity:")
    for k, n in sorted(polarity.items()):
        print(f"  {k:<8} {n}")


if __name__ == "__main__":
    main()
