"""Source retriever v0 -- deterministic section selection.

Given a list of source_candidates from classifier, fetch the most
relevant section text.

Strategy v0:
  - For RFC sources: tokenize the prompt into content words, score each
    section by word overlap, return the top-scoring section.
  - For POSIX sources: default to the DESCRIPTION section of the named
    function.
  - Returns None if nothing applies.

This is the cheapest possible retriever that still does real work.
v1 would use BM25 or a small embedding model; v0 keyword-overlap is
enough to validate the orchestration shape.
"""

from __future__ import annotations
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT))
from tools.dnra.impl.sources.rfc import fetch_rfc  # type: ignore[import-not-found]
from tools.dnra.impl.sources.posix import get_section as posix_get_section  # type: ignore[import-not-found]


# Match RFC section headers at column 0.  Mirrors impl/sources/rfc.py.
SECTION_HDR = re.compile(r"^(?P<id>\d+(?:\.\d+)*)\.?\s+\S", re.MULTILINE)

STOPWORDS = frozenset(
    "the a an and or but if then of in on at to for from with by as is are was "
    "were be been being do does did has have had can could should would may might "
    "must will shall this that these those it its their there what which who when "
    "where why how does what's whats".split()
)


def _content_words(text: str) -> list[str]:
    """Lowercase tokens >=4 chars, no stopwords, no punctuation-only."""
    toks = re.findall(r"[A-Za-z][A-Za-z_]+", text.lower())
    return [t for t in toks if len(t) >= 4 and t not in STOPWORDS]


def _split_rfc_into_sections(text: str) -> list[tuple[str, int, int]]:
    """Return [(section_id, start_offset, end_offset), ...] for top-level RFC sections."""
    matches = list(SECTION_HDR.finditer(text))
    out = []
    for i, m in enumerate(matches):
        sid = m.group("id")
        start = m.start()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        out.append((sid, start, end))
    return out


def _retrieve_rfc(rfc_num: int, prompt: str) -> dict | None:
    text = fetch_rfc(rfc_num)
    if text is None:
        return None
    prompt_words = set(_content_words(prompt))
    if not prompt_words:
        return None
    sections = _split_rfc_into_sections(text)
    if not sections:
        return None
    best = None
    best_score = -1
    for sid, s, e in sections:
        body = text[s:e]
        if len(body) < 200:
            continue  # too short, skip header-only sections
        body_words = set(_content_words(body))
        score = len(prompt_words & body_words)
        # Penalize TOC / references / acknowledgments / appendix-ish sections
        if re.search(r"^(?:table of contents|references|acknowledg|appendix|authors?)", body[:80], re.IGNORECASE):
            score -= 5
        if score > best_score:
            best_score = score
            best = (sid, s, e, body)
    if best is None or best_score <= 0:
        # Fallback: section 1 (Introduction) is usually safe
        if sections:
            sid, s, e = sections[0]
            return {
                "source": f"RFC {rfc_num}",
                "section": sid,
                "text": text[s:e][:4000],
                "score": 0,
                "fallback": True,
            }
        return None
    sid, s, e, body = best
    return {
        "source": f"RFC {rfc_num}",
        "section": sid,
        "text": body[:6000],  # cap to keep prompt budget reasonable
        "score": best_score,
        "fallback": False,
    }


def _retrieve_posix(func_name: str) -> dict | None:
    body = posix_get_section(func_name, "DESCRIPTION")
    if not body:
        return None
    return {
        "source": "POSIX.1-2017",
        "section": f"{func_name} / DESCRIPTION",
        "text": body[:6000],
        "score": 1,
        "fallback": False,
    }


def retrieve(source_candidates: list[tuple[str, object]], prompt: str) -> dict | None:
    """Return the best retrieved section across all candidates, or None."""
    best = None
    best_score = -1
    for kind, ident in source_candidates:
        if kind == "rfc":
            r = _retrieve_rfc(int(ident), prompt)
        elif kind == "posix":
            r = _retrieve_posix(str(ident))
        else:
            r = None
        if r is None:
            continue
        if r["score"] > best_score:
            best_score = r["score"]
            best = r
    return best


if __name__ == "__main__":
    cases = [
        ([("rfc", 8259)], "Does RFC 8259 require JSON object keys to be unique?"),
        ([("posix", "fork")], "What does fork() do when called by a thread?"),
        ([("rfc", 8446), ("rfc", 5246)], "How does TLS 1.3 differ from TLS 1.2 in key exchange?"),
        ([("rfc", 7540)], "Does HTTP/2 RST_STREAM immediately terminate the stream?"),
    ]
    for sources, prompt in cases:
        r = retrieve(sources, prompt)
        print(f"  Q: {prompt}")
        if r is None:
            print("     -> NO RETRIEVAL")
        else:
            print(f"     -> {r['source']} sec {r['section']} (score={r['score']}, fallback={r['fallback']})")
            print(f"        head: {r['text'][:200]!r}")
        print()
