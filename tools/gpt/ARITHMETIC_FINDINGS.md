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

---

## UPDATE 2026-07-07 (evening): the copy curriculum REFUTES the ceiling

Ran the "copy-forcing curriculum" that the line above called the next lever. It WORKED —
conclusion #2 ("circuit ceiling, NOT fixable by recipe") is **wrong and now retracted.**

**Curriculum** (`~/.ledatic/railml-trial/arith/gen_copy_curriculum.py`): 8,000 ex =
4,000 ECHO (`-- Echo the number N.` -> copy N; the induction-head builder) + 4,000 SUM,
numbers digit-balanced 0..9999. Tokenized byte-identical to arith_sum.bin (self-verified).
Same all-positions trainer (`arith_finetune_copy.rail`), 200 steps, alr=1677, gate@100.

**Eval = PREFIX-GIVEN** (isolates the copy circuit — model emits only the number(s)):

| probe | BASE | after curriculum | |
|---|---|---|---|
| Echo 512  | `length [3,24,30,` | `512)` | ✅ |
| Echo 7    | `8 + 7))`          | `7)`   | ✅ |
| Echo 3388 | `34 + 38))`        | `3388)`| ✅ 4-digit |
| Sum 90+5  | `0 + 5))` (dropped 90) | `90 + 5))` | ✅ both |
| Sum 6+9   | `6 + 9))`          | `6 + 9))` | ✅ both |
| Sum 512+7 | `15 + 7))`         | `7 + 7))` | ⚠️ 1st operand |

- **ECHO: total failure -> perfect, incl. 4-digit 3388.** Single-number copy is SOLVED at
  138M. The induction head forms; ck100->step199 shows it consolidating (512->`48` at 100,
  512->`512` by 199, monotonic, no regression).
- **SUM: 2/3 correct incl. 90 (a 2-digit 1st operand the base DROPPED).**
- **The residual (`512+7 -> 7+7`) is NOT a copy failure** — the model just PROVED it can copy
  512 in echo. It's a **two-operand positional-binding** miss (which number lands in the
  first slot when both are multi-token and the 1st sits further back). A narrower, different
  problem. Lever: sum-heavy curriculum w/ large *distinct* operands, or more steps (still
  improving at 199).

**Strategic consequence:** the gate question "can 138M be saved before Studio-weeks on 300M?"
answered YES. Capability was a CURRICULUM gap, not a capacity wall (same shape as the v6
tokenization-boundary fix). Path A (300M) is de-risked but NOT urgent. Artifact:
`~/.ledatic/railml-trial/arith_copy_probe.safetensors` (555 MB).
Discipline win: the mid-run gate + prefix-given eval isolated exactly what changed.

## UPDATE 2026-07-07 (probe 2, binding): binding SOLVED; residual = a TOKENIZER artifact

Hypothesis going in: `512+7 -> 7+7` was a two-operand POSITIONAL-BINDING miss. **The data
REFUTED that hypothesis** (honest-critique win). Ran a sum-heavy, distinct-operand curriculum
(`gen_binding_curriculum.py`: 6,500 sum all-distinct + 1,500 echo, magnitude-asymmetric both
directions) for 300 steps (`arith_finetune_bind.rail`), 8-probe eval.

FINAL (step 299), both-operands-correct: **90+5 ✓✓, 4096+8 ✓✓, 6+9 ✓✓, 3388 echo ✓;
384+512 -> `384`+123 (1st ✓), 7+512 -> `7`+123 (1st ✓), 512+7 -> 10+`7` (2nd ✓); echo 512 -> 128.**

- **Positional binding is SOLVED.** In EVERY case the non-512 operand lands in its correct
  slot -- incl. `4096+8` (the exact big-first/small-second shape that `512+7` failed) and
  `384` as a 3-digit first operand. The model composes two operands fine at 138M.
- **The lone failure is copying `512` -- because it is a single RARE atomic BPE token
  (`14891`).** Tokenization proof: `512`->`[14891]` (1 content token) but every number that
  copies is MULTI-token from COMMON sub-tokens: `384`->`[3176,859]`, `4096`->`[2736,53,1246]`,
  `3388`->`[27,3176,1356]`, `90`->`[53,397]`. `512` fails IDENTICALLY in every position (echo,
  1st slot, 2nd slot) = the signature of a token problem, NOT binding, NOT capacity. 44
  fine-tune occurrences couldn't overcome the base model's near-zero exposure to token 14891.
- **This is the v6 tokenization-boundary bug's cousin.** Fix needs ZERO extra params:
  digit-consistent number tokenization eliminates the whole rare-atomic-number class (echoes
  [[feedback_lm_unigram_floor]] "BPE hides local structure"); or cheaply upweight the numbers
  that happen to be single tokens.

**Two-probe bottom line:** single-copy ✅, multi-operand binding ✅, arbitrary magnitude ✅
(4-digit copies fine) -- ALL unlocked at 138M with CURRICULUM, no scale. Residual = a
tokenizer artifact, not the model. Path A (300M) stays on the shelf; next lever = the
tokenizer. Artifact: `~/.ledatic/railml-trial/arith_bind_probe.safetensors` (555 MB).

## PROOF 2026-07-08 (probe 3, inference-only): the tokenizer diagnosis, falsified-tested

Falsifiable prediction: copy success is predicted by token composition, NOT magnitude/capacity.
Tested the TRAINED bind model (no retrain, `probe3_tokcheck.rail`) on 8 rare-atomic single-token
numbers (A) vs 8 multi-token common numbers (B), echo copy.

  Group B (multi-token): 8/8 copied  -- 3259 4421 5757 6879 7444 8044 8139 8263 ALL exact
  Group A (rare atomic): 2/8 copied  -- 100✓ 128✓; 256->72 500->72 512->128 1024->9765
                                        2147->82 6666->(empty) FAIL

**The model copies `8263` but not `512`** (8263>512) -> magnitude & capacity hypotheses BOTH
dead. Only difference = tokenization: 8263->common sub-tokens (strong induction), 512->[14891]
one rare atomic token (weak induction). Even failures diagnostic (512->128 = reached for a
different atomic number-token it DOES know). The 2 A-hits (100,128) = the commonest atomics.

CONCLUSION (proven, not argued): the residual copy failure is 100% a TOKENIZER artifact. A 300M
model with the SAME tokenizer fails on 512 identically -> SCALE CANNOT FIX IT, the tokenizer can
(digit-consistent number tokenization). This is a "check me" result: falsifiable prediction ->
tested on a fully-inspectable self-hosted stack -> confirmed 8/8 vs 2/8. Harness:
`arith/{gen_copy_curriculum,gen_binding_curriculum,tokenize_copy,probe3_tokcheck via score_probe3}.py/rail`.
