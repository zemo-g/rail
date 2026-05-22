"""POSIX.1-2017 (Open Group) function-page fetcher + section extractor.

Source: pubs.opengroup.org/onlinepubs/9699919799/functions/<func>.html.
Cached locally so each page is fetched at most once.  Section extraction
keys off the standard `<h4 class="mansect">HEADING</h4>` headers used on
every POSIX function page (NAME, SYNOPSIS, DESCRIPTION, RETURN VALUE,
ERRORS, EXAMPLES, APPLICATION USAGE, RATIONALE, FUTURE DIRECTIONS, SEE
ALSO, CHANGE HISTORY).

Usage:
    from impl.sources.posix import get_section
    text = get_section("close", "DESCRIPTION")
    text = get_section("fork",  "ERRORS")
"""

import re
import urllib.request
from html import unescape
from pathlib import Path

CACHE_DIR = Path("tools/dnra/cache/posix")
USER_AGENT = "DNRA-citation-verifier/0.1 (https://ledatic.org)"
TIMEOUT_SECS = 15
BASE_URL = "https://pubs.opengroup.org/onlinepubs/9699919799/functions"


def _cache_path(func_name: str) -> Path:
    # func_name is something like "close" / "fork"; sanitize to keep
    # filenames sane even if a caller passes oddly.
    safe = re.sub(r"[^A-Za-z0-9_+-]", "_", func_name)
    return CACHE_DIR / f"{safe}.html"


def fetch_page(func_name: str) -> str | None:
    """Return the full HTML for `func_name`'s POSIX page.  None on failure."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache = _cache_path(func_name)
    if cache.exists() and cache.stat().st_size > 0:
        return cache.read_text(encoding="utf-8", errors="replace")
    url = f"{BASE_URL}/{func_name}.html"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECS) as r:
            text = r.read().decode("utf-8", errors="replace")
    except Exception as e:
        print(f"  [posix] fetch failed {func_name}: {e}")
        return None
    cache.write_text(text, encoding="utf-8")
    return text


# Match a mansect heading: <h4 class="mansect">...HEADING...</h4>.
# The inner content typically wraps an <a name="..."></a> anchor before
# the visible heading text; we strip tags from the inner content to get
# the heading label.
HEADER_RE = re.compile(
    r'<h[1-6][^>]*class="[^"]*mansect[^"]*"[^>]*>(?P<inner>.*?)</h[1-6]>',
    re.IGNORECASE | re.DOTALL,
)

# Fallback: some sub-sections (rare) use a different class; if we don't
# find a matching mansect header for the requested section, try any
# header that matches by visible text.  Conservative — only used if the
# primary search misses.
ANY_HEADER_RE = re.compile(
    r'<h[1-6][^>]*>(?P<inner>.*?)</h[1-6]>',
    re.IGNORECASE | re.DOTALL,
)

TAG_RE = re.compile(r"<[^>]+>")
BLOCK_BREAK_RE = re.compile(
    r"</?(?:p|div|blockquote|li|tr|br|h[1-6])\b[^>]*>",
    re.IGNORECASE,
)
WS_COLLAPSE_RE = re.compile(r"[ \t]+")
MULTI_NL_RE = re.compile(r"\n{3,}")


def _strip_tags(html: str) -> str:
    """Convert an HTML fragment to plain text.

    Preserves paragraph breaks (turns block-level tag boundaries into
    newlines).  Strips remaining inline tags.  Decodes HTML entities.
    Collapses excess whitespace.
    """
    # Drop <script>/<style> bodies wholesale.
    html = re.sub(r"<script\b.*?</script>", "", html, flags=re.IGNORECASE | re.DOTALL)
    html = re.sub(r"<style\b.*?</style>", "", html, flags=re.IGNORECASE | re.DOTALL)
    # Insert a newline at block boundaries so paragraphs don't run together.
    html = BLOCK_BREAK_RE.sub("\n", html)
    # Drop all remaining tags.
    text = TAG_RE.sub("", html)
    # Decode entities (&nbsp; &amp; ...).
    text = unescape(text)
    # Normalize NBSPs to plain space.
    text = text.replace(" ", " ")
    # Collapse runs of spaces/tabs and excess blank lines.
    lines = [WS_COLLAPSE_RE.sub(" ", ln).strip() for ln in text.splitlines()]
    text = "\n".join(lines)
    text = MULTI_NL_RE.sub("\n\n", text)
    return text.strip()


def _header_label(inner_html: str) -> str:
    """Strip tags + whitespace from the inner HTML of an <h4> to get its label."""
    label = TAG_RE.sub("", inner_html)
    label = unescape(label)
    label = re.sub(r"\s+", " ", label).strip()
    return label


def extract_section(html: str, section: str) -> str | None:
    """Return plain-text body of `section` from a POSIX function page.

    Match is case-insensitive against the heading's visible text.  Body
    is everything between the matched header and the next mansect
    header (or end of document).
    """
    target = re.sub(r"\s+", " ", section).strip().lower()
    if not target:
        return None

    # Primary pass: walk all mansect headers.
    headers = []
    for m in HEADER_RE.finditer(html):
        label = _header_label(m.group("inner")).lower()
        headers.append((m.start(), m.end(), label))

    # Fallback: if we found no mansect headers (unexpected), use any header.
    if not headers:
        for m in ANY_HEADER_RE.finditer(html):
            label = _header_label(m.group("inner")).lower()
            headers.append((m.start(), m.end(), label))

    for i, (h_start, h_end, label) in enumerate(headers):
        if label == target:
            # Body is from end-of-this-header until start-of-next-header.
            end = len(html)
            if i + 1 < len(headers):
                end = headers[i + 1][0]
            body_html = html[h_end:end]
            return _strip_tags(body_html)
    return None


def get_section(func_name: str, section: str) -> str | None:
    """Fetch POSIX page for `func_name` and return the text of `section`."""
    html = fetch_page(func_name)
    if html is None:
        return None
    return extract_section(html, section)


if __name__ == "__main__":
    for func, sec in [
        ("close", "DESCRIPTION"),
        ("close", "ERRORS"),
        ("fork", "DESCRIPTION"),
    ]:
        out = get_section(func, sec)
        if out is None:
            print(f"{func} / {sec}: NOT FOUND")
        else:
            preview = out.replace("\n", " ")[:200]
            print(f"{func} / {sec} ({len(out)} chars): {preview}")
