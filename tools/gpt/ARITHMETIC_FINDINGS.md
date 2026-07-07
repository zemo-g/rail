# Rail-native GPU fine-tune: arithmetic-copying arc (2026-07-07)

Goal: make the owned 138M copy numbers from prompt into program (`sum of 90 and 5`
→ `show (90 + 5)`; Rail computes the sum at runtime, so this is a **copying** task,
not arithmetic reasoning). Used to stress-test the all-positions Rail-GPU trainer.

## Runs (all 138M, all-positions loss, streaming corpus)

| # | context L | LR (alr) | steps | corpus | result |
|---|---|---|---|---|---|
| orig | 64 | 1677 | 200 | mixed sum+mul | **best** — 90✓ 512✓ first operands (not saved — pre-writer) |
| — | 64 | 1677 | 800 | mixed | overfit → garbage (628/892), 512 regressed |
| v2 | 64 | 838 (½) | 200 | mixed | undertrained — 90✓ but 512✗, CE 0.75 |
| v3 | 32 | 1677 | 200 | sum-only | worst, CE 1.0 (L=32 hurt; also confounded 2 levers) |
| **v4** | 64 | 1677 | 200 | **sum-only** | **operator fixed** (no `*`); 90✓ but 512→646, 2nd operand still fails |

## Two conclusions (the deadman's test settled it)

1. **Operator confusion `+`↔`*` = a CORPUS problem, fixable.** The mixed sum/mul
   corpus made the model emit `*` for `sum` prompts. v4 (sum-only, one lever changed
   from orig) eliminated every `*`. Confirmed by isolation.
2. **Arbitrary number-copying = the 138M's CIRCUIT CEILING, NOT fixable by recipe.**
   Across 5 runs (LR, steps, context, corpus) it copies a small first operand
   sometimes (`90`) but fails larger (`512`→`646`) and mangles the 2nd operand.
   Reliable copy-to-arbitrary-precision is a precise induction head that needs
   **scale**, not knobs.

## What the arc actually proved (the real deliverables)

- **All-positions trainer works** (~64× the gradient signal/step; CE 4.9→0.03 overfit).
- **Full multi-tensor safetensors save works** (`arith_tuned_v4.safetensors`, drop-in).
- **Mid-run eval gates** catch regression the end-only 800-step run hid.
- **Trainer is dispatch-bound, not compute-bound** — L=64→32 barely sped it up
  (~14 vs ~9 s/step); the ~160 Metal syncs/step dominate. Real speedup = kernel
  FUSION (jit_emit machinery), not smaller context.
- **Discipline earned:** change ONE lever at a time (v3 confounded L + corpus);
  eval the user-facing metric mid-run, not just at the end.

## Kept artifact
`~/.ledatic/railml-trial/arith_tuned_v4.safetensors` — operator-corrected sum model
(555 MB, drop-in). The v2/v3/800-step outputs were removed (inferior, regenerable).

## Next lever (out of scope / separate project)
Clean number-copying needs a bigger base than 138M, or a copy-forcing curriculum
(induction-head warmup). Not a recipe tweak.
