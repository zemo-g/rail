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
from tools.dnra.impl.sources.posix import get_section as posix_get_section  # type: ignore[import-not-found]  # noqa: E402
from tools.dnra.impl.sources.python_docs import get_section as pydoc_get_section  # type: ignore[import-not-found]  # noqa: E402
from tools.dnra.impl.sources.rail_local import get_section as rail_local_get_section  # type: ignore[import-not-found]  # noqa: E402


QUOTED_SPAN = re.compile(r"'([^']{15,})'|\"([^\"]{15,})\"")
WHITESPACE = re.compile(r"\s+")
# Markdown formatting markers stripped before substring match.  A model
# is allowed to quote `Allocator:` even if the source has `**Allocator**:`.
MARKDOWN_MARKERS = re.compile(r"[*_`]+")

# Recognized POSIX-page section headers; used to detect whether the
# curator's `section` field carries an explicit section name (e.g.
# "DESCRIPTION", "ERRORS") or just the function name.
POSIX_SECTIONS = (
    "NAME", "SYNOPSIS", "DESCRIPTION", "RETURN VALUE", "ERRORS",
    "EXAMPLES", "APPLICATION USAGE", "RATIONALE", "FUTURE DIRECTIONS",
    "SEE ALSO", "CHANGE HISTORY",
)
POSIX_PATTERN = re.compile(r"\bPOSIX(?:\.1-\d{4})?\b", re.IGNORECASE)
PYTHON_PATTERN = re.compile(
    r"\b(?:docs\.python\.org|Python\s+(?:docs|language\s+reference|data\s+model|stdtypes|glossary|library|reference))\b",
    re.IGNORECASE,
)
RAIL_LOCAL_PATTERN = re.compile(
    r"\b(?:Rail\s+CLAUDE\.md|Rail\s+HANDOFF|CLAUDE\.md|HANDOFF\.md|rail/CLAUDE|rail/HANDOFF)\b",
    re.IGNORECASE,
)


def _normalize(s: str) -> str:
    """Whitespace-collapse + lowercase + strip markdown bold/italic/code markers.

    The verifier is checking semantic substring containment, not exact
    presentation.  A quote that drops the source's `**foo**` markdown
    bolding still grounds in the same content."""
    s = MARKDOWN_MARKERS.sub("", s)
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

    if POSIX_PATTERN.search(source):
        # Curator's section convention: "System Interfaces / close",
        # "System Interfaces / fork / ERRORS", or sometimes just
        # "close".  Split on '/', strip each chunk, then:
        #   - the rightmost chunk that matches a known POSIX section
        #     name (case-insensitive) is the section header to fetch;
        #   - the chunk immediately to its left (or, if no explicit
        #     section name is given, the rightmost chunk) is treated
        #     as the function name.
        chunks = [c.strip() for c in section.split("/") if c.strip()]
        if not chunks:
            return None, "posix"
        sec_name = "DESCRIPTION"
        func_chunks = chunks
        if chunks[-1].upper() in POSIX_SECTIONS:
            sec_name = chunks[-1].upper()
            func_chunks = chunks[:-1]
        if not func_chunks:
            return None, "posix"
        # The function name is the rightmost remaining chunk.  Strip
        # any trailing manpage suffix like "(2)" or "()" defensively.
        func = func_chunks[-1]
        func = re.sub(r"\s*\(\d*\)\s*$", "", func).strip()
        if not func:
            return None, "posix"
        text = posix_get_section(func, sec_name)
        return text, "posix"

    # Python docs.  Source variants accepted:
    #   "docs.python.org" / "Python docs" / "Python language reference" /
    #   "Python data model" / "Python stdtypes" / "Python glossary"
    # Section field formats:
    #   "library/time#time.sleep"
    #   "library/time / time.sleep"
    #   "library/stdtypes / dict"
    #   "term-global-interpreter-lock"  (page defaults to "glossary")
    if PYTHON_PATTERN.search(source):
        sec = section.strip()
        if "#" in sec:
            page, ident = sec.split("#", 1)
        elif "/" in sec:
            parts = [p.strip() for p in sec.split("/") if p.strip()]
            if len(parts) == 1:
                page, ident = "glossary", parts[0]
            elif len(parts) == 2:
                page, ident = parts[0], parts[1]
            else:
                # 3+ chunks -> last is identifier, rest is page slug
                page = "/".join(parts[:-1])
                ident = parts[-1]
        else:
            page, ident = "glossary", sec
        text = pydoc_get_section(page.strip(), ident.strip())
        return text, "python"

    # Rail local docs.  Section field forms:
    #   "Output Discipline"
    #   "CLAUDE.md / Output Discipline"
    #   "Known Compiler Limitations"
    if RAIL_LOCAL_PATTERN.search(source):
        # If section has "doc / section", split.  Else assume the
        # source identifies the doc and section is just a header name.
        if "/" in section:
            parts = [p.strip() for p in section.split("/") if p.strip()]
            doc, sec_name = parts[0], "/".join(parts[1:])
        elif "#" in section:
            doc, sec_name = section.split("#", 1)
        else:
            doc, sec_name = source, section.strip()
        text = rail_local_get_section(doc, sec_name)
        return text, "rail_local"

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
