"""docs.python.org fetcher + section extractor.

Pages live at https://docs.python.org/3/<page>.html with each item
anchored by `id="<identifier>"` on a `<dt class="sig">` tag.  The
section body is the immediately-following `<dd>` block.

Common pages worth caching:
    library/time          -- time.sleep, time.monotonic, ...
    library/stdtypes      -- dict, list, str.*, bool, ...
    library/threading     -- Thread, Lock, RLock, ...
    reference/datamodel   -- object.__hash__, special methods, identity vs equality
    reference/expressions -- operator precedence, etc.
    c-api/init            -- thread state + the Global Interpreter Lock
    glossary              -- definitions (GIL, iterator, generator, ...)

Usage:
    from impl.sources.python_docs import get_section
    text = get_section("library/time", "time.sleep")
    text = get_section("c-api/init", "PyGILState_Ensure")
    text = get_section("glossary", "term-global-interpreter-lock")
"""

from __future__ import annotations
import html
import re
import urllib.request
from pathlib import Path

CACHE_DIR = Path("tools/dnra/cache/python_docs")
USER_AGENT = "DNRA-citation-verifier/0.1 (https://ledatic.org)"
TIMEOUT_SECS = 15


def _cache_path(page: str) -> Path:
    safe = page.replace("/", "__")
    return CACHE_DIR / f"{safe}.html"


def fetch_page(page: str) -> str | None:
    """Return the full HTML for a docs.python.org page, fetching+caching."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache = _cache_path(page)
    if cache.exists() and cache.stat().st_size > 0:
        return cache.read_text(encoding="utf-8", errors="replace")
    url = f"https://docs.python.org/3/{page}.html"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECS) as r:
            text = r.read().decode("utf-8", errors="replace")
    except Exception as e:
        print(f"  [python_docs] fetch failed {page}: {e}")
        return None
    cache.write_text(text, encoding="utf-8")
    return text


# Block-level tags whose boundaries become paragraph breaks in the
# stripped text.  Inline tags are silently removed.
BLOCK_TAGS = ("p", "div", "li", "tr", "br", "section", "h1", "h2", "h3", "h4", "h5", "dt", "dd")
BLOCK_RE = re.compile(
    r"<(" + "|".join(BLOCK_TAGS) + r")\b[^>]*>|</(" + "|".join(BLOCK_TAGS) + r")>",
    re.IGNORECASE,
)
INLINE_TAG_RE = re.compile(r"<[^>]+>")
NBSP_RE = re.compile(r"&nbsp;| ")
MULTI_NL = re.compile(r"\n{3,}")
MULTI_SP = re.compile(r"[ \t]+")


def _html_to_text(snippet: str) -> str:
    """Crude but effective HTML -> text: insert newlines at block boundaries,
    strip remaining tags, decode entities, collapse whitespace."""
    s = BLOCK_RE.sub("\n", snippet)
    s = INLINE_TAG_RE.sub("", s)
    s = html.unescape(s)
    s = NBSP_RE.sub(" ", s)
    s = MULTI_SP.sub(" ", s)
    s = MULTI_NL.sub("\n\n", s)
    return s.strip()


# Match the <dt id="..."> ... </dt> <dd> ... </dd> block for the
# requested identifier.  Tolerant of attribute order.
def _dt_dd_pattern(ident: str) -> re.Pattern:
    safe = re.escape(ident)
    return re.compile(
        r"<dt[^>]*\bid=\"" + safe + r"\"[^>]*>(?P<dt>.*?)</dt>"
        r"\s*<dd[^>]*>(?P<dd>.*?)</dd>",
        re.IGNORECASE | re.DOTALL,
    )


def _section_pattern(ident: str) -> re.Pattern:
    """Match <section id="..."> ... </section> for prose sections
    (e.g. 'thread-state-and-the-global-interpreter-lock')."""
    safe = re.escape(ident)
    return re.compile(
        r"<section[^>]*\bid=\"" + safe + r"\"[^>]*>(?P<body>.*?)</section>",
        re.IGNORECASE | re.DOTALL,
    )


def _h_anchor_pattern(ident: str) -> re.Pattern:
    """Some glossary terms anchor on <dt id="term-..."> with <dd> body."""
    return _dt_dd_pattern(ident)


def get_section(page: str, identifier: str) -> str | None:
    """Fetch `page` from docs.python.org and return the prose body of
    the `id="<identifier>"` element, plus its signature/heading."""
    html_text = fetch_page(page)
    if html_text is None:
        return None
    # 1. <dt id="..."><dd>...</dd> -- the common item form (functions,
    #    classes, methods, glossary terms).
    m = _dt_dd_pattern(identifier).search(html_text)
    if m:
        head = _html_to_text(m.group("dt"))
        body = _html_to_text(m.group("dd"))
        return f"{head}\n\n{body}".strip()
    # 2. <section id="..."> -- chapter/section prose.
    m = _section_pattern(identifier).search(html_text)
    if m:
        return _html_to_text(m.group("body"))[:8000]
    return None


if __name__ == "__main__":
    cases = [
        ("library/time", "time.sleep"),
        ("library/stdtypes", "boolean-type-bool"),     # docs anchor for bool
        ("reference/datamodel", "object.__hash__"),
        ("c-api/init", "thread-state-and-the-global-interpreter-lock"),
        ("glossary", "term-global-interpreter-lock"),
        ("library/time", "nonexistent.thing"),         # expect None
    ]
    for pg, ident in cases:
        out = get_section(pg, ident)
        if out is None:
            print(f"{pg}#{ident}: NOT FOUND")
        else:
            head = out.splitlines()[0] if out else ""
            print(f"{pg}#{ident}: {len(out)} chars; head: {head[:100]!r}")
