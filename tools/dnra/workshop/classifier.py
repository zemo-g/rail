"""Citation-need classifier v0 -- deterministic pattern rule.

Given a prompt, decide:
  - needs_cite: bool      -- should the answer include a Cite line?
  - source_candidates: list[tuple[str, str|int]]
      e.g. [("rfc", 8259), ("posix", "fork")]
      Empty list if no specific source can be inferred.

This is the cite-then-derive analog of CONVENER.v0.spec.md's R0..R5
rule.  Deterministic on purpose: lets us prove the orchestration shape
before swapping in a learned classifier.
"""

from __future__ import annotations
import re

# Direct RFC mention takes priority.
RFC_MENTION = re.compile(r"\bRFC\s*(\d+)\b", re.IGNORECASE)

# POSIX function names that appear in the existing POSIX cache.
POSIX_FN_NAMES = (
    "open", "close", "read", "write", "lseek", "dup", "dup2", "fcntl",
    "fstat", "stat", "fork", "exec", "execl", "execv", "execvp",
    "wait", "waitpid", "_exit", "kill", "pthread_create",
    "pthread_join", "pthread_mutex_lock", "sigaction", "sigprocmask",
    "fsync", "fdatasync", "ftruncate", "unlink", "rename", "mmap",
    "sysconf", "alarm", "access", "chmod", "sleep", "signal", "getpid",
    "getppid",
)
# Require parentheses after the function name (or word boundary on both
# sides) so we don't false-match 'close' inside 'close to the limit' or
# 'open' inside 'fail open' or 'read' inside 'read-after-write'.
POSIX_PAT = re.compile(
    r"\b(" + "|".join(POSIX_FN_NAMES) + r")\s*\(\)?", re.IGNORECASE
)

# Topic -> RFC. Add freely; this is just a hint table.
TOPIC_HINTS: list[tuple[int, re.Pattern]] = [
    (8259, re.compile(r"\bJSON\b", re.IGNORECASE)),
    (8446, re.compile(r"\bTLS\s*1\.?3\b", re.IGNORECASE)),
    (5246, re.compile(r"\bTLS\s*1\.?2\b", re.IGNORECASE)),
    (7540, re.compile(r"\bHTTP/?\s*2\b", re.IGNORECASE)),
    (9110, re.compile(r"\bHTTP\s+semantics\b", re.IGNORECASE)),
    (9114, re.compile(r"\bHTTP/?\s*3\b", re.IGNORECASE)),
    (1034, re.compile(r"\bDNS\b|\bNXDOMAIN\b", re.IGNORECASE)),
    (8259, re.compile(r"\bobject\s+keys?\b", re.IGNORECASE)),
    (5280, re.compile(r"\bX\.?509\b|\bPKIX\b", re.IGNORECASE)),
    (9000, re.compile(r"\bQUIC\b", re.IGNORECASE)),
    (6749, re.compile(r"\bOAuth\b", re.IGNORECASE)),
    (7519, re.compile(r"\bJWT\b", re.IGNORECASE)),
    (791, re.compile(r"\bIPv4\b|\bIP\s+packet\b", re.IGNORECASE)),
    (793, re.compile(r"\bTCP\b", re.IGNORECASE)),
    (8200, re.compile(r"\bIPv6\b", re.IGNORECASE)),
    (6376, re.compile(r"\bDKIM\b", re.IGNORECASE)),
    (5321, re.compile(r"\bSMTP\b", re.IGNORECASE)),
]

# Reasoning-style framings that signal a NO-CITE response.  Lifted from
# the corpus_d_balance NC bucket -- these are the kinds of questions
# where a citation would be cargo-culting.
NO_CITE_FRAMING = re.compile(
    r"\b(how should i think|compare|tradeoffs?|when is|when should|"
    r"why might|walk me through|what should we|how do you|"
    r"thoughts on|opinion|design philosophy|architectural|pros and cons)\b",
    re.IGNORECASE,
)


def classify(prompt: str) -> dict:
    """Return {needs_cite, source_candidates, rationale}."""
    sources: list[tuple[str, object]] = []

    # 1. Direct RFC number wins immediately.
    rfc_m = RFC_MENTION.search(prompt)
    if rfc_m:
        sources.append(("rfc", int(rfc_m.group(1))))

    # 2. POSIX function names.
    for m in POSIX_PAT.finditer(prompt):
        fn = m.group(1).lower()
        if ("posix", fn) not in sources:
            sources.append(("posix", fn))

    # 3. Topic-to-RFC hints.
    for rfc_num, pat in TOPIC_HINTS:
        if pat.search(prompt) and ("rfc", rfc_num) not in sources:
            sources.append(("rfc", rfc_num))

    # 4. Decide needs_cite.
    if sources:
        needs_cite = True
        rationale = "specific source hint present in prompt"
    elif NO_CITE_FRAMING.search(prompt):
        needs_cite = False
        rationale = "reasoning-framing detected (compare/tradeoffs/how-should-I-think)"
    else:
        # No source hint AND no reasoning framing -- ambiguous. Default
        # to no-cite so we don't fabricate.  Strictly safer than the
        # opposite default; the corpus failure mode was over-citing.
        needs_cite = False
        rationale = "ambiguous prompt with no specific source hint; defaulting no-cite"

    return {
        "needs_cite": needs_cite,
        "source_candidates": sources,
        "rationale": rationale,
    }


if __name__ == "__main__":
    # Smoke
    cases = [
        "Does RFC 8259 require JSON object keys to be unique?",
        "What does fork() do when called by a thread?",
        "How should I think about idempotency vs at-least-once delivery?",
        "Walk me through monorepo vs polyrepo tradeoffs.",
        "What is a hash table?",
        "Explain Python's GIL in practical terms.",
        "How does TLS 1.3 differ from TLS 1.2 in key exchange?",
    ]
    for c in cases:
        r = classify(c)
        print(f"  Q: {c}")
        print(f"     needs_cite={r['needs_cite']}  sources={r['source_candidates']}  ({r['rationale']})")
        print()
