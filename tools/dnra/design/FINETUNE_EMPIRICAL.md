# Finetune Spec: EMPIRICAL Panelist

**Status:** v0 scope. Pre-training, no code, no run.
**Base:** Llama 3.2 1B (LoRA). Production graduation: 3B if 1B mode-separates cleanly.
**Hardware:** Apple Silicon (24 GB unified, MLX preferred, PyTorch-MPS fallback).
**Sibling specs:** Deductive + Adversarial (separate files, same recipe family, divergent corpora).

---

## 1. Mode under training

Spec quote (`spec/FALSIFICATION.spec.md` §Mode embodiment):

> Empirical: "What does running this / measuring this show?" Best at: cases where data exists, observation is reliable, pattern-from-cases. Misses: when data is misleading, when the sample doesn't cover the edge case, when the right answer is unreachable by observation alone.

POC scoreboard against 40-problem set (HANDOFF.md 2026-05-22):
- right=26 / unique-right=2 (F-002, F-026) / lost-alone=3
- Unique wins live where the spec is silent and a runtime test resolves the question.
- Below the production ≥5 unique-right floor; held under the scaling thesis.

**Niche.** Impl-defined behavior, spec-silent corners, runtime quirks the docs don't mention.
**Failure mode.** Happy-path observation that misses pessimistic edges; hallucinated runtime traces.
**Adjacency risk.** E is hardest to separate from D. Both anchor on authoritative sources (D=spec, E=behavior). Mode collapse is the dominant failure for this panelist.

---

## 2. Corpus design

### 2.1 Theory of divergence (the load-bearing decision)

For E to be a real mode and not a Deductive cosplay, the corpus must teach:

1. **Run-then-cite shape.** Every Empirical target answer references a concrete observation: a return value, a measured latency, a REPL transcript, a hex dump, a stdout line. Not "the docs say X."
2. **Sample contamination.** A non-trivial slice of the corpus contains observations that *contradict each other across versions / platforms / build flags*. The Empirical answer must say so. Teaches E to volunteer the impl-defined caveat, not paper over it.
3. **Pessimistic-edge bias.** When the prompt invites a one-shot test, the Empirical target shows a multi-input sweep (small / medium / boundary / adversarial). The corpus penalises "I tried n=10 and it worked" as a complete answer.
4. **Spec-silent priority.** A heavy fraction of the corpus is questions where the official docs are silent or contradicted by behavior. E should win these; D should defer. The corpus must over-represent this niche to force divergence.

### 2.2 Sample pairs (held out from the falsification set)

```
(prompt) "In CPython 3.12, what does sys.intern('') return identity-wise across
two separate calls in the same process?"
(target) "Ran both calls, compared with `is`: True. CPython interns the empty
string as a singleton -- observed identical id() across calls. Note: behavior
is CPython-specific; the Python language reference does not mandate empty-string
interning, so PyPy or Jython may differ. Verified on CPython 3.12.4 (macOS arm64)."
```

```
(prompt) "Does `numpy.array([1, 2, 3]) + numpy.array([1, 2])` raise immediately
or broadcast in numpy 2.0?"
(target) "Ran it on numpy 2.0.1: ValueError, operands could not be broadcast
together with shapes (3,) (2,). Immediate raise at the BLAS dispatch layer,
not lazy. Same shape mismatch in numpy 1.26 also raises. Confirmed on both."
```

```
(prompt) "In Rail (current master), what does `mod -7 3` evaluate to?"
(target) "Ran `main = let _ = print (show (mod -7 3)) 0`: output is 2.
Rail's mod follows Euclidean / non-negative-result convention here, not
C-style truncated division (which would give -1). Confirmed with a second
case: mod -1 3 -> 2. The compile.rail source path that emits mod
matches this observation; no separate floor-mod helper exists."
```

```
(prompt) "Does `dict | None` annotation work as a type hint at runtime in
Python 3.9?"
(target) "Tried on CPython 3.9.18: `dict | None` raises TypeError at module
load time -- the PEP 604 union syntax is 3.10+. On 3.10.13 it returns
types.UnionType without error. Annotation evaluation is what triggers the
failure; `from __future__ import annotations` defers the error to
introspection time."
```

```
(prompt) "How many decimal digits of precision does an IEEE 754 binary64
preserve in a round-trip through str()?"
(target) "Ran a sweep: 0.1, 0.2, ..., 1.0 each round-trip clean through
repr(); through str() they also round-trip on CPython 3.12 because
str(float) uses the shortest-repr algorithm (Grisu/Ryu) that picks a
representation distinguishing the float from its neighbors. Counter-test:
math.pi at 17 digits round-trips; at 15 it does not. Observed precision
ceiling: 17 significant decimal digits."
```

Each pair (a) leads with the run, (b) names the platform/version, (c) volunteers a caveat or counter-test, (d) does not quote a docs paragraph as the load-bearing evidence.

### 2.3 Size + composition

Order of magnitude: **~3,000 to 5,000 pairs**. Below 2k risks LoRA underfit at rank 16; above 8k is plausibly wasted on a 1B base for a single mode.

Split by niche:

| Bucket | Share | Notes |
|---|---|---|
| Spec-silent (impl-defined, version skew, platform skew) | 35% | This is E's unique-right niche. Over-represent vs D. |
| Runtime quirks (REPL artifacts, build-flag effects, GC timing) | 20% | Forces "observation has noise" framing. |
| Multi-input sweeps (small / boundary / adversarial trio) | 20% | Teaches pessimistic-edge habit. |
| Honest "matches docs" (E agrees with D, both correct) | 15% | Convergence baseline; prevents over-training contrarianism. |
| "I cannot observe this" abstentions | 10% | Hardware unavailable, historical version, etc. E must refuse, not hallucinate. |

### 2.4 Sources (all locally reachable)

- **Already on disk (private training repo):** `training/git_harvest.jsonl`, `claude_rail.jsonl`, `builtin_examples.jsonl`, `real_programs.jsonl`. Repurpose for the run-then-cite shape: for each Rail example, execute via `rail_native run` and append the observed stdout as the target's evidence line.
- **Compiler oracle traces:** drive `./rail_native run` over a synthesised problem bank; capture (source, stdout, exit) tuples. This is the most reliable factory for genuine empirical pairs in our environment.
- **REPL transcripts** from CPython, Node, Rail (`tools/repl.rail`). Captured locally; no scraping.
- **Test logs from this repo:** `./rail_native test` output across recent git history surfaces version-skew observations.
- **Golden / bench writeups (private training repo):** `training/rail_native/BENCH_*.md`, `MODEL_CARD_*.md` already contain "we measured X, got Y" prose -- mine it for shape, not content.
- **Manual curation** of well-known impl-defined corners (Python, JS, Rail, C, SQL, TLS). Curator pulls from memory + a one-line REPL check; we are not scraping the web.

Do **not** propose to scrape Stack Overflow, GitHub issues at scale, or vendor docs. Anything we cannot regenerate locally is not in scope.

### 2.5 Anti-collapse mechanic

The corpus must include ~15% of pairs where the *prompt looks like a Deductive question* (asks "what does the spec say?") but the *target leads with the run anyway*: "Before reading the spec I ran X; observed Y. The spec at §6.2 confirms this." The target acknowledges the spec but anchors on observation first. This is the surgical lever against E→D collapse.

---

## 3. LoRA recipe

Conventions cribbed from the Llama-3 small-LoRA community (HF PEFT defaults + the QLoRA paper's middle ground). Numbers are starting points, not lock-ins; first pass adjusts after the eval below.

| Param | Value | Note |
|---|---|---|
| Base model | `meta-llama/Llama-3.2-1B` | Instruct variant if SFT-style; base if completion-style. Pick instruct for v0 since targets are conversational. |
| Adapter | LoRA (MLX-LM if available, else PEFT on MPS) | bitsandbytes int4 not used (no CUDA). |
| Rank `r` | 16 | Convention for 1B; 8 underfits this corpus size, 32 is wasteful. |
| `alpha` | 32 | `alpha = 2*r` per QLoRA. |
| Target modules | `q_proj`, `k_proj`, `v_proj`, `o_proj` (attention only first; expand to MLP only if mode separation fails) | Attention-only is the cheapest run; MLP adapters double param count. |
| Dropout | 0.05 | Mild; corpus is small. |
| Learning rate | 2e-4 | LoRA convention for 1B. |
| Scheduler | cosine, no restarts | Linear warmup 3% of total steps. |
| Batch size | 4 sequences, grad-accum 8 (effective 32) | 24 GB unified RAM, 1B, seq 1024 is comfortable; bump seq before batch. |
| Max sequence length | 1024 | Most pairs are short; 1024 covers the multi-input-sweep targets. |
| Epochs | 3 | At 4k pairs / batch 32 → ~375 steps/epoch → ~1100 steps total. |
| Total steps | ~1100 | Eyeball; first checkpoint at step 200. |
| Weight decay | 0.0 | LoRA on small corpora; decay tends to hurt. |
| Optimizer | AdamW (or MLX's Adam) | bf16 if available else fp16. |
| Eval cadence | Every 100 steps | Cheap on 40-problem set. |
| Save cadence | Every 200 steps | Keep last 3. |
| Wall-clock budget | < 6 hours on the train host | If it exceeds, drop epochs to 2 and re-evaluate. |

Sources: HF PEFT LoRA defaults, the QLoRA paper's small-model recipe, the MLX-LM examples folder. Convention-driven, not load-tested for this specific corpus.

---

## 4. Success criteria

### 4.1 Held-out eval set

- **Size:** 60 prompts. Built separately from the falsification 40; same shape (`prompt, target_with_observed_evidence`).
- **Composition:** mirrors the corpus niche split (35% spec-silent, 20% runtime quirks, etc.) but with no exact-string overlap with training pairs.
- **Grading:** mixed.
  - 40 of 60 are auto-graded: target is a known stdout/value; pass if the model's generated answer contains the value AND a phrase from the small whitelist `{"ran", "observed", "measured", "executed", "REPL", "stdout"}` AND does **not** lead with a docs quote.
  - 20 of 60 are hand-graded for rationale shape (does the answer cite an observation? did it volunteer a caveat? did it abstain when unobservable?). Two-tier rubric: pass / fail. Goal: hand-grader is mechanical; spend < 5 min per item.
- **Build effort:** ~3-4 hours. Single curator. Done before training kicks off.

### 4.2 Replay against falsification set

After training, replay the 40 problems through the trained E panelist. For each problem, capture the model's `(prediction, rationale)` and run two checks:

1. **Prediction match:** does the model's prediction match `mode_predictions.empirical.prediction` from the JSONL? Acceptable threshold: **≥ 30 / 40 (75%)**. Below 30 means the trained panelist is not behaving like the curator's E model; investigate before declaring success.
2. **E-niche match:** on the 2 problems where E is uniquely right in the curator's ledger (F-002, F-026), does the model match the oracle? Both must pass. Below 2 / 2 is a hard fail (the niche is the whole point).
3. **Spec-silent generalisation:** on the 10 problems we estimate are spec-silent in some sense (F-001, F-002, F-003, F-022, F-026, F-029, F-030, F-031, F-034, F-039 -- to be confirmed by re-tagging during eval set construction), does the model produce observation-anchored rationales (auto-detector: contains `{"ran", "observed", ...}` and does **not** start with `"the docs"` / `"the spec"`)? Threshold: **≥ 7 / 10**.

### 4.3 Mode separation test (load-bearing)

Pair-wise comparison against the (yet-to-be-trained) Deductive panelist. The single most informative test:

> Run both panelists against the *same* 40-problem falsification set under the *same* prompt template. For each problem, label the response **D-shape** if it leads with a docs/spec citation, **E-shape** if it leads with an observation/run, **other** otherwise. The test passes if: on the 25 problems where the curator's D and E predictions diverge (different `prediction` strings between `mode_predictions.deductive` and `mode_predictions.empirical`), **the trained E panelist produces an E-shape response in ≥ 18 / 25** *and* its prediction agrees with the curator's E entry in ≥ 15 / 25.

Auto-graded via the same lexical detector as §4.2. The number that matters is **D-shape vs E-shape rate on divergence problems**, not raw accuracy -- mode separation is shape, not score.

If the trained E panelist's responses are >50% indistinguishable from D's by this classifier, modes collapsed. Drop back to shared-base finetuning failure, escalate to the cross-family fallback (Llama + Gemma + Phi-3 panel).

### 4.4 Pass conditions (all three must hold)

1. Held-out eval (§4.1) auto-grade ≥ 30 / 40 and hand-grade ≥ 14 / 20.
2. Falsification replay (§4.2): prediction match ≥ 30 / 40; E-niche match 2 / 2; spec-silent rationale shape ≥ 7 / 10.
3. Mode separation (§4.3): E-shape rate ≥ 18 / 25 on D/E divergence problems.

Miss any → do not graduate to 3B; iterate corpus.

---

## 5. Expected mode behavior (4 concrete patterns)

Drawn from falsification set rationales; each shows what the trained E should output given a problem of that flavor.

**Pattern 1 — Spec-silent observation (F-002 style).**
> Prompt: "Does Python 3.12 preserve dict insertion order?"
> Expected E: "Ran `d = {'a':1, 'b':2, 'c':3}; print(list(d.keys()))` on CPython 3.12.4: ['a', 'b', 'c']. Re-ran across three processes: same order each time. The language spec formalised this in 3.7; before then it was a CPython implementation detail. Observed behavior matches the post-3.7 guarantee."

**Pattern 2 — Impl-defined corner the spec doesn't mention (F-026 style).**
> Prompt: "Does `() is ()` return True in CPython 3.12?"
> Expected E: "Ran in CPython 3.12.4 REPL: True. Tested across two separate process launches: still True. CPython interns the empty tuple as a singleton -- this is an implementation detail; the Python language reference does not require it, so PyPy / Jython may differ."

**Pattern 3 — Happy-path observation traps E (F-003 / F-005 style; E loses alone).**
> Prompt: "If `f` is documented as a 'partial function', does it always terminate?"
> Expected E (acknowledging the trap): "Tested f on sample inputs n=1..100: all returned. Observation suggests termination. *Caveat:* 'partial' is a formal term meaning f may be undefined on some inputs -- my sample may not cover those. If the question hinges on the formal contract, defer to Deductive."

The E response should *acknowledge* when observation is insufficient. Honest abstention is corpus-trained behavior (10% slice in §2.3).

**Pattern 4 — Pessimistic-edge sweep (anti-happy-path).**
> Prompt: "Does `int(math.sqrt(N))**2 <= N` always hold for non-negative N?"
> Expected E: "Tested N = 0..10000: holds in every case. *Pessimistic sweep:* N = 10**18, N = 2**62, N = (10**9)**2 - 1. At N = 10**18 the relation breaks: `int(math.sqrt(10**18))**2 = 999999999999999488**2 = 1e36 - ...` (overflows the floor). Holds for small N, fails near the fp64 precision limit. Use math.isqrt for guaranteed-correct integer sqrt."

(Note: F-032 is curator-tagged as A-unique; if E is trained to sweep pessimistic inputs, E *can* reach the same answer through observation. This is intentional -- E and A overlap on edge cases reachable by sampling; the orthogonality lives in the cases where the edge is unreachable by sampling and only conceptual fault-finding gets there.)

---

## 6. Risks

### 6.1 Mode collapse to Deductive (THE risk)

D and E are epistemic siblings on documented questions. On well-specified material the two converge by construction -- spec matches behavior in healthy systems. A LoRA trained on a corpus that mixes both shapes will average toward whichever is more frequent. Mitigation: the 35% spec-silent + 15% prompt-looks-like-D-but-target-leads-with-run slices, plus the §4.3 mode-separation gate. If gate fails, the corpus needs more spec-silent content, not more training steps.

### 6.2 Hallucinated runtime observations

LLMs are excellent at inventing plausible REPL transcripts. A trained E panelist could fabricate "ran on CPython 3.12.4, got X" without ever having seen that observation. Two mitigations:
- Corpus targets only include observations we *actually* generated locally (compiler oracle, REPL captures). No second-hand observations. If we can't reproduce it, it doesn't go in.
- Eval-time spot check: for 5 random eval items, manually re-run the observation the model cites; flag fabrications. A high fabrication rate is a corpus-trust signal even if accuracy is good.

### 6.3 "E rarely wins" under-weighting

E was 2/40 unique-right in the falsification set. A naive read says "E barely matters." Under-training is the trap -- if the panelist defaults to deferring, E contributes no information. Mitigations:
- Train against the §4.2 prediction-match target (≥30/40), not the unique-right count. E *agrees with the oracle* often; that contribution matters even when not unique.
- The corpus over-represents E's niche relative to its natural frequency (35% spec-silent) so the model learns to volunteer observation even when D would also be right.

### 6.4 Corpus bootstrap is single-curator

Same risk that the falsification set carries (HANDOFF.md §2026-05-22 17:25): the curator who writes the corpus is also the curator who tagged the falsification set. Curator bias compounds. Mitigation acknowledged, not solved at POC: the bias dilutes at production scale with more curators / domains. Flag in the model card.

### 6.5 LoRA recipe is unvalidated for this corpus

The recipe in §3 is convention. Loss curves at the first checkpoint (step 200) decide whether to keep going. If training loss is flat after step 400, double LR. If validation diverges from training by step 600, drop to 2 epochs and reduce rank to 8.

---

## 7. Next steps (kick off the actual run)

1. Re-tag the 10 spec-silent problems in `sets/falsification_v0a+b+c.jsonl` with a `spec_silent: true` field so §4.2 auto-eval has the slice without re-reading.
2. Stand up a small `corpus_gen/` directory under `tools/dnra/impl/`. Three generators: rail-oracle (drives `rail_native run`), python-repl (subprocess + capture), curated-yaml (hand-written impl-defined pairs).
3. Generate corpus v0.1: target 1,000 pairs across the §2.3 niche split. Spot-check 50 by hand for run-then-cite shape; reject and regenerate any with docs-leading targets.
4. Build the 60-prompt held-out eval (§4.1). Hand-curate; no machine generation. Sign + chain-append the eval set hash to the DNRA ledger before training, so we can't tweak it after-the-fact.
5. Confirm Llama 3.2 1B weights are local (`ls ~/.cache/huggingface/hub/models--meta-llama--Llama-3.2-1B*` or equivalent) and MLX-LM is installed. If not, fetch + smoke-test inference on the base model.
6. Write `tools/dnra/impl/train_empirical.py` (Python, not Rail -- training is the one place we use Python). Wraps MLX-LM `lora.py` with the §3 recipe and our corpus path. Loss curve + eval cadence to a sidecar log.
7. Scale up to corpus v0.2 (3,000-5,000 pairs) once v0.1 spot-check passes. Same generators; just run them longer.
8. Kick off the run with `nohup` (per the detached-pipeline rule). Expected wall clock < 6 h. First eval at step 200; abort and re-tune if step-200 eval auto-grade is < 10 / 40 (proxy for "training is wrong direction").
9. At step 1100 (end of training), run §4.1 + §4.2 + §4.3 in sequence. Sign the eval JSON; chain-append a `kind: "ledatic.dnra.eval"` entry referencing the model checkpoint hash.
10. If all three pass conditions hit, draft the Deductive + Adversarial finetune specs (same shape, different niche). If any fail, write the failure mode into the ledger and iterate corpus before re-training.

---

## 8. Out of scope (deliberately)

- Convener routing (when does E even get asked?) -- separate ticket.
- Arbiter weighting by mode-accuracy -- arbiter v1, post-finetune.
- Multi-node panelist deployment -- single-node POC first.
- Cross-family panel composition -- plan B, only if shared-base collapses.
- Production graduation to 3B -- gated on this 1B run passing §4.4.
