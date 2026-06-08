# Rung 24 — Fix Notes (2026-06-08)

The lone red rung on the 15-rung attested-LM ladder (22–36). Goal was 15/15. This documents the
fix to **why r24 wouldn't complete**, and the honest capacity result it exposed.

## Symptom
- Studio GPU run: **4h20m, no completion**. An earlier Mini attempt **froze the machine**.

## Layered diagnosis (each layer was real)
1. **GPU-per-matvec marshalling.** `lm4_grads` routed its two readout GEMMs through `gpu_matvec`,
   which for a d=8 model allocates a 64×64 float array, fills it element-by-element, dispatches a
   Metal kernel, and reconstructs element-by-element — per training step, ×2, ×(40+40) epochs. The
   dispatch+marshalling dwarfs the actual compute (~60× per-epoch).
2. **Unbounded heap / no per-epoch reset.** `lm4_chain` accumulated ~2 GB of training garbage per
   epoch with no `arena_reset`, filling any arena (~epoch 3 on Mini) → GC thrash / stall.
3. **Segment-survivor leak (in my first segmenting graft).** r23's `seg_loop` passes the
   deserialized weights as a heap arg across the recursion, so each segment's deser garbage (~14
   MB) survives the *next* segment's `arena_reset`. Invisible at r23's 4 segments; at 40 it's ~560
   MB (tolerable), at 200 it's ~2.8 GB → stall again.

## The fix (3 parts, all bit-exact)
1. **CPU matvec swap** — `gpu_matvec` → `lm4_matvec` in `lm4_grads`. The in-file witness
   `gpu_d2_eq` asserts GPU==CPU bit-for-bit, the gate has no GPU term, and the foreign Python
   verifier uses CPU integer math — so CPU is the canonical arithmetic. ~60× faster per epoch.
2. **Segmented training** — finished wiring the half-built `lm4_chain_d0_pw`/`bnd_wp_ser/deser`
   scaffolding into `seg_loop` (signed) + `seg_loop_d0` (D0), the rung-23 proven pattern
   (segmented head/body == one-shot, byte-for-byte). 1 epoch/segment.
3. **Disk-only state carrier (leak fix)** — restructured `seg_loop`/`seg_loop_d0` so ALL resume
   state lives on disk; each iteration reads it *after* the `arena_mark`, trains, writes it back,
   then `arena_reset` frees everything (deser garbage + wp + train garbage). Nothing survives the
   reset → **constant memory for any epoch count**.

## Validation
- **Bit-exact**: the fixed 40-epoch chain is **byte-for-byte IDENTICAL** to the pre-fix chain
  (`diff` clean), and `training reproduces (D0) = 1`. The restructure changed zero Q.24 bits.
- **Speed/memory**: 40-epoch run **completes in 2m25s** (was 4h+/never), **peak RSS 2.27 GB, flat**
  (~0.3 MB/epoch vs the old 14 MB/epoch leak).
- All sigs verify, all 4 falsifiers fire, checkpoint-0 abort correct.

Canonical config unchanged (d=8, hidden=64, 2 blocks, 2 heads, 40 epochs). Backups:
`out/r24_chain.40ep.txt`, `out/r24_eval.40ep.txt`. Pre-fix source: `r24_attested_holdout.rail.gpuorig`.

## The honest capacity result (the gate the rung was built to test)
- **40 epochs: `HONEST model echo acc = 0/4`** (needs ≥ 2/4 = T). Full-sequence acc 19/54, loss
  descended 221.2B → 17.4B (12×). The d=8 model **learns the corpus but does not form the copy/
  induction rule** to generalize to the held-out `31`/`75` pairs. This is exactly the open capacity
  question IMPL.md names ("weeks — the capacity search is open").
- **200 epochs (same model, 5× training): ALSO `0/4`.** Completed ~9 min at constant 2.31 GB peak
  (leak fix holds across 400 epoch-passes), `D0=1`. Critically: full-seq acc **identical** (19/54),
  loss essentially flat (17.45B → 17.03B). The model **converged by epoch 40** — 5× more training
  changed nothing. This **rules out undertraining**: it is a genuine **capacity wall**, not a
  training-time issue. The d=8/2-block model cannot form the copy/induction circuit at this scale.

## 15/15 status
- **Infrastructure: FIXED.** r24 now completes fast, at constant memory, bit-exact, fully attested.
- **Green: blocked on capacity, not infra.** The gate is an *honest* generalization gate; it fails
  because the minimal model doesn't generalize. Honest options for a true 15/15 (Reilly's call —
  some change the rung's "smallest honest instance" claim):
  - more training (in-bounds; testing now) — may need grokking-scale epochs;
  - larger model (d, heads, blocks) — changes the claim;
  - more training data / corpus diversity — changes the claim.
- Do NOT move T, train on holdout, or fake the metric (forbidden by the rung design + the
  no-synthetic-evidence rule).

_State: branch `reward/first-utterance`, UNPUSHED. Canonical r24 fix is local-only pending review._
