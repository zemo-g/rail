#!/usr/bin/env python3
"""
harvest_filter_report.py — Build HARVEST_FILTER_REPORT.md from TSV logs.

Called from flywheel/harvest_filter.rail after the Rail scoring loop
writes /tmp/rail_hf_prep/{keeps,drops}.tsv.

Reads:
  /tmp/rail_hf_prep/keeps.tsv  rows: idx\tdecls\tq\tchars
  /tmp/rail_hf_prep/drops.tsv  rows: idx\tdecls\tq\tchars\tfirst_line
  /tmp/rail_hf_prep/stats.tsv  from prep stage
  training/self_train/harvest_clean_v2.jsonl  (for the line count)

Writes:
  training/self_train/HARVEST_FILTER_REPORT.md
"""
import os

PREP = "/tmp/rail_hf_prep"
V2 = "training/self_train/harvest_clean_v2.jsonl"
REPORT = "training/self_train/HARVEST_FILTER_REPORT.md"


def read_tsv(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [line.rstrip("\n").split("\t") for line in f if line.strip()]


def read_stats():
    d = {}
    for r in read_tsv(f"{PREP}/stats.tsv"):
        if len(r) >= 2:
            d[r[0]] = int(r[1])
    return d


def q_scores(rows):
    out = []
    for r in rows:
        try:
            out.append(int(r[2]))
        except Exception:
            pass
    return sorted(out)


def pct(xs, p):
    if not xs:
        return 0
    i = int(len(xs) * p)
    if i >= len(xs):
        i = len(xs) - 1
    return xs[i]


def median(xs):
    return pct(xs, 0.5)


def evenly_sample(rows, n):
    if not rows or n <= 0:
        return []
    step = max(1, len(rows) // n)
    out = []
    i = 0
    while i < len(rows) and len(out) < n:
        out.append(rows[i])
        i += step
    return out


def read_content(idx):
    p = f"{PREP}/content_{idx}.txt"
    try:
        with open(p) as f:
            return f.read()
    except FileNotFoundError:
        return "(content file missing)"


def fence(s, cap=600):
    s = s if len(s) <= cap else s[:cap] + "\n...[truncated]"
    return "```rail\n" + s + "\n```"


def main():
    stats = read_stats()
    keeps = read_tsv(f"{PREP}/keeps.tsv")
    drops = read_tsv(f"{PREP}/drops.tsv")

    ks = q_scores(keeps)

    v2_lines = 0
    if os.path.exists(V2):
        with open(V2) as f:
            v2_lines = sum(1 for _ in f)

    kept_sample = evenly_sample(keeps, 5)
    dropped_sample = evenly_sample(drops, 5)

    lines = []

    def p(s=""):
        lines.append(s)

    p("# Harvest filter — rebuild report")
    p()
    p("**Date:** 2026-04-20")
    p("**Source:** flywheel/harvest_filter.rail")
    p("**Backup:** training/self_train/harvest.jsonl.pre_filter_2026_04_20")
    p()
    p("## Pipeline")
    p()
    p("1. Back up `harvest.jsonl` (cp -n — idempotent).")
    p("2. Python SHA-256 dedupe by assistant content "
      "(mirrors `flywheel/dataset.rail`).")
    p("3. Rail scoring per unique item: "
      "`count_top_level_decls >= 1` AND `oracle_quality > 0` "
      "(both from `stdlib/oracle.rail` — Stream 2's tightened thresholds).")
    p("4. Survivors appended to "
      "`training/self_train/harvest_clean_v2.jsonl`.")
    p()
    p("## Counts")
    p()
    p("| Stage                               | Count |")
    p("|-------------------------------------|-------|")
    p(f"| Raw harvest.jsonl lines             | {stats.get('total_in', 0)} |")
    p(f"| Skipped malformed JSON              | {stats.get('skipped_malformed', 0)} |")
    p(f"| Skipped empty content               | {stats.get('skipped_empty', 0)} |")
    p(f"| Skipped duplicate content (SHA)     | {stats.get('skipped_dupe', 0)} |")
    p(f"| Unique entering oracle gate         | {stats.get('unique', 0)} |")
    p(f"| Survivors (decls>=1 & q>0)          | {len(keeps)} |")
    p(f"| Dropped by oracle gate              | {len(drops)} |")
    p(f"| Lines in harvest_clean_v2.jsonl     | {v2_lines} |")
    p()
    p("## oracle_quality distribution (survivors)")
    p()
    p("| Stat   | Value |")
    p("|--------|-------|")
    p(f"| min    | {ks[0] if ks else 0} |")
    p(f"| median | {median(ks)} |")
    p(f"| p90    | {pct(ks, 0.9)} |")
    p(f"| max    | {ks[-1] if ks else 0} |")
    p()
    p("## Sample: 5 kept (evenly spaced through keeps.tsv)")
    p()
    for r in kept_sample:
        if len(r) < 4:
            continue
        idx, decls, q, clen = r[:4]
        p(f"### keep #{idx}  —  decls={decls}  q={q}  chars={clen}")
        p(fence(read_content(idx)))
        p()
    p("## Sample: 5 dropped (evenly spaced through drops.tsv)")
    p()
    for r in dropped_sample:
        if len(r) < 4:
            continue
        idx, decls, q, clen = r[:4]
        p(f"### drop #{idx}  —  decls={decls}  q={q}  chars={clen}")
        p(fence(read_content(idx)))
        p()

    with open(REPORT, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"report written: {REPORT}")


if __name__ == "__main__":
    main()
