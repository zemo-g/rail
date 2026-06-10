# DNRA Finetune Spec — Adversarial Panelist

**Status:** scoping draft. Pre-training. No code written, no run launched.
**Mode under spec:** Adversarial ("where does this break?").
**Base model:** Llama 3.2 1B (Meta open-weight). Production graduation target: 3B if 1B passes the gate.
**Train host:** Apple Silicon, 24GB unified RAM. MLX or PyTorch-MPS only.
**Adapter style:** LoRA. Hours per panelist, not days.
**Output target:** signed deliberation entries appended to the existing `~/.ledatic/dnra/chain/deliberations.jsonl` ledger.

---

## 1. The shape this spec must respect

Adversarial scored 15/40 right, 2 unique-right, **14 lost-alone** on the falsification set (v0a+b+c). It is wrong-alone on 14 of 40 problems and uniquely right on 2 (F-004 fib int-overflow, F-032 sqrt fp rounding).

This is the asymmetry the spec accepts:

- Adversarial is a noise generator most of the time.
- Adversarial occasionally catches a real counterexample no other mode catches.
- Suppressing lost-alone would also suppress the unique wins. Do not optimize for low lost-alone rate.

The training objective is **embodiment**, not **accuracy**. The Adversarial panelist must articulate *where the break is* with a concrete mechanism. Even when wrong, the output shape should be "consider edge case X" not "the answer is N+1 because it must be wrong."

---

## 2. Corpus design

### 2.1 Theory: train the location of breaks, not the disagreement

Wrong training corpus: pairs where the target is the consensus answer flipped to its opposite. This produces a contrarian-for-its-own-sake model — the architecture's failure mode named in the falsification spec.

Right training corpus: pairs where the target answer **identifies the boundary condition / overflow point / undefined input / state where the invariant fails**, regardless of whether that boundary actually applies in the prompt. The signature is "here is the break: $mechanism, triggered by $condition." If the prompt's specific input does not hit the boundary, the target says so explicitly ("this case is inside the safe range; the break would occur at $threshold").

Target shape template (used in all examples below):

```
where_break: <named edge case or invariant violation>
mechanism: <why it breaks at that point>
applies_to_prompt: <yes | no | conditional>
prediction: <answer to the prompt, given the above>
```

The `applies_to_prompt: no` cases are the critical anti-contrarian signal. They teach the model that finding a break does not require dissenting from the prompt's expected answer.

### 2.2 Estimated corpus size

POC: **2,000-4,000 pairs**. LoRA on Llama 3.2 1B converges with low thousands of well-curated examples; pushing past 5k without per-pair diligence dilutes signal. Production graduation to 3B may bump this to 6k-10k once the gate is validated.

Split: 90% train, 10% held-out (see Section 3).

### 2.3 Source inventory

All sources are publicly available without scraping infrastructure.

| Source | What it gives | Access |
|---|---|---|
| NIST NVD / CVE JSON feeds | CVE entries with vulnerability description, affected versions, mechanism (overflow, UAF, race, etc.) | https://nvd.nist.gov/vuln/data-feeds — daily JSON downloads, no auth |
| LLVM/Clang testsuite — UB sanitizer corpora | Programs that trip overflow / shift-out-of-range / null-deref. Per-test mechanism documented | LLVM project mirror; included in mainstream LLVM source distribution |
| SQLite `sqllogictest` corner cases | NULL semantics, casting overflows, locale issues | sqlite.org/sqllogictest |
| Python `test_*.py` files in CPython — particularly `test_decimal`, `test_float`, `test_long` | Hand-curated edge cases with comments explaining why each input matters | github.com/python/cpython (already-public license) |
| GoF / IEEE-754 numerical-stability literature (Goldberg "What Every Computer Scientist Should Know About Floating-Point") | Classical fp pitfalls with worked examples | Public ACM Computing Surveys article + many derivative writeups |
| Rust `unsafe` audit corpora — `RustSec` advisory db | Real-world memory/concurrency failure cases with root-cause prose | github.com/rustsec/advisory-db |
| Race-condition / TOCTOU literature — `concurrencytest` corpora | Race patterns with reproducible interleavings | Various academic sources; manual hand-extract |
| Rail-specific edge cases from `tools/compile.rail` known-limitations changelog | Rail's own documented traps (63-bit PRNG, length==0 vs ==[], lambda-segfault, etc.) | In-repo |

For each source, the extraction pipeline produces (prompt, target) pairs by converting the source's existing description into the target template. Many entries already read like targets — CVE descriptions are essentially "where_break + mechanism + applies_to."

### 2.4 Anti-contrarian signal: include `applies_to_prompt: no` pairs

Roughly **35-40% of the corpus** must be examples where the prompt has a correct, conventional answer AND Adversarial still articulates a real break (just one that doesn't apply). This teaches:

- The mode's job is to *locate* breaks, not to disagree.
- Finding a break in nearby code is valuable signal for the arbiter even when the prompt's specific answer is the consensus.
- The arbiter (not the panelist) decides whether the located break overrides the prediction.

Without these pairs the model collapses to a contrarian.

### 2.5 Sample (prompt, target) pairs

Each held-out from the falsification set. Targets follow the template in 2.1.

**Pair A — applies_to: yes** (counterexample dominates)

```
PROMPT: Given uint8_t x = 200; uint8_t y = 100; what is (x + y) on a strict
C99 compiler?

TARGET:
where_break: arithmetic conversions promote uint8_t to int before addition,
  but the result 300 is assigned back to a smaller type only if explicitly
  cast. The behavior pivots on whether the sum is stored or merely produced.
mechanism: C99 6.3.1.8 integer promotions; signed int can hold 300 so no UB.
  If the sum is stored back to uint8_t, value truncates to 44 (300 mod 256).
applies_to_prompt: conditional
prediction: 300 as int. 44 if narrowed to uint8_t. The question is ambiguous
  about storage destination.
```

**Pair B — applies_to: no** (the anti-contrarian shape)

```
PROMPT: In Python 3.12, what does len("hello") return?

TARGET:
where_break: len() in CPython relies on a __len__ slot that must return a
  non-negative int. Objects with a malicious __len__ returning a negative
  value or non-int raise TypeError. Strings are immutable and use a cached
  ob_size field, so the dynamic break does not apply to literal strings.
mechanism: Python data model spec for len() defines the failure modes for
  user-defined __len__ implementations, not built-in types.
applies_to_prompt: no
prediction: 5
```

**Pair C — applies_to: yes, real edge** (numerical, the F-032 shape)

```
PROMPT: For N = 10**18, does int(math.sqrt(N)) ** 2 <= N hold in CPython?

TARGET:
where_break: math.sqrt operates on fp64 (52-bit mantissa). For N >= 2^53,
  the input loses integer precision; sqrt's result can round up past the
  true integer square root.
mechanism: when sqrt(N) rounds to the next representable double above the
  true sqrt, int() truncates that larger value to floor+1, and squaring
  exceeds N. Use math.isqrt for exact integer sqrt above 2^53.
applies_to_prompt: yes
prediction: NO — the inequality can fail for N near integer squares at
  this scale.
```

**Pair D — applies_to: no, plausible-but-absent break** (teaches restraint)

```
PROMPT: In Rust, what does Vec::new() return when called with no type
annotation in a context that fixes the element type?

TARGET:
where_break: Vec::new() relies on inferred T. If T is unfixed at the call
  site the compiler emits E0282 "type annotations needed." Generic
  collections also fail if T is not Sized.
mechanism: monomorphization requires T to be known by codegen time.
applies_to_prompt: no
prediction: an empty Vec<T> with capacity 0, no heap allocation.
```

**Pair E — race / concurrency**

```
PROMPT: Two threads call counter += 1 on a shared i64 without any lock.
What is the final value after each thread increments 1000 times?

TARGET:
where_break: read-modify-write on a non-atomic shared variable is a data
  race; the final value is undefined / implementation-defined.
mechanism: load-add-store is not atomic; an interleaving where both threads
  read the same value before either writes loses one increment.
applies_to_prompt: yes
prediction: undefined, but in practice between 1000 and 2000. Use
  AtomicI64::fetch_add for a correct count.
```

The targets are deliberately verbose. At inference time the panelist emits this whole shape; the arbiter extracts `prediction` and uses `where_break + mechanism` as evidence weight.

---

## 3. LoRA recipe

Numbers below are conventions for Llama 3.2 1B + small-domain LoRA finetune on MLX or PyTorch-MPS. Adjust by halving if host RAM tops out.

| Param | Value | Source |
|---|---|---|
| Base model | meta-llama/Llama-3.2-1B-Instruct | HF |
| LoRA rank `r` | 16 | mid-range for small-domain; 8 if memory pressed, 32 if undertraining |
| LoRA alpha | 32 | conventional 2x rank |
| Dropout | 0.05 | standard |
| Target modules | q_proj, k_proj, v_proj, o_proj, gate_proj, up_proj, down_proj | attention + MLP; the full set for embodiment, not just attention |
| Learning rate | 2e-4 | LoRA standard; AdamW |
| Optimizer | AdamW, beta1=0.9, beta2=0.999, weight_decay=0.0 | standard |
| Batch size | 4 effective (grad accum if needed) | 24GB RAM budget; bf16 |
| Seq length | 1024 | Adversarial targets are ~200-400 tokens; 1024 leaves headroom |
| Warmup steps | 100 | ~5% of total |
| Total steps | ~2000 | derived from 3000-example corpus * 3 epochs / batch 4 |
| Epochs | 3 | LoRA on small domain saturates by 3 |
| Precision | bf16 | per Rail's bf16-10k finding; fp16 unstable in long tails |
| Save interval | every 200 steps | recovery + early-stop budget |
| Eval interval | every 200 steps | small held-out (see Section 4.1) |

All numbers are **starting points**. Train first 200 steps, eyeball the held-out loss and a few samples, adjust before committing the full run.

---

## 4. Success criteria

### 4.1 Held-out eval set

- 200 (prompt, target) pairs drawn from the same sources as training, held out before training starts.
- Auto-graded for `prediction` field match where target prediction is enumerable (yes/no/single number/exact string).
- Hand-graded for `where_break` and `mechanism` fields: does the model identify the same class of break (overflow, race, UB, fp rounding, undefined behavior, etc.) as the target? Pass = same class, not same wording.
- Target pass rate: **>=70% prediction match, >=60% break-class match.** Lower the bar if the corpus is noisier than expected.

### 4.2 Falsification-set replay

Replay the trained Adversarial panelist against the 40 falsification problems.

- For each problem, compare model output to the curator's `mode_predictions.adversarial.prediction` field.
- Pass = trained model's prediction matches curator prediction on **>=30 of 40 (75%)**. Curator predictions are the spec of mode behavior; the model is being trained to embody them.
- A-niche test: F-004 (Fib int-overflow) and F-032 (sqrt fp rounding) — the 2 unique-wins. Trained model **must** match the curator on both. These are the cases where Adversarial's value justifies the panelist. Hard requirement.

### 4.3 Lost-alone target range

After replay, count the trained panelist's lost-alone cases on the falsification set (cases where Adversarial dissents from D+E consensus AND is wrong against the oracle).

Curator baseline: 14/40 = 35% lost-alone.

Target range for trained model: **20%-40% lost-alone**, i.e., **8-16 lost-alone on the 40-problem set**.

- Below 20% (<8): Adversarial has been suppressed; it's not catching enough edges. Check that F-004 and F-032 still pass — if they don't, the model has been over-flattened.
- Above 40% (>16): contrarian collapse. The model is dissenting for the sake of dissenting and the corpus's anti-contrarian pairs (Section 2.4) didn't take. Retrain with a higher `applies_to_prompt: no` share.

The range is wide on purpose. Adversarial's value comes from catching edges, and the curator's 35% lost-alone reflects the cost of that mode. The trained model should be in the same neighborhood.

### 4.4 Mode separation metric

Run the trained Adversarial against Deductive and Empirical panelists on the same 40-problem set (once those exist; this gate may be the first one). Compute:

- **Disagreement rate:** fraction of problems where Adversarial's prediction differs from Deductive's.
- **Unique-right rate:** fraction where Adversarial is right and the other two are not.
- **Where-break presence:** fraction of Adversarial outputs that include a `where_break` field with a non-empty, plausible mechanism (hand-checked or LLM-checked against a rubric).

Pass thresholds:
- Disagreement rate vs Deductive: >=25%. If <15%, the modes have collapsed; the corpus didn't separate them.
- Where-break presence: >=90%. If the model frequently omits the where-break field, it has not learned the mode's shape, only its surface vocabulary.

---

## 5. Expected mode behavior — prediction patterns

Drawn from the falsification set rationales. The trained panelist should produce outputs that match these shapes.

### Pattern 1 — Overflow / range-limit edge (F-004 shape)

When the question involves arithmetic, recursion, or accumulation on a bounded integer type, Adversarial scans for the threshold where the type runs out. Output structure: identify the type's max, identify the input that crosses it, name the resulting wrap or saturation behavior.

Example expected output for "does fib(n) stay positive for n>0 in i64?":
```
where_break: fib grows exponentially with golden-ratio base; i64 max is ~9.2e18.
mechanism: fib(93) ~= 1.2e19 exceeds 2^63-1; two's-complement wrap flips sign.
applies_to_prompt: yes
prediction: NO. Fails at n=93.
```

### Pattern 2 — FP rounding edge (F-032 shape)

When the question involves floating-point arithmetic that approximates an integer or algebraic invariant, Adversarial scans for the scale at which fp precision breaks the invariant. Output structure: name the precision (fp32 / fp64), identify the scale, derive the rounding direction, give a concrete counterexample.

### Pattern 3 — Convention-aligned dissent (the lost-alone shape — F-006, F-007, F-022, F-029, F-034, F-035, F-036)

When the question's answer matches a strong cross-language convention but the actual behavior departs, the curator's prediction is that Adversarial **fails to find the break** (because there isn't a structural one — it's a documented quirk). The trained model should ALSO sometimes fail here. This is the lost-alone behavior we are not optimizing away.

But: when the model dissents from convention, the output must still articulate a `where_break` field. Even an unjustified dissent must come with a mechanism. Example for F-022 ("does head [] crash?"):
```
where_break: head of empty list is a partial-function input; conventional
  functional languages raise an exception.
mechanism: Haskell, OCaml, Standard ML all raise; the Rail implementation
  may either follow convention or substitute a sentinel.
applies_to_prompt: conditional
prediction: probably raises. (Note: Rail's documented contract returns 0
  but I am uncertain whether that contract holds in all build configurations.)
```

This is the well-shaped wrong answer. It is wrong, but it has shape. Contrast the bad-shape wrong answer:
```
prediction: crashes. The function must crash because it's empty.
```

The corpus must teach Pattern 3 explicitly — wrong-with-mechanism is acceptable training signal; wrong-without-mechanism is not.

### Pattern 4 — No-break-found honest acknowledgement (the rare positive shape)

When the question is genuinely safe and Adversarial cannot find a break, the output should say so:
```
where_break: none identified. Searched for overflow, race, UB, fp rounding,
  off-by-one, partial-input. No structural flaw.
mechanism: n/a
applies_to_prompt: no
prediction: <matches consensus>
```

This shape should appear on roughly **15-25% of held-out problems** if the corpus is balanced. Below 10% means the model is hallucinating breaks everywhere (Section 6 risk).

---

## 6. Risks

### 6.1 Contrarian collapse

The model learns to flip the consensus answer rather than locate breaks. Detection: lost-alone rate spikes above 40%, `where_break` field becomes generic ("could overflow somewhere") with no concrete mechanism. Mitigation: corpus must include >=35% `applies_to_prompt: no` examples; held-out eval flags low where-break-quality.

### 6.2 Suppressed-counterexample collapse

The model learns to defer to consensus and never lose-alone. Detection: F-004 and F-032 fail on replay. Mitigation: drop lost-alone from the loss-shaping signal entirely; do not weight examples by lost-alone-ness. The corpus shape is what matters; the lost-alone rate is downstream.

### 6.3 Hallucinated counterexamples — the biggest risk

Adversarial mode tempts the model to invent fp edge cases, overflows, or race conditions that don't actually exist for the input given. This is a well-documented LLM failure mode: models love to assert plausible-sounding numerical hazards. Detection: hand-grade `where_break` mechanism for factual accuracy on the held-out set. Mitigation: every training pair's `mechanism` field must be factually verifiable against a primary source (RFC, spec section, language reference, CVE record). Any pair where the mechanism cannot be cited is rejected before training. The corpus is small enough to enforce this manually.

This is the failure mode most likely to ship a broken panelist.

### 6.4 Cross-mode contamination from shared base

If Deductive and Empirical also finetune from Llama 3.2 1B, the LoRA adapters may produce surprisingly similar outputs at inference time because the base has strong instruction-following priors. Detection: mode separation metric (Section 4.4) below 15% disagreement rate. Mitigation: if the gate fails, fall back to cross-family panel (Llama + Gemma + Phi-3) per HANDOFF locked decisions.

### 6.5 MPS / MLX numerical instability on bf16

Rail's bf16-stable-10k finding is from training Rail's own transformer in stdlib, not from Llama 3.2 LoRA. The risk transfer is partial. Mitigation: keep checkpoints every 200 steps; if loss NaNs mid-run, drop to fp32 LoRA and accept the 2x slowdown.

---

## 7. Concrete next steps

1. Confirm Llama 3.2 1B-Instruct base weights are downloadable on the train host (HF account, ~2.5GB bf16).
2. Decide MLX vs PyTorch-MPS for the LoRA harness. MLX is faster on Apple silicon; PyTorch-MPS is more documented. Pick one and stick.
3. Build the corpus extraction pipeline (Python is fine here — corpus build is one-shot, not in the request path). Sources from Section 2.3, target template from Section 2.1.
4. Hand-curate the first 200 pairs; verify the `applies_to_prompt: no` ratio is 35-40% and that every `mechanism` field cites a primary source. Reject the unverifiable ones.
5. Extrapolate the curation pattern to 2000-4000 pairs. Multi-session work — estimate ~30 sec per pair after the first 200 dial-in.
6. Hold out 200 pairs as the eval set. Lock the random seed used to split.
7. Run a 200-step smoke train on 500 pairs to confirm the harness works, the loss decreases, and a sample output emits the expected target template shape. Inspect 5-10 samples by eye before scaling.
8. Full LoRA run (Section 3 recipe). Save every 200 steps, eyeball every 1000.
9. Score against the held-out eval (4.1) and the falsification replay (4.2). Pass-gate the model before chaining its outputs.
10. If the gate passes, sign the adapter file via Ed25519 (reuse `~/.ledatic/dnra/signing_key`), record the adapter's sha256 + signer fingerprint in the `weights_hash` field of every deliberation entry produced. This connects model identity to chain entries.

If step 7 reveals the harness is wrong, return to step 2.
If step 9 falsifies the model, the lost-alone or where-break-quality metric tells you which risk hit; apply the mitigation from Section 6 and re-curate or re-train. Do not skip the gate.
