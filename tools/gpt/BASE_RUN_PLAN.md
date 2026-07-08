# Path A: tokenizer-fixed compute-optimal base run (plan, 2026-07-08)

The "genuinely larger model." Fixes both real ceilings we identified: the proven
tokenizer artifact (rare atomic number-tokens) AND the memorization limit (scale).

## What's already done / de-risked tonight

- **Digit-consistent tokenizer — BUILT + PROVEN** (`~/.ledatic/railml-trial/arith/digittok.merges`,
  `build_digit_tokenizer.py`). Drops 807 digit-merges (16384 -> 15577 vocab); EVERY number now
  tokenizes to individual digit tokens (512->[51,23,26], 1024/8263/6666 all pure digits),
  round-trip exact, non-digit text unchanged. **Structurally eliminates the rare-atomic class
  probe 3 proved fatal at 138M** — every number is now common-digit-tokens (strong induction).
- **Corpus — READY at scale, no new work.** 55,795 docs already clean->dedup->per_doc'd
  (`~/.ledatic/attested-corpus/records/per_doc.jsonl`), n_chars = 20.6B => **~4.9B tokens**.
  (The signed v2 was a 25,541-doc / 1.54B-tok SUBSET; the full processed set is 3.2x bigger.)
- **Trainer — ~5x faster** (resident optimizer state, `arith_finetune_res.rail`, byte-identical
  training). Makes a self-hosted Rail-native run tractable.

## Honest sizing (Chinchilla, corpus-grounded)

~4.9B tokens => compute-optimal **~240M params** (20 tok/param). 300M is reasonable (slightly
data-rich is fine, better than data-starved). NOT 185M — that was anchored on the old 1.54B
subset. Candidate config: d=1024, 24 layers, 16 heads, d_ff=4096, ctx=1024, vocab=15577
(~290M) OR d=1024, 20 layers (~240M). Right-size to VRAM: s337m OOM'd at ctx1024xbs32x24L on
64GB; use ctx512 or gradient-checkpoint / smaller batch. Prove the config fits BEFORE the run.

## Remaining steps (multi-day, Studio)

1. **Retokenize the 55,795-doc corpus with the DIGIT tokenizer** -> train.bin/val.bin
   (`tokenize_parallel.py` w/ --vocab-prefix=digittok; 16 procs; multi-hour). THE next concrete job.
2. **Sign the corpus root** (records->merkle->sign, Pi witness fleet0:9102) -> attested v3.
   Strand-F provenance stays `source-cleared` (never pitch "fully public-domain model").
3. **Config + prove-small**: MLX pilot at tiny scale to the first checkpoint (retro rule #1:
   write the strict eval BEFORE the run; ABORT if the user-facing metric is 0 and stays 0).
4. **Success criteria (BEFORE training, frozen+hashed):** (a) copy@arbitrary-number — the thing
   we're fixing: sample N numbers, does the model copy them? target >90% (was ~impossible for
   rare-atomic at 138M); (b) compile@1 on the frozen bench (>=30% bar); (c) held-out val bpc <
   unigram floor (real context, not memorization).
5. **Train on Studio** (heavy job; never load-test on Mini). Resident-optimizer Rail trainer OR
   MLX-prove-then-Rail-ship per the attested-base discipline. Mid-run gates, not end-only.

## Box discipline
Built/proven on Mini; the heavy run goes to Studio (64GB). Pause its MLX servers first
(reversible launchctl bootout). Monitor detached w/ Slack alerts (see attested-base pattern).
