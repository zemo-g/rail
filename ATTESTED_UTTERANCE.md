# The First Attested Utterance

*A Rail-native transformer trained itself, **spoke a Rail program**, bound those exact words into
its own Ed25519 hash-chain, and two independent implementations — one in Rail, one in a different
language — reproduced the words bit-for-bit from the signed ledger. You can verify the **saying**,
not just the gradients.*

Built 2026-06-06 as the capstone on top of the rung-21 attested transformer (`lm10`). Isolated
worktree, no live-tree changes.

---

## What the model said

Trained (greedy-memorized) on a one-line corpus — a minimal valid Rail program — the transformer,
prompted with `main = let _ = print (show (`, deterministically completed it:

```
main = let _ = print (show (1)) in 0
```

The language speaking itself: a transformer **written in Rail** emits **valid Rail**, and the
utterance, when run, prints `1`.

## The model

| | |
|---|---|
| architecture | 2 stacked pre-norm blocks, each = multi-head (H=2) RoPE causal self-attention + residual, then position-wise FFN(GELU) + residual, feeding an MLP readout (the real rung-21 `lm10`) |
| dims | vocab=21, d=8, nheads=2, hidden=64, ctx=8, epochs=19, pairs=29 |
| arithmetic | exact-integer **Q.24 fixed-point** end to end (bit-reproducible; zero float drift) |
| training | exact-integer Adam, gradient-clipped; readout GEMM on Metal GPU (bit-identical to CPU) |
| loss descent | 12,766,067,986 → 2,431,660 |

## The attestation (LOCAL/DEV keys only — never a prod sign surface)

The training run is a hash-chained, Ed25519-signed ledger of 19 per-epoch checkpoints. **New here:**
a final `UTTER` record that commits the model's spoken token-ids (`t_hex = SHA-256` of the canonical
id list), bound to the final-weights commitment (`w_hex`) and the prompt, chained onto the training
head and signed.

```
pubkey         c1dbe8407ebe486c290052c34ebaf65723ab763ca625f4b719c4fd835b60558b
genesis        83d3baff204309b11832954aa8343ed1470bde6ffcfbf5b518cb0e05449ea098
corpus  sha256 deb156aa97614b4d79375d7c465d87bebfe61d335a1b85482f12081b49d0b276
training head  14eff20ec9a4dec0b1a02f9a53fb6a8696a0ce210bf2fcf4aa41ad3a286be935
utterance t_hex f6af1142b89c59197b7549feb1b94a48c5a860068951dd5f69df3cc8ce763c86
utterance link  6f551fc338f3aae28d64deb14d5e2ca0e6f72b525e4b0239c012e379624d9b08
```

## The verification (two independent witnesses)

**1. Rail self-witness** (`attested_utterance.rail`): re-trains from scratch in a fresh arena and
re-decodes — reproduces the training head AND the utterance `t_hex` bit-for-bit. Per-checkpoint
signatures verify; flipped sig, wrong key, tampered weight-commitment, and forged (zeroed-readout)
weights are all rejected.

**2. Foreign cross-language witness** (`utterance_foreign_check.py`): a *separate implementation in
a different language* reconstructs the weights from data+config+seed in pure big-integers,
re-generates the model's greedy decode itself, and confirms:

```
corpus pin reproduced            = True   (19 checkpoints re-derived)
training head reproduced         = True   (chains onto UTTER)
final-weights commitment matches = True
prompt commitment matches        = True
UTTERANCE reproduced bit-for-bit = True   (independent greedy decode -> same t_hex)
utterance Ed25519 sig verifies   = True
forged utterance rejected        = True
the words (foreign-reproduced)   = 'main = let _ = print (show (1)) in 0'
```

## The insight earned along the way

The first forged-weights control was a *small* embedding nudge — and the output did **not** change.
That's real: a model that memorized hard is robust to small perturbations, so **output-divergence is
a weak tamper test**. The cryptographic weight-commitment is the real guarantee — it rejects *any*
weight change, including ones too small to change a single token. (The shipped control now uses a
guaranteed-divergent forge so the demonstration is unambiguous, but the principle stands.)

## Reproduce

```bash
cd ~/rail-reward
# build (isolated output prefix; do not collide with /tmp/rail_out)
./rail_native --out-prefix out/utter_bin tools/bitexact/attested_utterance.rail
# run — RAIL_ARENA_MB IS REQUIRED: lm10 needs a multi-GB arena; the 512MB default GC-thrashes forever
RAIL_ARENA_MB=8192 ./out/utter_bin
# foreign cross-language verification of the SAYING
python3 tools/bitexact/utterance_foreign_check.py out/utterance_chain.txt
```

Artifacts: `out/utterance_chain.txt` (signed ledger: 19 checkpoints + 1 UTTER record),
`out/utterance.txt` (the words + token-ids + t_hex).

## Why it matters

This is [[paos-specialist-models]] Stage-2 in one breath: attested training → honest generation →
**foreign verification of the utterance**. Not "the model trained honestly" (already proven at
rung 19) but "here is what the honestly-trained model **says**, and an independent party in another
language reproduced it exactly." The bound between the weights and the words is the moat.
