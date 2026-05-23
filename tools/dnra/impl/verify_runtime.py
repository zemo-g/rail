#!/usr/bin/env python3
"""Runtime citation verifier for trained-model probe responses.

The training-corpus verifier (impl/verify_citation.py) checks that each
(prompt, target) pair grounds its quoted spans in the cited source.  This
script does the same thing -- but on the MODEL'S outputs, not on
curator-written targets.

For each response in a probe_responses_*.jsonl file:
  1. Extract every 'Cite: ...' marker (a model may emit multiple).
  2. Parse each marker into (source, section).
  3. Extract every quoted span >=15 chars from the response.
  4. Construct a synthetic pair {source, section, target=full_response}
     and pass it through impl.verify_citation.verify_pair.
  5. Per-cite verdict: PASS / FAIL / NO_CLAIM / NO_VERIFIER / FETCH_FAIL.

Aggregate metrics emitted at end:
  total_cites
  grounded_cites               (PASS)
  fabricated_cites             (FAIL or FETCH_FAIL when source IS supported)
  unverifiable_cites           (NO_VERIFIER -- source family unsupported)
  no_claim_cites               (NO_CLAIM -- no quoted span to verify)
  grounding_rate               = grounded / (grounded + fabricated)
  responses_with_fabrication   = count of responses with >=1 FAIL

Usage:
    python3 tools/dnra/impl/verify_runtime.py probe_responses_d_v0_prod_3b_v2.jsonl
    (defaults to looking in tools/dnra/sets/)
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT))
from tools.dnra.impl.verify_citation import verify_pair  # type: ignore[import-not-found]

CITE_PATTERN = re.compile(r"Cite:\s*([^\n]{1,200})", re.IGNORECASE)


def parse_cite(cite_text: str) -> tuple[str, str]:
    """Parse a 'Cite: X' tail into (source, section).

    Handles:
      'RFC 8259 section 4'                -> ('RFC 8259', '4')
      'RFC 5234 section 3.3.1'            -> ('RFC 5234', '3.3.1')
      'POSIX.1-2017 close() section DESCRIPTION'
                                          -> ('POSIX.1-2017', 'close() / DESCRIPTION')
      '~/projects/rail/CLAUDE.md section Output Discipline'
                                          -> ('Rail CLAUDE.md', 'Output Discipline')
      'Python Guide to the GIL'           -> ('Python Guide to the GIL', '')
      Anything else: section field falls back to full text.
    """
    cite_text = cite_text.strip().rstrip(".,;")
    # RFC
    rfc_m = re.search(r"RFC\s+(\d+)", cite_text, re.IGNORECASE)
    if rfc_m:
        source = f"RFC {rfc_m.group(1)}"
        sec_m = re.search(r"section\s+([\w.]+)", cite_text, re.IGNORECASE)
        section = sec_m.group(1) if sec_m else cite_text
        return source, section
    # POSIX
    posix_m = re.search(r"POSIX(?:\.1-\d+)?", cite_text, re.IGNORECASE)
    if posix_m:
        # Pull function name + optional section header.
        # Strip the POSIX prefix and parse the rest.
        rest = cite_text[posix_m.end():].strip()
        # function name may be 'close()' or 'fork' or 'close()  section DESCRIPTION'
        func_m = re.search(r"([A-Za-z_][\w]*)\s*\(?\)?", rest)
        sec_m = re.search(r"section\s+([A-Z][A-Z\s_]*)", rest, re.IGNORECASE)
        func = func_m.group(1) if func_m else ""
        section = sec_m.group(1).strip() if sec_m else "DESCRIPTION"
        if func:
            return "POSIX.1-2017", f"{func} / {section.upper()}"
        return "POSIX.1-2017", cite_text
    # Python docs.  Cite shapes observed in the wild:
    #   'docs.python.org section library/time#time.sleep'
    #   'Python glossary section term-global-interpreter-lock'
    #   'Python data model section object.__hash__'
    py_m = re.search(
        r"(docs\.python\.org|Python\s+(?:docs|language\s+reference|data\s+model|stdtypes|glossary|library|reference))",
        cite_text,
        re.IGNORECASE,
    )
    if py_m:
        source = py_m.group(1)
        rest = cite_text[py_m.end():].strip()
        # strip optional ' section ' prefix
        rest = re.sub(r"^\s*section\s+", "", rest, flags=re.IGNORECASE).strip()
        return source, rest

    # Rail local docs (unverifiable at v0 -- no fetcher yet)
    if "CLAUDE.md" in cite_text or "HANDOFF" in cite_text or "rail/" in cite_text:
        sec_m = re.search(r"section\s+(.+)", cite_text, re.IGNORECASE)
        return "Rail CLAUDE.md", sec_m.group(1).strip() if sec_m else cite_text
    # Anything else
    return cite_text, ""


def verify_response(rec: dict) -> dict:
    """Return per-response stats."""
    resp = rec.get("response", "")
    cites = [m.group(1).strip() for m in CITE_PATTERN.finditer(resp)]
    out = {
        "id": rec.get("id", "?"),
        "n_cites": len(cites),
        "cite_verdicts": [],  # list of status strings, one per cite
    }
    for cite_text in cites:
        source, section = parse_cite(cite_text)
        synth_pair = {
            "id": rec.get("id", "?"),
            "source": source,
            "section": section,
            "polarity": "keep",
            "prompt": rec.get("text", ""),
            "target": resp,  # full response; verifier extracts quotes from it
        }
        v = verify_pair(synth_pair)
        out["cite_verdicts"].append({
            "cite_text": cite_text,
            "source": source,
            "section": section,
            "status": v["status"],
            "notes": v["notes"],
        })
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path", help="Probe responses JSONL")
    ap.add_argument("--verbose", action="store_true", help="Print per-response cite verdicts")
    args = ap.parse_args()
    p = Path(args.path)
    if not p.exists():
        # Try as a name in sets/
        alt = REPO_ROOT / "tools/dnra/sets" / p.name
        if alt.exists():
            p = alt
        else:
            print(f"ERROR: {args.path} not found", file=sys.stderr)
            return 1

    records = [json.loads(l) for l in open(p) if l.strip()]
    print(f"verifying citations across {len(records)} probe responses from {p.name}")
    print()

    total_cites = 0
    grounded = 0
    fabricated = 0
    unverifiable = 0
    no_claim = 0
    fetch_fail = 0
    responses_with_fab = 0

    for rec in records:
        rstat = verify_response(rec)
        total_cites += rstat["n_cites"]
        had_fab = False
        for cv in rstat["cite_verdicts"]:
            s = cv["status"]
            if s == "PASS":
                grounded += 1
            elif s == "FAIL":
                fabricated += 1
                had_fab = True
            elif s == "NO_VERIFIER":
                unverifiable += 1
            elif s == "NO_CLAIM":
                no_claim += 1
            elif s == "FETCH_FAIL":
                fetch_fail += 1
                had_fab = True  # cited an RFC section that doesn't exist
        if had_fab:
            responses_with_fab += 1
        if args.verbose and rstat["n_cites"] > 0:
            print(f"  {rstat['id']}  cites={rstat['n_cites']}")
            for cv in rstat["cite_verdicts"]:
                print(f"     [{cv['status']}] {cv['cite_text'][:80]}: {cv['notes']}")

    # Grounding rate: of citations to a SUPPORTED source family, what
    # fraction ground.  Unverifiable cites are excluded from numerator
    # and denominator (we can't say either way).
    verifiable_cites = grounded + fabricated + fetch_fail + no_claim
    grounding_rate = grounded / verifiable_cites if verifiable_cites > 0 else 0.0
    fabrication_rate = (fabricated + fetch_fail) / max(1, total_cites)

    print(f"==== runtime citation aggregate ====")
    print(f"  total cites:           {total_cites}")
    print(f"  grounded (PASS):       {grounded}")
    print(f"  fabricated (FAIL/FF):  {fabricated + fetch_fail}  ({fabricated} bad-quote + {fetch_fail} bad-section)")
    print(f"  unverifiable (other):  {unverifiable}")
    print(f"  no_claim (no quote):   {no_claim}")
    print()
    print(f"  responses with >=1 fab: {responses_with_fab}/{len(records)} ({100*responses_with_fab/len(records):.0f}%)")
    print(f"  grounding rate         (grounded / verifiable) = {grounding_rate:.2%}")
    print(f"  fabrication rate       (fab+ff / total_cites) = {fabrication_rate:.2%}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
