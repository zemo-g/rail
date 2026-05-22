#!/usr/bin/env python3
"""Citation verifier for the Deductive panelist corpus.

Input: a drafted pair {id, source, section, prompt, target, polarity}.
Output: a verdict {pair, status, evidence, notes}.

Statuses:
  PASS         - at least one quoted span in target is grounded in the cited
                 section text (substring match, whitespace-normalized).
  FAIL         - the target quotes something not present in the section.
  NO_VERIFIER  - the source family has no fetcher yet (e.g. C11 paywalled);
                 the pair is held for manual review.
  NO_CLAIM     - the target paraphrases but quotes nothing.  Held back; the
                 verifier cannot ground a non-claim.  Authors should rewrite
                 to include at least one verbatim quotation.
  FETCH_FAIL   - source fetcher reached but couldn't retrieve the section.

Currently supported source families:
  - RFC <N>   (via sources/rfc.py)

Future fetchers (NO_VERIFIER until added):
  - POSIX.1-2017, Python docs, Rust reference, Rail local docs, bash man,
    ISO/IEC 9899 (C11; paywalled), IEEE 754 (paywalled).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

# Make `tools.dnra.impl.sources` importable when run from repo root.
REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT))
from tools.dnra.impl.sources.rfc import get_section as rfc_get_section  # type: ignore[import-not-found]  # noqa: E402


QUOTED_SPAN = re.compile(r"'([^']{15,})'|\"([^\"]{15,})\"")
WHITESPACE = re.compile(r"\s+")


def _normalize(s: str) -> str:
    return WHITESPACE.sub(" ", s).strip().lower()


def _extract_quotes(target: str) -> list[str]:
    out = []
    for m in QUOTED_SPAN.finditer(target):
        span = m.group(1) or m.group(2)
        if span and len(span) >= 15:
            out.append(span)
    return out


RFC_PATTERN = re.compile(r"RFC\s+(\d+)", re.IGNORECASE)
SECTION_NUMBER = re.compile(r"(\d+(?:\.\d+)*)")


def resolve_source(source: str, section: str) -> tuple[str | None, str]:
    """Return (section_text or None, family-tag).

    For RFC sources, parses the section identifier robustly: handles
    'section 4.3.4', '4.3.4', '5.1; 6.4' (takes the first), and the
    leading-RFC-number variant 'RFC 1034 section 4.3.4'.
    """
    m = RFC_PATTERN.search(source)
    if m:
        rfc_num = int(m.group(1))
        # Take the first ';'-separated chunk, then pull the first dotted
        # number out of it.  Skips a leading RFC <N> if the chunk
        # mentions one (the chunk's RFC overrides `source`'s RFC).
        chunk = section.split(";")[0].strip()
        chunk_rfc = RFC_PATTERN.search(chunk)
        if chunk_rfc:
            rfc_num = int(chunk_rfc.group(1))
            chunk = RFC_PATTERN.sub("", chunk)
        sec_m = SECTION_NUMBER.search(chunk)
        if sec_m is None:
            return None, "rfc"
        text = rfc_get_section(rfc_num, sec_m.group(1))
        return text, "rfc"
    return None, "unsupported"


def verify_pair(pair: dict[str, Any]) -> dict[str, Any]:
    out = {
        "id": pair.get("id", "?"),
        "source": pair.get("source", ""),
        "section": pair.get("section", ""),
        "status": "NO_VERIFIER",
        "matched_quotes": [],
        "unmatched_quotes": [],
        "notes": "",
    }

    target = pair.get("target", "")
    quotes = _extract_quotes(target)
    section_text, family = resolve_source(pair.get("source", ""), pair.get("section", ""))

    if family == "unsupported":
        out["status"] = "NO_VERIFIER"
        out["notes"] = f"no fetcher for source family: {pair.get('source','')}"
        return out
    if section_text is None:
        out["status"] = "FETCH_FAIL"
        out["notes"] = f"could not fetch section {pair.get('section','')} of {pair.get('source','')}"
        return out
    if not quotes:
        out["status"] = "NO_CLAIM"
        out["notes"] = "target contains no quoted span >= 15 chars"
        return out

    norm_section = _normalize(section_text)
    matched, unmatched = [], []
    for q in quotes:
        if _normalize(q) in norm_section:
            matched.append(q)
        else:
            unmatched.append(q)
    out["matched_quotes"] = matched
    out["unmatched_quotes"] = unmatched

    if matched:
        out["status"] = "PASS"
        if unmatched:
            out["notes"] = f"{len(unmatched)} of {len(quotes)} quoted span(s) unmatched but >=1 grounded"
        else:
            out["notes"] = f"all {len(quotes)} quoted span(s) grounded in section text"
    else:
        out["status"] = "FAIL"
        out["notes"] = f"none of {len(quotes)} quoted span(s) found in section text"
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path", help="JSONL of drafted pairs to verify")
    ap.add_argument("--out", default=None, help="Optional JSONL of verdicts")
    args = ap.parse_args()

    in_path = Path(args.path)
    if not in_path.exists():
        print(f"ERROR: {in_path} does not exist", file=sys.stderr)
        return 1

    pairs = []
    with open(in_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            pairs.append(json.loads(line))

    print(f"verifying {len(pairs)} pairs from {in_path}")
    print()
    verdicts = []
    counters: dict[str, int] = {}
    for p in pairs:
        v = verify_pair(p)
        verdicts.append(v)
        counters[v["status"]] = counters.get(v["status"], 0) + 1
        mark = {"PASS": "PASS", "FAIL": "FAIL", "NO_CLAIM": "NCLM", "NO_VERIFIER": "NVER", "FETCH_FAIL": "FFAIL"}.get(v["status"], "?")
        print(f"  {v['id']:<6} [{mark}] {v['source']} sec {v['section']}: {v['notes']}")
        if v["status"] == "FAIL" and v["unmatched_quotes"]:
            print(f"        unmatched: {v['unmatched_quotes'][0][:140]!r}")

    print()
    print("==== verdict summary ====")
    for status in ("PASS", "FAIL", "NO_CLAIM", "FETCH_FAIL", "NO_VERIFIER"):
        n = counters.get(status, 0)
        if n:
            print(f"  {status:<12} {n}/{len(pairs)}")

    if args.out:
        with open(args.out, "w") as f:
            for v in verdicts:
                f.write(json.dumps(v, separators=(",", ":")) + "\n")
        print(f"\nwrote verdicts to {args.out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
