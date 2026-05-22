# Finetune Spec — Deductive Panelist

**Status:** scope-only. No training code. No training run.
**Target:** Llama 3.2 1B base, LoRA, Mini-hosted (M4 Pro, 24GB unified).
**Graduation:** Llama 3.2 3B if 1B clears the gate.
**Gate:** see Success Criteria below.

---

## 1. What this panelist is

From `spec/FALSIFICATION.spec.md`:

> Given premises P1...Pn, what follows? Best at: formal proof chains,
> logical entailment, premise-to-conclusion. Misses: when premises are
> subtly wrong, when the problem has no formal structure, when the right
> answer requires escaping the given framing.

Empirical posture on the 40-problem falsification set: D=36/40 right,
9 unique-right, 0 lost-alone. D is the workhorse. Its niche is
**documented invariants** — problems where the spec, RFC, language
reference, or compiler note IS the source of truth and behavior follows.

The training objective is NOT "make a Llama that scores higher on the
40-problem set." The set is held-out. The objective is to instantiate
a panelist whose response style is mode-recognizable as Deductive when
replayed across an unseen problem stream.

---

## 2. Corpus design

### 2.1 Theory

Train the **reasoning style**, not the facts. Each example pairs a
question with a Deductive-shaped answer: cite the authoritative source,
quote or paraphrase the load-bearing clause, derive the conclusion in
two to four steps. The corpus must teach the move "look up the invariant
that governs this question, then walk the implication," not "recall
that Python 3.7 guarantees dict order."

Anti-pattern: a corpus where (prompt, target) pairs are
question-and-answer-key. That trains lookup, and a 1B model with
1k-2k LoRA pairs has no capacity to lookup-by-memorization the world.
What it CAN learn in that budget is a response template + a posture.

### 2.2 Sample (prompt, target) pairs

These are not in any falsification set. Curated fresh.

**Pair D-001**

```
prompt:
  Does the C11 standard guarantee that sizeof(int) >= 2?

target:
  Yes. C11 section 5.2.4.2.1 defines INT_MIN <= -32767 and
  INT_MAX >= 32767, requiring int to represent values in
  [-32767, 32767]. A 16-bit two's-complement integer covers
  this range exactly, so any conforming implementation has
  sizeof(int) * CHAR_BIT >= 16. Since CHAR_BIT >= 8 (5.2.4.2.1),
  sizeof(int) >= 2 follows. Cite: ISO/IEC 9899:2011 5.2.4.2.1.
```

**Pair D-002**

```
prompt:
  In POSIX, does close(2) on a file descriptor guarantee that
  all buffered data has been flushed to the underlying device?

target:
  No. POSIX.1-2017 close(): "The close() function shall
  deallocate the file descriptor." It does not specify a flush
  to durable storage. fsync(2) is the operation defined to
  request that the file's contents be transferred to the
  storage device. Therefore close alone does not provide the
  guarantee; the program must call fsync (or equivalent)
  before close to obtain it.
```

**Pair D-003**

```
prompt:
  In Rust, can a value of type &mut T and a value of type &T
  coexist pointing to the same memory at the same time in
  safe code?

target:
  No. The borrow checker enforces the aliasing rule
  (Rust Reference, "References and Borrowing"): at any given
  time you can have either one mutable reference or any number
  of immutable references to the same data, never both. A safe
  program that constructed both would not compile. Unsafe code
  can violate this but the result is undefined behavior, not
  a counterexample to the rule.
```

**Pair D-004**

```
prompt:
  Does the JSON spec (RFC 8259) require keys in objects to
  be unique?

target:
  No, not strictly. RFC 8259 section 4: "The names within an
  object SHOULD be unique." SHOULD, not MUST. Parsers that
  encounter duplicate keys are permitted to accept the input;
  behavior is implementation-defined (last-wins is common but
  not mandated). Therefore "the JSON spec requires unique
  keys" is false; uniqueness is recommended.
```

**Pair D-005**

```
prompt:
  In Python, does the operator `is` test value equality?

target:
  No. The Python data model (docs.python.org/3/reference/
  datamodel.html, section "Objects, values, and types")
  specifies that `is` tests object identity, not value
  equality. `==` invokes __eq__ for value equality. The
  distinction matters when two equal-valued objects are
  separately allocated (e.g., two list literals): `==` is
  True, `is` is False.
```

### 2.3 Size estimate

Order of magnitude: **1,500-3,000 pairs** for the 1B LoRA. Rationale:

- LoRA on a 1B base with rank 16 has roughly 4-8M trainable params.
  Standard practice for instruction-style LoRA tunes at this scale is
  1k-10k examples (Alpaca: 52k, but that's for full instruction
  tuning; mode-shaping is narrower).
- Below ~1k the panelist may not depart from base-Llama default style.
- Above ~5k risk of overfitting the cite-this-RFC template; we want
  generalization to specs the model never saw quoted.
- Start at 1,500 (cheapest viable), grow to 3,000 only if mode-separation
  metric (Section 4.3) shows insufficient differentiation from base.

Production graduation to 3B: same corpus, no enlargement needed unless
mode-separation falters at the larger capacity (3B can absorb more
without overfitting; may benefit from doubling).

### 2.4 Sources usable from Mini

- **Public specs**: C11 draft N1570 (public PDF), POSIX.1-2017 (Open
  Group), RFCs (ietf.org), Python language reference, Rust reference,
  ECMA-262, IEEE 754 summary tables (the standard itself is paywalled
  but the structure is public).
- **Language references in /usr/share/doc and Homebrew**: bash man,
  zsh man, sed man (BSD), find man, awk man. These have rich
  "behavior is defined as ..." prose ideal for Deductive targets.
- **Rail's own docs**: CLAUDE.md sections, stdlib quick reference,
  HANDOFF docs across `~/projects/rail/`. Best source for problems
  about Rail itself; the model learns to quote project-internal
  invariants the same way it quotes RFCs.
- **Wikipedia "Specification" pages**: well-curated summaries of
  formal language, type theory, IEEE 754. Acceptable for paraphrased
  targets, not direct quote.

Not usable on Mini: anything requiring scraping behind auth
(IEEE Xplore, ACM DL, ISO direct). Skip those; the open-source
spec corpus is ample for 1.5-3k pairs.

### 2.5 Avoiding lookup-memorization

Three discipline rules:

1. **Every target cites the source by section number.** Trains the
   "look up invariant" move. Targets without a citation are rejected
   in QC.
2. **No more than 2 pairs per source document.** Forces breadth.
   We want Llama to recognize "this is a spec-literacy question" and
   reach for a citation, not memorize what RFC 8259 says.
3. **Half the pairs invert the obvious answer.** "Does X spec require
   Y?" with target "no, only recommends" forces the model to read the
   verb (MUST/SHOULD/MAY) rather than pattern-match on topic familiarity.

---

## 3. LoRA recipe

| Param | Value | Source |
|---|---|---|
| Base | Llama 3.2 1B Instruct | locked |
| Framework | MLX (mlx-lm `lora.py`) | Mini-native; no CUDA |
| Rank (r) | 16 | convention for 1B style transfer |
| Alpha | 32 | r * 2, standard |
| Dropout | 0.05 | standard |
| Target modules | q_proj, k_proj, v_proj, o_proj | attention-only first; expand to MLP if undertrained |
| Learning rate | 1e-4 | mlx-lm default for LoRA |
| Batch size | 4 | Mini 24GB RAM limit at 1B |
| Grad accum | 4 (effective 16) | for stable updates on tiny batches |
| Warmup steps | 50 | ~3% of 1500-step run |
| Total steps | ~1500 | one effective epoch over 1.5k pairs at eff-batch 16 = ~94 steps/epoch; train 16 epochs |
| Eval interval | every 100 steps | hold-out loss + sample generations |
| Max seq len | 1024 | targets are short; longer wastes RAM |
| Optimizer | AdamW (mlx default) | standard |
| Weight decay | 0.0 | LoRA convention |

Rough wall-clock estimate on Mini (M4 Pro, 24GB): 2-4 hours for the
1B run. 3B graduation: 12-24 hours, batch 1-2, accum 8-16.

Caveat on numbers: rank/alpha are convention not measurement. The
right rank for THIS corpus is unknown until run 1. Plan a sweep of
{8, 16, 32} after the first run lands.

---

## 4. Success criteria

### 4.1 Held-out eval set

- **Size**: 100 prompts. Held back from corpus collection from day 1
  (not a train/eval split after the fact).
- **Construction**: same source mix as training corpus but different
  documents. If C11 5.2.4.2.1 trained, eval pulls C11 6.7.2 instead.
- **Grading**: hand-graded by curator (single grader, 2-3 hours for
  100 items). Three buckets per response:
  - **cite-correct**: response names the right authoritative source
  - **derive-correct**: conclusion follows from the cited clause
  - **mode-shape**: response reads as Deductive (cite-then-derive)
    rather than as base-Llama default (assert-then-handwave)
- **Pass threshold (held-out)**: 70/100 cite-correct, 60/100
  derive-correct, 80/100 mode-shape. Mode-shape is the loosest
  criterion intentionally — the panelist's job is to BE Deductive,
  not to be a search engine.

### 4.2 Falsification-set replay (the load-bearing test)

Run the trained 1B Deductive panelist against all 40 problems in
`sets/falsification_v0a.jsonl`, `v0b.jsonl`, `v0c.jsonl`.

For each problem, the panelist generates a response. Score:

- **(a) curator-prediction match**: does the response's claim match
  `mode_predictions.deductive.prediction`? Allow paraphrase; the
  judgment is "would the curator have written this as D's prediction?"
  Hand-graded, binary.
- **(b) oracle match**: does the response match
  `oracle.expected_output`? Hand-graded for hand_grade problems,
  auto-compared for compiler problems.

**Pass threshold**:
- (a) curator-prediction match: ≥ 32/40 (80%). Below this, the
  trained panelist is not behaving like Deductive-as-modeled.
- (b) oracle match: ≥ 28/40 (70%). The curator's prediction for D
  was right 36/40, so an 80% reproduction of D's behavior implies
  ~28 oracle-correct. Lower means the LoRA learned a worse
  Deductive than the curator's mental model.

Crucial: the panelist must hit BOTH thresholds. (a) alone is
mode-shape success but could be wrong; (b) alone could mean the
model is just generally smart and not specifically Deductive.

### 4.3 Mode-separation metric

The real risk: all three LoRAs converge to base-Llama default.
Mode-separation is the test that protects against this.

After Deductive AND Empirical AND Adversarial are trained (each spec
written separately), run all three against a held-out 30-prompt
**disagreement probe set** (prompts deliberately ambiguous between
modes). For each prompt, record each panelist's response.

Compute:

- **Surface diff** (cheap): pairwise normalized edit distance between
  the three responses, averaged across 30 prompts. Pass: mean >= 0.35
  for each pair (D-E, D-A, E-A). Below 0.25 = mode collapse.
- **Style classifier** (better, optional v2): train a tiny classifier
  (or hand-grade) on which response is which mode WITHOUT seeing the
  prompt's correct answer. Pass: >= 70% correct mode-attribution.
  Pure chance is 33%.
- **Disagreement rate**: on what fraction of 30 prompts do all three
  panelists give substantively different responses (not just
  rephrased)? Pass: >= 40%.

If mode-separation fails, the fallback is cross-family panel
(Llama-D + Gemma-E + Phi-3-A). The 1B-LoRA experiment is partly
designed to falsify the shared-base hypothesis cheaply before
spending on the cross-family setup.

---

## 5. Expected mode behavior — concrete predictions

Drawn from existing falsification-set rationales. The trained D
panelist should respond like the rationale field describes.

**Example 1: F-011 (filter lambda segfault, Rail-code)**
Prompt asks whether `filter (\x -> x > 0) [1,-1,2,-2]` reliably
returns [1,2]. D should answer NO and cite Rail CLAUDE.md "Known
Compiler Limitations: filter with lambda can segfault." D should
NOT run the snippet to check (that's E's move) and should NOT
search for semantic flaws (that's A's move). The cite IS the
reasoning.

**Example 2: F-005 (signed overflow UB, C99)**
Prompt asks if signed overflow has defined behavior in C99. D
should answer NO, cite C99 section 6.5/5 (or equivalent UB list),
and stop. D should not defend the answer with "I tested on gcc -O0"
(E) or "the optimizer exploits it" (A). The spec settles it.

**Example 3: F-013 (63-bit tagged-int PRNG overflow, Rail)**
Prompt about LCG with 64-bit constants. D should cite Rail outer
CLAUDE.md "Integer overflow in PRNG: Rail's 63-bit tagged integers
overflow for multiplicative PRNGs." D should answer NO and stop.
The numeric demonstration that an LCG step overflows is not D's
proof shape; the documented invariant is.

**Example 4: F-002 (Python dict order, E-niche)**
Prompt asks if modern Python dict preserves insertion order. D
should answer DEPENDS (or "since Python 3.7 yes, but with version
caveat") and cite the data model docs noting it was an
implementation detail before 3.7. D's epistemic primitive says
the version cite-line matters. This is a problem where the curator
predicted D would be wrong (saying DEPENDS when the answer is YES
in modern Python); training should preserve that wrongness as a
mode signature. We do NOT want a trained D that learned to say
YES here just to score better — that would be mode collapse
toward generic correctness.

The last example illustrates the design principle: the trained
panelist should be **predictably wrong in mode-characteristic
ways**, because being wrong-as-D is what makes the panel
informative when D dissents.

---

## 6. Risks

### 6.1 Mode collapse to base-Llama default (HIGHEST)

A 1.5k-pair LoRA on a 1B base may not shift response style enough
to be distinguishable from base-Llama. Section 4.3 catches this,
but if it triggers we have already spent the training compute and
done corpus curation for all three modes before learning.

Mitigations:
- Run **Deductive first, in isolation**. If D vs base-Llama 1B has
  edit-distance < 0.25 on the 30-prompt probe (compared zero-shot
  against base), abort the multi-panelist plan and switch to
  cross-family before training E and A.
- Use longer training (more epochs) on the existing corpus before
  enlarging.
- Increase rank to 32 or expand target modules to include MLP
  before declaring failure.

### 6.2 Falsification-set leakage

The trained panelist must NOT have seen any of the 40 v0a/b/c
problems during training. Risks:
- Curator wrote both the corpus and the falsification set in the
  same week with the same head-state; semantic overlap is possible
  even without literal copying.
- Rail-specific problems (F-011 through F-025) all draw from
  Rail's CLAUDE.md. The corpus also draws from CLAUDE.md. Need
  source-document partitioning: if F-011 cites the "filter with
  lambda" CLAUDE.md note, no training pair may quote that note.

Mitigation: build the corpus AFTER the falsification set is frozen.
Each corpus pair tagged with which document section it touches;
diff against falsification-set sections; reject overlaps.

### 6.3 "D is the workhorse" curator bias becoming hardcoded

The 40-problem set was curated by one person who modeled D as the
most reliable mode (36/40 right). Training D against that mental
model risks baking the bias in: the trained D panelist becomes
"the one that's almost always right" rather than "the one that
reads invariants."

Mitigation: the corpus is curated independently of the falsification
set's mode-prediction logic. Corpus pairs target the **move**
(cite-then-derive), not the **outcome** (be right). If the trained
D is correctly Deductive-shaped, it will be wrong on F-004
(adversarial-unique-win on overflow) and F-026 (empirical-unique-win
on empty-tuple interning), and that wrongness is a feature.

### 6.4 Llama-3.2 license drift

Llama 3.2 is community-license-gated (Meta acceptable use policy,
non-commercial restrictions on some uses, attribution required).
DNRA is internal-only at this stage, well inside acceptable use.
If DNRA ever ships as a public surface, re-read the license; the
Phi-3 fallback (MIT) sidesteps this entirely.

---

## 7. Concrete next steps to kick off training

1. Freeze the falsification set: tag `~/projects/rail/tools/dnra/sets/`
   commit as `falsification_v0_frozen_for_finetune`. No more edits to
   v0a/b/c until after the LoRA pass/fail is known.
2. Build the corpus collection skeleton at
   `~/projects/rail-training/dnra/corpus_deductive/`. Single JSONL
   file `train.jsonl`, schema: `{id, source_doc, source_section,
   prompt, target}`.
3. Source-partition check: enumerate every document section cited in
   v0a/b/c (Rail CLAUDE.md headings, RFCs, Python data model
   subsections). These are blacklisted for corpus pairs.
4. Curate 1,500 pairs across the source list in Section 2.4. Budget
   ~10 minutes per pair (find the section, paraphrase, write the
   derivation). Plan: 4-6 sessions of 4-5 hours each, ~3 weeks
   elapsed at relaxed pace.
5. Build the held-out eval set (100 prompts) in parallel with corpus
   curation, in a separate file `eval.jsonl`. Source-partitioned the
   same way.
6. Pull Llama 3.2 1B Instruct via `mlx-lm` to Mini:
   `mlx_lm.convert --hf-path meta-llama/Llama-3.2-1B-Instruct`. Verify
   it runs with a single sample prompt before training.
7. Run base-Llama zero-shot against the 30-prompt mode-separation
   probe set. Save responses as `base_responses.jsonl`. This is the
   "before" baseline for Section 4.3.
8. Kick off LoRA training: `mlx_lm.lora --train --data corpus/
   --iters 1500 --batch-size 4 --lora-rank 16 --lora-alpha 32
   --learning-rate 1e-4`. Wall ~2-4 hours.
9. Run the trained D panelist against (a) the 100-prompt held-out
   eval, (b) the 40-problem falsification set, (c) the 30-prompt
   mode-separation probe set vs base-Llama. Apply thresholds from
   Section 4.
10. Decision point: if D passes all three thresholds, write the
    Empirical spec next (separate session, same template). If D
    fails Section 4.3 (mode-separation vs base-Llama), abort
    multi-panel-Llama plan and open the cross-family fallback ticket.

---

## 8. What this spec deliberately defers

- Empirical and Adversarial panelist specs (separate documents, same
  template, written only after D's training-run result is known)
- 3B graduation plan (only writable after 1B run produces signal)
- Cross-family fallback details (only relevant if 1B mode-separation
  fails)
- Convener routing to panelists (T6 in the original DNRA roadmap)
- Per-mode lost-alone-rate calibration in the arbiter (deferred to
  arbiter v1 post-finetune)
- Multi-curator validation of corpus pairs (single curator at POC;
  add second curator at v1 if D passes)
