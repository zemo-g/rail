"""RFC plain-text fetcher + section extractor.

Source: rfc-editor.org plain-text RFCs.  Cached locally so each RFC is
fetched at most once.  Section extraction is heuristic but covers the
common RFC layouts (top-level sections at column 0 with `N.` or `N.M.`
prefixes).

Usage:
    from impl.sources.rfc import get_section
    text = get_section(8259, "4")           # RFC 8259 section 4
    text = get_section(8446, "1.3")         # RFC 8446 section 1.3
"""

import re
import urllib.request
from pathlib import Path

CACHE_DIR = Path("tools/dnra/cache/rfc")
USER_AGENT = "DNRA-citation-verifier/0.1 (https://ledatic.org)"
TIMEOUT_SECS = 15


def _cache_path(rfc_num: int) -> Path:
    return CACHE_DIR / f"rfc{rfc_num}.txt"


def fetch_rfc(rfc_num: int) -> str | None:
    """Return the full RFC text, fetching + caching if needed.  None on failure."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache = _cache_path(rfc_num)
    if cache.exists() and cache.stat().st_size > 0:
        return cache.read_text(encoding="utf-8", errors="replace")
    url = f"https://www.rfc-editor.org/rfc/rfc{rfc_num}.txt"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECS) as r:
            text = r.read().decode("utf-8", errors="replace")
    except Exception as e:
        print(f"  [rfc] fetch failed rfc{rfc_num}: {e}")
        return None
    cache.write_text(text, encoding="utf-8")
    return text


# Matches section headers at column 0: "4. Objects", "4.3.4 Negative ..."
# Allows the trailing dot to be optional; section id segments are 1+ digits
# (RFC sections don't have alpha-section like Appendix A.1 in section numbering;
# Appendix sections use "Appendix N." prefix which we handle separately).
SECTION_HDR = re.compile(
    r"^(?P<id>\d+(?:\.\d+)*)\.?\s+\S",
    re.MULTILINE,
)


def _section_depth(sid: str) -> int:
    return sid.count(".") + 1


def extract_section(text: str, section: str) -> str | None:
    """Return the text of `section` (e.g. '4', '4.3.4') from `text`.

    Strategy: scan for all column-0 section headers, find the one whose
    identifier exactly matches `section`, return everything from that line
    until the next header at depth <= target depth.
    """
    section = section.strip().rstrip(".")
    target_depth = _section_depth(section)

    headers = []
    for m in SECTION_HDR.finditer(text):
        sid = m.group("id")
        headers.append((m.start(), sid))

    for i, (pos, sid) in enumerate(headers):
        if sid == section:
            # Find the next header at depth <= target_depth
            end = len(text)
            for nx_pos, nx_sid in headers[i + 1:]:
                if _section_depth(nx_sid) <= target_depth:
                    end = nx_pos
                    break
            return text[pos:end].rstrip()
    return None


def get_section(rfc_num: int, section: str) -> str | None:
    """Fetch RFC `rfc_num` and return the text of `section`, or None."""
    text = fetch_rfc(rfc_num)
    if text is None:
        return None
    return extract_section(text, section)


if __name__ == "__main__":
    # Smoke: pull a few known-good sections.
    cases = [
        (8259, "4"),     # JSON: object keys SHOULD be unique
        (8259, "6"),     # JSON: numbers
        (8446, "1.3"),   # TLS 1.3: differences from 1.2
        (7540, "6.4"),   # HTTP/2: RST_STREAM
        (8259, "999"),   # nonexistent -> None
    ]
    for rfc, sec in cases:
        out = get_section(rfc, sec)
        if out is None:
            print(f"RFC {rfc} section {sec}: NOT FOUND")
        else:
            head = out.splitlines()[0]
            print(f"RFC {rfc} section {sec}: {len(out)} chars, first line: {head!r}")
