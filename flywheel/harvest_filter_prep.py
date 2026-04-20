#!/usr/bin/env python3
"""
harvest_filter_prep.py — Parse harvest.jsonl, SHA-256 dedupe, extract.

Called from flywheel/harvest_filter.rail. Writes:
  /tmp/rail_hf_prep/manifest.tsv   (idx\tsha256 — one row per unique item)
  /tmp/rail_hf_prep/content_<i>.txt (assistant content)
  /tmp/rail_hf_prep/line_<i>.jsonl  (original full JSONL line)
  /tmp/rail_hf_prep/stats.tsv       (input counters)

Mirrors the SHA-256 dedup pattern in flywheel/dataset.rail — key is
the assistant content, not the whole JSONL line, so whitespace /
system-prompt tweaks don't fool the dedup.
"""
import json
import hashlib
import os

HARVEST = "training/self_train/harvest.jsonl"
PREP = "/tmp/rail_hf_prep"


def main():
    os.makedirs(PREP, exist_ok=True)
    # Purge any prior prep run so idx accounting stays consistent.
    for f in os.listdir(PREP):
        os.remove(os.path.join(PREP, f))

    seen = set()
    idx = 0
    total_in = 0
    skipped_malformed = 0
    skipped_empty = 0
    skipped_dupe = 0

    with open(os.path.join(PREP, "manifest.tsv"), "w") as manifest, \
         open(HARVEST) as f:
        for raw in f:
            raw = raw.rstrip("\n")
            if not raw.strip():
                continue
            total_in += 1
            try:
                obj = json.loads(raw)
            except Exception:
                skipped_malformed += 1
                continue
            content = ""
            for m in obj.get("messages", []):
                if m.get("role") == "assistant":
                    content = m.get("content", "")
            if not content.strip():
                skipped_empty += 1
                continue
            h = hashlib.sha256(content.encode()).hexdigest()
            if h in seen:
                skipped_dupe += 1
                continue
            seen.add(h)
            with open(f"{PREP}/content_{idx}.txt", "w") as g:
                g.write(content)
            with open(f"{PREP}/line_{idx}.jsonl", "w") as g:
                g.write(raw + "\n")
            manifest.write(f"{idx}\t{h}\n")
            idx += 1

    with open(f"{PREP}/stats.tsv", "w") as g:
        g.write(f"total_in\t{total_in}\n")
        g.write(f"unique\t{idx}\n")
        g.write(f"skipped_malformed\t{skipped_malformed}\n")
        g.write(f"skipped_empty\t{skipped_empty}\n")
        g.write(f"skipped_dupe\t{skipped_dupe}\n")

    print(
        f"prep ok: total_in={total_in} unique={idx} "
        f"malformed={skipped_malformed} empty={skipped_empty} dupe={skipped_dupe}"
    )


if __name__ == "__main__":
    main()
