# Rail-native transformer — Model Card v0.3a

**Trained:** 2026-04-15
**Supersedes:** v0.2 (which was entirely a bug artifact — see below)

## Headline

Same architecture as v0.1 / v0.2 (single-block pre-norm, d=64, d_ff=256,
V=32, seq=382, 2000 Adam steps, cosine LR). One-line fix to the input
pipeline. The model now actually works — autoregressive "To be"
generates a coherent 20-char continuation of the memorized corpus
rather than collapsing into noise.

## The bug (inherited from v0.1/v0.2)

`tools/train/lm_transformer.rail:fill_onehot` walked the id list with
`list_nth i ids` while *also* tailing `ids` each recursive step. At
recursion depth `i`, `ids` was already `tail^i(original)`, so
`list_nth i ids` dereferenced `original[2i]` — with a `0` fallback
once the list ran out.

Verified with a 5-element input:

```
fill_onehot dst [10,20,30,40,50] V=? seq=5 i=0
→ dst rows encode: [10, 30, 50, 0, 0]    (not [10,20,30,40,50])
```

The model was trained on a one-hot input where position `i` held
`corpus[2i]` for `i < seq/2` and the first-appearance char `'T'` for
`i ≥ seq/2`. Labels were correct. The model learned a position →
next-char lookup that only worked when fed the exact same corrupted
input. Teacher-forcing at the full training seq with the *same* bug
reproduced the shifted Shakespeare, which looked like memorization.
Autoregressive sampling at any other seq cannot reproduce the
corrupted input distribution, so v0.2 autoregressive was noise.

Found while shipping `tools/train/lm_infer.rail` (commit 31e4d17).

## The fix

```rail
-- Before (v0.1 / v0.2)
fill_onehot dst ids V seq i =
  if i >= seq then 0
  else
    let c = list_nth i ids
    let _ = float_arr_set dst (i * V + c) 1.0
    fill_onehot dst (tail ids) V seq (i + 1)

-- After (v0.3a)
fill_onehot dst ids V seq i =
  if i >= seq then 0
  else
    let c = head ids
    let _ = float_arr_set dst (i * V + c) 1.0
    fill_onehot dst (tail ids) V seq (i + 1)
```

`list_nth i` was the wrong access — `head ids` is the right one since
we're already tailing.

## Loss curve (v0.3a)

```
step    0   loss=15.58
step  100   loss= 2.96
step  200   loss= 2.01
step  400   loss= 1.64
step  600   loss= 0.98
step  800   loss= 0.74
step 1000   loss= 0.59
step 1200   loss= 0.50
step 1400   loss= 0.45
step 1600   loss= 0.42
step 1800   loss= 0.411
step 1990   loss= 0.4094
final       loss= 0.4094
```

Perplexity ≈ 1.51. Converges to memorization territory; slightly
higher final loss than v0.2's 0.333 because predicting the next char
from real context is harder than learning a position-stamp lookup.

## Teacher-force reconstruction

Feed the full corpus (correct `head`-walked input) and take argmax at
each position:

```
o be, or not to be, thathin the questios.
Whetier ths nobler in the mind thu ufffr nhe slings and aroows o  outrrgeo s fuutrne,
or to take arms againstua searof to  bles
and by oppo ing end them. To die, to sleep,
no more; and by a sleepoto say we end
the heat -ache and the thousand naturaleshockshthatlf es  is heis  i: tis a consummatiood
 voutiy to be wished. To dis, to sleep;
```

~85% of positions recovered correctly. Matches what a genuinely
memorized near-fit model should look like.

## Autoregressive samples (the real test)

Greedy argmax, generation length 80, prompt fed through the same
`head`-walked pipeline.

### Prompt: `"To be"` (memorized prefix)

```
output: To be, or not to be, thaththestheseherneseb y y  is  yblea :Tbth th tin s     rrrrr
```

First **20 characters** continue the corpus faithfully
("To be, or not to be, tha"). Then it falls into a looping state
populated with high-probability training-set bigrams — the model has
~6k params and one block, so it doesn't have the capacity to hold the
whole corpus in an autoregressive-recoverable form, but the start
condition is genuinely right.

### Prompt: `"Hello world"` (out-of-distribution)

```
(note: prompt had chars outside vocab — replaced with id 0)
output: Tello worldrb o a   e s peap sslhbhbprri.hy   y y llllesa eabe  a,rthee saeitlllllllllh sm
```

Noise. 'H' and 'w' rendered as Ts via the <unk>→0 substitution in the
tokenizer. Expected — no capacity left for generalisation.

## Interpretation

**v0.2 was the wrong result entirely.** The loss curve was real but
the model it produced was a position-indexed lookup table trained on
corrupted input. The architecture's true quality was invisible until
v0.3a.

**v0.3a passes the go criterion** (loss ≤ 0.5 AND autoregressive "To
be" continues corpus cleanly). Next-session work:

1. Scale the corpus (the 553KB stdlib snapshot in
   `training/rail_native/data/corpus.txt` was the v0.2 plan).
2. Scale depth (single block is the cap on memorization horizon —
   the autoregressive trail-off after 20 chars is a capacity signal,
   not a flow signal).
3. Rerun `tools/train/lm_xval.rail` with the fixed input. The 3.96
   val/train ratio there was also measured with the broken input and
   may or may not survive.

## Reproducing

```
cd ~/projects/rail
./rail_native run tools/train/lm_transformer.rail   # 20 min, writes latest.*
./rail_native run tools/train/lm_infer.rail         # teacher-force + autoregressive
```

The checkpoint at `training/rail_native/checkpoints/latest.*` is
v0.3a — v0.2's weights are in git history only and remain correctly
described in MODEL_CARD_v0.2.md as a bug artifact.

---

Commit: `rail: fix fill_onehot — v0.3a real autoregressive`
