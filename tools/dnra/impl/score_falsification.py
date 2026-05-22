"""DNRA falsification scorer — re-runnable across sets.

Reads one or more JSONL set files (default: v0a + v0b), normalizes each
mode prediction and oracle expected_output by extracting the first
alphanumeric token, and reports:

  - Per-mode total right (prediction matches oracle)
  - Per-mode unique-right (mode is right AND no other mode is right)
  - Per-mode lost-alone (mode is wrong AND both others right)
  - Per-mode dominance: mode X dominates mode Y if X-right >= Y-right
    on every problem (no problem where Y wins and X doesn't)

This is intentionally Python so the scorer can iterate cheaply during
curation; a Rail port is a later ticket.
"""
import json
import re
import sys
from pathlib import Path

MODES = ["deductive", "empirical", "adversarial"]


def first_token(s) -> str:
    """Normalize: uppercase + leading alphanumeric run."""
    if not s:
        return ""
    m = re.match(r"^([A-Za-z0-9]+)", s.strip())
    return m.group(1).upper() if m else ""


def score(records):
    n = len(records)
    per_mode_right = {m: 0 for m in MODES}
    per_mode_unique = {m: 0 for m in MODES}
    per_mode_lost_alone = {m: 0 for m in MODES}

    rows = []
    for r in records:
        oracle_tok = first_token(r["oracle"]["expected_output"])
        right = {}
        for m in MODES:
            pred_tok = first_token(r["mode_predictions"][m]["prediction"])
            right[m] = (pred_tok == oracle_tok)
            if right[m]:
                per_mode_right[m] += 1

        n_right = sum(right.values())
        winner = None
        loser = None
        if n_right == 1:
            winner = next(m for m in MODES if right[m])
            per_mode_unique[winner] += 1
        elif n_right == 2:
            loser = next(m for m in MODES if not right[m])
            per_mode_lost_alone[loser] += 1
        rows.append({
            "id": r["id"],
            "oracle_tok": oracle_tok,
            "preds": {m: first_token(r["mode_predictions"][m]["prediction"]) for m in MODES},
            "right": right,
            "winner": winner,
            "expected_winner": r.get("design_notes", {}).get("expected_unique_winner", "?"),
        })

    print(f"\n=== DNRA Falsification Score ({n} problems) ===\n")
    print(f"{'ID':<8} {'oracle':<10} {'D':<6} {'E':<6} {'A':<6} {'winner':<14} {'predicted':<14}")
    print("-" * 70)
    for row in rows:
        marks = {m: ("✓" if row["right"][m] else "✗") + f" {row['preds'][m]}" for m in MODES}
        w = row["winner"] or "none"
        ew = row["expected_winner"]
        flag = "" if w == ew else "  [MISS]"
        print(f"{row['id']:<8} {row['oracle_tok']:<10} {marks['deductive']:<6} {marks['empirical']:<6} {marks['adversarial']:<6} {w:<14} {ew:<14}{flag}")

    print("\n=== Per-mode totals ===")
    print(f"{'mode':<14} {'right':<8} {'unique-right':<14} {'lost-alone':<12}")
    print("-" * 50)
    for m in MODES:
        print(f"{m:<14} {per_mode_right[m]:<8} {per_mode_unique[m]:<14} {per_mode_lost_alone[m]:<12}")

    print("\n=== Pairwise dominance ===")
    for a in MODES:
        for b in MODES:
            if a == b:
                continue
            a_only = sum(1 for row in rows if row["right"][a] and not row["right"][b])
            b_only = sum(1 for row in rows if row["right"][b] and not row["right"][a])
            if a_only > 0 and b_only == 0:
                print(f"  {a:>11} dominates {b:<11} ({a_only} problems where {a} right alone vs {b})")

    print("\n=== Gate evaluation ===")
    threshold = 5
    for m in MODES:
        ok = per_mode_unique[m] >= threshold
        print(f"  {m:<14} unique-right = {per_mode_unique[m]} / >= {threshold}  {'PASS' if ok else 'FAIL'}")


def main():
    paths = sys.argv[1:] or [
        "sets/falsification_v0a.jsonl",
        "sets/falsification_v0b.jsonl",
    ]
    base = Path(__file__).resolve().parent.parent
    records = []
    for p in paths:
        with open(base / p) as f:
            for line in f:
                if line.strip():
                    records.append(json.loads(line))
    score(records)


if __name__ == "__main__":
    main()
