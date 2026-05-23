"""DNRA workshop -- orchestrated cite-then-derive panelist.

The Deductive panelist is not a model; it's a workflow:

    prompt
      |
      v
    classifier        (deterministic v0; learned classifier later)
      |
      v
    needs_cite?  ----no--->  deriver (no retrieved text; produces uncited answer)
      |
      yes
      v
    retriever         (deterministic v0; learned retriever later)
      |
      v
    section_text
      |
      v
    deriver           (LLM call: prompt + retrieved section text -> answer with grounded Cite)
      |
      v
    runtime gate      (impl/verify_runtime + impl/score_probe.py)

Each step is small and independently verifiable.  The model never has
to recall section numbers from training data -- the retriever brings
the actual text to the model at inference time.  The model's job is
just to quote and derive, both of which a small LLM can do.

Components in this package:
    classifier.py     -- pattern-based citation-need predictor
    retriever.py      -- RFC/POSIX/local-doc section fetcher
    deriver.py        -- pluggable LLM backend (default: Studio 122B via tunnel)
    orchestrator.py   -- chains the three; takes a prompt, returns an attested answer
"""
