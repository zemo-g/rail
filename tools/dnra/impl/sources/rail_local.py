"""Rail local documentation fetcher.

The first non-HTTP source family.  Reads ~/projects/rail/CLAUDE.md and
~/projects/rail/tools/dnra/HANDOFF.md off disk, splits by markdown
section header, returns the requested section's body.

Source identifiers accepted:
  "CLAUDE.md"           -- the project-level repo guide
  "HANDOFF.md"          -- the DNRA living working doc
  "tools/dnra/HANDOFF.md"     (alias)
  "tools/dnra/spec/SCHEMA.md" (also auto-resolvable)

Section identifiers: the markdown header text (case-insensitive,
matches `^#+\s*<text>\s*$` lines).  Examples:
  "Rail Compiler"
  "Rail Compiler Known Limitations"
  "Output Discipline"
  "Runtime Safety"             -- a subsection of "Rail Compiler"

Usage:
    from impl.sources.rail_local import get_section
    text = get_section("CLAUDE.md", "Rail Compiler Known Limitations")
    text = get_section("HANDOFF.md", "Locked decisions (2026-05-22)")
"""

from __future__ import annotations
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
DEFAULT_FILES = {
    "claude.md": REPO / "CLAUDE.md",
    "rail claude.md": REPO / "CLAUDE.md",
    "rail/claude.md": REPO / "CLAUDE.md",
    "handoff.md": REPO / "tools/dnra/HANDOFF.md",
    "rail handoff.md": REPO / "tools/dnra/HANDOFF.md",
    "tools/dnra/handoff.md": REPO / "tools/dnra/HANDOFF.md",
    "tools/dnra/spec/schema.md": REPO / "tools/dnra/spec/SCHEMA.md",
    "schema.md": REPO / "tools/dnra/spec/SCHEMA.md",
}

HEADER_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$", re.MULTILINE)


def _resolve_file(source_id: str) -> Path | None:
    key = source_id.strip().lower()
    # exact alias hit
    if key in DEFAULT_FILES:
        p = DEFAULT_FILES[key]
        return p if p.exists() else None
    # path under the repo (allow either absolute or repo-relative)
    p = Path(source_id)
    if not p.is_absolute():
        p = REPO / source_id
    return p if p.exists() else None


def get_section(source_id: str, section_name: str) -> str | None:
    """Return the body of the named section, or None if not found."""
    p = _resolve_file(source_id)
    if p is None:
        return None
    try:
        text = p.read_text(encoding="utf-8")
    except OSError:
        return None
    headers: list[tuple[int, int, str, int]] = []
    for m in HEADER_RE.finditer(text):
        level = len(m.group(1))
        name = m.group(2).strip()
        headers.append((m.start(), m.end(), name, level))
    if not headers:
        return None

    want = section_name.strip().lower()
    # Tolerate "Section name" matching across exact, prefix, contains.
    for i, (start, hdr_end, name, level) in enumerate(headers):
        nlower = name.lower()
        if nlower == want or nlower.startswith(want) or want in nlower:
            # End of section = next header at SAME or SHALLOWER depth.
            end = len(text)
            for ns, _ne, _nn, nlevel in headers[i + 1:]:
                if nlevel <= level:
                    end = ns
                    break
            return text[start:end].rstrip()
    return None


if __name__ == "__main__":
    cases = [
        ("CLAUDE.md", "Output Discipline"),
        ("CLAUDE.md", "Rail Compiler Known Limitations"),
        ("CLAUDE.md", "Runtime Safety"),
        ("CLAUDE.md", "Rail Compiler"),
        ("HANDOFF.md", "Locked decisions"),
        ("CLAUDE.md", "nonexistent thing"),
    ]
    for src, sec in cases:
        out = get_section(src, sec)
        if out is None:
            print(f"{src}#{sec!r}: NOT FOUND")
        else:
            head = out.splitlines()[0][:80]
            print(f"{src}#{sec!r}: {len(out)} chars; head: {head!r}")
