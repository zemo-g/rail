#!/usr/bin/env python3
"""DNRA probe edit-distance scorer.

Pairwise normalized Levenshtein edit-distance between two probe response
files. Used for the D-vs-base pre-gate (FINETUNE_DEDUCTIVE Section 4.3)
and -- when three trained panelists exist -- the D-E-A separation test.

Usage:
    python3 tools/dnra/impl/score_probe.py \\
        --a tools/dnra/sets/probe_responses_base.jsonl \\
        --b tools/dnra/sets/probe_responses_d_v0_trained.jsonl

Output (stdout):
    Per-prompt edit-distance table (id, domain, distance).
    Aggregate: mean / median / min / max across the 30 prompts.
    Gate verdict against the 0.25 (collapse) and 0.35 (productive) thresholds.

Exit code: 0 if mean >= 0.35 (productive), 1 if 0.25 <= mean < 0.35
(inconclusive), 2 if mean < 0.25 (mode collapse).

No external deps. Levenshtein hand-rolled to keep this script portable.
"""

import argparse
import json
import statistics
import sys
from pathlib import Path

COLLAPSE_THRESHOLD = 0.25
PRODUCTIVE_THRESHOLD = 0.35


def levenshtein(a: str, b: str) -> int:
    """Iterative Levenshtein with two-row buffer. O(len(a) * len(b)) time, O(min(len)) space."""
    if a == b:
        return 0
    if len(a) < len(b):
        a, b = b, a
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, start=1):
        cur = [i] + [0] * len(b)
        for j, cb in enumerate(b, start=1):
            cost = 0 if ca == cb else 1
            cur[j] = min(
                cur[j - 1] + 1,
                prev[j] + 1,
                prev[j - 1] + cost,
            )
        prev = cur
    return prev[-1]


def normalized_edit_distance(a: str, b: str) -> float:
    """Distance / max(len). Range [0, 1].  0 = identical, 1 = maximally different."""
    if not a and not b:
        return 0.0
    return levenshtein(a, b) / max(len(a), len(b))


def load_responses(path: Path) -> dict[str, dict]:
    """Load a probe_responses_*.jsonl file, keyed by prompt id."""
    out = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            out[rec["id"]] = rec
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True, help="First probe responses JSONL (e.g. base)")
    ap.add_argument("--b", required=True, help="Second probe responses JSONL (e.g. d_v0_trained)")
    ap.add_argument("--quiet", action="store_true", help="Suppress per-prompt table")
    args = ap.parse_args()

    a_path, b_path = Path(args.a), Path(args.b)
    if not a_path.exists() or not b_path.exists():
        print(f"ERROR: input missing ({a_path.exists()=}, {b_path.exists()=})", file=sys.stderr)
        return 3
    a_recs = load_responses(a_path)
    b_recs = load_responses(b_path)
    shared = sorted(set(a_recs) & set(b_recs))
    if not shared:
        print("ERROR: no prompt ids shared between the two files", file=sys.stderr)
        return 3

    a_tag = next(iter(a_recs.values())).get("model_tag", "A")
    b_tag = next(iter(b_recs.values())).get("model_tag", "B")
    print(f"comparing {a_tag} (n={len(a_recs)})  vs  {b_tag} (n={len(b_recs)})")
    print(f"shared prompt ids: {len(shared)}")
    print()

    distances = []
    by_domain: dict[str, list[float]] = {}
    if not args.quiet:
        print(f"  {'id':<8} {'domain':<10} {'dist':>7}")
        print(f"  {'-' * 8} {'-' * 10} {'-' * 7}")
    for pid in shared:
        ra = a_recs[pid]["response"]
        rb = b_recs[pid]["response"]
        d = normalized_edit_distance(ra, rb)
        distances.append(d)
        dom = a_recs[pid].get("domain", "?")
        by_domain.setdefault(dom, []).append(d)
        if not args.quiet:
            print(f"  {pid:<8} {dom:<10} {d:>7.3f}")

    print()
    mean_d = statistics.mean(distances)
    median_d = statistics.median(distances)
    print(f"==== aggregate over {len(distances)} prompts ====")
    print(f"  mean   = {mean_d:.3f}")
    print(f"  median = {median_d:.3f}")
    print(f"  min    = {min(distances):.3f}")
    print(f"  max    = {max(distances):.3f}")
    for dom in sorted(by_domain):
        ds = by_domain[dom]
        print(f"  domain={dom:<10} mean={statistics.mean(ds):.3f}  n={len(ds)}")
    print()
    print(f"thresholds: < {COLLAPSE_THRESHOLD:.2f} = mode collapse,  >= {PRODUCTIVE_THRESHOLD:.2f} = productive")
    if mean_d >= PRODUCTIVE_THRESHOLD:
        print(f"VERDICT: PRODUCTIVE  (mean {mean_d:.3f} >= {PRODUCTIVE_THRESHOLD:.2f})")
        return 0
    if mean_d >= COLLAPSE_THRESHOLD:
        print(f"VERDICT: INCONCLUSIVE  ({COLLAPSE_THRESHOLD:.2f} <= mean {mean_d:.3f} < {PRODUCTIVE_THRESHOLD:.2f})")
        return 1
    print(f"VERDICT: MODE COLLAPSE  (mean {mean_d:.3f} < {COLLAPSE_THRESHOLD:.2f})")
    return 2


if __name__ == "__main__":
    sys.exit(main())
