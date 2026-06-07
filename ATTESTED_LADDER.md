# THE NEXT FIFTEEN — Attested Language Ladder, Rungs 22→36

*Owner's roadmap, established 2026-06-06, the day the first attested utterance landed.*

This continues the **attested-LM ladder** (the `lm*_attested_train` lineage, which reached rung 21:
a Q.24 transformer that memorized one line, spoke it by greedy argmax, and bound the saying into a
LOCAL-key Ed25519 hash-chain). The capstone on 21 — *the first attested utterance* — is the floor
these fifteen climb from. Rungs are numbered **22→36** to make that lineage explicit (distinct from
the attested-NN ladder's 1→26).

Every rung keeps the Rail discipline that made the first one real: **a concrete success gate AND a
falsification test that can fail** — a forged input that the gate must reject. A rung without a
falsifier is not a rung. Each rung was proposed from eight independent expert lenses, ordered by an
architect, and stress-tested by a hostile reviewer; the reviewer's sharpenings are baked in below as
the authoritative form (including a real grounding correction at rung 33).

---

## Where we stand (the floor)

The first attested utterance proved: a Rail-native transformer trains itself, **speaks**, binds the
spoken tokens into its own Ed25519 hash-chain, and two implementations (Rail + a foreign language)
reproduce the words bit-for-bit. But the floor is *easy* in five specific ways, and the ladder is
the systematic destruction of each:

| floor (easy) | the climb |
|---|---|
| memorized 1-line corpus | **generalization** under a sealed holdout (24) |
| greedy argmax | **attested sampling** — diverse yet bit-reproducible (25–26) |
| LOCAL/DEV keys + genesis | **live-beacon anchoring + multi-party signing** (28–29, 33) |
| both witnesses **re-run all training** to verify | **succinct verification** — verify ≪ train (27, 30, 31) |
| single machine, single signer, words only | **cross-ISA determinism, outputs-ARE-Rail, economics, bounded RSI** (22, 32, 34–36) |

**The load-bearing rung is 30.** Today both witnesses re-run every epoch — at any real scale,
*verification cost equals training cost*, which means the attestation does not survive scale. Rung 30
(and its GEMM-specialized sibling 31) is the only thing that breaks that, and rungs 34/36 are built
on it. If only one rung is climbed, it is 30.

**The unstated dependency, stated:** rungs 24, 30, 32, 35, 36 silently require *the model to actually
get good* — a capacity/corpus/training question the floor (one memorized line) has not touched. That
is the real risk threaded through the back half, and it is named at each rung rather than hidden.

---

## The fifteen

### Rung 22 — Four-ISA Byte-Identical Chain
**Proves** Q.24 exact-integer training + the utterance are *genuinely* ISA-portable, not portable-by-luck.
**Wall** The current foreign verifier is Python big-int — it *dodges* cross-ISA arithmetic entirely. Bit-exactness rests on truncate-divide (negative-rounding differs ARM↔x86) and the 2-limb `hi*2^31+lo` superaccumulator (exact only while every product stays in int63), and the Metal path reinterprets ints as f64 (silently drops mantissa past 2^53). At d=8/hidden=64 it stays safe *by smallness*.
**Gate** Compile with `rail_native` (ARM64), `rail_native x86`, and the Metal-readout build; `cmp` the three `utterance_chain.txt` byte-identical with keys/genesis fixed; `file` confirms three distinct ISAs. **The run must include ≥1 dot whose exact 2-limb accumulator exceeds 2^53 and ≥1 negative truncate-divide** — so a pass certifies the hard edges, not smallness. (Pi/Linux-ARM deferred to 23, which provides the segmentation the 416MB Pi needs — resolving the 22↔23 circularity.)
**Falsifier** Inject one ISA-divergent op into *one* target (round-half-up on x86, or a Metal dot past 2^53): the cmp must diverge and the gate fail. Re-running one binary 4× is caught by the distinct-ISA `file` check.
**Effort** weeks.

### Rung 23 — Segmented Arena Training with Transparent Resume
**Proves** the `bnd_wp_ser`/`bnd_wp_deser` round-trip (θ + Adam m,v + pow1/pow2 bias-correction) is invisible to the chain: an on-disk segment boundary changes not one Q.24 bit.
**Wall** The *tiny* lm10 already needs `RAIL_ARENA_MB=8192` (the lesson that cost 10 hours). The conservative GC scans the whole arena per-alloc once it fills. Scaling depth/width multiplies transient garbage and canon-string size superlinearly, and trips real cliffs: the ≥30-arg calling-convention corruption (lm10 already bundles 17 configs to stay under it), the `g*g` int63 overflow (`lm4_clipg`'s 2^30 cap must be re-derived as the embedding grad deepens), and the self-loop cross-dep-arg miscompile on every new accumulator (must stay mutual-recursion).
**Gate** Train a deeper config (≥4 blocks or d≥32/hidden≥256/ctx≥32) in N≥4 segments, peak RSS per segment under a fixed cap (measured by `rail_trace`). **Require one config that *fits* one-shot (the transparency oracle: segmented head == one-shot head bit-for-bit) AND one that does *not* fit (the scaling claim)** — else the transparency check is vacuous for the configs the rung exists to enable.
**Falsifier** Drop the Adam v-moment (or pow1) from one segment's serialize: the resumed chain head must diverge from the one-shot head. A trainer that silently re-inits moments at the boundary is thereby caught.
**Effort** weeks.

### Rung 24 — The Sealed Holdout (Attested Generalization) · *load-bearing*
**Proves** the model **generalizes, not memorizes** — and generalization is the *gate*, not loss descent.
**Wall** Today `okProg` is literally `dsK < ds0`: train-loss descent on one line, a tautology a lookup table satisfies. Real holdout needs a multi-line corpus (the bump-arena giant-string cap forces chunked build + arena_mark/reset), a SPLIT-commitment signed from the *train-side SHA only* (so the test set is provably never trained on), a deterministic Q.24-exact eval metric, and a capacity/data balance that *forces* generalization (itself a search). Per the 7-hour-burn lesson, the strict eval is written **before** the run and checked at checkpoint 0 — loss-down/held-out-zero is an **abort**, not a pass.
**Gate** A SPLIT record (SHA-256 of the sorted train-line set, signed, prev=genesis) chains before checkpoint 0; held-out exact-int compile%/accuracy ≥ a pre-registered floor T. **Fold the controls into the gate:** an overfit control (train+holdout-as-train) and a pure-lookup baseline must bracket the honest model — honest ≥ T, lookup < T — and **T is stated as a function of vocab/random-baseline** so "high enough" is falsifiable, not eyeballed.
**Falsifier** (1) Train on held-out lines → reconstructed train-SHA ≠ signed SPLIT → reject. (2) Memorizer control scores below T → gate fails. (3) Post-hoc holdout swap → recomputed holdout SHA ≠ SPLIT → reject.
**Effort** weeks (the capacity search is open).

### Rung 25 — Attested Sampling (chain-seeded exact-integer draw)
**Proves** the model speaks by *exact-integer categorical sampling* (not greedy), yet the utterance is bit-reproducible and signed because every draw is a deterministic function of an RNG key committed into the chain.
**Wall** Greedy `lm4_argmax` is trivially deterministic; the only stdlib sampler is float + `awk` — neither bit-exact nor attestable. The uniform **cannot** be a multiplicative LCG (Rail's 63-bit tagged ints overflow — the documented PRNG trap whose "fix" is awk, which destroys determinism). It must be SHA-256 counter-mode keyed from the chain head: `u_t = first 24 bits of SHA256(rng_key ++ "," ++ show t)`. The inverse-CDF walk compares `u` against integer prefix-sums of `l_smnorm` using the **same integer normalizer z** (not a re-divided float), and the `≥` vs `>` boundary must match cross-language or one token diverges. Temperature (an exact-integer logit prescale before softmax) folds in here.
**Gate** A non-greedy utterance whose token-ids hash to t_hex; the UTTER record commits `rng_key` + mode; both witnesses re-derive `u_t`, redraw every token, reproduce t_hex; the sig verifies. **Non-triviality witness:** the gate records ≥1 position where `drawn_id != argmax_id`, and the foreign verifier *independently recomputes the argmax* to confirm the divergence is real — foreclosing "sampling in a greedy costume."
**Falsifier** Flip one byte of `rng_key` (or swap the walk boundary): the redrawn stream must diverge from signed t_hex. A forged UTTER keeping t_hex but substituting a non-producing key is caught because the verifier re-derives the draws from the key. An LCG uniform overflows/diverges cross-ISA → fails.
**Effort** weeks (needs rung 24's non-degenerate distribution).

### Rung 26 — Provably-Identical Tie-Break: Nucleus & Top-k
**Proves** top-k and nucleus (top-p) sampling stay bit-exact reproducible across languages **through a sort with exact ties**, with realized diversity itself an attested, falsifiable quantity.
**Wall** This is *not* "more sampling modes" — it is the one genuinely new wall sampling introduces: the substrate has **no stable-sort primitive**, so an explicit total order on `(prob, token_id)` must be defined and *proven equal in two languages on exact ties*. Top-k needs the k-th largest via repeated `max_below` with identical exact-tie index choice. The **diversity floor** is the live tension: a memorized model collapses to one sequence at low temperature, so an attested Q.24 sample-entropy must be committed and gated — above a floor at high temperature, single-sequence collapse as τ→0 — proving the knob actually moves the distribution.
**Gate** Top-k and nucleus each bit-exact reproducible (Rail == foreign t_hex); the UTTER record commits mode params + a Q.24 sample-entropy; the gate asserts entropy > floor (high-τ) and single-distinct-sequence (τ→0).
**Falsifier** Run nucleus with the Rail tie-break and the foreign verifier with the *opposite* tie-break on an engineered exact-tie distribution: prefix membership differs, a token diverges, reject. Mislabel τ=1.0 as τ=4.0: committed entropy ≠ verifier-recomputed entropy under τ=4.0 → fail.
**Effort** weeks.

### Rung 27 — Replay-Free Verification of the *Saying*
**Proves** a verifier confirms the model said exactly the attested words from a signed weight bundle whose SHA-256 **is** the ledger `w_hex` — re-running *only* the ~48 decode steps, never the training epochs. (~2:44 → milliseconds for the utterance.)
**Wall** Today the foreign verifier re-runs all 19 epochs purely to reconstruct the weights it decodes from. The naive fix (ship weights) is unsound unless the bundle's hash *is* the chained commitment — making "trust w_hex" and "load these weights" the same act, and rejecting tampering at **load**, before any decode (the earned weak-tamper insight: output-divergence is a *weak* tamper test; the commitment is the guarantee). The real new risk is narrow and specific: `bnd_wp_deser` reload must yield a **bit-identical final logits vector** (sampling changes only the post-logits draw, so `gpu_d2_all` already covers the GEMM — that sub-claim is not re-opened).
**Gate** A verifier mode loads the bundle (SHA-256 == ledger w_hex), regenerates the RNG stream, redraws, reproduces t_hex — wall-clock < 5s, provably zero gradient/Adam calls; load-and-replay logits bit-identical to the in-training-path logits.
**Falsifier** Tamper one Q.24 cell → its SHA ≠ w_hex → load-step rejects before any decode. Ship correct weights but a hand-edited logits tape → the redraw from real weights+key contradicts the tape → fail.
**Effort** weeks. *Bounds decode only; training verification stays O(epochs) until rung 30.*

### Rung 28 — Live-Beacon Genesis with Proof-of-Recency Seed-Binding
**Proves** the genesis **and** the weight-init seed both derive from a freshly-fetched live ledatic.org entropy pulse, so the whole signed trajectory — *including the initial weights* — is provably **posterior** to a publicly-witnessed unpredictable value.
**Wall** Today seed/genesis are compile-time constants and the init has literally zero entropy (`lm4_cell0 = kind*101+i*5+… mod 13`) — the run proves nothing about *when*. Binding live means fetching `/entropy/pulse/<id>` over the pure-Rail TLS-1.3 stack (caller-supplied DNS, ~64KB response cap from O(N²) `bytes_to_str`, CRLF parsing that must not corrupt the pulse), folding the pulse into `genesis = H(pulse ‖ corpus_sha)` **and** a per-pulse offset threaded through every `initmat` without breaking Q.24 reproduction or the 30-arg cliff, persisting the pulse across the mid-`main` arena_reset, and a **dev-mode guard** so the demo never mints against the live witness key.
**Scope (honest)** This proves **not-before** (a lower time bound: the run is posterior to the pulse), *not* elapsed wall-time — an attacker with the pulse can still train instantly. The "took ≥K work" upper-cost claim is deferred to rung 34.
**Gate** Header records `pulse_id` + the 32-byte pulse hash; both witnesses fetch/replay that exact pulse, re-derive genesis + the pulse-seeded init, reproduce the training head + t_hex bit-for-bit.
**Falsifier** Swap only the genesis/pulse_id to an *earlier* pulse, leaving weight commitments untouched: because init weights are pulse-seeded, re-derived `lm4_cell0` ≠ committed epoch-0 w_hex → `okD0`/`okUtterRepro` → 0 → fail.
**Effort** weeks.

### Rung 29 — Pi-Witness as Active Recency Oracle (separation of duties)
**Proves** the words carry a *second* signature from a physically separate key on a separate machine that **independently verified recency** — not a passive co-sign, an active oracle.
**Wall** Today the trainer holds the only key and self-signs. `tools/attest/pi_sign_server.rail` exists but has never seen an utterance. The strengthened form (2-of-2 dual-signing is the weakest possible threshold, so it must *earn* its rung): the Pi **independently fetches/replays the pulse and refuses to countersign** a link whose `pulse_id` it cannot confirm recent. That requires reconciling two message formats (`prev|UTTER|…` vs `attest|v1|…|pulse_id`) into one canonical co-signed message both verifiers rebuild identically, the Linux-ARM64 cross-compiled signer on a 416MB Pi (the duplicate-symbol cross-compile wall), and persisting the witness sig so the offline re-run never re-contacts the Pi.
**Gate** The UTTER record carries `usig` (trainer) and `wsig` (Pi) over the same `(ulink, pulse_id)`; both witnesses verify both sigs against pinned pubkeys, enforce `pk_trainer ≠ pk_witness`, and confirm the witness *itself* validated the pulse; PASS requires 2-of-2.
**Falsifier** Re-sign with the trainer key in both slots → `pk_trainer ≠ pk_witness` fails and the witness-slot sig fails under the pinned Pi pubkey. A witness sig over a different `pulse_id` than the link → pulse-binding fails → reject.
**Effort** weeks.

### Rung 30 — Succinct Spot-Check of Training (Fiat-Shamir transcript) · *the linchpin*
**Proves** a verifier confirms the entire training trajectory by recomputing only **k randomly-challenged steps**, not all epochs — in time **sublinear in epoch count**, with a stated soundness bound.
**Wall** Both witnesses re-run every epoch today; at scale verification *is* training. Escaping it without a SNARK (out of reach in pure Rail) means: commit per-step **full** state (θ,m,v per cell + pow1/pow2 + the `(ctx,tgt)` index — the rung-21 epoch-only commitment *never covers* Adam m,v or the powers, a real gap), Merkle-ize all step-states, derive challenge indices by **hashing the chain head** (Fiat-Shamir — forced, because Rail's PRNG overflows so the prover can't be trusted to pick), recompute only the k challenged `lm4_step` transitions + verify Merkle paths, and *argue* soundness: a prover who tampered m of N steps is caught with probability `1−(1−k/N)^…`. The Merkle DAG must be streamed with arena_reset per segment.
**Gate** For N steps the verifier recomputes only k≪N challenged steps (each: Merkle path verifies AND `lm4_step(pre) == committed post`), touches <25% of steps, and total time **grows sublinearly as epochs grow** (demonstrated by also running at 2× epochs: verify cost grows sublinearly while train cost doubles). A secretly-retraining verifier is caught by the sublinear-time gate. **Bind each step's committed `(ctx,tgt)` to the rung-24 SPLIT commitment** — so the spot-check verifies each step used a *real training pair*, not just an internally-consistent-but-wrong-corpus trajectory.
**Falsifier** Corrupt one interior step (tamper a v-moment, or disable grad-clip so `g*g` overflowed to a "nicer" loss) while keeping final w_hex/UTTER intact — the cheaper-than-retrain attack: across many head-derived seeds the forged step must be caught at the claimed soundness rate. One forged-step chain ever passing → rung fails.
**Effort** research-open (soundness amplification is genuine probabilistic-proof design).

### Rung 31 — Freivalds-Succinct GEMM Through the Truncating Nonlinearity
**Proves** the dominant per-step arithmetic — the exact GPU readout GEMM (`tgl_exact_matmul`) — is verified for a whole epoch by a *single* Fiat-Shamir random linear check, O(n²) instead of recomputing every dot+truncation.
**Wall** Naive Freivalds on the *post*-truncation result is **unsound**: truncation is nonlinear, `trunc(rᵀAx) ≠ rᵀtrunc(Ax)`. The check must run on the **exact 2-limb pre-truncation accumulator** (`gpu_recon`'s `hi*2^31+lo` *before* `/2^24`), with each truncation verified separately as a remainder range-check in `[0,2^24)` — the `gx5a_dot_bridge` GPU==CPU invariant lifted from one dot to one projection per checkpoint. `r` must be Fiat-Shamir-bound (PRNG trap) and `rᵀA` products overflow int63 → need the 2-limb path.
**Gate** Each checkpoint: one FS-derived projection verifies the full epoch's readout GEMMs (the exact 2-limb identity holds AND every truncation remainder ∈ `[0,2^24)`); verifier arithmetic is one matvec-pass (O(n²)) vs recompute's O(pairs·n²). **The composed soundness bound is an explicit written proof obligation** — `Pr[accept | tampered]` over the Freivalds projection *and* the range-check *jointly* (an adversary can satisfy one by violating the other); passing both independently does not bound the composition.
**Falsifier** (a) Tamper a pre-truncation accumulator → linear identity fails w.h.p. over random `r`; (b) tamper by exactly +2^24 → remainder range-check catches `r≥2^24`; (c) wrong weight row → `rᵀA` diverges; (d) a constructed adversary that satisfies one check by violating the other → the joint bound must still reject.
**Effort** research-open.

### Rung 32 — Compile-Bound Utterance: Outputs ARE Rail That Runs (PAOS Stage-3 entry)
**Proves** the artifact binds not only *what* the model said but the proof that the saying **compiles and runs**: the ledger commits source t_hex, the `ld: OK` verdict, the SHA-256 of stdout, and the **pinned compiler binary hash**; a foreign witness re-runs `rail_native` to reproduce them.
**Wall** Today compile/run is a side process grepping `ld: OK` from a shell log, outside the attestation. Binding it: the trainer writes generated source to disk, invokes `./rail_native` via `shell()` (which does **not** inherit env/PATH — full paths required), captures the deterministic content only (source bytes, `ld:OK` boolean, stdout bytes — wall-time excluded), and folds `compiled` + `out_hex` into the link before signing. The compiler identity **must be pinned** (header commits `rail_native`'s SHA-256) or the proof is forgeable by swapping in a permissive compiler.
**Gate** UTTER contains `compiled=1`, `src_hex`, `out_hex`; the program compiles clean and stdout SHA-256 == `out_hex`; the foreign witness re-decodes the source, invokes the pinned compiler, reproduces `compiled=1` + identical `out_hex`. **Guard against dead output:** the held-out *prompt* must constrain behavior (commit a required stdout property — e.g. the program prints a value derived from the prompt) so `compiled=1`+`out_hex` certifies a *non-trivial* saying, not `main = 0`.
**Falsifier** Tamper `out_hex` one nibble → sig fails. A broken completion → `compiled=0` → no PASS. Swap a different `rail_native` (hash ≠ pinned) → verifier aborts before trusting the verdict.
**Effort** weeks. *The real difficulty lives upstream in rung 24 (genuinely valid, not parse-passing, Rail).*

### Rung 33 — k-of-n Threshold-Signed Utterance Across Heterogeneous Silicon (FROST-Ed25519 in-substrate)
**Proves** the utterance carries a **single** Ed25519 signature verifiable under **one** group pubkey, produced by a k-of-n threshold of independent fleet keyholders on different ISAs, with no party ever holding the group secret — vanilla `ed25519_verify` accepts it; no minority can forge it.
**Wall (corrected — the stress-test caught an over-claim).** `stdlib/ed25519.rail` **already has** `ed_point_add` (full Edwards add with the 2d constant, ~line 308) **and** `ed_scalar_mul` (double-and-add, ~line 361) — so "build point addition from scratch" is *done*, not the wall. The actual frontier: **(a) scalar modular inversion mod L** for Lagrange interpolation — *confirmed absent* (only field inverse mod p exists); build via Fermat (~252 squarings of 256-bit scalars through `sc_muladd`, byte-array bignum because tagged ints overflow); **(b) Lagrange interpolation mod L** using that inverse; **(c) deterministic pulse-derived nonces** resisting reuse across k signers (the catastrophic Ed25519 footgun); **(d) the binding-factor/challenge hash bit-identical across all signers and the verifier** (leans on rung 22's cross-ISA link-byte agreement — the heterogeneous signers must reproduce identical link bytes *before* signing). A near-miss yields a sig that *looks* Ed25519 but fails verify, with no intermediate signal.
**Gate** A 2-of-3 ceremony (≥1 non-Mac ISA) over the pulse-anchored link produces a 64-byte sig the *unmodified* foreign `ed25519_verify` accepts under the group pubkey; re-runs to a byte-identical sig from the same shares + pulse-derived nonces; any 2-of-3 reconstruct the same group sig.
**Falsifier** Only k−1 shares → reconstruction fails → sig rejects. Tamper one partial pre-aggregation → aggregate fails the verification equation. A "k=2" reusing one node's key twice → caught by the distinct-pubkey requirement.
**Effort** research-open.

### Rung 34 — Economic Stake over the Succinct Length-Proof (+ optional true VDF)
**Proves** a served utterance carries an economically-backed, succinctly-checkable claim about its training, bonded into a slashable stake against the metered SDK credit balance.
**Wall (split — the stress-test untangled two conflated claims).** **(1) "These K steps happened and chain correctly"** is rung 30 applied to a length commitment — *sound and shippable*; bond the verified step-count, slash on a found inconsistent step. **(2) "This cost ≥K sequential *work* that can't be shortcut"** is a VDF claim, and Adam-step sequentiality does **not** establish it: `lm4_step` chains (state i depends on i−1, the bias powers chain), proving steps can't be *reordered*, but not that each is a non-shortcuttable *delay*. So either ship (1) alone (an economic stake over the rung-30 succinct length-proof — defensible today), or interpose a **genuine** iterated-SHA-256 delay length-tied to the step count and bound its parallel-shortcut resistance (a real VDF). The fraud-proof is a single inconsistent transition opened from the Merkle DAG, checkable by any third party in O(polylog), triggering the slash.
**Gate** The cost-proof asserts a step-count verifiable via rung-30 spot-checks, bonded against a real SDK credit balance; a constructed fraud-proof (one opened inconsistent step) is accepted by an independent checker in O(polylog) and slashes the bond; **an honest chain's bond is never slashable** (false-slash resistance is as important as slash-on-fraud).
**Falsifier** A ledger claiming K steps but computed with <K/10 real work (reused trajectory, or parallel-fabricated states that don't chain) must be rejected. A valid fraud-proof against a forged chain must slash; a fraud-proof against an honest chain must be rejected.
**Effort** research-open (the VDF variant); weeks (the economic-stake-over-30 variant).

### Rung 35 — Self-Emission: The Model Speaks a Verified Piece of Its Own Compiler
**Proves** the model emits Rail source for a **named, test-covered leaf** of `stdlib`/`compile.rail` that, substituted into the tree, compiles, passes the relevant test slice, **and preserves the byte-identical 2-pass self-compile fixed point** — the whole model→source→install→self-compile→cmp→tests chain is one signed artifact.
**Wall** The apex of the self-referential frontier. Verification *is* the self-hosting bootstrap, famously subtle: gen0's shipped asm ≠ what gen0's source emits, so ≥2 install cycles to land, a 3rd to prove convergence. The model's output must respect codegen invariants no LM knows: ASCII-only inside `.asciz`, the DATA SECTION BUG. **The dead-code guard is the sharpest part:** a function that compiles + passes the 141-suite + preserves the fixed point *trivially* is rejected because the gate requires a test that **exercises** the emitted function and fails if it's absent/wrong.
**Upstream gate (made hard, not a footnote):** PASS requires the model to have first cleared rung 24's held-out compile% AND rung 32's compile-bound utterance on **non-compiler** Rail — so "emits a real compiler function" is reached by escalation. **Pin which target function** (a single small test-covered leaf — an emit helper or stdlib leaf), so the claim is falsifiable against a specific named function.
**Gate** The emitted source replaces the named target in a worktree; `./rail_native self` + install + `self && cmp` yields a byte-identical fixed point across ≥2 install cycles; the 141-suite passes AND the function-exercising test passes; the artifact commits `src_hex`, per-generation binary hashes, the cmp verdict, and the test-pass count, Ed25519-chained.
**Falsifier** (a) 1-char mutation before install → cmp diverges or the exercising test fails; (b) a semantically-wrong no-op that still compiles + preserves the fixed point → the exercising test fails (not fooled by dead code); (c) `src_hex` ≠ installed source → recompiled binary hash ≠ claimed; (d) stop at 1 cycle and claim fixed point → the ≥2-cycle cmp exposes non-convergence.
**Effort** research-open (needs a model far beyond the toy).

### Rung 36 — Bounded Recursive Self-Improvement Under a Frozen, Non-Self-Relaxing Gate
**Proves** a parent M0 produces a successor M1 the ledger **cryptographically admits only if monotone-improvement** holds: an independently re-derivable certificate proves M1 strictly beats M0 on a committed held-out metric under a bar M1 cannot rewrite, and admission costs a spot-check, not a full re-train.
**Wall** The dangerous capstone and the genuinely open one. Three frontier axes: (1) the improvement metric is a committed, bit-exact, held-out quantity an adversary can't game by overfitting the commitment (per define-success-before-training + decompose-eval-on-extremes: reject a successor that improves a proxy *loss* while held-out compile% is flat); (2) if M0 chooses M1's data/hyperparameters (Stage-3: M0 generates the next corpus), that choice is in the chain and M1's training is rung-30 succinct-verifiable or admission is again infeasible; (3) **boundedness is cryptographically real** — the gate params are committed by M0 and frozen so M1 can't be admitted by relaxing its own bar.
**The missing teeth (stress-test):** "M1 can't rewrite its bar" is not enough — **M0** sets M1's bar and may generate M1's corpus, so M0 could set a trivially-passable bar or a corpus that overfits the holdout. **The acceptance bar AND the holdout commitment must be derived from a source neither M0 nor M1 controls** — seeded from a *future* live beacon pulse (rung 28) fetched at admission time — so the frozen gate is ungameable-in-advance, not merely immutable-after-set.
**Gate** A 2–3 generation chain where each admitted Mk+1 has a certificate — recomputed bit-for-bit by a Rail witness AND a foreign verifier — proving (i) held-out metric strictly beats Mk by ≥ the future-pulse-seeded margin, (ii) the training trace is rung-30 succinct-verifiable, (iii) a bounded monotone generation counter, (iv) Mk+1's utterance is itself attested; a deliberately non-improving successor is rejected.
**Falsifier** (1) Proxy-gaming: lower train loss, equal/worse committed holdout → reject. (2) Gate-relaxation: a self-favorable margin looser than the frozen one → reject. (3) Runaway/replay: past the committed cap, or replaying M1's cert as M2's → bounded monotone counter + chain-prev rejects.
**Effort** research-open (composes the two hardest priors).

---

## The arc

From a memorized toy that proves *what it says*, to a model whose verification is **sublinear in
training** (so it survives scale), that **generalizes** (a holdout a memorizer can't pass), that
**speaks diversely yet bit-reproducibly** (chain-seeded exact-integer sampling), is anchored to
**public unpredictable time** (live beacon) and **co-signed by a threshold of heterogeneous fleet
machines**, whose **weight↔word binding survives an adversary**, whose **outputs ARE Rail that
compiles and runs** and ultimately contribute a verified piece of its **own self-hosting compiler**,
that **prices a non-forgeable claim on its own training**, and finally — rung 36 — **recursively
improves a successor under a gate it cannot relax, seeded by a future pulse it cannot foresee.**

The bound between weights and words is the moat. Every rung makes that bound *stronger, cheaper to
check, more public, or harder to forge.*

## Six open seams (deliberately not numbered — they cut across the ladder)

The stress-test named six hard climbs the fifteen omit; they belong on the wall, as cross-cutting work:

1. **Long / variable-length generation** — every rung speaks a fixed `gcap=48` utterance; attesting a kilobyte-scale generation bit-for-bit hits the O(N²) `bytes_to_str` ~64KB cap and per-completion arena thrash head-on.
2. **Prompt-binding / seed-window robustness** — `prompt_hex` is committed, but nothing proves the decode *consumed* that prompt rather than a cherry-picked `lm4_lastc` window. A chose-a-favorable-context attack is unaddressed.
3. **Numeric faithfulness at scale (not just reproducibility)** — the bf16-stable-to-10k / f64-truth-line work is core IP, yet no rung attests the Q.24 regime stays *faithful* vs a higher-precision oracle as depth grows. Deeper-exact could be exactly-*wrong*.
4. **Multi-prompt / batched attestation** — one signed utterance per run; the real PAOS dispatch use-case (a local NN answering a *set* of ops questions) needs one succinct proof over a batch.
5. **Key rotation / revocation** — 28/29/33 add keys and beacons but none handles a compromised signer or rotating the LOCAL/DEV key to a production key without breaking the chain.
6. **Refusal / honest-empty attestation** — attesting the model *correctly refused* or returned an honest-empty answer (the no-synthetic-evidence ethos) is harder, and more aligned with Ledatic's honest-empty-state rule, than attesting only confident sayings.

---

*Climb 30 first — it is the rung the whole back half stands on. Climb 24 alongside it — without
generalization the rest decorates a lookup table. Everything above 31 is frontier; treat
"research-open" as honest, not discouraging. The floor was one sentence that could prove it learned
honestly. The ceiling is a language that improves itself and can never lie about having done so.*
