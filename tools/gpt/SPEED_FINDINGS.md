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

## Next (the actual speedup): RESIDENT OPTIMIZER STATE

Keep W (already resident via ibuf), m, v, and dW RESIDENT across steps; a resident-adam
kernel reads W/dW/m/v resident and updates W/m/v IN PLACE, GPU-side. Kills the ~10n
CPU round-trip in all 96 adam_w calls -> attacks the 88%. Est. step ~10.7s -> a few s (~3-7x).
Must re-validate byte-exactness (twin discipline) after each kernel change.
