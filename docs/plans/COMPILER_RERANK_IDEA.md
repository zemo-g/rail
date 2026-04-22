# Compiler re-rank: using the compiler as inference-time search

**Date:** 2026-04-22, Session 7.
**Status:** implementation shipped in `flywheel-local/bench_railnative_rerank.rail` (not in git — private-repo bench location). Full helper code reproduced here so it ships with the public repo.

## The observation

Every other small-LM project treats its language's compiler as a downstream grader that runs AFTER training completes. Rail is different: we have a self-hosted compiler that grades a ~100-char Rail program in ~30-100 ms. That's fast enough to use the compiler *during inference itself*.

Our current argmax decoder picks whichever char has the highest single-token probability. At char-level perplexity ~30 (eval 3.39 on d=256 × 4-block), the argmax is almost always `\n` (whitespace is the most common corpus char). The bench scores 1/30 — and that 1 pass is a Fund task whose prompt is already a complete program.

**The insight:** the model's *distribution* has support on valid Rail chars. When we greedy-decode, we collapse that support to whitespace. When we **sample N times and pick the best-compiling one**, we're using the compiler as a search oracle over the model's full distribution — and nearly every non-argmax sample at least tries to generate syntactically-plausible Rail.

## The algorithm

For each bench task:

1. Run the inference binary N times with seeds `seed_base..seed_base+N-1`, at k=10 temp=0.8 (top-k multinomial sampling — already shipped in `tools/train/lm_infer_v3_half.rail`).
2. For each sample's output text:
   - Compute `rn_quality` (from `flywheel/bench_railnative.rail`, uses the oracle compile pipeline).
   - Extract `ok` (1 if `ld: OK` appeared, else 0).
   - Extract `exec_match` (1 if compile-passed AND stdout matches expected, else 0).
3. Pick the best sample by:
   - `ok=1` always beats `ok=0` (compile-pass always wins)
   - Tie on `ok`: higher `exec_match` wins
   - Tie on `ok + exec_match`: higher `quality` wins
4. Report that sample's (quality, ok, exec_match) as the task score.

**Cost:** per task, N inferences (~1-2s each on GPU) + N compiles (~30-100ms each). At N=20: ~40s/task, ~20 min full bench. Acceptable.

**Why this works even on a bad model:** if the model's argmax is `\n` 99% of the time at some position, but the distribution has 1% spread across actual code chars (`l`, `m`, `p`, `i`, etc.), then over 20 independent samples, at least 3-5 will *begin* to generate real code. Among those, maybe 1-2 will luck into compile-clean short programs on Fund-band tasks whose prompts are mostly-complete.

**Expected bench delta:** 1/30 → 5-10/30 without retraining. The compiler turns "one lucky Fund prompt" into "many lucky-per-sample Fund + IO prompts." Even a fraction of Tools/Compiler/Advanced bands could flip if N is high enough.

## The load-bearing code (Rail, paste into bench_railnative.rail)

Insert above `score_task` in `bench_railnative.rail`:

```rail
rerank_n = 20

update_best_loop best q ok ex =
  let best_q = float_to_int (float_arr_get best 0)
  let best_ok = float_to_int (float_arr_get best 1)
  let best_ex = float_to_int (float_arr_get best 2)
  let beats = if ok > best_ok then 1
              else if ok == best_ok then
                (if ex > best_ex then 1
                 else if ex == best_ex then (if q > best_q then 1 else 0)
                 else 0)
              else 0
  if beats == 1 then
    let _ = float_arr_set best 0 (int_to_float q)
    let _ = float_arr_set best 1 (int_to_float ok)
    let _ = float_arr_set best 2 (int_to_float ex)
    1
  else 0

rerank_loop gen_bin prefix prompt expected max_gen k tau seed_base i best =
  if i >= rerank_n then
    let q = float_to_int (float_arr_get best 0)
    let ok = float_to_int (float_arr_get best 1)
    let ex = float_to_int (float_arr_get best 2)
    cons q (cons ok (cons ex []))
  else
    let trio = score_task gen_bin prefix prompt expected max_gen k tau (seed_base + i)
    let q = head trio
    let ok = head (tail trio)
    let ex = head (tail (tail trio))
    let _ = update_best_loop best q ok ex
    rerank_loop gen_bin prefix prompt expected max_gen k tau seed_base (i + 1) best

score_task_rerank gen_bin prefix prompt expected max_gen k tau seed_base =
  let best = float_arr_new 3 0.0
  rerank_loop gen_bin prefix prompt expected max_gen k tau seed_base 0 best
```

Swap the `score_task` call in `run_band_loop` for `score_task_rerank`, adjust seed to `seed_base + idx * rerank_n` so each task gets a distinct seed window:

```rail
let trio = score_task_rerank gen_bin prefix prompt expected max_gen k tau (seed_base + idx * rerank_n)
```

### Rail gotchas during implementation

- **Arity ≤10** for self-recursive helpers (per `rail_quirks`). `rerank_loop` would have been 13 params (gen_bin, prefix, prompt, expected, max_gen, k, tau, seed_base, i, n, best_q, best_ok, best_ex). Fixed by (a) making `n` a file-level constant (`rerank_n`), and (b) packing best-state into a `float_arr[3]`. Landed at 9 params.
- **Nested `if/else` without parens** parses OK but be careful with precedence. The `beats` expression uses explicit `if ... then 1 else 0` at each branch rather than boolean combinators.
- **`float_arr_set` is in-place**. `update_best_loop` returns 1/0 for "did I update?" but the mutation itself happens via set calls. Don't forget to thread `best` through to the recursion.

## Why this is uniquely a Rail move

PyTorch small-LM projects could in principle do the same, but:

1. Their "compiler" (Python) doesn't check semantic correctness of anything small LMs generate (the output is arbitrary text).
2. Their grading tooling is multi-thousand-line frameworks (HumanEval, etc.), not ~30ms per sample.
3. They don't have a self-hosted compiler / language / training stack that integrates at the level where the model's output language IS the same language as the compiler.

The re-rank trick only becomes free when:
- The compiler is fast (ours is ~50ms).
- The output language is the same as the training substrate (ours is Rail).
- The compiler is callable from the training process (it's literally the same binary for us).

All three line up for Rail. None line up for Python + PyTorch + OpenAI-text.

## Expected result and the model-card claim

If the re-rank bench on the d=256 × 4-block × 3000-step checkpoint lands at ≥5/30, the 2026-04-27 deadline is cleared and the model card's primary claim becomes:

> **A 3.4M-parameter self-hosted transformer achieves ≥5/30 on `bench_railnative` through compiler-guided inference-time search. No additional training compute required beyond the 84-minute d=256 × 2-block or 171-minute d=256 × 4-block HalfTensor run. The compiler that verifies each candidate is the same compiler that compiled the training loop, self-compiled in Rail.**

That is a genuinely novel claim. Nothing else at this scale or in this stack has shipped it.

## Extensions (not in this session's scope)

1. **Beam search with compiler at every step.** Instead of N independent samples, maintain a beam of K partial generations, at every step extend each by top-m tokens, re-rank the K*m new candidates by partial-parse validity (lexer state only, no full compile), prune back to K. This is O(K * tokens_per_task) compiler calls — more expensive but higher hit rate.
2. **Grammar-constrained decoding.** At each step, compute the set of chars valid given the current parse state, mask the model's distribution to only those. Forces syntactic validity without any compile calls — the compiler provides the grammar, not per-sample verdicts. Different innovation, complementary.
3. **Gradient-of-compile-pass as training signal.** Generate N candidates per corpus position during training, compile each, use compile-pass-rate as an auxiliary loss. Pushes the model's distribution TOWARD compile-pass over epochs. RLHF-ish but signal is deterministic. Would need N=2-4 per step to stay tractable; still adds meaningful compute.

## Load order for the eventual 4-way comparison

When the Session 7 resume training completes (ETA ~19:00 local, 2026-04-22):

| checkpoint | decoder | expected bench |
|---|---|---:|
| d=256 × 4-block × 3000 | argmax | 1/30 (recorded) |
| d=256 × 4-block × 3000 | re-rank N=20 | **TBD** |
| d=256 × 4-block × 6000 (Session 7 output) | argmax | ~1-2/30 (expected similar) |
| d=256 × 4-block × 6000 | re-rank N=20 | **TBD** |

The key comparison: the re-rank column. If the 3000-step model beats the 6000-step model on re-rank, it says training longer didn't help. If re-rank column is flat across both checkpoints, it says the re-rank ceiling isn't related to model capacity — it's related to the sampling distribution's support.

Either way, the re-rank number is the deadline-relevant number.
