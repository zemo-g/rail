# Open Seam: Long / Variable-Length Generation (attest a kilobyte bit-for-bit)

*Cross-cutting work on the attested-LM ladder. Not numbered — it cuts across every rung, all of
which speak a fixed `gcap=48` utterance and commit the whole thing as one in-memory string.*

## The claim

A Rail-native transformer generates a **kilobyte-scale** completion (target: ≥4096 generated
tokens, ~4–8KB decoded text — well past the documented ~64KB `bytes_to_str` cap and at a length
where the current `utt_ids_canon` + `cat` path is quadratic), binds it bit-for-bit into the
Ed25519 hash-chain, and a foreign witness reproduces the `t_hex` **and** the decoded-text hash
exactly — with trainer peak RSS bounded **independent of generation length**.

## The two walls (verified against the substrate)

Both walls live entirely in the *attestation/serialization* path, NOT the decode math. The decode
itself (`lm4_gen`, `attested_utterance.rail:832`) is already a fixed-window sliding loop whose
per-step cost is constant; only the bookkeeping around it blows up.

**Wall 1 — O(N²) commitment string.** `utt_ids_canon` (line 862) is
`cat [show (head ids), ",", utt_ids_canon (tail ids)]` — right-nested `cat`, re-measuring the
growing suffix at every level (the *exact* pathology the code's own comment at line 634 flags for
`lm4_canon_mat`, fixed there by build-list-then-single-`cat`). Then `t_hex = sha256_hex (...)`
(line 958) hands the whole comma-joined string to `sha256` → `string_to_bytes` materializes the
full byte array at once. At 4096 tokens (~5 chars each w/ comma) that's a ~20KB string built
quadratically, and `bytes_to_str`-class concat tops out ~64KB. The decoded `utter_text`
(`lm4_finish (cat [prompt, lm4_decode gen_ids vocab])`, line 954) hits the same wall and also the
`str_find " in 0"` truncation only works for the one toy program.

**Wall 2 — per-completion arena thrash.** Already diagnosed in-tree at `lm4_emit_all`
(line 851, comment 846–850): a single generation's transient garbage climbs the ~3.5GB training
base toward the 8GB cap, the conservative GC starts scanning the whole arena per-alloc, ~1
min/completion, watchdog-killed at 29/30. The existing fix brackets *each completion* in
`arena_mark`/`arena_reset`. But the UTTERANCE path (lines 949–965) holds `gen_ids` (the full id
list), the canon string, AND the weights live simultaneously — at 4096 tokens the id list alone is
a 4096-cons list that must survive to the commitment, so the per-completion reset trick doesn't
apply: the live set grows with length.

## The design on THIS substrate

The keystone is already in stdlib and unused by the ladder: **streaming SHA-256**
(`stdlib/sha256.rail:242–326`) — `sha256_init` / `sha256_update_arr st arr off n` /
`sha256_update_str st s` / `sha256_finalize_hex st`. It absorbs 64-byte blocks into a fixed 5-slot
state array (`sha256.rail:253`), so a kilobyte can be hashed **chunk-by-chunk, holding only the
chunk** — never the full string. This dissolves Wall 1 directly and enables Wall 2's reset.

Concretely, replace the "generate-all-then-canon-then-hash" pipeline with **generate-and-absorb in
fixed-size segments**, mirroring the proven `bnd_wp_ser`/`bnd_wp_deser` streaming idiom
(lines 763–814) that already crosses an arena boundary bit-identically:

1. **`utt_gen_attest_seg`** — a mutual-recursion (`_a`/`_b`, to dodge the self-loop cross-dep-arg
   miscompile that `lm4_gen`'s tail-args would otherwise risk on the new accumulators) loop that:
   - runs `SEG` (e.g. 256) decode steps via the existing `lm4_argmax (lm4_forward …)`, building
     only a `SEG`-length id sublist + the sliding ctx;
   - canonicalizes *that segment only* with the O(N) build-list-then-single-`cat` form
     (`utt_seg_canon_p`/`cat`, copying the line-637 pattern), feeds it to **two running streaming
     states** via `sha256_update_str`: `st_ids` (over the comma-canon of ids → reproduces `t_hex`)
     and `st_text` (over the decoded `vocab` chars → a new `text_hex` commitment);
   - **`arena_reset`s to a mark taken before the segment**, freeing that segment's id-list + canon
     garbage; the two `sha256` state arrays + weights were alloc'd before the mark so they survive
     (identical discipline to `lm4_emit_all:853–856`, but now the *commitment* survives the reset
     because it's an incremental hash, not a string);
   - **persists the generated text to disk by appending** (segment-at-a-time `write_file` to
     `out/utterance_long.txt`), so the full saying is recoverable without ever being in memory.
   - threads `pid_carry` (last `cwin` ids) across segment boundaries so the sliding window is
     continuous — a segment boundary must be **invisible** to the decode (the transparency oracle,
     §gate).
2. **Commitments.** `t_hex = sha256_finalize_hex st_ids` and `text_hex = sha256_finalize_hex
   st_text` after the last segment. The UTTER link gains `text_hex` and the realized length `n_gen`:
   `ulink = cat [head_link,"|UTTERLONG|",prompt_hex,"|",show cwin,"|",show n_gen,"|",w_hex_final,"|",t_hex,"|",text_hex]`.
   `t_hex` is *defined identically* to the short path (comma-canon of the full id stream), so a
   short run and a segmented run of the same generation produce the **same** `t_hex` — that's the
   load-bearing transparency claim.
3. **Foreign verifier** (`utterance_long_foreign_check.py`, extending the line-128 `generate`):
   re-derives weights via `rederive`, regenerates `n_gen` tokens itself, and — to prove it ALSO
   isn't holding the kilobyte — uses `hashlib.sha256()` in **the same segmented `.update()` mode**,
   reproducing both `t_hex` and `text_hex`, then `ed25519_verify` on the rebuilt link. Foreign
   segmentation can be any chunking (Python `.update()` is associative over byte boundaries) — that
   independence is itself evidence the segment boundary is non-semantic.

**Why the boundary is sound:** SHA-256's Merkle–Damgård structure makes `update(a);update(b)` ≡
`update(a‖b)` for *any* split — so the trainer's `SEG=256` chunking and the verifier's arbitrary
chunking hash to the identical digest by construction, with no per-boundary fixup. The only thing
that must match is the **byte stream** (comma-canon of ids; raw decoded chars), which the existing
short path already pins.

**Decode-faithfulness guard (cheap, kept):** keep the small `gcap`-style argmax decode verbatim —
this seam changes *only* serialization/memory, not the model, so `okUtterRepro` (re-train +
re-decode → same `t_hex`) carries over unchanged and certifies the math is untouched.

**Artifacts to write:** `tools/bitexact/utterance_long.rail` (trainer; reuses lm10 transformer +
streaming-sha helpers verbatim), `tools/bitexact/utterance_long_foreign_check.py`,
`out/utterance_long.txt` (the appended kilobyte saying), `out/utterance_long_chain.txt` (ledger
with the `UTTERLONG` record).

## Substrate traps already mapped (so the build doesn't rediscover them)

- **No short-circuit** → the per-segment `if n <= 0` termination must be nested `if/then/else`,
  not `&&`.
- **`\r`/multi-char**: ids canon uses only `show` + `","`; decoded text is raw vocab chars — both
  ASCII-safe for `.asciz`-free runtime strings (these never enter codegen, only `write_file`).
- **Self-loop cross-dep miscompile** → the segment loop carries `(st_ids, st_text, pid_carry,
  g_remaining, mark)` which cross-depend; use the mutual-recursion `_a/_b` pair idiom (as
  `bnd_*`/`ln_*`/`rn_*` do throughout `attested_utterance.rail`).
- **`arena_reset` frees the sha state if marked too early** → take the segment mark AFTER
  `sha256_init` (states must outlive every reset), exactly mirroring "weights arrive as args
  alloc'd before this inner mark" (line 850).
- **`RAIL_ARENA_MB=8192` still required** for the training phase; the seam's win is that the
  *generation+commit* phase no longer climbs toward the cap regardless of length.

## Success gate (must pass to climb the seam)

Pre-registered before the run (per the define-success-before-training rule):

1. **Scale + bound:** generate `n_gen ≥ 4096` tokens (≥ a length that overflows the short path's
   single-string canon — demonstrate the short path *fails/OOMs* at that length as the control, so
   the seam isn't vacuous at toy size). Trainer peak RSS during the generate+commit phase, measured
   by `rail_trace`, is **flat across `n_gen ∈ {1024, 4096, 8192}`** (within GC noise) — proving
   memory is length-independent, not just "big enough."
2. **Transparency oracle:** for an `n_gen` that *also* fits the short single-string path (e.g.
   1024, if it fits), the segmented `t_hex` == the short-path `t_hex` **bit-for-bit** — the segment
   boundary changed not one bit. (Vacuous-check guard: this requires one config small enough that
   both paths run.)
3. **Dual commitment + foreign repro:** the `UTTERLONG` record commits `t_hex`, `text_hex`,
   `n_gen`; `utterance_long_foreign_check.py` (different language, segmented `hashlib.update`)
   reproduces **both** hashes and `ed25519_verify` passes under the ledger pubkey.
4. **Round-trip text:** `sha256` of the *appended-to-disk* `out/utterance_long.txt` (decoded with
   the prompt prefix stripped per the committed `prompt_hex`) == committed `text_hex` — proving the
   on-disk saying is exactly what was hashed in-stream.

## Falsifier (a forged input the gate MUST reject)

Each is a real attack the gate fails on if the design is wrong:

1. **Wrong-split forgery:** re-run the verifier with a *deliberately corrupted* segment byte stream
   (drop one comma between segments, or off-by-one the `pid_carry` window so segment k+1 starts one
   token early) → the streamed `t_hex` must diverge from the committed one → reject. (Confirms the
   boundary carries real state, not that we got lucky with a length divisible by `SEG`.)
2. **Truncation forgery:** ship a ledger claiming `n_gen=4096` but with `out/utterance_long.txt`
   holding only the first 2048 tokens (cheap "I generated more than I did") → re-hashing the file
   yields a `text_hex` ≠ committed → reject; and the verifier's own 4096-token regen ≠ truncated
   file.
3. **Tamper one nibble of `text_hex` or `t_hex`** in the UTTER link → `ed25519_verify` fails (the
   commitment is the guarantee, per the weak-tamper insight, ATTESTED_UTTERANCE §insight).
4. **Forged-weights control (kept from short path):** zero the readout (`utt_zero_mat`), regenerate
   → different kilobyte → both `t_hex` and `text_hex` diverge → `okForgeWeights=0` if equal.
5. **Memory falsifier (the seam's own claim):** a "streaming" implementation that secretly
   `cat`s all segments before hashing must FAIL gate-1's flat-RSS check — RSS grows with `n_gen`,
   exposing the fake. (This is what makes the bound a *gate*, not a vibe.)

## Why this is the right cut

The seam needs **zero new crypto and zero model change** — it reuses the already-shipped streaming
SHA-256, the already-proven `arena_mark/reset` + on-disk-spill discipline (`lm4_emit_all`,
`bnd_wp_ser`), and the already-pinned decode. The entire novelty is reorganizing the commitment
from "materialize → hash" to "generate → absorb → spill → free," which is exactly the
bounded-memory pattern rung 23 (segmented training) and rung 30 (streamed Merkle DAG with
`arena_reset` per segment) will both lean on. Climbing long-gen de-risks those two directly:
the streaming-commitment primitive it builds is the same primitive a kilobyte utterance, a
multi-line corpus (rung 24's chunked giant-string build), and a streamed step-state DAG all need.
