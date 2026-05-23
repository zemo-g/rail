# DNRA Workshop -- orchestrated cite-then-derive panelist

The Deductive panelist is not a model.  It's a workflow.

```
prompt
  |
  v
classifier (deterministic v0)
  | needs_cite?
  +-- no --> deriver_uncited(prompt)               --> uncited prose
  |
  +-- yes
        |
        v
      retriever (deterministic v0; fetches the section text)
        |
        v
      deriver_cited(prompt, retrieved)              --> answer with grounded Cite
        |
        v
      runtime gate (verify_runtime + score_probe.py --strict)
```

## Why this exists

The original DNRA plan trained a small LLM (Llama 3.2 1B/3B + LoRA) on a
1,794-pair citation-verified corpus to produce a Deductive panelist.  The
training succeeded at teaching CITATION FORMAT (cite-then-derive shape)
but failed at teaching CITATION CONTENT.  All five trained adapters
produced ZERO grounded citations across hundreds of cite attempts.  See
the full session log in `../HANDOFF.md`.

The diagnosis: SFT on a verified corpus DOES NOT TRANSFER the verification
process to the model.  The model learns the surface shape and confidently
fabricates section numbers that don't exist.

The workshop fixes this by NOT trying to encode the workflow into a
single model's weights.  Each step is small and verifiable on its own.

## Components

  classifier.py    -- pattern rule.  Decides needs_cite + source_candidates.
                      Mirrors CONVENER.v0.spec.md's R0-R5 pattern.

  retriever.py     -- given source_candidates, fetches the most relevant
                      section text via tools/dnra/impl/sources/{rfc,posix}.py.
                      Keyword-overlap scoring; top section wins.

  deriver.py       -- HTTP client to an OpenAI-compatible chat endpoint.
                      Default: Studio's Qwen3.5-122B at localhost:8082 via
                      SSH tunnel.  Two prompt templates -- one for cited
                      (RAG-fed) and one for uncited (plain prose).

  orchestrator.py  -- chains the three.  `answer(prompt)` returns
                      {response, classification, retrieval, path, time}.
                      `run_probe(tag)` runs the 30-prompt probe and writes
                      JSONL in the existing probe_responses_*.jsonl shape.

## v0 results

Workshop v0 on the 30-prompt probe (vs. base Llama 3.2 1B with temp=0.7 +
min-tokens=64):

  total cites emitted:    7
  grounded (PASS):        5  (71%)
  fabricated (FAIL):      2  (29%)
  fabrication rate:       29% (just below 30% ceiling)
  responses_with_fab:     2/30 (7%)

For comparison, the best SFT'd D-LoRA in the session (3B Llama + balanced
2094-pair corpus):

  total cites emitted:    34
  grounded:               0
  fabricated:             9
  fabrication rate:       26%
  responses_with_fab:     6/30 (20%)
  GROUNDING RATE:         0%   (0/11 verifiable attempts)

The workshop produces grounded citations where every SFT attempt failed.

The single gate flag fired on workshop v0 is `length_ratio = 0.41 < 0.50`.
That's because the deriver's system prompt asks for concise 2-4 sentence
responses (the Deductive style) while base produces verbose explanations.
Tunable -- either loosen the gate for the Deductive regime or extend
deriver prompts to include more derivation.

## Known v0 issues / tunable next

  - Classifier word-boundary discipline.  v0.1 just tightened the POSIX
    function regex to require `(` after the name -- otherwise `close` in
    "close to its limit" or `open` in "fail open" matched and routed
    irrelevant retrievals to the deriver.  The model recovered honestly
    ("the supplied text does not describe X"), but the cite still went
    through the gate as bad-quote.
  - Retriever uses keyword overlap.  Misses semantic matches (e.g.
    "interoperability" in the prompt vs. "interoperable" in the section).
    v1: BM25 or a small embedding model.
  - No Python/Rust/Rail-local source fetchers yet.  Cite hint for those
    families currently routes via the verifier as NO_VERIFIER.  Mirror the
    `sources/rfc.py` pattern when adding them.
  - The deriver's max_tokens=400 caps responses.  Combined with the
    "concise" system prompt this drives length_ratio below the gate
    floor.  Either increase the cap + loosen the conciseness ask, or
    accept that deductive-style responses are shorter than base's
    verbose default.

## Why this design beats SFT for the Deductive role

  - The model never needs to recall section numbers from training data.
    The retriever brings the actual text inline.  Citations are GROUNDED
    by construction.
  - Adding a new source family means writing a fetcher, not retraining.
    `sources/python_docs.py` would unlock 50+ probe prompts that
    currently get the uncited path.
  - The classifier is a single regex file.  Tunable in seconds.  A wrong
    classifier decision routes through the uncited path safely (no
    fabricated cite) rather than producing a bad cite.
  - The deriver is pluggable.  Today: Studio 122B.  Tomorrow:
    7B/13B local, Claude API, or a tiny specialized derivation head.
    The orchestration shape doesn't change.

## How this relates to DNRA's structural-uncertainty thesis

The original thesis: uncertainty is structural, not scalar -- a panel's
disagreement geometry IS the confidence signal.  We tried to encode that
structure into a single LoRA's weights.  The model collapsed the workflow
into a learned text-shape.

The workshop puts the structure back where it belongs: in the
orchestration.  Each step is independently verifiable.  The "Deductive"
panelist is a program, not a model -- a composition of (decide-need,
retrieve-source, derive-with-source).  The model is a tool inside it.

Empirical/Adversarial panelists will follow the same shape with different
deriver prompts.  Convener.v0 routes between them.  The whole DNRA
substrate -- the Ed25519-signed chain, the hardened gate, the runtime
verifier -- still applies, unchanged.

## Pickup protocol

  1. Confirm tunnel: `ps aux | grep "ssh.*8082"`; if down,
     `ssh -N -L 8082:localhost:8082 studio &` (Studio 122B must be
     loaded).
  2. Single-prompt: `python3 tools/dnra/workshop/orchestrator.py --prompt "..."`
  3. Full probe + score:
     `python3 tools/dnra/workshop/orchestrator.py --probe --tag <name>`
     then `score_probe.py --a probe_responses_base_v2.jsonl --b probe_responses_<name>.jsonl --strict`
  4. Inspect citations: `python3 tools/dnra/impl/verify_runtime.py tools/dnra/sets/probe_responses_<name>.jsonl --verbose`
