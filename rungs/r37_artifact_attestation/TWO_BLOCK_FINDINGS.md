# 2-block float RoPE — findings (2026-06-08/09)

Follow-up to `FRONTIER.md`. The frontier execution there concluded **"the wall is induction
DEPTH"** (every trainable model in the arc was 1-block; the only 2-block model, r24's lm10, was
exact-int and untrainable). This file records what building + running the actual 2-block float RoPE
model established — which **corrects that conclusion**.

## The build
`float_lm_2block.rail` — a true 2-block pre-norm transformer (RoPE, residuals, LayerNorm, FFN),
reverse-mode backprop with **cross-block gradient chaining** (`block_fwd`/`block_bwd`/`fwd2`,
weights bundled as 5-elem lists to stay under Rail's ARM64 arity limit). Built on the proven 1-block
inline code, factored.

**Gradient correctness is proven empirically**: the model trains *below the "copy-fails" floor*
(~0.31 nats/char), which a broken cross-block backward could never reach. (Loss floors for this task:
~0.15 = copy-rule learned, only the 2 input digits per line are unpredictable; ~0.31 = template
learned but copy not; >0.31 = template not even learned.)

## Finding 1 — "depth is the wall" was a CONFOUND, not a fact
The earlier 1-block RoPE plateau (0.78) and the first 2-block attempt (0.74) were **not** depth/representation
limits. They were two stacked bugs:
1. **No `1/sqrt(fan_in)` init.** `init_weight` used a fixed +-0.5 scale (the code comment even admits
   Xavier was "deferred"). Over 2 blocks the scale compounds -> initial loss ~14-17 (vs uniform 3.3),
   a saturated softmax, poor gradients.
2. **Cosine LR decaying to ~0.** At 1500-4000 steps the schedule drove lr to ~1e-5, freezing the model.
   The "plateau" was the LR dying, not an optimization floor.

Fix: **Glorot/Xavier uniform init** (`limit = sqrt(6/(fan_in+fan_out))`) + a tuned constant-ish LR.
Result: 2-block RoPE trains to **loss 0.147** (the copy floor) on the 16-line corpus — vs the 0.74-0.78
"plateau" before. The architecture and optimizer were always capable.

## Finding 2 — at 16 examples it MEMORIZES, it does not generalize
Well-trained (loss 0.147) but held-out echo on `31`/`75` = **0/4**. Low train loss + failed holdout =
textbook **memorize-without-generalize**. Because there is *no absolute PE* (only RoPE), the model
cannot key on absolute position — yet it still fits, by learning a **content-addressed lookup over
the 16 seen digit-pairs** rather than a general copy operation. The novel pair is outside the table.

## The reframe (what the build actually bought us)
The wall is **not** numerics (float trains where exact-int diverged), **not** depth (2-block trains to
floor), **not** position-encoding (RoPE is in place and correct). It is the **pure
memorize-vs-generalize gap** — an architecture-independent phenomenon. That narrows the remaining
levers to two:
- **(A) Regularization / grokking** — weight decay makes the low-norm general copy cheaper than the
  high-norm lookup; with sustained LR the model eventually groks. Keeps data small.
- **(B) Make memorization impossible** — a value space too large to memorize forces the rule
  immediately (the literal "data scale past capacity" reading). Needs many distinct examples.

## Grok experiment (IN PROGRESS as of this writing)
`float_lm_2block_grok.rail`: d=32, 2-block RoPE, **AdamW wd=0.1**, **constant post-warmup lr=0.002**
(NOT cosine-to-zero — that is actively anti-grokking), 20k steps, held-out echo eval every 500 steps
to catch the phase transition. Step-500 state: train loss 0.134, held-out 0/4 — the canonical
pre-grok signature (memorized, held-out at chance). Outcome pending.
- If held-out -> >=2/4 at some step: grokking confirms (A); weight decay + sustained LR was the missing
  ingredient. Determinism (fixed init seeds, no RNG) lets us reproduce + wrap in the artifact-attestation
  frame (B4/B5/B6) for an attested, trainable, *generalizing* model = PAOS Stage-2 template.
- If still 0/4 at 20k: (A) needs more steps/tuning; pivot to (B) data-scale forcing.

## Resolution attempts — neither grokking NOR data-scale forcing induced the copy head

### (A) Weight-decay grokking on the 16-line set — NO grok in budget
AdamW, constant post-warmup LR (cosine-to-zero is anti-grokking), d=32, periodic held-out eval:
- wd=0.1, lr=0.002: train loss -> 0.003 (memorizes harder), held-out flat 0/4..1/4 (chance) through 6k.
- wd=0.5, lr=0.002 (effective decay 1e-3, literature-grade): same — train sits at memorization (~0.01,
  with a wd-spike to 0.886 at step 4000 that immediately re-memorized), held-out flat at chance.
The memorization basin is too deep for weight decay to escape in a tractable step budget.

### (B) Data-scale forcing — windowed over 9,984 distinct 4-digit numbers, d=32 — NO copy head
Each step trains on a fresh 10-line window of the pool, so low train-window loss can only come from
generalizing (you can't memorize 9,984 numbers in ~24K params). Result through step 2500:
- twloss: 14.2 -> **plateaus at ~0.52**, which is *exactly the copy-FAILS floor* for the 4-digit task
  (`(4 input + 4 echo) digits x log10 / 35 chars = 0.526`). The model learned the **template perfectly**
  (27/35 deterministic chars -> ~0 loss) but predicts the **4 echo digits at full entropy — zero copy.**
- held-out: noisy ~3-12/64, i.e. chance (~6/64 baseline). One flicker to 12, no steady climb.
RoPE is *relative*, so held-out length is NOT a confound — a real copy head would work at any position.
The model found the easy "template + guess-a-digit" minimum and never formed the copy circuit.

### (B') Data-scale forcing, d=64 — IT GENERALIZES (the answer)
Same windowed forcing, but **d=64 / d_ff=256 / lr=0.003**. Held-out climbed and then **consolidated in a
grokking-style jump around step 5000-5250**:
```
step 3000  twloss=0.54  HELDOUT=40/64
step 4500  twloss=0.53  HELDOUT=39/64   <- plateau
step 5000  twloss=0.46  HELDOUT=47/64
step 5250  twloss=0.43  HELDOUT=60/64   <- phase transition
step 5500  twloss=0.50  HELDOUT=62/64
FINAL                   HELDOUT=62/64   (>=48 = GENERALIZES; 97% of held-out digits copied)
```
twloss drops BELOW the no-copy floor (0.43 < 0.526) and held-out hits 62/64 on numbers NEVER seen.
**The copy/induction head forms.**

### The unifying finding: generalization is gated on CAPACITY, and data-scale forcing is the trigger
- Small data (16 lines): reaches the copy *floor* (0.147) but holdout 0/4 -> a **content lookup**, not a
  copy head. Weight-decay grokking didn't escape it in budget.
- Large data (9,984), **d=32**: can't memorize -> falls back to template + guess, twloss pinned at the
  copy-fails floor, holdout ~chance. **Too narrow to fit the induction circuit.**
- Large data (9,984), **d=64**: the induction head **forms and generalizes (62/64)** via a late
  consolidation. Capacity was the gate; data-scale forcing was the trigger.
So a copy/induction head (classically a 2-layer prev-token -> induction circuit) DOES emerge from plain
gradient descent here — given (i) data too large to memorize, and (ii) enough width. No multi-head, no
weight decay, no exotic schedule required. (Multi-head would likely make it form sooner/cleaner — the
d=64 transition is noisy and late — but it is NOT required.)

### What this means for PAOS Stage-2 — loop CLOSED
A trainable + **generalizing** 2-block RoPE transformer exists (62/64 held-out). Wrapping it in the
artifact-attestation frame (B4/B5/B6: quantize to Q.24 -> SHA-256 commit -> re-eval Q.24 -> foreign-verify)
gives an **attested, trainable, generalizing** model — the PAOS Stage-2 template, realized end to end.
Determinism (fixed seeds, no RNG) means the exact 62/64 model reproduces on re-run, so the attested Q.24
artifact is bit-for-bit checkable cross-platform. Numerics was never the wall; nor depth; the wall was
memorize-vs-generalize + capacity, both now resolved.

**Verified end-to-end (2026-06-09, `float_lm_force_d64.rail` capstone re-run):**
- Deterministic re-run reproduced **HELDOUT 62/64 bit-identically** (step-0 twloss 14.2270829487696 matched to the digit).
- Quantized to Q.24, committed embed+readout (3456 exact-int weights) → **SHA-256 `35eadeabdf9d78ab9701ce663882e137b628c0439a468db47b2171fdda01dd63`** (`r37_force_weights_q24.txt`).
- **R37_FORCE_ECHO_Q24 = 62/64** == float echo → the Q.24 commitment is faithful (generalization survives quantization).
- **B6 foreign-verify PASS** — with scope honestly stated: the v1 checker re-derived the SHA of the
  *embed+readout commitment only* (3,456 of 93,696 weights, hash-only, no signature, no metric
  re-derivation). **The model result is closed; the v1 attestation wrapper was partial.**
- **v2 gate-grade closure (2026-06-09, post-PAOS-audit):** full pipeline rebuilt to the rung-26
  standard — split SHAs pre-registered, ckpt-0 abort control, ALL 14 tensors quantized + committed
  (93,696 Q.24 ints, canonical order in the signed message), twin-run artifact-level determinism,
  Ed25519 dev-key signature bound to pre/post beacon pulses, and a foreign verifier
  (`r37_foreign_check_v2.py`) that re-implements the full forward in numpy float64 and re-derives
  the 62/64 metric from the committed weights alone. Record: `out/r37_attestation.txt`.
- **Bracket corrected (audit finding):** the strongest lookup-table memorizer scores **exactly
  48/64** on this split (16 holdout numbers x best 1-digit-neighbor match; pool is 99.84% dense) —
  equal to the old T=48, so the old threshold did NOT separate model from lookup. Corrected
  **T' = 55** (lookup 48 < 55 <= model 62), embedded in the signed message.

## Reusable engineering lessons (earned)
1. **Deep stacks need `1/sqrt(fan_in)` init.** Without it a 2-block model starts at loss ~14-17
   (saturated softmax) and lands in a bad basin even if it eventually descends.
2. **Cosine-LR-to-zero is anti-grokking.** Generalization phase transitions need *sustained* LR;
   a schedule that decays to ~0 freezes the model at the memorization solution before it can grok.
3. **For tiny matmuls (d<=32, short seq), GPU dispatch latency dominates** — but the naive Rail CPU
   matmul is *also* slow (~0.4-0.7s/step here), slower than GPU's ~0.34s/step. Neither is fast;
   batching short sequences (vs one long concat) is the real speed lever, deferred.
4. In-place tensor ops after a GPU matmul silently no-op on the GPU side — use copy-then-mutate
   (`rope_copy`). See `rail-bug-inplace-after-gpu-matmul` memory.
5. **Wide (22-param) self-recursive functions with mixed int/float params MISCOMPILE.** An int param
   (`wlen`) adjacent to a float param (`lr`) got type-poisoned to a float denormal (`show wlen` ->
   3.46e-321 = the int bits read as a double), so `float_arr_new (wlen*V)` allocated a ZERO-size buffer
   and the fill-loop spun out-of-bounds forever — a SILENT HANG (5% CPU, no output) for 2 hours. Fix:
   bundle scalar ints into a list (`dims=[V,d,d_ff,wlen,nwin,...]`), pass that + the lone float `lr`.
   Drastically cuts param count and removes int/float param adjacency. (The `(var+0)` float_arr_new
   workaround alone was NOT enough — the param-list width was the real trigger.)
6. **Long jobs need a LIVENESS watchdog, not just a completion watcher.** My watchers waited for output
   that never came (the hang produced none), so nothing fired until the user pinged at 2h. A watchdog
   that alerts on "log mtime stale > N min" catches hangs in minutes. Earned hard 2026-06-09.
