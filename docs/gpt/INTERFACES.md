# Rail GPT — Phase 0 Frozen Interfaces

**Branch:** `feat/rail-gpt-unify` (off `feat/attested-int-gpu-kernels` @ `09aed3a`).
**Status:** FROZEN. Every later phase builds against these four contracts. Changing one is a deliberate, reviewed event.
**Spine:** GPT-2 family, F=24 / Q39.24 — the family of the model we own (`rail-training/attested-base/pilot/gpt.py`, `mid` preset).

---

## 1. Canonical model — the `mid` 138M we own

Authoritative source: `attested-base/pilot/gpt.py` GPT class + `mid` preset.

| Field | Value | Notes |
|---|---|---|
| n_layer | 16 | |
| d_model | 768 | |
| n_head | 12 | head_dim = 64 |
| d_ff | 3072 | = 4·d_model |
| block_size (ctx) | 512 | learned positional embedding, `nn.Embedding(ctx, dim)` |
| vocab_size | load-time | byte-level BPE; set from checkpoint meta, never hardcoded |
| norm | LayerNorm **with bias** | pre-norm: `x=x+attn(ln1(x))`, `x=x+mlp(ln2(x))` |
| activation | GELU | |
| attention | standard MHA (not GQA) | self-attn q=k=v=ln1(x); additive causal mask; **proj bias=False** (verified from real weights — MHA defaults bias=False) |
| head | `Linear(d_model, vocab, bias=False)` | **UNTIED**, no bias — separate from token embedding |
| tie_head | 0 (untied) — DECIDED | Owned 138M is trained untied; tying would make our weights un-loadable/un-witnessable and forces dense Adam over 12.6M embed rows (fights sparse-SGD embed + dense-Adam head). Flag reserved for future from-scratch small runs where the ~9% saving + regularization may help. |
| loss | mean CE over ALL T positions | matches `loss_fn`; last-position is the weaker witness metric |
| fbits | 24 | Q39.24 fixed-point substrate (fixed for the whole stack) |

Other presets (`gpt.py:59-67`) parameterize the same class: tiny 128/4/4, small 512/8/8, mid2 1024/24/16. `GptConfig` carries all four architecture dims so any preset loads.

---

## 2. `GptConfig` — packed flat array (Rail high-arity SIGSEGV → bundle, never pass loose)

Index → field (integers only):

```
[0] n_layer      [1] d_model     [2] n_head      [3] head_dim   [4] d_ff
[5] block_size   [6] vocab_size  [7] fbits(=24)  [8] tokenizer  [9] seed   [10] tie_head
```

`tokenizer`: 0=char, 1=bpe. `seed`: reproducible init + data-order (attestable). `tie_head`: 0=untied (default, owned model), 1=tie (future runs only). Canonical builder `gpt_config_mid vocab seed` (2-arg, arity-safe). Accessors `gc_*` by index. Reference impl: `stdlib/gpt/gpt_config.rail`.

---

## 3. `GptWeights` — full tensor set (closes the head-only checkpoint gap)

Every trainable tensor, in canonical serialization order. This is the COMPLETE set the checkpoint must persist — no more head-only.

All Linear weights stored **RAW [out, in]** row-major (nn.Linear), indexed `W[o*in+i]` — NO transpose (matches raw safetensors + the certified fx_matmul_wx kernel). Verified: this layout reproduces the owned 138M's argmax 5836.

```
tok.weight            [vocab, d_model]   (row lookup by token id)
pos.weight            [block_size, d_model]
-- per layer i in 0..n_layer-1 (×16):
  blk.i.ln1.weight    [d_model]        blk.i.ln1.bias    [d_model]
  blk.i.attn.q.weight [d_model,d_model]   (query_proj.weight, BIAS-FREE)
  blk.i.attn.k.weight [d_model,d_model]   (key_proj.weight,   BIAS-FREE)
  blk.i.attn.v.weight [d_model,d_model]   (value_proj.weight, BIAS-FREE)
  blk.i.attn.o.weight [d_model,d_model]   (out_proj.weight,   BIAS-FREE)
  blk.i.ln2.weight    [d_model]        blk.i.ln2.bias    [d_model]
  blk.i.mlp.up.weight [d_ff,d_model]   blk.i.mlp.up.bias  [d_ff]   (mlp.layers.0)
  blk.i.mlp.dn.weight [d_model,d_ff]   blk.i.mlp.dn.bias  [d_model] (mlp.layers.2)
lnf.weight            [d_model]        lnf.bias           [d_model]
head.weight           [vocab, d_model]   (bias-free)
```

**Real model = 197 tensors** (5 + 16·12): attention projections are bias-free.
The in-memory forward array keeps a uniform 16-slot/layer stride (261 slots) with
**zero arrays in the 4 absent attn-bias slots**, so `gp_forward` needs no special-casing (a zero-bias add is a no-op). Names map 1:1 to HF/MLX safetensors keys (`blocks.{i}.attn.query_proj.weight`, `mlp.layers.0/2.weight`, …) for load + `export`.

---

## 4. Checkpoint format — full-tensor, Python-reproducible

Length-prefixed integer stream (dodges the Rail `cat`-drops-NUL trap; every field re-readable by Python for cross-verify).

```
MAGIC     "RAILGPT1\n"
config    10 ints (GptConfig), space-separated, "\n"
n_tensors int, "\n"
-- per tensor (canonical order §3):
  name    len-prefixed string
  ndim    int ; dims int*ndim
  fbits   int (=24)
  data    numel int64 fixed-point values (Q39.24), space-separated
-- optimizer state (present iff training checkpoint):
  opt_present  0|1
  step         int
  per tensor:  m (numel int64) ; v (numel int64)     -- Adam moments, same order
config_sha256  hex (sha256 of the config line)
```

`m`/`v`/`step` persisted so bias-correction exponent survives resume (dropping `step` resets it to 1 — a real hazard). Reader asserts every dim against `GptConfig`; loud fail on mismatch, never silent truncate.

---

## 5. Ledger record — canonical, sorted-key, integers-only (closes the correspondence hole)

One schema for train (mode A) and witness (mode B). JSON-lines, keys lexicographic, `json.dumps(sort_keys=True)` separators — hashes reproduce cross-language. **No float in any hashed field.**

```
{ "batch_sha256":  <hex, sha256 of comma-joined token-id TEXT of the window(s)>,
  "loss_mean_f24": <int, all-position mean CE in Q39.24 — the TRAIN metric>,
  "mode":          "train" | "witness",
  "optstate_sha256":<hex, sha256 of m||v>,             -- makes resume attestable
  "prev_hash":     <hex>,
  "ptgt_f24":      <int, last-position prob of true token, Q39.24 — witness metric>,
  "step":          <int>,
  "target":        <int, true next-token id>,
  "weights_sha256":<hex, sha256 of the ACTUAL pre-step weights (recomputed), NOT w0>,
  "record_hash":   <hex, appended out of sort-order; verifier pops+re-sorts> }
```

**Correspondence rule (the keystone):** `verify`/`witness` re-runs `gpt_forward` over checkpoint+corpus bytes and asserts the recorded `loss_mean_f24`, `ptgt_f24`, `weights_sha256` all reproduce. A chain that links but whose losses don't reproduce = FAIL. This is the automated A-vs-B comparator that does not exist today.

**Signing/anchoring:** ledger tip digest = `sha256("railgpt|v1|<tip_record_hash>|steps<N>|<pulse_id>")`, Ed25519-signed by fleet0 (Pi), pulse bound *inside* the digest (replay-safe). Reuses `tools/attest/pi_sign_server.rail` + `finalize_sign.py`.

---

## Overflow contracts (L0 — enforced at runtime, not by comment)

Every fx kernel's precondition (bounds on `|x|`, `d`, shift) becomes a runtime assert. The 63-bit-Rail vs 64-bit-Metal wrap is the one place twins silently diverge (caught once at 1/√d); asserts turn silent divergence into a loud abort. Q39.24: `eps=1e-3` (16777) is the representability floor — 1e-8 underflows to 0. Documented, not tunable without widening F.
