# Plan: fix the GPU substrate body-fp16 divergence

## What we just learned (2026-05-09)

`tools/diagnose/forward_diff_analyze.sh` produced the first per-layer
CPU↔GPU table on `smoke_v54_repro_best`:

| Layer | max_abs_delta | mean_abs_delta |
|---|---:|---:|
| x_embed | 1.79 | 0.21 |
| block0_x_attn | 117 | 34 |
| block0_x_out | 978 | 357 |
| block1_x_attn | 957 | 350 |
| block1_x_out | 1614 | 666 |
| x_final | 2.69 | 1.12 |
| logits | 4.23 | 0.92 |

Body residuals diverge three orders of magnitude beyond fp16 quantization
noise. RMSNorm before unembed rescales x_last back to unit-RMS so logits
delta is bounded — but ~4 max_abs is enough to flip top-k ranks (the
`v54_fp32logits_partial_lift` regression was 9/30 CPU → 0/30 mixed).

The dump points we have are POST-residual. We don't yet know which op
inside the block triggers the explosion.

## Why fix this at all

Substrate parity would unblock 10–100× faster bench iteration on Spur via
GPU. Independent of `comprehension_cracked_substrate` (Qwen+spec at 30/30 is
the project flagship); this is Spur-internal infrastructure that pays off
across any future small-model training run.

If body precision turns out to be structurally insufficient, the same
table tells us "stop trying" with a hard number — also valuable.

## Hypotheses (each falsifiable in Stage 1)

| H | Hypothesis | Falsification signal |
|---|---|---|
| H1 | One specific kernel has a bug → divergence has a single sharp spike at one within-block op | If table is monotone-smooth across all ops, H1 is out |
| H2 | RoPE phase or softmax-over-seq mismatch → spike at the position-dependent op (RoPE-Q, RoPE-K, attn_scores, softmax) | If those ops match within fp16 noise, H2 is out |
| H3 | Compound fp16 precision through 9 matmuls per block → smooth growth across every matmul, no single spike, with quasi-geometric growth ratio | If growth is sub-linear or bursty, H3 is out |
| H4 | f32→fp16 weight repacking loses critical dynamic range for this checkpoint specifically | If x_embed delta scales with weight max-abs (high-mag weight rows have higher delta), H4 is supported. Independent of H1-H3 — this lives in the load path. |

## Stage 1 — within-block instrumentation (1–2 hr)

Add 14 dump points inside `infer_block_fwd` in `tools/diagnose/forward_dump_gpu.rail`
and `tools/diagnose/forward_dump_cpu.rail`:

```
ln1            (post first RMSNorm)
q              (post Q projection)
k              (post K projection)
v              (post V projection)
q_rope         (post RoPE on Q)
k_rope         (post RoPE on K)
attn_scores    (post Q·Kᵀ matmul, pre-mask)
scaled         (post 1/√d scale)
attn_softmax   (post softmax)
attn_val       (post attn·V matmul)
attn_out       (post attn output projection)
x_attn         (post residual — exists)
ln2            (post second RMSNorm)
h_gate         (post gate projection)
h_up           (post up projection)
h_silu         (post SwiGLU activation)
h_act          (post element-wise multiply)
h_out          (post down projection)
x_out          (post residual — exists)
```

Run on the same `smoke_v54_repro_best` ckpt + `main = ` prompt as Stage 0
so we can pair the new table against the existing residual-only table for
sanity.

**Deliverable**: a table with ~20 rows per block. The shape of the curve
identifies the failing hypothesis directly. Feed back into Stage 2.

**Cost guard**: 28 dumps/forward × ~25 KB/dump = ~700 KB on disk, ~30 ms
extra wall time per forward. Heavy but bounded; the join fix already
proven at 8 dumps.

## Stage 2 — triage by Stage 1's curve shape

### 2A — H1 confirmed: specific kernel bug (2–6 hr)

If ONE op shows a sudden >10× jump above the running compounded drift:

1. `nm -gU tools/metal/libtensor_gpu.dylib | grep tgl_<op>` → confirm symbol
2. Open the kernel in `tools/metal/tensor_gpu.metal`. Common bugs:
   - Wrong loop dimension order (k×n vs n×k accumulation)
   - Missing zero-init of `float acc = 0.0;` per output element
   - fp16 → fp32 cast applied AFTER multiply rather than before (saturation)
   - Bias-handling mismatch (Rail-side has no bias in attention; kernel may add stale)
3. Patch, rebuild dylib (`tools/metal/build.sh` or equivalent — check
   memory `dylib_rebuild_hang.md` for the .pre-rebuild restore step), rerun
   Stage 1 → divergence at that op should drop to compound-precision floor.

### 2B — H3 confirmed: compound fp16 precision (multi-day or accept)

Smooth monotone growth, no single spike. Body fp16 simply can't represent
the dynamic range of activations.

Three options, in order of cost:

- **2B-i (ship, no fix)**: Document. Update `cpu_inference_substrate.md`
  to be the formal recommendation. Accept GPU substrate as inference-only
  (when top-k fidelity isn't required), retire it as a bench oracle.
  0 cost.
- **2B-ii (~1 day)**: Add bf16 path. bf16 has 8-bit mantissa (worse than
  fp16's 10) but full f32 exponent range — covers the dynamic range that
  fp16 saturates in. Requires a new `matmul_bf16` kernel + `bf16_of_tensor`
  packing. Then re-run Stage 1 — if divergence drops to <10 max_abs at
  block layers, ship bf16 substrate.
- **2B-iii (multi-day)**: Train next model with fp16 quantization-aware
  loss (clip activations to a learnable scale, force the body into a
  representable range). Affects the next training run, not existing
  Spur ckpts. Lowest priority.

### 2C — H2 confirmed: RoPE phase or softmax-over-seq mismatch (2–3 hr)

Spike at one of `q_rope`, `k_rope`, `attn_scores`, `attn_softmax`.

CPU narrowed substrate sees `[active, d]` shapes; GPU full-seq sees
`[seq, d]`. RoPE encodes position via `pos_idx`. Softmax normalizes over
the key dimension. If positional indexing differs between substrates'
internal representations, scores diverge.

Fix: align position computation. The CPU substrate's `infer_forward`
takes the active dim; check it passes `active` (not `seq`) to RoPE +
softmax. The GPU substrate uses `seq=1024` everywhere. Equalize.

### 2D — H4 confirmed: weight repacking (1 hr)

If x_embed delta has high variance per weight row (some rows clean, some
catastrophic) AND correlates with weight magnitude, the f32→fp16 pack at
`half_of_tensor` is the culprit. fp16 saturates at ±65504 absolute and
loses precision symmetrically per binade.

Diagnostic: dump `w_e` (CPU side, full f32) and `w_e_h` (GPU side, fp16
unpacked back to f64) and tabulate per-row max-abs delta vs per-row max-abs
weight magnitude. High correlation → confirmed.

Fix: scaled fp16 — store a per-row (or per-tensor) scale factor, divide
weights by scale at pack, multiply output by scale at unpack. ~30 lines
of stdlib changes + matching kernel update. Cost: 4–6 hr.

## Decision tree

```
Stage 1 → look at within-block table
  ├── one big spike at a non-position op?      → 2A
  ├── one big spike at q_rope/k_rope/softmax?  → 2C
  ├── smooth monotone growth across all ops?   → 2B
  └── x_embed scales with weight magnitude?    → 2D (in addition to one above)
```

The branches are mutually informative — Stage 1 identifies them all in
one run.

## Risk register

| Risk | Mitigation |
|---|---|
| `dump_tensor` interleaved with forward changes timing → may mask Heisenbugs | Run Stage 1 with a "no-dump" control (just measure walltime + final logits) — if no-dump produces same logits, dumps are non-perturbing |
| CPU substrate has its own bug that makes it the wrong reference | Run Stage 1 on a SECOND ckpt (e.g., spur_v48_back_quarter_seed=100) — same divergence pattern → CPU is consistent oracle, different pattern → CPU has ckpt-dependent bug |
| `arena_reset` heisenbug (cpu version line 305) limits per-iter memory bracket | Stage 1 runs single-forward only (--max 1), no gen_loop, no arena_reset — bug surface not exercised |
| 28-dump volume re-triggers join leak surface | join is fixed (200× margin); 28 dumps × ~25 KB = ~700 KB total — orders below the new ceiling |
| inference_seed_segfault on CPU bin at certain seeds | Stage 1 uses --max 1 not --k 10 sampling — segfault is sampling-path specific |

## Dependency on the substrate thesis

Per `comprehension_cracked_substrate.md` (Qwen + 1KB spec → 30/30), Spur
is no longer the bench-cracker. So this fix is **infrastructure for
Spur-internal training + future model work**, not the project's headline
metric. If Stage 1 reveals 2B (multi-day for the real fix), 2B-i (document
and accept) is the right call until/unless we restart Spur scaling.

## Concrete next step

Single command: write `tools/diagnose/forward_dump_blockfine_{cpu,gpu}.rail`
with the 14 added dump points, rebuild bins, run on
`smoke_v54_repro_best`, run analyze. Total walltime ~5 min including
build. Decision branch decided same session.
