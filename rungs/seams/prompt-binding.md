# Cross-cutting seam — Prompt-binding / seed-window robustness

*One of the six open seams the attested-LM ladder omits (ATTESTED_LADDER.md, seam #2). This is a
**design + gate + falsifier**, grounded in the live `attested_utterance.rail` substrate — not a built
rung. No heavy build is run here; the skeleton below is the implementation contract.*

---

## The hole, located exactly in the substrate

`tools/bitexact/attested_utterance.rail`, `main`, the SPEAK + ATTEST block:

```
950  let pr      = "main = let _ = print (show ("        -- 28 chars -> 28 tokens (1 char/token)
951  let pids    = lm4_tokens pr vocab                    -- 28 ids
952  let seedp   = lm4_lastc pids cwin                    -- KEEPS ONLY THE LAST cwin=8 ids
953  let gen_ids = lm4_gen ... fw1 fw2 ... seedp cwin gcap []   -- decode conditions on seedp ONLY
...
957  let prompt_hex = sha256_hex pr                       -- COMMITS THE FULL 28-char prompt
959  let ulink_str  = cat [head_link,"|UTTER|",prompt_hex,"|",show cwin,"|",show gcap,"|",w_hex_final,"|",t_hex]
```

`lm4_lastc ids c = ... if n <= c then ids else lm4_lastc (tail ids) c` (line 835) drops everything but
the trailing `cwin` tokens. With `cwin=8` and a 28-token prompt, **20 committed prompt tokens are
provably ignored by the decode.** The ledger commits `prompt_hex = SHA256(pr)` but the decode ran on
`lastc(pids, 8)`. Nothing in the signed `ulink` ties the committed prompt to the window the model
actually consumed.

Both witnesses share the flaw symmetrically, which is *why it hides*:

- Rail self-witness (lines 1000-1007): `seedp2 = lm4_lastc pids2 cwin` then `lm4_gen ... seedp2 ...` —
  recomputes the *same* window from the committed prompt and agrees with itself.
- Foreign witness (`utterance_foreign_check.py` lines 123-130): `prompt_ok = sha256_hex(PROMPT) ==
  u_prompt_hex` checks the **full**-prompt hash, then independently `seedp = lastc(pids, cwin)` and
  `generate(... seedp ...)`. It re-derives the identical window and agrees with Rail.

So the two implementations cross-check each other perfectly while **neither proves the committed
prompt is the prompt that drove the utterance.** The agreement is vacuous w.r.t. the prefix: any two
honest re-runs of `lastc` over the same `prompt_hex` preimage will collapse to the same window.

### The attack the gate must defeat (chose-a-favorable-context)

`prompt_hex` is opaque (a SHA — the verifier never sees the preimage). An adversary:

1. Searches short suffixes `W` (`|W| = cwin`) for one that makes the frozen weights emit a *favorable*
   `t_hex` (a clean compiling completion, a desired answer).
2. Prepends an arbitrary, impressive-looking prefix `P` — a long, on-topic, plausible-looking prompt —
   to form `pr = P ++ W`. The prefix is **provably never read** (`lastc` discards it).
3. Commits `prompt_hex = SHA256(P ++ W)`, signs, ships.

The artifact now *claims* the model answered the full prompt `P ++ W`, while the saying was actually
conditioned on the cherry-picked 8-token window `W`. This is exactly the "decode consumed a
cherry-picked `lm4_lastc` window, not the committed prompt" failure named in ATTESTED_LADDER.md. It is
not caught by rung 27 (weight-load tamper), rung 24 (holdout — the *corpus* is split, the *prompt* is
not), or rung 28 (recency — binds *when*, not *what was read*). It is its own seam.

---

## Design — on THIS substrate

The fix has two independent obligations, both signed into `ulink`. Neither alone is sufficient.

### Obligation A — commit the **consumed window**, not just the full prompt

Add a `seed_hex` to the UTTER record: the SHA-256 of the canonical id-list of the *exact tokens the
decoder conditioned on* — the value `seedp` actually held at line 952, computed with the same
`utt_ids_canon` already used for `t_hex` (line 862, reused verbatim — same canon, foreign verifier
already mirrors it as `ids_canon`).

```
-- new, mirrors prompt_hex / t_hex construction
let seed_ids = lm4_lastc pids cwin in            -- == seedp, named for the commitment
let seed_hex = sha256_hex (utt_ids_canon seed_ids) in
```

This makes the window a *first-class signed quantity*. A forger who swaps the window now changes
`seed_hex`, which changes `ulink`, which breaks `usig`.

### Obligation B — prove the window is a genuine **suffix** of the committed prompt, AND that nothing beyond it could have mattered

Committing `seed_hex` alone is not enough: the adversary could commit a `prompt_hex` over `P++W` and a
`seed_hex` over an *unrelated* `W'`. We must bind `seed_hex` to `prompt_hex` by a relation the verifier
re-checks from the **preimage**. So the UTTER record must additionally carry the prompt **length in
tokens** `plen` and commit that the window is the deterministic `lastc` of the committed prompt:

```
let plen = lm4_len pids in
-- ulink now binds: prompt_hex, plen, cwin, seed_hex, gcap, w_hex, t_hex
let ulink_str = cat [head_link, "|UTTER|", prompt_hex, "|", show plen, "|", show cwin,
                     "|", seed_hex, "|", show gcap, "|", w_hex_final, "|", t_hex] in
```

The verifier (Rail self + foreign) is handed the **prompt preimage** (it already has it — `PROMPT` is a
constant in both witnesses; in the general case the preimage ships in the artifact alongside the
opaque hash and the verifier re-hashes it). It then enforces all four ties:

1. `SHA256(preimage) == prompt_hex`  (preimage is the committed prompt — existing check, kept)
2. `lm4_len(tokens(preimage)) == plen`  (length is honest)
3. `sha256_hex(utt_ids_canon(lastc(tokens(preimage), cwin))) == seed_hex`  (the window is the genuine
   `lastc` suffix of the committed prompt — **the new binding**)
4. decode from that recomputed window reproduces `t_hex`  (existing `utter_ok`, now provably fed the
   bound window)

The **window-coverage assertion** that kills the cherry-pick: the gate asserts `plen <= cwin`. When the
prompt fits inside the context window, *every committed prompt token is consumed* — `lastc` is the
identity, the prefix-discard attack has zero room. For the shipped `pr` (28 tokens, `cwin=8`) this
**fails today and must fail** — which is precisely the seam being surfaced. The honest fix is one of:

- **(B-fit)** shorten the attested prompt so `plen <= cwin` (full coverage; the strongest claim), or
- **(B-window)** keep `plen > cwin` but make the claim *honest about its scope*: the artifact states
  "decode conditioned on the last `cwin` of `plen` tokens; `seed_hex` is the consumed window" — the lie
  ("answered the whole prompt") is removed because the verifier sees `seed_hex` and `plen` and can
  recompute the discarded prefix length `plen - cwin`. The gate then forbids the *opaque* prompt: the
  preimage MUST ship, so a long impressive prefix is auditable, not hidden behind a SHA.

The default for this seam is **B-fit at the gate** (the falsifiable, ungameable form) with B-window
documented as the honest-scope fallback for `ctx`-exceeding prompts.

### Why this composes with the existing pipeline (no re-opened sub-claims)

- Reuses `utt_ids_canon` (line 862) and `lm4_lastc` (line 835) verbatim — same canon Rail and Python
  already agree on for `t_hex`, so no new cross-language tie-break risk.
- `seed_hex`/`plen` fold into `ulink` exactly like `prompt_hex` already does — same `sha256` link,
  same `ed25519_sign`/`verify` (lines 960-964), same `bnd_wp_*` weight path untouched.
- The `gpu_d2_all` GEMM sub-claim and rung-27 load-replay are **not re-opened**: this seam is
  purely about *what the decoder was fed*, post-weights.

---

## Gate (a concrete, falsifiable success bar)

A new isolated harness `rungs/seams/prompt_binding.rail` + `prompt_binding_foreign_check.py` (skeletons
below; not built here per compute discipline). PASS requires **all**:

- **G1 window-commitment present:** UTTER record carries `seed_hex`, `plen` (in addition to
  `prompt_hex`, `cwin`, `gcap`); `usig` verifies over the extended `ulink`.
- **G2 suffix binding:** verifier recomputes `sha256_hex(utt_ids_canon(lastc(tokens(preimage), cwin)))`
  and it equals committed `seed_hex`; recomputes `len(tokens(preimage))` == `plen`;
  `SHA256(preimage) == prompt_hex`.
- **G3 coverage (the ungameable bar):** `plen <= cwin` (B-fit) — every committed prompt token is
  consumed; OR, under documented B-window scope, the preimage ships in the artifact and the discarded
  prefix length `plen - cwin` is recorded, so the prefix is auditable rather than hidden.
- **G4 decode-from-bound-window:** decode conditioned on the verifier-recomputed window reproduces the
  signed `t_hex` (the existing `utter_ok`, now provably driven by the bound seed).
- **G5 two-witness agreement:** Rail self-witness and the foreign Python witness both reproduce
  `seed_hex` + `t_hex` from the preimage and both verify `usig`.

The gate is light (scalar + SHA + the existing tiny decode path; reuse the proven `lm10` weights from a
prior run or a small frozen fixture — **no retraining required**, the seam is post-weights).

---

## Falsifier (must be able to fail, and does)

A meta-falsifier in the harness constructs the **chose-a-favorable-context** forgery and asserts the
gate rejects it:

- **F1 prefix-swap (the headline attack):** keep the consumed window `W` and `t_hex` fixed, but commit
  `prompt_hex' = SHA256(P' ++ W)` for an impressive prefix `P'` while signing the *old* `seed_hex`/`usig`.
  The verifier recomputes `lastc(tokens(P'++W), cwin)` — but with `P' != P` and the suffix relation
  re-checked, `len` and (under B-fit) the coverage assertion break: `plen' = len(P'++W) > cwin` →
  **G3 fails**. Reject.
- **F2 unrelated-window:** commit `prompt_hex` over `P++W` but `seed_hex'` over an unrelated `W'` (the
  attacker's cherry-pick decoupled from the prompt). G2's suffix recompute yields
  `lastc(tokens(P++W),cwin) = W != W'` → `seed_hex` mismatch → **reject**.
- **F3 length lie:** commit truthful `prompt_hex`/`seed_hex` but a smaller `plen` to dodge coverage.
  `len(tokens(preimage)) != plen` → **G2 fails** → reject.
- **F4 opaque-prompt (B-window mode):** ship no preimage / a wrong preimage. `SHA256(preimage) !=
  prompt_hex` → reject; the gate refuses to certify an unauditable prompt.
- **F5 control — honest passes:** the honest B-fit run (a prompt with `plen <= cwin`, e.g. the trailing
  `cwin` tokens promoted to *be* the attested prompt) reproduces `seed_hex`, satisfies coverage,
  reproduces `t_hex`, both witnesses verify → PASS. (False-reject resistance: an honest artifact is
  never rejected.)

The discriminating test is **F1 vs F5 on the same frozen weights**: same model, same `t_hex`-favorable
window — the honest full-coverage prompt passes, the prefix-padded forgery fails, *purely because the
window↔prompt binding is now signed and re-checked.* A gate that passes both has not closed the seam.

---

## Artifact skeletons (to be built; not run here)

`rungs/seams/prompt_binding.rail` (trainer/attestor diff vs `attested_utterance.rail`):

```rail
-- (after frozen weights fw1/fw2/femb/fblk0/fblk1 are available)
let pr       = "<= cwin tokens for B-fit, e.g. a short attested prompt>" in
let pids     = lm4_tokens pr vocab in
let plen     = lm4_len pids in
let seedp    = lm4_lastc pids cwin in
let seed_hex = sha256_hex (utt_ids_canon seedp) in       -- NEW: commit consumed window
let gen_ids  = lm4_gen ct st fw1 fw2 femb fblk0 fblk1 isd seedp cwin gcap [] in
let prompt_hex = sha256_hex pr in
let t_hex      = sha256_hex (utt_ids_canon gen_ids) in
-- coverage assertion baked into the gate value:
let okCover  = if plen <= cwin then 1 else 0 in          -- B-fit; B-window swaps to scope-record
-- extended link binds the window + length:
let ulink_str = cat [head_link,"|UTTER|",prompt_hex,"|",show plen,"|",show cwin,
                     "|",seed_hex,"|",show gcap,"|",w_hex_final,"|",t_hex] in
-- ... sha256 / ed25519_sign / verify exactly as lines 960-964 ...
-- write the preimage too (auditability): write_file "out/pb_prompt.txt" pr
-- FALSIFIERS (computed inline, must each be 1):
--   okF2 = (seed_hex of unrelated W') != seed_hex     -> 1
--   okF3 = recomputed len != lied plen detected       -> 1
--   okF1 = prefix-padded prompt fails coverage/len    -> 1
let allPB = okUtterSig * okCover * okF1 * okF2 * okF3 in
```

`rungs/seams/prompt_binding_foreign_check.py` (diff vs `utterance_foreign_check.py`): parse `seed_hex`,
`plen` from the UTTER row; read the shipped preimage; assert
`sha256_hex(PROMPT) == prompt_hex`, `len(tokens(PROMPT)) == plen`,
`sha256_hex(ids_canon(lastc(tokens(PROMPT), cwin))) == seed_hex`, `plen <= cwin`,
then `generate(... lastc(tokens(PROMPT),cwin) ...)` reproduces `t_hex`; verify `usig` over the extended
link; and run the F1/F2/F3 forgeries asserting rejection.

`rungs/seams/validate.sh`: compile both, run the light harness (no lm10 retrain — load a frozen weight
fixture), cross-verify with the foreign checker, run the meta-falsifier; exit 0 iff `allPB == 1` AND
foreign PASS AND all forgeries rejected.

---

## Scope (honest)

This seam binds **what the decoder was fed** (the consumed window, provably a suffix of an auditable
committed prompt, with full-coverage as the ungameable default). It does **not** by itself address:
variable-length generation (seam #1), batched multi-prompt proofs (seam #4), or numeric faithfulness
(seam #3) — those are their own seams. It composes cleanly with rungs 24/27/28: the prompt becomes a
signed, auditable, fully-consumed input rather than an opaque hash hiding a cherry-picked window.
