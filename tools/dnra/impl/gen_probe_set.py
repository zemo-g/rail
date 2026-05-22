#!/usr/bin/env python3
# Generator for the DNRA D-vs-base mode-separation probe set.
#
# Per design/FINETUNE_DEDUCTIVE.md Section 4.3: 30 deliberately mode-ambiguous
# prompts. Each prompt could plausibly elicit a Deductive-style answer (cite
# spec), an Empirical-style answer (describe running it), or an Adversarial-
# style answer (look for where it breaks).
#
# Discipline:
#   - No mode-biasing framing in the question itself ("explain", "describe",
#     "show me where" etc. tilt the model toward one mode).  Prefer "how
#     should I think about X" / "walk me through Y" / "compare A vs B".
#   - Mix domains: 10 Rail-specific, 10 general CS/programming, 10
#     reasoning/system-design.  Cross-domain reduces curator bias toward any
#     one mode.
#   - Topics drawn from areas where the falsification set already has signal,
#     so probe responses are interpretable against prior data.

import json

prompts = [
    # ── Rail-specific (10) ────────────────────────────────────────
    {"id": "P-001", "domain": "rail", "text": "How does Rail's fold differ from foldl in other languages?"},
    {"id": "P-002", "domain": "rail", "text": "What happens with head when applied to a non-list value in Rail?"},
    {"id": "P-003", "domain": "rail", "text": "Tell me about pattern match exhaustiveness in Rail."},
    {"id": "P-004", "domain": "rail", "text": "Why does Rail keep to_int float-only when string-to-int conversion is so common?"},
    {"id": "P-005", "domain": "rail", "text": "Walk me through what happens when Rail's bump allocator gets close to its limit."},
    {"id": "P-006", "domain": "rail", "text": "Is str_split worth using over multiple split calls when working with multi-character delimiters?"},
    {"id": "P-007", "domain": "rail", "text": "How would you write a tail-recursive Fibonacci in Rail?"},
    {"id": "P-008", "domain": "rail", "text": "How does Rail's GC interact with long-running self-recursive loops?"},
    {"id": "P-009", "domain": "rail", "text": "Compare arena-based allocation to malloc inside Rail's runtime."},
    {"id": "P-010", "domain": "rail", "text": "How should I think about Rail's effect handlers when designing error recovery?"},

    # ── General CS / programming (10) ─────────────────────────────
    {"id": "P-011", "domain": "general", "text": "When should you use a B-tree over a hash table?"},
    {"id": "P-012", "domain": "general", "text": "How does HTTP/2 multiplexing actually work?"},
    {"id": "P-013", "domain": "general", "text": "What is the practical difference between TCP_CORK and TCP_NODELAY?"},
    {"id": "P-014", "domain": "general", "text": "Explain Python's GIL in practical terms."},
    {"id": "P-015", "domain": "general", "text": "Why is it considered bad practice for C++ destructors to throw?"},
    {"id": "P-016", "domain": "general", "text": "Walk me through how virtual memory mapping works in a modern OS."},
    {"id": "P-017", "domain": "general", "text": "What is the actual cost of SELECT * on a one-billion-row table in PostgreSQL?"},
    {"id": "P-018", "domain": "general", "text": "Tell me how copy-on-write works in fork()."},
    {"id": "P-019", "domain": "general", "text": "Why does time.sleep(0) exist in Python?"},
    {"id": "P-020", "domain": "general", "text": "Compare Ed25519 to RSA-2048 for application-level signing."},

    # ── Reasoning / system design (10) ────────────────────────────
    {"id": "P-021", "domain": "reasoning", "text": "How should I think about read-after-write consistency in a distributed cache?"},
    {"id": "P-022", "domain": "reasoning", "text": "Walk me through the tradeoffs of monorepo versus polyrepo."},
    {"id": "P-023", "domain": "reasoning", "text": "When is microservices the wrong architectural call?"},
    {"id": "P-024", "domain": "reasoning", "text": "How should I think about idempotency versus at-least-once delivery?"},
    {"id": "P-025", "domain": "reasoning", "text": "How do you reason about retry storms in a distributed system?"},
    {"id": "P-026", "domain": "reasoning", "text": "What is the right way to model rate limits across multiple tenants?"},
    {"id": "P-027", "domain": "reasoning", "text": "How should observability differ between batch and streaming pipelines?"},
    {"id": "P-028", "domain": "reasoning", "text": "Walk me through how you would debug a memory-pressure incident on a production host."},
    {"id": "P-029", "domain": "reasoning", "text": "How do you make a system gracefully degrade versus fail open?"},
    {"id": "P-030", "domain": "reasoning", "text": "Why is exactly-once delivery semantics actually hard in practice?"},
]

assert len(prompts) == 30, f"expected 30 prompts, got {len(prompts)}"
counts = {}
for p in prompts:
    counts[p["domain"]] = counts.get(p["domain"], 0) + 1
assert counts == {"rail": 10, "general": 10, "reasoning": 10}, counts

with open("tools/dnra/sets/probe_v0.jsonl", "w") as f:
    for p in prompts:
        # Compact form (Rail-side parsers prefer no whitespace after : or ,).
        f.write(json.dumps(p, separators=(",", ":")) + "\n")
print(f"wrote {len(prompts)} prompts (10/10/10 across rail/general/reasoning) to tools/dnra/sets/probe_v0.jsonl")
