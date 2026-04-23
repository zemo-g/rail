# The diagnostic corpus: Rail's asymmetric signal

**Date:** 2026-04-22.
**Thesis:** Every other code-language model is trained on positive examples of working code scraped from GitHub. They see output but not dialogue. **Rail's compiler produces a second, structurally-richer signal — error diagnostics — that we can capture at training time. No scraping LM has access to this signal, because they do not own their target language's compiler.**

Train on that signal, and the model learns not just "what Rail looks like" but "what broken Rail looks like + how the compiler describes the problem + how to fix it." The compiler becomes a teacher, not a grader.

## The signal decomposition

Every invocation of `./rail_native <file.rail>` emits three kinds of output:

| signal | structure | usually ignored by LMs |
|---|---|---|
| **Parse errors** | `file:line:col: error: <message>` | ✓ |
| **Type warnings** | `WARNING [typecheck] in <fn>: <description>` | ✓ |
| **Link errors** | `ld: Undefined symbols: _<symbol>` | ✓ |

All three are machine-parseable. All three carry structured information about *where* the code is broken and *why*. A model trained on these — not just on working code — learns the rare skill of "mechanical debugging": given a broken program and a diagnostic, write the correction.

## The training format

Triples of the form `(broken_code, diagnostic, fixed_code)` serialized as:

```
<BROKEN>
fact n = if n <= 1 thn 1 else n * fact (n - 1)
main = let _ = print (show (fact 5))
  0
<DIAG>
fact.rail:1:20: error: expected expression after 'then', got 'thn'
<FIXED>
fact n = if n <= 1 then 1 else n * fact (n - 1)
main = let _ = print (show (fact 5))
  0
<END>
```

The delimiters (`<BROKEN>`, `<DIAG>`, `<FIXED>`, `<END>`) are literal char sequences the model learns as structural markers. At char-level vocab, no special tokenization is needed — just reserve these sequences.

## Where the triples come from

**Path A — Deterministic mutation (the starting data engine).**
Take any valid program from the stdlib corpus. Apply one of N mutation operators:

| operator | example |
|---|---|
| delete_random_line | removes one line of a multi-line program |
| remove_main | removes `main = ...` declaration entirely (→ link error) |
| swap_operator | `a + b` → `a - b`, `==` → `!=` |
| truncate_let_rhs | `let x = 42` → `let x = ` (→ parse error) |
| insert_stray_paren | inject extra `)` or `"` (→ parse error) |
| typo_keyword | `then` → `thn`, `match` → `matc` |
| partial_rename | rename var at one site but not others (→ unbound) |
| remove_ctor | delete an ADT constructor that's referenced later |
| wrong_arity | add/remove arg to a known function call |

Each mutation is paired with its inverse — we know the ground-truth fix because we applied the break ourselves. A 500KB corpus × 10 mutations per program = 5MB of triples from pure data engineering. Cheap, deterministic, structurally diverse.

**Path B — Model-generated (the flywheel).**
The model generates a candidate C. Compile C. If it fails with diagnostic D, prompt a *larger* teacher model (Qwen 3.6 35B on Studio port 8081 — already running, already in the fleet) with `<BROKEN>\n{C}\n<DIAG>\n{D}\n<FIXED>\n` and receive F. Compile F. If it compiles, we have `(C, D, F)` as a triple. Add to corpus.

Over time Path B replaces Path A as the model becomes good enough to fix its own mistakes — the flywheel closes.

**Path C — Git history from the compiler itself.**
`tools/compile.rail` has been modified 500+ times in this project's git log. Many commits are "fix parse bug in X" or "correct arity check." Each one pairs `before-commit` (broken wrt test) with `after-commit` (fixed) plus compiler output changes. Real-world fix patterns, free. Lower priority than A+B but shouldn't be left on the table.

## Why the compiler-as-teacher architecture is Rail-unique

1. **Fast compiles.** Our compiler grades a 100-char program in ~50ms. At N candidates per bench task, total grading cost is ~1.5s. Python projects running their equivalent (unit tests, linters, type checkers) take seconds to minutes per candidate. We can afford to compile-in-the-loop at training AND inference time.

2. **Self-hosted.** The compiler, trainer, inference harness, and grader are all Rail. A commit that improves the compiler (parse bug fix, new type warning) automatically improves the training signal for future runs. No "which compiler version was this dataset graded with?" problem.

3. **Char-level compatibility.** Diagnostic messages are ASCII text within our 130-char vocab. We don't need a separate diagnostic-tokenizer or a cross-modal model. The same transformer that reads code reads diagnostics.

4. **Corpus-size agnostic.** Path A generates unlimited triples from any seed corpus. We stop being corpus-bottlenecked — we become operator-design-bottlenecked, which is an engineering problem with a ceiling, not an infinite resource hunt.

## The research claim this enables

If Spur-Fix (the triple-trained variant) outperforms Spur-0.1 on bench_railnative **at the same parameter count**, we have demonstrated:

> A small self-hosted language model, trained with compiler-diagnostic feedback, achieves material bench improvement without parameter scaling. Each gradient step is structured by compiler output — a signal only available to projects that own their target language's compiler. GitHub-scrape-based LMs at 10× the parameter count cannot obtain this signal.

That's a publishable claim in a world where "scale is all you need" is the default narrative. It's not "we beat GPT-2 scaled-down" — it's "we found a training signal axis that requires compiler ownership, and it beats parameter scaling on small models."

## Implementation roadmap

### Tonight (non-GPU, parallel to the overnight sweep)

- `tools/train/mutate.rail` — 8-10 mutation operators, each with inverse-transform tracking.
- `tools/train/diagnose.rail` — compile + capture stderr + parse into structured tuples.
- Smoke test on 3 programs × 3 mutations to verify triple format.

### Tomorrow (pending sweep results)

- `tools/train/gen_triples.rail` — walk stdlib corpus, emit triples to disk.
- `tools/train/lm_v3_triples.rail` — training variant that reads triple-serialized corpus instead of plain text. Same architecture as Spur-0.1 (d=256 × 2-block × half), just a new data pipeline.
- Train Spur-Fix-0.1 for 3000 steps. Same 84-min wall as Spur-0.1.

### Day 2

- `tools/train/lm_infer_v3_fix.rail` — inference harness that knows the `<BROKEN>` / `<DIAG>` / `<FIXED>` / `<END>` protocol. At bench time: sample candidate → compile → if fail, prompt with diagnostic → sample fix → repeat up to N loops.
- Bench Spur-Fix-0.1. Compare to Spur-0.1's 13/30.

### Day 3 (if baseline good)

- Wire self-training flywheel (Task #14 from `DEADLINE_2026-04-27_PUNCHLIST.md`): let Spur-Fix harvest its own successful fixes back into the corpus. Growth mechanism.

## What success looks like

- **Minimum-viable:** Spur-Fix-0.1 scores 15+/30 (≥2 passes above Spur-0.1 baseline) on the same bench, at same parameter count. Establishes that compiler-diagnostic training has nonzero value.
- **Strong:** Spur-Fix-0.1 scores 18+/30. Close to the 14/30 historical peak on Shakespeare-corpus models, but at 1.74M params and with the compile-in-the-loop grading — no artificial inflation.
- **Transformational:** Spur-Fix-0.1 scores 22+/30. Crosses the "reliable Rail writer" threshold at 1.74M params, opens the door to "use the model as an inline compile-error fixer in the editor."

## What fails — explicitly naming the risks

1. **Mutation operators may not produce realistic failure modes.** Model trained on "always deletes a whole line" learns to fix whole-line deletions, doesn't generalize to 1-char typos. Operator coverage matters.

2. **Diagnostic messages may be too sparse/terse to actually guide a fix.** Rail's error format is `file:line:col: error: message` — one line. Languages with richer error ecosystems (Rust's `rustc --explain`, OCaml's structured messages) give the model more to work with. Our compiler's diagnostics may need enrichment.

3. **Char-level vocab on diagnostic text may be inefficient.** Messages like "expected expression after 'then'" share substrings across errors. At char-level, each token has to learn those substrings independently. BPE would likely compound with this idea.

4. **The fix space may still be under-determined.** `"a + b"` → compile fail → "expected expression" could be fixed many ways. The ground-truth fix we trained on is one point; at inference the model could generate a different valid fix that doesn't match training targets. Need to be careful with loss formulation (probably ignore the FIXED block at training loss for non-determinism, compute loss only on BROKEN→DIAG mapping? or accept that any compiling fix is correct at inference and score by compile-pass, not string-match).

Each risk has a mitigation path; none are showstoppers. The engineering effort is ~3 days to build the pipeline + ~1 day to bench.

## The naming

- **Spur-0.1**: the current flagship (2-block × 3000 × 13/30). Architecture-scaling proof of concept.
- **Spur-Fix-0.1** (proposed): same architecture, trained on diagnostic triples. If it outperforms Spur-0.1, it becomes the flagship and Spur-0.1 becomes the baseline.
- **Spur-Fix-1.0**: version after the self-training flywheel has grown the corpus by 10×+.

"Spur-Fix" because the model fixes things — the defining capability is debugging, not writing from scratch. Most small-LM projects chase "write programs"; we chase "fix programs." Compiler ownership makes the second a gift.
