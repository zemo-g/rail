#!/usr/bin/env python3
"""r37 okBracket adversary: the strongest LOOKUP-TABLE baseline.

Gate criterion okBracket demands: lookup_baseline < T <= honest_model_score.
The capstone used T=48 without measuring the lookup side. This measures it.

Adversary model: a pure memorizer that never learns the copy rule. For each
held-out 4-digit number it outputs ONE whole training number (its best guess).
Its echo score on that line = positional digit matches between guess and truth.
The strongest such adversary picks argmax-positional-match per holdout number.

Upper bound argument (verified empirically below): a training number is never
identical to a holdout number (disjoint split), so positional matches <= 3.
Score 3 requires a training number differing in exactly ONE digit position.
With 9,984/10,000 pool density each holdout number has 36 one-digit neighbors,
so the expected strongest-lookup score is 16*3 = 48/64 -- exactly AT T=48.

Also reported: the longest-common-PREFIX variant (a greedy next-char memorizer
that follows the trie of memorized lines and commits to the majority branch).

Output: R37_LOOKUP_BASELINE=<n>/64 plus the corrected bracket recommendation.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TRAIN = ROOT / "rungs/r24/force_train_4d.txt"
HOLD = ROOT / "rungs/r24/force_holdout_4d.txt"

num_re = re.compile(r"-- (\d{4})$")


def numbers(path):
    out = []
    for line in path.read_text().splitlines():
        m = num_re.search(line)
        if m:
            out.append(m.group(1))
    return out


def main():
    train = numbers(TRAIN)
    hold = numbers(HOLD)
    tset = set(train)
    assert len(tset) == len(train), "duplicate train numbers"
    assert not (tset & set(hold)), "split leak: holdout number in train"
    print(f"train={len(train)} holdout={len(hold)} (disjoint verified)")

    pos_total = 0   # strongest whole-number lookup (positional matches)
    pre_total = 0   # longest-common-prefix memorizer
    detail = []
    for h in hold:
        best_pos = max(sum(a == b for a, b in zip(t, h)) for t in tset)
        best_pre = 0
        for t in tset:
            k = 0
            while k < 4 and t[k] == h[k]:
                k += 1
            best_pre = max(best_pre, k)
        pos_total += best_pos
        pre_total += best_pre
        detail.append((h, best_pos, best_pre))

    for h, bp, bq in detail:
        print(f"  holdout {h}: best positional match={bp}/4, longest prefix={bq}/4")

    print(f"R37_LOOKUP_BASELINE={pos_total}/64  (strongest whole-number memorizer)")
    print(f"R37_PREFIX_BASELINE={pre_total}/64  (greedy prefix-trie memorizer)")
    model = 62
    t_old = 48
    verdict_old = "FAILS (lookup >= T)" if pos_total >= t_old else "holds"
    print(f"okBracket at T={t_old}: lookup={pos_total} -> {verdict_old}")
    # Corrected threshold: strictly above the strongest lookup, at/below the model.
    t_new = (pos_total + model + 1) // 2  # midpoint, robust to +-few digits
    assert pos_total < t_new <= model
    print(f"R37_BRACKET_CORRECTED: lookup={pos_total} < T'={t_new} <= model={model}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
