# Seam: Multi-prompt / Batched Attestation

*Cross-cutting open seam #4 from `ATTESTED_LADDER.md`. One succinct proof that the model answers a
SET of held-out prompts — the PAOS dispatch use-case (a local NN answering a batch of ops
questions), bound into ONE signed record, verifiable in ≪ batch time.*

Grounded on the proven floor: `tools/bitexact/attested_utterance.rail` (one UTTER record per run)
and `tools/bitexact/utterance_foreign_check.py` (foreign re-derivation of the saying). This seam
turns the single UTTER record into a Merkle-rooted batch over N prompts.

---

## The floor it must break

`attested_utterance.rail:main` speaks **once**: one `pr`, one greedy `lm4_gen`, one `t_hex`, one
`UTTER` line whose link is
`head_link|UTTER|prompt_hex|cwin|gcap|w_hex_final|t_hex` (line 959). The foreign verifier
(`utterance_foreign_check.py:136`) rebuilds that exact link, re-decodes once, checks one `t_hex`.

PAOS dispatch needs the inverse shape: **N prompts, N answers, one proof**. The naive extension —
N independent UTTER lines, each separately signed and each re-decoded by the verifier — fails the
seam's own success criterion two ways:

1. **Not succinct.** N signatures + N foreign re-decodes is O(N) proof size AND O(N) verify cost.
   The whole point ("one succinct proof over a batch") is lost.
2. **No set-integrity.** N loose lines let an attacker drop or reorder the embarrassing answer
   ("which questions did the model NOT answer?" is unattested). A batch proof must commit the
   *exact set* and *exact membership*.

The reusable wins from the floor stay verbatim: the lm10 transformer (`lm4_forward`/`lm4_gen`),
exact-integer Q.24, the `w_hex_final` weight commitment, Ed25519 via `ed25519_sign`/`_verify`,
`sha256_hex`, and the foreign-witness contract.

---

## Design (on THIS substrate)

### 1. One answer per prompt — a deterministic per-prompt leaf

Reuse `lm4_complete`/`lm4_gen` unchanged. For prompt `j` in the batch:

```
pids_j   = lm4_tokens prompt_j vocab
seedp_j  = lm4_lastc pids_j cwin
gids_j   = lm4_gen ct st fw1 fw2 femb fblk0 fblk1 isd seedp_j cwin gcap []
phex_j   = sha256_hex prompt_j                       -- prompt commitment (mirrors prompt_hex)
thex_j   = sha256_hex (utt_ids_canon gids_j)         -- answer commitment (mirrors t_hex)
leaf_j   = sha256_hex (cat [show j, "|", phex_j, "|", thex_j])   -- ordered, positional leaf
```

`leaf_j` binds the prompt, the answer, **and its position `j`** — so reorder/drop is detectable.
Each leaf is exactly the floor's per-utterance commitment with the position prefix added.

### 2. Merkle root over the leaves — the succinctness mechanism

Fold the N leaves into a binary Merkle tree with a **domain-tagged** node hash (tag bytes prevent
second-preimage between leaf and internal levels):

```
node(l, r) = sha256_hex (cat ["N|", l, "|", r])      -- internal
leaf  tag  = already "L|" implicit via leaf_j's "j|phex|thex" form (j fences it)
odd level: promote the lone right node unchanged (Bitcoin-style duplication is a known
           malleability footgun — promote instead, and commit N so the shape is fixed)
batch_root = fold up to a single 32-byte root hex
```

The ledger commits `batch_root` + `N` + `gcap` + `cwin` + a **prompt-set commitment**
`set_hex = sha256_hex(concat of sorted phex_j)`. `set_hex` pins WHICH prompts (order-independent),
`batch_root` pins the prompt→answer→position binding (order-dependent). Both are needed: `set_hex`
catches "you swapped in an easier prompt", `batch_root` catches "you reordered/dropped an answer".

### 3. The BATCH record — one signed line, drop-in alongside UTTER

New ledger record, same key/genesis/chain discipline as UTTER (LOCAL/DEV only — never a prod sign
surface, mirroring lines 917-921):

```
blink_str = cat [head_link, "|BATCH|", set_hex, "|", show N, "|", show cwin, "|",
                 show gcap, "|", w_hex_final, "|", batch_root]
blink_b   = sha256 blink_str
bsig      = ed25519_sign seed blink_b 32
BATCH set_hex N cwin gcap w_hex_final batch_root head_link blink_hex bsig_hex
```

ONE signature over the whole batch. The sidecar `out/batch.txt` lists, per prompt, the human-
readable `(prompt_j, answer_j, phex_j, thex_j, j)` so the served answers are recoverable — but the
*proof* is the single signed line.

### 4. Succinct verification — Merkle-path spot-check, not full re-decode

This is the load-bearing piece and where it earns "succinct over a batch". The foreign verifier
(extend `utterance_foreign_check.py` pattern) does NOT re-decode all N prompts. It:

1. Reconstructs `fw1/fw2/femb/fblk0/fblk1` once (reuses `rederive`, already O(epochs) — that cost
   is amortized across the whole batch, the key asymmetry vs N separate runs).
2. Verifies `bsig` over the rebuilt `blink_b` under the pinned pubkey, and `head_link == prev`.
3. Derives **k challenge indices** by Fiat-Shamir from the chain head:
   `idx_m = parse_hex(first 8 hex of sha256(blink_hex ++ "," ++ show m)) mod N`, for m in 0..k-1
   (SHA-derived randomness — NOT an LCG; Rail's int63 PRNG overflow trap, CLAUDE.md, makes any
   multiplicative generator non-deterministic across ISA).
4. For each challenged `j`: re-decode ONLY prompt `j` (`generate(...)`), recompute `leaf_j`, and
   **verify its Merkle path** to `batch_root` (the path is ~log2(N) sibling hashes, supplied in the
   sidecar). Re-decode cost = k·(decode) ≪ N·(decode) when k≪N.
5. Recompute `set_hex` from the sidecar's sorted `phex_j` and check it equals the committed value
   (catches set-substitution cheaply, O(N) hashing but NO decode).

A prover who faked answer `j*` is caught with probability `1 − (1 − 1/N)^k` per the same soundness
argument as ladder rung 30; `k` is chosen for the target bound and is committed in the header so the
witness can't silently lower it.

### 5. Rail limits this design routes around (CLAUDE.md / known traps)

- **O(N²) `bytes_to_str` ~64KB cap + giant-string bump-arena cap.** Never build one mega-string of
  all N answers. The Merkle root is fixed 32 bytes; the sidecar is written incrementally with
  `write_file`/append, and each per-prompt decode is bracketed in `arena_mark`/`arena_reset`
  exactly like `lm4_emit_all` (line 851-856) so batch generation doesn't climb toward the 8GB cap
  and GC-thrash.
- **No short-circuit `&&`.** The all-gate accumulator stays the multiplicative form
  (`all = okSigs * okBatchSig * okMerkle * okSet * ...`) used at line 1016 — never `&&`.
- **`split` single-char / `parse_int` for string→int.** Parse the header's `N`/`k`/`gcap` with the
  digit-walk pattern (`lm4_hd_int`, line 56), not `to_int`.
- **≥30-arg cliff.** The batch loop threads the weight bundle as the single nested `fwp` (as
  `lm4_chain` already does) plus the prompt list — well under 30. Do NOT explode the 17 configs.
- **Self-loop cross-dep-arg miscompile.** The Merkle-fold accumulator and the leaf-list builder use
  mutual-recursion `_a`/`_b` pairs (the file's established discipline, e.g. `ln_up_a`/`_b`,
  `dvcol_a`/`_b`) — never a single self-loop that permutes/cross-uses its args.
- **PRNG int63 overflow.** Challenge indices are SHA-256-derived (step 3), the only determinism-safe
  source of randomness here.
- **`\r`/ASCII-in-`.asciz`.** Sidecar/prompt corpus stays ASCII; prompts are plain Rail-ish ops
  text. No CR bytes needed.

### 6. The prompt corpus

A small held-out set, e.g. `tools/bitexact/lm10_batch_prompts.txt`, one prompt per line (`str_split
"\n"`), all drawn from the same vocab as `lm10_corpus.txt` so `lm4_tokens` never hits an OOV char.
First cut: N=4–8 prompts that share the trained vocab (the dispatch toy: variants of
`main = let _ = print (show (` completed to different valid Rail). This deliberately stays on the
*reproducibility* claim, not the *generalization* claim — generalization is ladder rung 24's job;
this seam proves "one proof, many sayings, cheaply verified", orthogonally.

---

## Gate (must PASS, all multiplicative)

A new `tools/bitexact/attested_batch.rail` (clone of `attested_utterance.rail` main, batch loop
substituted) + `tools/bitexact/batch_foreign_check.py` (clone of the foreign verifier) where:

- **okBatchSig** — `ed25519_verify pk blink_b 32 bsig == 1`; `head_link` chains onto training head.
- **okMerkle** — for the k Fiat-Shamir-challenged indices, the Rail-recomputed `leaf_j` + its
  supplied Merkle path hash up to the committed `batch_root` (path verifies for every challenge).
- **okSet** — `set_hex` recomputed from sorted per-prompt `phex_j` equals the committed value.
- **okBatchRepro** — the foreign Python witness, decoding ONLY the k challenged prompts,
  reproduces those `leaf_j` and the same `batch_root` via the paths, AND verifies `bsig`.
- **okSuccinct (the seam's defining gate)** — the foreign witness's *decode count* is recorded and
  asserted `k < N` with `k ≤ ⌈N/2⌉` AND wall-clock decode time scales with k, not N: run the
  verifier at N and at 2N with k fixed; verify time must stay flat while a full-replay baseline
  doubles. (Mirrors rung 30's "verify ≪ train, demonstrated by doubling".)
- **okSigs / okProg / okTamper / okWrongKey / okD0** — inherited unchanged from the floor
  (line 1011-1016); training still reproduces and per-checkpoint sigs verify.

PASS = product of all == 1.

---

## Falsifier (each must FAIL the gate — a forgery the gate rejects)

1. **Drop the embarrassing answer.** Remove prompt `j`'s leaf and re-fold N−1 leaves but keep the
   committed `N` and `batch_root` → either `batch_root` recomputation diverges, or the Merkle path
   for a challenged surviving index no longer reaches the committed root → **okMerkle = 0**.
2. **Swap in an easier prompt.** Replace `prompt_j` with a softball (keep its slot/answer) →
   recomputed `set_hex` from sorted `phex_j` ≠ committed `set_hex` → **okSet = 0**. (And if the
   answer is also swapped, the challenged `leaf_j` diverges → okMerkle = 0.)
3. **Forge one answer, keep the root.** Substitute `thex_j` for a nicer answer but leave
   `batch_root`/`bsig` untouched → if `j` is challenged, recomputed `leaf_j` ≠ path leaf →
   okMerkle = 0; across many FS seeds the forged index is hit at the claimed soundness rate (one
   forged batch ever passing → seam fails), exactly the rung-30 argument.
4. **Tamper the batch commitment.** Flip one nibble of `batch_root` (or `set_hex`) in the BATCH
   line, `bsig` unchanged → `ed25519_verify` over the rebuilt `blink_b` fails → **okBatchSig = 0**.
   (Direct analogue of `okForgeChain`, line 967-970.)
5. **Fake succinctness.** A verifier that secretly re-decodes all N (to "pass" okMerkle the lazy
   way) is caught by **okSuccinct**: its decode count == N and its time doubles at 2N → the flat-
   time assertion fails. (Mirrors rung 30's secretly-retraining-verifier catch.)
6. **Lower k silently.** Witness uses k=1 against a header committing k=⌈N/2⌉ → the committed-k
   check in step 3 of verification fails (k is in the signed header, so it can't be quietly
   reduced). This is the multi-prompt analogue of the rung-30 "bind the soundness parameter".

---

## Why this is the seam, not a rung

It cuts across the ladder rather than sitting on it: the **Merkle-batch + Fiat-Shamir spot-check**
machinery is the same primitive rung 30 builds for training-step succinctness, applied here to
*answers* instead of *steps*. Building it as a seam means rung 30's transcript and this batch proof
share one Merkle/FS implementation. It is the direct PAOS-dispatch shape: a local NN answers a batch
of ops questions, and the operator gets ONE 32-byte root + one signature that any third party
verifies by spot-checking a handful of answers — never re-running the model on the whole batch.

**Honest scope (enough-for-now):** this seam proves *batched reproducibility + set-integrity +
succinct verification*. It does NOT prove the answers are *correct* or *generalize* (rung 24) or
that the prompt was actually *consumed* rather than a cherry-picked context window (seam #2,
prompt-binding) — those compose on top. Each is named, not hidden.

---

## Concrete next step (no heavy build)

1. Write `tools/bitexact/lm10_batch_prompts.txt` (N=4 vocab-safe prompts).
2. Clone `attested_utterance.rail` → `attested_batch.rail`; replace the single-utterance block
   (lines 949-975) with: per-prompt leaf loop (arena-bracketed, mutual-recursion fold) →
   `batch_root`/`set_hex` → BATCH line + sidecar.
3. Clone `utterance_foreign_check.py` → `batch_foreign_check.py`; replace single-`generate` with the
   FS-challenged k-of-N decode + Merkle-path verify + the N-vs-2N succinctness timer.
4. Run with `RAIL_ARENA_MB=8192` (lm10 needs the multi-GB arena — ATTESTED_UTTERANCE.md line 88).
