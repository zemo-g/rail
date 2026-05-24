#!/usr/bin/env python3
"""DNRA probe edit-distance scorer (hardened).

Pairwise normalized Levenshtein edit-distance between two probe response
files PLUS two quality checks that catch the failure modes a raw
edit-distance gate cannot see:

  1. LENGTH-RATIO check.  If trained mean response length is < 50% of
     base, the model is collapsing to empty-emit (it learned <|eot_id|>
     follows ~N chars in training and emits it early on OOD prompts).
     Edit-distance vs a ~1200-char base then trivially exceeds 0.5
     even though the trained model is producing nothing.
  2. SPURIOUS-CITE check.  If the trained model emits 'Cite:' on
     prompts where the base never does, AND the rate is >= 70%, the
     model has learned the citation surface pattern and is pasting it
     onto unrelated content (FINETUNE_DEDUCTIVE Section 6.1 risk -
     hallucinated citations).  This is observed-from-smoke: a 19-pair
     overfit LoRA cited 25 of 30 OOD prompts versus 0 from base.

Both checks default to WARNING.  With --strict they flip the final
verdict to QUALITY COLLAPSE regardless of edit-distance.

Usage:
    python3 tools/dnra/impl/score_probe.py \\
        --a tools/dnra/sets/probe_responses_base.jsonl \\
        --b tools/dnra/sets/probe_responses_d_v0_trained.jsonl \\
        [--strict]

Exit codes:
    0 = PRODUCTIVE (edit >= 0.35) AND no quality flag in --strict mode
    1 = INCONCLUSIVE (0.25 <= edit < 0.35)
    2 = MODE COLLAPSE (edit < 0.25) OR --strict + quality flag

No external deps. Levenshtein hand-rolled to keep this script portable.
"""

import argparse
import json
import statistics
import sys
from pathlib import Path

COLLAPSE_THRESHOLD = 0.25
PRODUCTIVE_THRESHOLD = 0.35
LENGTH_RATIO_FLOOR = 0.30          # trained mean / base mean must be >= this
SPURIOUS_CITE_CEILING = 0.70       # rate of base-no-cite-but-trained-cites
FABRICATION_RATE_CEILING = 0.30    # of cites emitted, <= 30% may be fabricated
GROUNDING_FLOOR = 0.20             # of verifiable cite attempts, >= 20% must ground
GROUNDING_MIN_SAMPLE = 10          # below this many verifiable cites, skip the floor
CITE_MARKER = "Cite:"              # the convention used in D corpus targets


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


def quality_checks(a_recs, b_recs, shared, a_tag, b_tag):
    """Return (length_ratio, spurious_cite_rate, fabrication_rate, flags_list).

    `flags_list` is a list of human-readable strings describing any
    quality concerns; empty list = clean.

    The fabrication_rate check runs the runtime citation verifier
    (impl/verify_runtime) over the B-side responses: counts grounded
    vs fabricated Cite: markers against the actual cited RFC / POSIX
    section text.  A trained model that emits cites which DON'T ground
    is hallucinating regardless of how the edit-distance / length /
    spurious-cite numbers look.
    """
    flags = []
    a_lens = [len(a_recs[pid]["response"]) for pid in shared]
    b_lens = [len(b_recs[pid]["response"]) for pid in shared]
    a_mean = statistics.mean(a_lens) if a_lens else 0
    b_mean = statistics.mean(b_lens) if b_lens else 0
    length_ratio = (b_mean / a_mean) if a_mean > 0 else 0.0
    if length_ratio < LENGTH_RATIO_FLOOR:
        flags.append(
            f"LENGTH COLLAPSE: {b_tag} mean {b_mean:.0f} chars vs {a_tag} mean "
            f"{a_mean:.0f} chars (ratio {length_ratio:.2f} < {LENGTH_RATIO_FLOOR:.2f}). "
            f"Likely empty-emit -- model learned to stop early on OOD prompts."
        )

    spurious = 0
    for pid in shared:
        a_cites = CITE_MARKER in a_recs[pid]["response"]
        b_cites = CITE_MARKER in b_recs[pid]["response"]
        if (not a_cites) and b_cites:
            spurious += 1
    spurious_rate = spurious / len(shared) if shared else 0.0
    if spurious_rate >= SPURIOUS_CITE_CEILING:
        flags.append(
            f"CITATION OVER-EMISSION: {b_tag} emits '{CITE_MARKER}' on "
            f"{spurious}/{len(shared)} prompts where {a_tag} does not "
            f"(rate {spurious_rate:.0%} >= {SPURIOUS_CITE_CEILING:.0%}). "
            f"Likely learned-template paste onto unrelated content."
        )

    # Runtime citation verifier: ground each Cite: against actual source.
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
        from tools.dnra.impl.verify_runtime import verify_response  # type: ignore[import-not-found]
        total = grounded = fabricated = verifiable = 0
        for pid in shared:
            stats = verify_response(b_recs[pid])
            total += stats["n_cites"]
            for cv in stats["cite_verdicts"]:
                s = cv["status"]
                if s == "PASS":
                    grounded += 1
                    verifiable += 1
                elif s in ("FAIL", "FETCH_FAIL"):
                    fabricated += 1
                    verifiable += 1
                elif s == "NO_CLAIM":
                    verifiable += 1
        fabrication_rate = fabricated / total if total > 0 else 0.0
        grounding_rate = grounded / verifiable if verifiable > 0 else 0.0
        if total > 0 and fabrication_rate > FABRICATION_RATE_CEILING:
            flags.append(
                f"CITATION FABRICATION: {b_tag} emits {fabricated} fabricated "
                f"cites out of {total} total (rate {fabrication_rate:.0%} > "
                f"{FABRICATION_RATE_CEILING:.0%}). Hallucinating sections."
            )
        if verifiable >= GROUNDING_MIN_SAMPLE and grounding_rate < GROUNDING_FLOOR:
            flags.append(
                f"NO GROUNDED CITATIONS: {b_tag} emits {verifiable} verifiable "
                f"cite attempts but only {grounded} ({grounding_rate:.0%}) "
                f"actually ground in the cited source. Floor {GROUNDING_FLOOR:.0%}. "
                f"Model is producing the Cite: surface format without "
                f"the underlying semantic competence."
            )
    except Exception as e:
        fabrication_rate = 0.0
        flags.append(f"RUNTIME-VERIFIER ERROR: {e!r}")
    return length_ratio, spurious_rate, fabrication_rate, flags


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True, help="First probe responses JSONL (e.g. base)")
    ap.add_argument("--b", required=True, help="Second probe responses JSONL (e.g. d_v0_trained)")
    ap.add_argument("--quiet", action="store_true", help="Suppress per-prompt table")
    ap.add_argument("--strict", action="store_true", help="Quality flags hard-fail the verdict (else they only warn)")
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
    # Quality checks (length-ratio + spurious-cite + fabrication) layered on top of edit-distance.
    length_ratio, spurious_rate, fabrication_rate, q_flags = quality_checks(a_recs, b_recs, shared, a_tag, b_tag)
    print(f"quality:    length_ratio={length_ratio:.3f}  (floor {LENGTH_RATIO_FLOOR:.2f})  "
          f"spurious_cite_rate={spurious_rate:.0%}  (ceiling {SPURIOUS_CITE_CEILING:.0%})  "
          f"fabrication_rate={fabrication_rate:.0%}  (ceiling {FABRICATION_RATE_CEILING:.0%})")
    if q_flags:
        for f in q_flags:
            print(f"  WARN: {f}")
    else:
        print("  quality: clean")

    print()
    print(f"thresholds: < {COLLAPSE_THRESHOLD:.2f} = mode collapse,  >= {PRODUCTIVE_THRESHOLD:.2f} = productive")
    # Apply strict-mode quality override BEFORE the edit-distance verdict.
    if args.strict and q_flags:
        print(f"VERDICT: QUALITY COLLAPSE  ({len(q_flags)} quality flag(s); --strict promoted to fail)")
        return 2
    if mean_d >= PRODUCTIVE_THRESHOLD:
        verdict = "PRODUCTIVE"
        if q_flags:
            verdict += " (with quality WARNINGS; pass --strict to fail on them)"
        print(f"VERDICT: {verdict}  (mean {mean_d:.3f} >= {PRODUCTIVE_THRESHOLD:.2f})")
        return 0
    if mean_d >= COLLAPSE_THRESHOLD:
        print(f"VERDICT: INCONCLUSIVE  ({COLLAPSE_THRESHOLD:.2f} <= mean {mean_d:.3f} < {PRODUCTIVE_THRESHOLD:.2f})")
        return 1
    print(f"VERDICT: MODE COLLAPSE  (mean {mean_d:.3f} < {COLLAPSE_THRESHOLD:.2f})")
    return 2


if __name__ == "__main__":
    sys.exit(main())
