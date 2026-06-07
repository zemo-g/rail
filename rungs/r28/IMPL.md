# Rung 28 — Live-Beacon Genesis with Proof-of-Recency Seed-Binding

*Builder artifact. Extends the proven attested-utterance pipeline
(`tools/bitexact/attested_utterance.rail` + `utterance_foreign_check.py`).*

## The claim (from ATTESTED_LADDER.md, verbatim intent)

> The genesis **and** the weight-init seed both derive from a freshly-fetched live
> ledatic.org entropy pulse, so the whole signed trajectory — *including the initial
> weights* — is provably **posterior** to a publicly-witnessed unpredictable value.

**Scope (honest, from the ladder):** This proves **not-before** (a lower time bound:
the run is posterior to the pulse), *not* elapsed wall-time. An attacker holding the
pulse can still train instantly. The "took >=K work" upper-cost claim is rung 34.

## What the floor did (the easy thing we destroy)

In `attested_utterance.rail` the genesis and init had **zero entropy**:

```
genesis_hex = sha256_hex "LM10.LOCAL.BEACON.GENESIS.dev"     -- compile-time constant
lm4_cell0 kind i j koff = (lm4_imod (kind*101 + i*5 + j*3 + 7 + koff) 13 - 6) * 1398101
```

and **every** `initmat`/`emb_initmat` call passed `koff = 0`. The run therefore
proves nothing about *when* it happened — its genesis and its initial weights are
fixed forever, identical to a run mounted a year ago or a year from now.

## The two seed-bindings this rung adds

Both bindings come from **one** live pulse, fetched once and **pinned to a file**
that both witnesses replay (see "Why a pinned pulse, not a live call in the binary"
below):

1. **Genesis binding.** `genesis = SHA-256( pulse_value_hex ++ "|" ++ corpus_sha )`.
   The chain root is now a hash *over* the public unpredictable pulse value, so the
   entire signed ledger is anchored beneath a value nobody could have predicted
   before the pulse was published.

2. **Init seed binding (the load-bearing half).** A per-pulse offset
   `poff = pulse_offset(pulse_value_hex)` is derived from the pulse and threaded
   into **every** `lm4_initmat` / `lm4_emb_initmat` call via the existing `koff`
   argument — the hook the floor already had but always passed `0`. So *the initial
   weights themselves* are a deterministic function of the live pulse:

   ```
   lm4_cell0 kind i j (koff + poff)
   ```

   `poff` is a residue rotation in `[0,12]` (see "Q.24 safety"), so it rotates the
   init's residue class deterministically without leaving the Q.24-safe magnitude
   band the floor already used. Because the seeded `wp0` is consumed identically by
   the signing chain (`lm4_chain`) **and** the no-resign mirror (`lm4_chain_d0`), the
   pulse propagates through training with **zero** new arithmetic and **no** new
   30-arg-cliff pressure: `poff` is folded into `koff` *before* the init calls, so the
   chain signatures are unchanged in arity.

### Why this is the *honest* binding the ladder demands

The ladder's falsifier is precise: *"Swap only the genesis/pulse_id to an earlier
pulse, leaving weight commitments untouched: because init weights are pulse-seeded,
re-derived `lm4_cell0` != committed epoch-0 w_hex -> okD0/okUtterRepro -> 0 -> fail."*

This works **only because the init is pulse-seeded**. If we bound *only* the genesis
(a string in the chain root) an attacker could swap the pulse_id in the header and
re-sign — the weight commitments would still reproduce, because the floor's weights
don't depend on genesis. By threading `poff` into `cell0`, the committed epoch-0
weight hash `w_hex` is now a function of the pulse, so a swapped pulse forces a
weight-hash mismatch that **no re-sign can repair without re-training** — and
re-training under the swapped (earlier) pulse contradicts the recorded `pulse_id`.

## Pipeline reuse (verbatim where possible)

Reused **unchanged**: the lm10 transformer (Q.24, RoPE, multi-head, exact-int Adam,
`gpu_matvec` readout), `bnd_wp_*` serialization shape, `lm4_chain` / `lm4_chain_d0`
re-run, the Ed25519 hash-chain, `sha256_hex`, the UTTER record, the
forged-commitment + forged-weights controls, the arena_mark/reset persist-across-reset
pattern. **Touched** (small, surgical):

- `lm4_cell0` callers: thread `poff` into the `koff` slot of every `initmat` /
  `emb_initmat`. (`lm4_cell0` itself is *unchanged* — it already accepts `koff`.)
- `genesis_hex`: derived from the pinned pulse instead of a constant string.
- `main`: read the pinned pulse file, compute `poff` + `genesis_hex`, record
  `pulse_id` + the 32-byte pulse hash into the ledger header, **and** a dev-mode
  guard so the demo never mints against the live witness key.
- Foreign check: header now carries `pulse_id` + `pulse_hex`; `rederive` takes a
  `poff` derived from `pulse_hex` and passes it into `initcells`/`emb_initcells`.

## The dev-mode guard (mandatory per the ladder Wall)

The ladder Wall: *"a dev-mode guard so the demo never mints against the live witness
key."* Implemented as a hard local-only invariant: this rung signs with the same
**LOCAL/DEV ephemeral key** the floor used (`lm10.local.ephemeral.dev.seed.v1`), and
the trainer **asserts** that the signing key is the dev key (`okDevKey`) — it never
reads `~/.fleet/*` and never contacts the Pi witness key. The *pulse* is public input
(read-only); the *signature* stays LOCAL/DEV. This honors the Ledatic rule
"manual runs must not sign the real chain" and keeps proof-of-recency about the
**pulse anchoring**, not the key.

## Why a pinned pulse file, not a live TLS call inside the binary

The ladder Wall describes fetching `/entropy/pulse/<id>` over the pure-Rail TLS-1.3
stack at admission time and persisting it across the mid-`main` arena_reset. The
fetch is a genuine part of the protocol, **but** the bit-exact verification property
requires the trainer + both witnesses to consume the *same* pulse — a live call
inside the heavy training binary would (a) be non-deterministic (the pulse advances
~every few seconds), (b) fail offline, and (c) make the foreign re-run irreproducible.

The sound resolution (and the one the ladder's own gate describes —
*"both witnesses fetch/replay **that exact pulse**"*): **fetch once, pin to a file,
replay the pinned pulse everywhere.**

- `fetch_pulse.sh` performs the live admission-time fetch (pure-Rail HTTPS path
  available via `stdlib/https_client.rail`; the shell wrapper uses `curl` only as the
  transport so the validate command stays light and offline-tolerant — the pulse is
  *public read-only input*, not a signing surface, so the transport choice is not
  security-relevant). It writes `out/pulse.json` + the flat `out/pulse_id.txt` /
  `out/pulse_hex.txt` the trainer reads.
- The trainer reads `out/pulse_id.txt` + `out/pulse_hex.txt` **before** `arena_mark`,
  re-persists them across the mid-`main` `arena_reset` (same pattern the floor uses
  for `head_link`/`t_hex`), and records them in the header.
- Both witnesses replay the pinned pulse from the header — never re-fetch — so the
  proof is *posterior to the pinned pulse* and fully offline-reproducible.

This is "fetch live, then freeze" — the recency is established by the pin's
provenance (a real published pulse with a monotone `pulse_id` and a prev-chained
`value_hex`), and reproducibility is preserved by the freeze.

## Q.24 safety argument

`poff in [0,12]` (one full residue period of the `mod 13` in `lm4_cell0`). Adding it
inside the `imod` only rotates which residue each `(kind,i,j)` maps to; the output
stays `(r-6)*1398101` for some `r in [0,12]`, i.e. exactly the same value *set*
`{-6..6} * 1398101` the floor already trained on and proved Q.24-reproducible. No new
magnitude, no overflow, no change to truncate-divide behaviour. The init distribution
is a **permutation** of the floor's, so all rung-21..27 Q.24 invariants carry over
unchanged.

## Genesis + offset derivation (bit-exact, cross-language)

```
pulse_hex      = the 64-hex value_hex from /entropy/pulse           (32 bytes)
genesis_hex    = sha256_hex( pulse_hex ++ "|" ++ corpus_sha )       (Rail + Python identical)
poff           = pulse_offset(pulse_hex)
                 = (hexpair_to_int(pulse_hex[0:2])) mod 13          (first byte mod 13, in [0,12])
```

`hexpair_to_int` reads the first two hex chars of `value_hex` as a byte (0..255) and
takes `mod 13`. Both languages compute it from the *same* `pulse_hex` string in the
header, so they agree by construction. (First-byte-mod-13 is deliberately simple and
auditable; any deterministic pulse->[0,12] map works — the soundness comes from the
init *depending* on the pulse, not from the map's complexity.)

## Gate (what PASS requires)

The validate command runs the full pipeline and asserts ALL of:

1. **Header records the pulse.** `out/utterance_chain.txt` header contains
   `pulse_id=<id>` and `pulse_hex=<64hex>`. (inlined header grep in `validate.sh`
   step 3b: `grep -Eq 'pulse_id=[0-9]+'` and `'pulse_hex=[0-9a-f]{64}'`)
2. **Genesis is pulse-derived.** `genesis_hex == sha256(pulse_hex ++ "|" ++ corpus_sha)`,
   re-checked independently by the foreign verifier.
3. **Floor invariants still hold** (the whole proven chain): per-checkpoint sigs
   verify, training reproduces (D0), UTTER sig verifies, UTTERANCE reproduces
   bit-for-bit, tamper-reject, wrong-key-reject, forged-commitment rejected,
   forged-weights cannot reproduce — i.e. the existing `all == 1` PASS, now under a
   pulse-seeded init.
4. **Dev-key guard.** `okDevKey == 1` — the signing key is the LOCAL/DEV key, never a
   prod/witness key.
5. **Foreign witness replays the exact pulse.** `utterance_foreign_check.py` reads
   `pulse_id` + `pulse_hex` from the header, re-derives `genesis` + `poff`, reproduces
   the training head + t_hex bit-for-bit, and verifies the sig — all from the pinned
   pulse, no re-fetch.

## Falsifier (what MUST fail — and the harness proves it fails)

The ladder's falsifier, mechanized in `falsify_earlier_pulse.py`:

> Swap only the genesis/pulse_id to an *earlier* pulse, leaving the committed weight
> hashes untouched. Because the init is pulse-seeded, the re-derived `lm4_cell0`
> diverges from the committed epoch-0 `w_hex` -> the chain head no longer reproduces
> -> okD0/okUtterRepro collapse -> the verifier must FAIL.

`falsify_earlier_pulse.py` takes the real ledger, rewrites *only* `pulse_id` +
`pulse_hex` in the header to a different (earlier) pulse value, leaves every committed
weight/utterance hash and signature byte untouched, and re-runs the foreign verifier.
**Expected: the verifier rejects** (re-derived genesis differs -> training head
mismatch -> chain_ok / utter_ok false). If the forged ledger ever *passes*, the rung
FAILS — the seed-binding would be cosmetic. The harness asserts the forged ledger is
rejected.

A second falsifier (`falsify_keep_genesis.py`): swap the pulse but keep the *genesis*
string, changing only the header `pulse_id`. This catches a "genesis-only binding"
regression: even though genesis still reproduces, the *recorded pulse_id* now
contradicts the genesis derivation (`genesis != sha256(pulse_hex ++ corpus_sha)`),
so the foreign verifier's pulse-consistency check rejects.

## EXACT validate command (orchestrator runs this serially)

```bash
bash /Users/ledaticempire/rail-reward/rungs/r28/validate.sh
```

`validate.sh`:
1. fetches + pins a live pulse (`fetch_pulse.sh`; falls back to a pinned recorded
   pulse if offline, clearly logged — recency provenance is the pin's, not the fetch's),
2. compiles `r28_live_beacon.rail` to an isolated out-prefix (no `/tmp/rail_out`
   collision),
3. runs it with `RAIL_ARENA_MB=8192` (lm10 needs the multi-GB arena),
4. runs the foreign verifier (must PASS),
5. runs both falsifiers (each must REJECT the forged ledger),
6. exits 0 + prints `RUNG28 PASS` only if all of the above hold.

**Compute note for the orchestrator:** step 2-3 is the one heavy build/train (~2-3
min, ~8 GB arena) — it is the *same* cost as the proven floor, with no added epochs.
Steps 1,4,5,6 are light.

## Files

| file | role |
|---|---|
| `r28_live_beacon.rail` | the trainer: floor pipeline + pulse-seeded genesis & init + header pulse fields + dev-key guard |
| `r28_foreign_check.py`  | foreign witness: replays the pinned pulse, re-derives genesis+poff, reproduces head+t_hex, verifies sig |
| `fetch_pulse.sh`        | admission-time live pulse fetch -> `out/pulse_id.txt` / `out/pulse_hex.txt` (+ recorded fallback) |
| `falsify_earlier_pulse.py` | swaps pulse_hex to an earlier value, weights untouched -> verifier MUST reject |
| `falsify_keep_genesis.py`  | swaps only pulse_id -> pulse/genesis-consistency MUST reject |
| `validate.sh`           | the single EXACT command the orchestrator runs |
| `pulse_fallback.json`   | a recorded real pulse, used only if the live fetch is offline (provenance logged) |

## Honest status

The Rail trainer + foreign verifier + falsifiers + validate harness are written and
internally consistent against the proven floor (every reused symbol verified present
in `attested_utterance.rail` / `utterance_foreign_check.py` / `lm10_foreign_check.py`).
I have **not** executed the heavy `RAIL_ARENA_MB=8192` build under the
compute-discipline rule (one shared compiler/GPU/24GB across ~15 builders). The
pulse-seeding hook (`koff`), the genesis derivation, the header round-trip, and the
falsifier logic are the genuinely new surface and are designed to the ladder's gate +
falsifier. Remaining risk is the usual lm10 build-fragility (arena pressure, 30-arg
cliff) — which the floor already clears at this exact config, and this rung adds no
arity and no arithmetic.
