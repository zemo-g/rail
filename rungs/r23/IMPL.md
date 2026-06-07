# Rung 23 — Segmented Arena Training with Transparent Resume

**Status: VALIDATE-READY (DESIGNED → built; new machinery unit-proven, full run gated to the orchestrator under compute discipline).**

## The claim (from ATTESTED_LADDER.md)

> **Proves** the `bnd_wp_ser`/`bnd_wp_deser` round-trip (θ + Adam m,v + pow1/pow2 bias-correction) is invisible to the chain: an on-disk segment boundary changes not one Q.24 bit.

## What this rung builds on (proven, reused verbatim)

The entire pipeline of `tools/bitexact/attested_utterance.rail` (the first attested utterance) is the floor:
- the lm10 transformer (2 stacked multi-head RoPE pre-norm blocks, FFN, exact-integer Q.24 Adam, `gpu_matvec` readout) — grafted **verbatim**;
- the SHA-256 / Ed25519 per-checkpoint sign+verify (`lm4_ckpt`) and the 17-matrix `lm4_canon17` commitment — **verbatim**;
- **`bnd_wp_ser` / `bnd_wp_deser`** — the full 17-config `[θ,m,v]` serialize/parse, already proven bit-exact in the floor — **verbatim**;
- `lm4_chain` (the signed training chain) is the **one-shot oracle** the segmented run must match.

Because every integer is identical, the **same foreign Python verifier machinery** (`lm10_foreign_check.rederive`) re-derives the run and reproduces every SHA — no foreign re-implementation of the transformer was needed.

## The only new machinery (a thin delta, no architecture change)

1. **`lm4_chain_pw`** — `lm4_chain` extended to *also* return the final `(pow1, pow2)` bias-correction powers, so a segment can resume them. It is the **signed sibling** of the already-present `lm4_chain_d0_pw` (which does this for the D0 path). The per-epoch line / sign / link logic is **unchanged**, so its head and ledger body are byte-identical to the proven `lm4_chain`. Result shape: `[all_ok, body, prev_hex, wp, pow1, pow2]`.

2. **`seg_loop` (the segment driver)** — runs the chain in `nsegs` segments. Each segment runs `seg_epochs` epochs starting from `(wp, pow1, pow2, prev_hex, epoch_index)`. **Between segments**, exactly mirroring the floor's mid-`main` reset pattern:
   - `bnd_wp_ser wp` → `write_file` to disk (`rungs/r23/out/seg_wp.txt`);
   - persist the small resume strings to disk too (`prev_hex`, ledger body, `pow1`, `pow2`, `all_ok`);
   - **`arena_reset`** — frees the whole segment's transient training garbage;
   - `read_file` the serialized state back → **`bnd_wp_deser`** → resume.

   The epoch index threads continuously (segment 1 runs epochs `[seg_epochs .. 2·seg_epochs)`), so every `lm4_ckpt` link uses the same `epoch_i` it would one-shot → byte-identical chain.

3. **`bnd_wp_ser_dropv` (the falsifier serializer)** — identical to `bnd_wp_ser` except it writes `0` for every cell's Adam **v-moment** (the 3rd field). Used at one segment boundary to model the dropped-moment forge.

4. **`str_to_int_signed`** — parses the persisted decimal `pow1`/`pow2`/`all_ok` strings back to ints (avoids the phantom `str_to_int` builtin; built from `char_to_int`).

## The gate (this run prints `PASS:` iff all hold)

| gate | meaning |
|---|---|
| `okSegN` | `nsegs ≥ 4` were actually used (the segmentation claim, not one fat segment). Oracle config: `ceil(19/5) = 4`. |
| `okHead` | **segmented chain head == one-shot chain head** — the **transparency oracle**. |
| `okBody` | segmented ledger body == one-shot ledger body, **byte-for-byte** (all 19 signed checkpoint lines). |
| `okSigs` | every per-checkpoint Ed25519 sig verified, in **both** the one-shot and segmented runs. |
| `okRT` | the `bnd_wp_ser → bnd_wp_deser` round-trip reproduced `wp`'s `canon17` commitment exactly. |
| `okProg` | loss descended (sanity, mirrors the floor's `okProg`). |
| `okFalsify` | the v-moment-dropping forge **diverges** the resumed head (the falsifier *fires*). |

`all = okRT * okProg * okSegN * okHead * okBody * okSigs * okFalsify`.

## The falsification test (must fail the gate if reintroduced)

`seg_loop` is called a second time with `forge_seg = 1`, which makes segment 1's serialize **drop the Adam v-moment** (`bnd_wp_ser_dropv`). On resume, `v = 0` → `vhat = 0` → `denom = sqrt(0)+eps = eps` → the Adam `step = lr·mhat/eps` is ~1000× too large → the post-boundary trajectory diverges → the resumed head ≠ the one-shot head. **`okFalsify` asserts `forged_head ≠ oneshot_head`.** A trainer that silently re-inits moments at the boundary is thereby caught. (This is the rung's stipulated falsifier: "Drop the Adam v-moment (or pow1) from one segment's serialize: the resumed chain head must diverge from the one-shot head.")

It is a *guaranteed-divergent* forge (v→0 changes the denominator regime), not a marginal perturbation — so the demonstration is unambiguous, mirroring the floor's earned "output-divergence is a weak tamper test" lesson by choosing a forge that always moves the head.

## Soundness argument

- **Why segment boundaries are invisible.** The signed chain is a pure function of `(wp, pow1, pow2, prev_hex, epoch_index)` at the start of each epoch. `bnd_wp_ser`/`bnd_wp_deser` is a proven bijection on the exact-integer `[θ,m,v]` state (unit-verified below); the powers/link/index are persisted as exact decimals that round-trip. Therefore the post-`arena_reset` resumed state equals the pre-reset state **bit-for-bit**, and the continuation produces the identical checkpoints. `okHead`/`okBody` are an *equality against the one-shot oracle computed in the same process*, so there is no room for a coincidental match.
- **Why the foreign witness clinches it.** `r23_foreign_check.py` re-derives the *entire* run **continuously**, knowing nothing about segmentation, and asserts every segmented checkpoint (w_hex, loss, prev-chaining, link, **and the Ed25519 sig verifies**) equals the continuous re-derivation. If any boundary had dropped/re-inited a moment, the post-boundary checkpoints would diverge from a continuous re-derivation → caught. This is the cross-language closure: a party ignorant of the boundaries certifies they changed not one bit.
- **Why the falsifier is sound.** Dropping `v` is a *real* state corruption that the resume must propagate; the gate fails iff the corrupted resume happens to reproduce the honest head, which the denominator-regime change rules out.

## Scaling (the rung requires one config that fits one-shot AND one that does not)

- **Transparency-oracle config (this file, `r23_segmented_train.rail`):** `d=8 / hidden=64 / ctx=8 / epochs=19`, **4 segments**. This **fits** one-shot, so `segmented == one-shot` is checkable — that is the whole point of the equality gate.
- **Scaling config (`r23_scaled_train.rail` + `r23_scaled_dims.txt`):** scales the **one bit-exact-safe axis the proven architecture admits — `hidden` (→256, the gate's "hidden≥256" alternative)** — plus `epochs` (→120) and a larger 8-line corpus, so a one-shot run's transient garbage + canon body exceed a fixed RSS cap while the segmented run (`arena_reset` every 20 epochs → **6 segments**) stays bounded. `validate.sh` (with `R23_SCALED=1`) generates it from the oracle source via a 4-line `sed` dims patch (one source of truth for the ~600 lines of proven machinery) and measures per-segment peak RSS with `tools/trace/rail_trace.rail`.

  **Honest scope note (surfaced, not hidden — per the rung's own ethos):** the gate's *dimensional* deepening (`d≥32 / ctx≥32`) is **blocked by a missing prerequisite**: the proven RoPE is hardcoded to `d=8 / ctx=8` (`rope_row` reads exactly 8 slots; the cos/sin tables are exactly 32 entries = 8 positions × 4 pairs). A *generalized variable-d RoPE* does not exist anywhere in the lm* lineage; building one bit-exact is a separate piece of work (and risky to land byte-identical under compute discipline). `hidden` is the honest, bit-exact-safe scaling axis (the readout MLP is dimension-generic via `gpu_matvec` / `lm4_matvec_t`). This is the genuine open edge of this rung.

## What was actually verified (light, compute-disciplined)

- `str_to_int_signed` round-trips `"16777216"`, `"-42"`, `"0"` — **compiled + ran, exit 0** (isolated probe).
- `bnd_wp_ser`/`bnd_wp_deser` round-trip preserves `θ=100, v=55`; `bnd_wp_ser_dropv` yields `θ=100, v=0` — **compiled + ran, exit 0** (isolated probe with a synthetic 2-matrix `wp`). This proves the new falsifier serializer AND the deser on the exact cell format.
- All Python imports in `r23_foreign_check.py` resolve (`from lm10_foreign_check import …` + the drop-v re-derivation helpers) — **import smoke passed**.
- The full Rail source: parens balanced (1154/1154), every called function defined exactly once, file complete, no `&&`/`||` (no short-circuit trap), `seg_loop` at 26 args (under the ≥30 cliff), arena-reset-survives-int (`ds0`/`dsK`/`okProg` are tagged ints, mirroring the floor's proven pattern).

**NOT run (compute discipline):** the full multi-GB segmented training build + run, and the scaled-config RSS trace. Those are the orchestrator's serial job — `validate.sh` is the exact command.

## The EXACT validate command

```bash
bash rungs/r23/validate.sh
```

This (serially): compiles `r23_segmented_train.rail` → `rungs/r23/out/r23_bin`; runs it with `RAIL_ARENA_MB=8192` (writes the segmented + one-shot ledgers); requires the run to print `PASS:`; then runs `python3 rungs/r23/r23_foreign_check.py rungs/r23/out/r23_segmented_chain.txt` and requires `R23-CHECK PASS`. Exit 0 iff the green gate holds. Extended scaling check: `R23_SCALED=1 bash rungs/r23/validate.sh`.

## Files

| file | role |
|---|---|
| `rungs/r23/r23_segmented_train.rail` | the trainer (oracle config) — segmented signed training + transparent resume + falsifier; prints `PASS:`/`FAIL`. |
| `rungs/r23/r23_foreign_check.py` | foreign cross-language re-verifier — continuous re-derivation reproduces the segmented ledger; falsifier check. |
| `rungs/r23/r23_scaled_train.rail` | scaling-config descriptor (the does-not-fit half; built from the oracle via the dims patch). |
| `rungs/r23/r23_scaled_dims.txt` | the exact `sed` dims patch + rationale (one source of truth). |
| `rungs/r23/lm10_corpus_big.txt` | deterministic 8-line corpus for the scaling config. |
| `rungs/r23/validate.sh` | the green-gate command the orchestrator runs serially. |
| `rungs/r23/IMPL.md` | this document. |
```
