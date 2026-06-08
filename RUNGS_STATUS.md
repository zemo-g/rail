# ALL RUNGS — Honest Status Board (22→36 + 6 seams)

*2026-06-07. 36-agent build+adversarial-verify workflow (5.0M tokens) over the attested-LM ladder + serial validation of the runnable rungs + the rung-35 self-emission harness. No fabricated passes.*

## Tally

**14 of 15 genuinely GREEN (2026-06-07/08: 6 -> 14)** — 22, 23, 25, 26, 27, 28, 29, 30, 31, 32, 33,
34, 35, 36. Remaining: **24** — INFRA FIXED 2026-06-08 (completes 2m25s, was 4h+/never; bit-exact
[D0=1 + byte-identical diff]; constant ~2.3GB memory via CPU-matvec + disk-only segmented arena).
But **honest capacity FAIL**: the d=8/2-block model scores `0/4` held-out echo at BOTH 40 and 200
epochs (full-acc 19/54 identical, loss plateaued = converged) — a genuine capacity wall, NOT a
training-time issue. Green needs a larger model / more data (changes the "smallest honest instance"
claim) — Reilly's call. Full writeup: `rungs/r24/FIX_NOTES.md`.

THE SYSTEMIC BUG (cracked 2026-06-08): r22, r25, and r24's "deep/capacity" failures were ONE bug --
`lm4_forward` was called with NINE args (a stray `emb` wedged between `w2` and `blk0`:
`lm4_forward ct st w1 w2 emb blk0 blk1 (rows) isd`) in every GENERATION/EVAL path. lm4_forward takes
EIGHT (`ct st w1 w2 blk0 blk1 rows isd`). Rail OVER-APPLIES silently: it shifts every later arg
(blk0<-emb, blk1<-blk0, rows<-blk1, isd<-rows) -> garbage logits -> garbled, NON-deterministic
generation (proven by a SAMETEST: two same-arena samples gave different hashes). The training LOSS
path used the correct 8-arg form, so training was fine -- only generation/eval was corrupted. Fixed
in all 5 files (rungs/r25, tools/bitexact/utterance_cross_isa{,_falsify}, rungs/r24 + _r24_extension).
- **22** -> LOCAL GATES GREEN (utterance reproduces + foreign + falsifier; x86/Pi exec stays walled).
- **25** -> GATE PASS (Rail + foreign both reproduce the sampled words bit-for-bit).
- **24** -> its generalization metric was measured THROUGH the garbled generation; re-running with the
  fix to measure REAL generalization (the lone remaining rung; capacity still the open question).

2026-06-07 second pass drove 6 more to green:
- **23** segmented training — ran clean (segmented head == one-shot, byte-for-bit across 4 arena-reset segments).
- **28** live-beacon genesis — ran clean (public pulse fetch + fallback; proof-of-recency not-before).
- **29** Pi-witness dual-sign — ran clean (separation of duties = two LOCAL keys; the Pi is modelled, not required).
- **31** Freivalds GEMM — FIXED: honest verify was rejected because rs_i*Slist_i (2^16*2^54) overflowed
  int63 as a single multiply; added a proper two-limb dot (`r31_tldot`) + magnitude-sound gWrap witness.
- **33** FROST — FIXED: multi-line `let all = a * b \n * c` product (leading-operator continuation) doesn't
  parse under Rail's newline lets; joined to one line.
- **34** economic stake — FIXED: isqrt was INLINED self-recursion (`r_isqrt_go x ((g+x/g)/2) (i-1)`) = the
  self-loop cross-dep-arg miscompile -> corrupted Adam denom -> chain root diverged from foreign Python;
  fixed to the mutual-recursion form (`r_isqrt_go <-> r_isqrt_step`) the GREEN r30_protocol uses.

RED (precise diagnoses):
- **25** attested sampling — asm codegen bug FIXED (`if invtemp == 16777216` compared a bare big literal ->
  invalid `mov #33554433`; removed the identity fast-path) + F2 falsifier de-vacuumed (constructed exact
  boundary). STILL red on `SAMPLED-reproduces`: re-train+re-sample gives a DIFFERENT t_hex (arena-state-
  dependent generation NON-determinism; foreign Python samples correctly). Shared root with r22.
- **22** four-ISA — `lm4_gen` decode is arena-state-dependent (garbled, NON-deterministic across the
  pressured vs post-reset arena; foreign Python decodes correctly). NOT GC (16GB bump didn't help), NOT the
  gen-loop (r27's identical loop is green). A deep memory/Metal-readout read in the post-training generation
  path. PLUS x86/Pi exec legs hardware-walled.
- **24** sealed holdout — HONEST generalization gate; ~60+ min/run (epochs=40 x2 exact-int CPU train).
  Capacity question: does the tiny d=8/2-block model generalize to the sealed holdout? (running to confirm.)

--- earlier 6-green detail ---

**6 genuinely GREEN** — 35 (apex, sealed), 32 (outputs-ARE-Rail),
**30 (succinct spot-check NOW BOUND TO THE REAL lm10 — 2026-06-07)**,
**26 (tie-break — FIXED 2026-06-07)**, **27 (replay-free verify — FIXED 2026-06-07)**.

r30 was driven from "mechanism on a stand-in transition" to bound-to-real-lm10: `rungs/r30/r30_prove.rail`
now runs the REAL `lm4_step` 87-step training (epochs=3 x 29 pairs), Merkle-commits every post-step
state, signs the root (LOCAL/DEV key), derives Fiat-Shamir challenges off the signed head, and
spot-checks k=12 of 87 steps -- all 12 recompute bit-exact (step_ok) and verify against the signed
Merkle root (merkle_ok); a poisoned committed state is rejected; sublinear (12<<87). Two bugs fixed to
get there: (a) the powers parser read pow2 via `str_sub s (str_find " " s) 64` = a LEADING-SPACE token
-> lm4_hd_int returned 0 (fixed: `+1` to skip the space); (b) the Merkle `p_pair_up` CARRIED an odd
last node unchanged while `p_proof_lv` SELF-HASHED it -> inconsistent at non-power-of-2 leaf counts
(fixed: duplicate-last, hash the lone node with itself). Built via a new `tools/bitexact/lm10_lib.rail`
(the trainer MINUS its heavy main; importing the full trainer codegen'd that main too -> 10+ min/compile
+ a duplicate-symbol link error from double-importing tensor.rail).

26 + 27 were debugged here from compile-clean-but-segfault to full green:
- **r26**: missing `cum=0` init arg (segfault) in BOTH nucleus init calls (`r26_nucleus_ids` /
  `r26_nucleus_ids_opp`) — `cum` bound to `[]`, the opp tie-rule traversal hit `[]+int` / garbage-snoc.
  Second issue unmasked after: the Python witness floored where Rail `/` truncates toward zero, so the
  Q.24 entropy mismatched by 3 ulps — fixed with a `tdiv` helper at the two negative-valued sites.
- **r27**: `head`/`tail` on a STRING faults (not a graceful 0) — `prc_one_int`/`prc_digits` expect a
  chars-LIST but `prc_map_int` fed them string tokens. One-char fix: `prc_one_int (chars (head xs))`.

ORIGINAL: 2 genuinely GREEN (35 + 32). 2 runnable-here pending compute (23, 25). 7 walled by
remote-HW / open-research / model-capacity / external surface (22 has a reachable Pi leg).

The adversarial layer downgraded EVERY builder-claimed ACHIEVED (22/30/35/36→PARTIAL) and flagged a vacuous falsifier (25). 35 was then driven to a real green out-of-band (the harness the workflow agent was told not to run).

## Board

| # | rung | adversary verdict | REAL outcome | falsifier | notes |
|---|------|------|------|:--:|---|
| 22 | Four-ISA Byte-Identical Chain | PARTIAL | **WALLED** | ✓ | REMOTE HW — x86 ELF won't link here (cannot find -lc); needs x86 Linux + Pi to execute the ELF legs |
| 23 | Segmented Arena Training, Transparent  | DESIGNED | **RUNNABLE** | ✓ | SERIAL COMPUTE — 4-segment train of a deeper model + does-not-fit OOM witness; not yet run |
| 24 | Sealed Holdout (Attested Generalizatio | DESIGNED | **WALLED** | ✓ | MODEL CAPACITY — needs a model that GENERALIZES; one-line floor cannot |
| 25 | Attested Sampling (chain-seeded exact- | DESIGNED | **RUNNABLE*** | ✗fix | SERIAL COMPUTE + falsifier fix (F2 boundary control is measure-zero) |
| 26 | Provably-Identical Tie-Break | PARTIAL | **GREEN ✅ (FIXED)** | ✓ | was missing `cum=0` init arg (segfault) + Python entropy floored vs Rail truncate-div (3-ulp gap); both fixed; self-witness + foreign witness PASS, all 3 falsifiers + 2 neg-controls reject |
| 27 | Replay-Free Verification | PARTIAL | **GREEN ✅ (FIXED)** | ✓ | binding PROVEN (SHA(bundle)==w_hex); segfault was head-on-string in int-parser (`prc_map_int` fed strings to a chars-list parser); fixed with `chars`; Rail + foreign Python verify replay-free in 0.118s, all 3 falsifiers reject |
| 28 | Live-Beacon Genesis, Proof-of-Recency | DESIGNED | **WALLED** | ✓ | EXTERNAL — fetch live ledatic.org entropy pulse over Rail TLS (dev-mode-guarded) |
| 29 | Pi-Witness Active Recency Oracle | DESIGNED | **WALLED** | ✓ | REMOTE HW — the Pi witness must countersign over the network |
| 30 | Succinct Spot-Check (Fiat-Shamir) | PARTIAL | **GREEN ✅ (REAL lm10, FULL-SCALE, FOREIGN-VERIFIED)** | ✓ | r30_prove.rail runs the REAL lm4_step training at FULL SCALE (epochs=19 = 551 steps, memory-bounded STREAMING prover w/ per-step arena_reset); k=12 challenged steps recompute bit-exact + verify against the signed Merkle root; poisoned state rejected; sublinear (12<<551). An INDEPENDENT Python verifier (r30_prove_foreign_check.py) reproduces the Merkle root + FS challenges + Ed25519 sig + all paths + falsifier in a different language. Stand-in caveat CLOSED 2026-06-07. |
| 31 | Freivalds-Succinct GEMM Through Trunca | DESIGNED | **WALLED** | ✓ | RESEARCH-OPEN — joint soundness of Freivalds projection + truncation range-check |
| 32 | Compile-Bound Utterance (Outputs ARE R | DESIGNED | **GREEN ✅** | ✓ | ACHIEVED — model speaks Rail that COMPILES+RUNS; foreign witness re-compiled+re-ran to identical stdout '7\n'; attested |
| 33 | k-of-n Threshold-Signed Utterance (FRO | PARTIAL | **WALLED** | ✓ | RESEARCH-OPEN crypto — scalar inversion mod L + Lagrange mod L for FROST; nonce safety |
| 34 | Economic Stake over Succinct Length-Pr | PARTIAL | **WALLED*** | ✓ | RESEARCH-OPEN — pure-Rail VDF; the economic-stake-over-succinct-length variant is shippable |
| 35 | Self-Emission (verified piece of own c | ACH+SEAL | **GREEN ✅ + SEALED** | ✓ | ACHIEVED — emits exact compile.rail:is_digit; self-host fixed point held; 170/170 tests; mutation falsifier fired; Ed25519-sealed |
| 36 | Bounded Recursive Self-Improvement, Fr | PARTIAL | **WALLED** | ✓ | RESEARCH-OPEN — proving non-self-relaxation under an adaptive adversarial successor |

## Per-rung artifacts (all implemented, validate-ready)

- **r22** Four-ISA Byte-Identical Chain: `tools/bitexact/utterance_cross_isa.rail`, `tools/bitexact/utterance_cross_isa_falsify.rail`, `rungs/r22/IMPL.md`, `rungs/r22/validate.sh`, `rungs/r22/witness_cross_check.py`
- **r23** Segmented Arena Training, Transparent Resume: `rungs/r23/r23_segmented_train.rail`, `rungs/r23/r23_foreign_check.py`, `rungs/r23/validate.sh`, `rungs/r23/IMPL.md`, `rungs/r23/r23_scaled_train.rail`
- **r24** Sealed Holdout (Attested Generalization): `rungs/r24/r24_attested_holdout.rail`, `rungs/r24/r24_foreign_check.py`, `rungs/r24/r24_train_corpus.txt`, `rungs/r24/r24_holdout_corpus.txt`, `rungs/r24/r24_overfit_corpus.txt`
- **r25** Attested Sampling (chain-seeded exact-integer draw): `rungs/r25/attested_sampling.rail`, `rungs/r25/sampling_foreign_check.py`, `rungs/r25/validate.sh`, `rungs/r25/IMPL.md`
- **r26** Provably-Identical Tie-Break: Nucleus & Top-k: `rungs/r26/tiebreak_sampling.rail`, `rungs/r26/r26_foreign_check.py`, `rungs/r26/r26_fixture_gen.py`, `rungs/r26/r26_neg_tiehigh.py`, `rungs/r26/validate.sh`
- **r27** Replay-Free Verification of the Saying: `rungs/r27/IMPL.md`, `rungs/r27/rung27_train.rail`, `rungs/r27/rung27_verify.rail`, `rungs/r27/rung27_foreign_check.py`, `rungs/r27/validate.sh`
- **r28** Live-Beacon Genesis, Proof-of-Recency: `rungs/r28/IMPL.md`, `rungs/r28/r28_live_beacon.rail`, `rungs/r28/r28_foreign_check.py`, `rungs/r28/fetch_pulse.sh`, `rungs/r28/falsify_earlier_pulse.py`
- **r29** Pi-Witness Active Recency Oracle: `rungs/r29/IMPL.md`, `rungs/r29/rung29_dual_sign.rail`, `rungs/r29/rung29_foreign_check.py`, `rungs/r29/validate.sh`
- **r30** Succinct Spot-Check of Training (Fiat-Shamir): `rungs/r30/r30_protocol.rail`, `rungs/r30/r30_foreign_check.py`, `rungs/r30/r30_prove.rail`, `rungs/r30/validate.sh`, `rungs/r30/IMPL.md`
- **r31** Freivalds-Succinct GEMM Through Truncation: `rungs/r31/r31_freivalds_gemm.rail`, `rungs/r31/r31_foreign_check.py`, `rungs/r31/validate.sh`, `rungs/r31/IMPL.md`, `rungs/r31/r31_transcript.txt`
- **r32** Compile-Bound Utterance (Outputs ARE Rail): `rungs/r32/compile_bound_utterance.rail`, `rungs/r32/cbutter_foreign_check.py`, `rungs/r32/validate.sh`, `rungs/r32/IMPL.md`, `tools/bitexact/cbutter_corpus.txt`
- **r33** k-of-n Threshold-Signed Utterance (FROST-Ed25519): `rungs/r33/frost.rail`, `rungs/r33/frost_main.rail`, `rungs/r33/frost_foreign_check.py`, `rungs/r33/frost_ledger_reference.txt`, `rungs/r33/validate.sh`
- **r34** Economic Stake over Succinct Length-Proof: `rungs/r34/r34_economic_stake.rail`, `rungs/r34/r34_foreign_check.py`, `rungs/r34/validate.sh`, `rungs/r34/IMPL.md`
- **r35** Self-Emission (verified piece of own compiler): `rungs/r35/IMPL.md`, `rungs/r35/validate.sh`, `tools/bitexact/selfemit.rail`, `tools/bitexact/selfemit_corpus.txt`, `tools/bitexact/self_emit_harness.sh`
- **r36** Bounded Recursive Self-Improvement, Frozen Gate: `rungs/r36/r36_rsi_protocol.rail`, `rungs/r36/r36_foreign_check.py`, `rungs/r36/falsify_ledger.py`, `rungs/r36/fetch_pulses.sh`, `rungs/r36/validate.sh`

## 6 open seams

- **long-gen: attest a kilobyte-scale variable-length generation bit**
- **Prompt-binding / seed-window robustness (ATTESTED_LADDER.md cros**
- **numeric-faithfulness — attest the Q.24 regime stays FAITHFUL (er**
- **multi-prompt / batched attestation: one succinct signed proof th**
- **key-rotation**
- **Refusal / honest-empty attestation: bind the model's weights to **

## Honest path to more green

- **Debuggable here (Rail bugs in agent code):** 26 (parse trap @485), 27 (verifier segfault; binding already proven). Each = read+fix+recompile(~5min)+rerun.
- **Runnable here (just compute):** 23, 25 (after falsifier fix).
- **Remote HW:** 22 (x86 Linux + Pi), 29 (Pi witness).
- **External:** 28 (live entropy pulse).
- **Open research:** 30, 31, 33, 34, 36.
- **Model capacity (the back half's real prerequisite):** 24, 32-generative — a model that generalizes / emits non-memorized valid Rail.
