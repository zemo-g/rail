"""Convener v0 -- decides which panelist mode(s) to invoke.

Maps the existing classifier's output to a panel composition.  The
deliberation primitive: when both Deductive and Empirical can answer
a prompt, run BOTH and let the orchestrator surface the
agreement/disagreement geometry.

Output envelope (matches the convener.rail triage shape):
  {
    "path": "fast" | "deliberate",
    "modes": ["deductive"] | ["deductive","empirical"] | ["uncited"],
    "reason": "<short label from a closed set>",
  }

Reason labels (auditable -- one of):
  C0_runtime_behavior  -- prompt has "how does X work / what happens"
                          framing; empirical-leaning, deductive backup
  C1_spec_literacy     -- prompt has "does the spec say / required by /
                          defined behavior" framing; deductive-leaning
  C2_panel_default     -- ambiguous-but-cited question; run both
  C3_reasoning_only    -- no source can ground; uncited path
  C4_definition        -- trivial definition; deductive single-shot
"""

from __future__ import annotations
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT))
from tools.dnra.workshop.classifier import classify  # type: ignore[import-not-found]


# Runtime-behavior framing -> Empirical-leaning.
RUNTIME_FRAMING = re.compile(
    r"\b(?:what\s+happens|how\s+does\s+\S+\s+(?:work|behave|interact)|"
    r"walk\s+me\s+through\s+(?:what|how)|what\s+would\s+happen|"
    r"when\s+\S+\s+runs|tell\s+me\s+(?:what|how))\b",
    re.IGNORECASE,
)

# Spec-literacy framing -> Deductive-leaning.
SPEC_FRAMING = re.compile(
    r"\b(?:does\s+(?:the\s+)?spec(?:ification)?\b|is\s+\S+\s+(?:required|mandated|guaranteed)|"
    r"required\s+by|defined\s+(?:behavior|in\s+the\s+spec)|"
    r"according\s+to\s+(?:RFC|POSIX|the\s+spec))\b",
    re.IGNORECASE,
)

# Definitional framing -> trivial single-shot.
DEFINITION_FRAMING = re.compile(
    r"^\s*what\s+is\s+(?:a|an)?\s*\S+\s*\?", re.IGNORECASE,
)


def convene(prompt: str) -> dict:
    """Decide the panel composition for a prompt."""
    cls = classify(prompt)
    sources = cls["source_candidates"]
    needs_cite = cls["needs_cite"]

    if DEFINITION_FRAMING.match(prompt):
        return {
            "path": "fast",
            "modes": ["deductive"] if needs_cite and sources else ["uncited"],
            "reason": "C4_definition",
            "classification": cls,
        }

    if not needs_cite or not sources:
        return {
            "path": "fast",
            "modes": ["uncited"],
            "reason": "C3_reasoning_only",
            "classification": cls,
        }

    if RUNTIME_FRAMING.search(prompt):
        return {
            "path": "deliberate",
            "modes": ["empirical", "deductive"],
            "reason": "C0_runtime_behavior",
            "classification": cls,
        }

    if SPEC_FRAMING.search(prompt):
        return {
            "path": "fast",
            "modes": ["deductive"],
            "reason": "C1_spec_literacy",
            "classification": cls,
        }

    # Default for cited questions: run both, see if they agree.
    return {
        "path": "deliberate",
        "modes": ["deductive", "empirical"],
        "reason": "C2_panel_default",
        "classification": cls,
    }


if __name__ == "__main__":
    cases = [
        "Does RFC 8259 require JSON object keys to be unique?",
        "What happens with head when applied to a non-list value in Rail?",
        "How does fork() handle copy-on-write?",
        "Walk me through what happens when Rail's bump allocator gets close to its limit.",
        "How should I think about monorepo vs polyrepo?",
        "What is a hash table?",
        "Why does time.sleep(0) exist in Python?",
        "Is dict insertion order guaranteed in Python?",
    ]
    for c in cases:
        r = convene(c)
        modes_str = ",".join(r["modes"])
        print(f"Q: {c}")
        print(f"  modes=[{modes_str:<25}]  path={r['path']:<10}  reason={r['reason']}")
        print()
