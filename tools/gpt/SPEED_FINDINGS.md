# Rail-native GPU trainer speedup (2026-07-08): measure-first

User picked "C then A" (fuse trainer, then 300M base run). Goal: make the
self-hosted Rail ijit trainer fast enough that an attested 300M run is tractable.

## Measurement (the whole point — CLAUDE.md hypothesis discipline)

Step is **~79% CPU-bound**, not GPU-compute-bound (16.75s CPU / 21.2s wall / 3 steps).
So the lever is CPU-side overhead, NOT fusing GPU math (the CLAUDE.md "35x rmsnorm+qkv"
fusion optimizes the ~21% GPU slice — wrong target).

Per-section CPU decomposition (`clock` around each stage of step_all, L=64):

| section | CPU/step | share |
|---|---|---|
| forward (16 layers) | 0.26 s | 2% |
| final LN + head | 0.003 s | — |
| CE softmax (L*vocab) | 0.07 s | 0.7% |
| head backward | 0.99 s | 9% |
| **layer backward** | **9.39 s** | **88%** |
| emb update | 0.0007 s | — |

**Layer-backward is 88%.** Forward is only 0.26s for the SAME 16 layers -> backward is 36x.
Root cause = **96 `adam_w` calls/step** (6 weights x 16 layers). Each `adam_w` does, on the
CPU, per weight (up to inter*d = 2.4M elems): 3x cpseg IN (W,m,v) + untag/retag 3n + 3x
cpseg OUT + ibuf_update re-upload ~= 10n element-ops. ~1.9B CPU element-ops/step.

**A micro-benchmark falsified the naive guess:** two chained matmuls via `ijit_run_wx` are
already cheap (400 dispatches in 0.09s) — activation round-trips are NOT the bottleneck.
The big movers are the OPTIMIZER matrices (W/m/v/dW), not forward activations.

## Built + validated: GPU-resident buffers (the mechanism)

`tensor_gpu_lib.m` + `stdlib/ijit.rail`: `abuf_alloc` / `abuf_upload` (=ibuf_update) /
`abuf_download` + `ijit_run_wxrr` (W,X,O all resident) + `ijit_run_rr`. Resident buffers hold
UNTAGGED int64 (same rep the kernels already consume), so a chain runs GPU-side with ZERO
CPU untag/retag/readback between ops. **`resident_proof.rail`: BYTE-IDENTICAL to the staged
`ijit_run_wx` path** (attestation preserved) — the critical property.

## DONE (2026-07-08): RESIDENT OPTIMIZER STATE -- ~5x less CPU, byte-identical

Shipped. W (already resident via ibuf), m, v, dW, and c1/c2 now all RESIDENT; a resident-Adam
kernel (`emit_msl_fx_adam_step_r`, dispatch `tgl_ijit_dispatch_adam_r`) reads W/dW/m/v resident
and updates W/m/v IN PLACE, GPU-side. The only CPU work left per adam call is the single dW
upload. `arith_finetune_res.rail` = the rewired trainer (wmv_load -> abuf_alloc; 96 adam_w ->
adam_w_r; resident C buffer updated per step; wcb_download restores W to Rail before save).

Validation (twin discipline):
- `resident_adam_test.rail`: resident Adam == staged adam_w BYTE-EXACT on W,M,V (inter*d=2.4M).
- CE trajectory: resident trainer == staged trainer BYTE-IDENTICAL over 5 steps (same corpus,
  same init) -> training dynamics unchanged, attestation preserved.
- Save path: wcb_download + head download + write_all_st -> valid 555MB safetensors.

Measured (5 steps, L=64, Mini M4 Pro):
| | wall | user CPU | CPU% |
|---|---|---|---|
| staged   | 82.2s | 60.6s | 74% |
| resident | 33.0s | 12.0s | 38% |
**~5x less CPU** (the 88% layer-backward adam bottleneck, gone), ~3.3x per-step wall
(amortizing startup: ~14s -> ~4s/step). Step moved from CPU-bound (74%) to GPU-bound (38%).

## Next levers (now that adam is off the CPU)
Step is now GPU-bound. Remaining CPU: forward/backward activation packing (cpseg in the LN/attn
paths) + wgrad dW readback + per-call dW upload. Options: (a) resident dW end-to-end (wgrad
writes resident -> adam reads resident, drop the dW upload too); (b) resident activations across
the layer (the original `ijit_run_wxrr`/`_rr` primitives, now free to use). Diminishing returns
vs the adam win; re-measure before building. For step A (300M), this ~3-5x already makes a
self-hosted run materially more tractable.
