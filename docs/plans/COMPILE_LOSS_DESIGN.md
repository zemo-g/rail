# Compile-Loss-During-Training — design

## Why

Compile rate at single-sample is the wall (`memory/compile_zero_wall.md`).
Architecture isn't the lever; corpus alone isn't either. The strongest
remaining signal — the compiler itself — is currently used only at eval
and rerank time, never during training. Wiring it into the training loop
turns rerank-N=20's 25/30 into a per-step training signal.

## Core idea — online RFT

Every K steps:

1. Pause forward/backward.
2. Spawn N rollouts at current weights.
3. Compile each via `rail_native`.
4. Append compiling rollouts to the training corpus on disk.
5. Re-load corpus into `corpus_ids_arr`.
6. Resume training; future `sample_chunk` calls naturally draw from
   the augmented corpus, so the model gets full CE-loss training on
   its own positively-verified samples.

This is REINFORCE-style positive-only RFT. No baseline, no advantage,
no policy gradient — just "the compiler said this was good, train on
it again." Cleaner than reward-weighted gradients and zero new math.

## Cost analysis

- Rollout (max=64, CPU, KV-narrowing): ~30 sec per seed
- Parallel batch of N=10 rollouts × 5 prompts = 50 rollouts: ~3-5 min
- Compile each: ~0.5 sec × 50 = 25 sec serial
- Total per harvest: ~5 min

At K=300 steps and 3000 total: 10 harvests × 5 min = 50 min added.
Training currently ~80 min for d=384 × 3000 steps → 130 min total.
+62% wall time for the strongest available training signal.

## Components shipped (this session)

### 1. `tools/train/rollout_harvest.sh`

Standalone harvest sidecar:
- `CKPT=<prefix> N_SEEDS=10 MAX=64 K=10 TEMP=0.8 OUT_CORPUS=path tools/train/rollout_harvest.sh`
- Spawns prompt × seed rollouts in parallel via `/tmp/rail_infer_cpu`
- Compiles each, appends survivors to `OUT_CORPUS`
- Prints `harvest: pass=X/Y appended_bytes=Z corpus=PATH wall=Ns`
- Always exit 0 so trainer doesn't crash on harvest failure
- 5 fixed prompts covering bench bands (fund, io, comp)

### 2. This design doc.

## Components TODO (future session)

### A. Trainer-side `maybe_harvest` helper

In `tools/train/lm_v08_compileloss.rail` (fork v0.7), add:

```rail
harvest_interval = 300
self_corpus_path = "training/corpus_self_distill.txt"

maybe_harvest step ckpt_prefix =
  if step % harvest_interval == 0 && step > 0 then
    let cmd = cat ["CKPT=", ckpt_prefix,
                   " N_SEEDS=10 MAX=64 K=10 TEMP=0.8 NO_WS=16 ",
                   " OUT_CORPUS=", self_corpus_path,
                   " tools/train/rollout_harvest.sh"]
    let _ = shell cmd
    1  -- signal "corpus changed"
  else
    0
```

### B. Corpus reload after harvest

The current trainer reads corpus once into `corpus_ids_arr`. After
harvest, it must re-encode and reload. Options:

**Option B1 — full reload:**
```rail
reload_corpus batch_ctx vocab =
  let combined_path = "/tmp/v3e_plus_self.txt"
  let _ = shell (cat ["cat ", corpus_path, " ", self_corpus_path,
                      " > ", combined_path])
  let new_text = read_file combined_path
  let new_ids = encode_to_int_array vocab new_text
  -- corpus_ids_arr is at batch_ctx[2]; replace it
  ...
```

The complication: `batch_ctx` is a cons-list, and replacing the third
element while keeping the same arena allocations is fiddly. Simpler:
`batch_ctx[2]` is an `int_array_new` ref; allocate a new (larger) array
and rebuild the cons-list. Float-arr aliasing rules say the old array
becomes garbage at next `arena_reset`.

**Option B2 — corpus-doubling buffer:**
Pre-allocate `corpus_ids_arr` at 2× original size. After harvest, write
new ids past the original tail. `corpus_len` is also at `batch_ctx[4]`
— bump it. No reallocation.

B2 is cheaper and safer; it caps corpus growth at 2× (about 1.2 MB)
which is well below the float-TCO 1.5 MB segfault threshold.

### C. Wiring into m_train_loop

Replace the existing line at v0.7 lm_v07_d384_minckpt.rail:723:

```rail
let _ = maybe_save_best mean weights_flat adams_flat best_buf step ckpt_best
```

with:

```rail
let _ = maybe_save_best mean weights_flat adams_flat best_buf step ckpt_best
let harvest_flag = maybe_harvest step ckpt_best
let _ = if harvest_flag == 1
        then reload_corpus_b2 batch_ctx vocab
        else 0
```

### D. Validation signals

After integration, the eval log should show:
- Pre-harvest baseline compile rate (run rollout_harvest.sh standalone)
- Post-harvest compile rate at each `harvest_interval`
- Trend: rising = working; flat = ineffective; falling = mode collapse

## Failure modes to watch

1. **Mode collapse to single program.** If model harvests "main = 0" 50
   times and that becomes 30% of the corpus, training will collapse to
   that pattern. Mitigations:
   - dedup rollouts within a harvest (same string → keep one)
   - cap self-distill corpus at max_self_bytes (e.g., 200 KB)
   - rotate prompts so we don't harvest all-same-prompt continuations

2. **Compile rate stays at zero.** If model never compiles anything in
   harvest, corpus doesn't grow, training reduces to v0.7. Acceptable
   degenerate behavior — no harm done.

3. **Corpus growth bloats memory.** Pre-cap with B2's 2× allocation.

## Sequencing

This design ships:
- **Now:** rollout_harvest.sh (callable standalone for measurement)
- **Next session:** trainer fork lm_v08_compileloss.rail with B2 +
  maybe_harvest wiring
- **Following:** train v0.8 with compile-loss enabled, compare to v0.7
  BEST under same mini-bench

## Cross-references

- Compile-zero wall: `memory/compile_zero_wall.md`
- Min-checkpoint lever (already integrated in v0.7): `memory/min_checkpoint_lever.md`
- CPU substrate (rollout backbone): `memory/cpu_inference_substrate.md`
- v0.7 trainer (fork target): `tools/train/lm_v07_d384_minckpt.rail`
- Quick-sample reference (parallel pattern): `tools/train/quick_sample.sh`
