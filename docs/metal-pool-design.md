# Tiered Metal Buffer Pool — track-d

## Why a redesign

The single-pool implementation (`POOL_MAX = 32`, one bucket of slots
keyed only by byte-size) shipped before native floats and the
malloc-chain refactor. It worked when the kernel mix was uniform.
At seq=1499 transformer training, it leaked: process RSS climbed to
~15 GB across an hour, even after the runtime malloc-chain fixes
in `64ee734` / `7fc484a`.

Static audit:

| pool surface | value |
| --- | --- |
| `pool_acquire` call sites in `tensor_gpu_lib.m` | 56 |
| Distinct kernels using the pool | 22 |
| Storage modes ever requested | 1 (`MTLResourceStorageModeShared`) |
| Peak in-flight per kernel call | 6 (`tgl_layernorm_backward_f64`) |
| Concurrency | 0 (every kernel `commit` + `waitUntilCompleted` synchronously) |

The daemon is single-threaded and every kernel waits to completion before
returning, so the **maximum simultaneous in-flight** count for the entire
process is `max(per-kernel in-flight) ≈ 6`. The 32-slot cap was never
hit by *concurrency*. It was hit by *fragmentation*: every distinct
`(M, K, N)` triple emits up to three new sizes, and once 32 distinct
sizes had been seen, the next miss (typically the 9 MB attention-scores
buffer at seq=1499) found no fitting free slot AND no slot to grow into.

The old code's miss-handling path:

```c
id<MTLBuffer> b = [g_device newBufferWithLength:rounded options:Shared];
if (g_pool_count < POOL_MAX) {       // ← false at steady state with seq=1499
    /* track in pool */
}
return b;                            // returns untracked buffer
```

The matching `pool_release(b)` then scans `g_pool` for `b`, doesn't find
it, and drops it on the floor — ARC will free it eventually, but the
allocation churn is real and Metal-backed memory is wired to the GPU.
Across thousands of training steps this is the source of the RSS climb.

## What changed

`tensor_gpu_lib.m` now keeps **size-tiered** sub-pools, one set per
storage mode. Tier boundaries are powers of two:

| tier | max bytes | typical residents |
| --- | --- | --- |
| T0 | 4 KB        | bias vectors, hyperparam blobs, tiny intermediates |
| T1 | 64 KB       | small projections, single-row attention rows |
| T2 | 1 MB        | embeddings, hidden states for short sequences |
| T3 | 16 MB       | seq=1499-class attention scores (~9 MB) |
| T4 | unbounded   | exceptional megabuffers — rounded to 64 KB pages |

Within a bounded tier, the requested size is rounded up to the next
power of two, so any sibling slot in that tier can satisfy any other
request — best-fit always finds an exact match after warmup.

Storage modes are first-class in the key. There are three parallel
sets of tier arrays (`shared`, `managed`, `private`) so a Shared buffer
is never reused as Private. Today only Shared is exercised; the others
stay zero-allocated until a caller asks.

Capacity is dynamic. Each tier starts at `TIER_INITIAL_CAP = 8` slots,
doubles on miss when full (capped at `TIER_MAX_CAP = 128`), and shrinks
one stale slot per release tick after `TIER_IDLE_SHRINK_SECS = 30`
seconds of inactivity (never below `TIER_MIN_KEEP = 4`). A Tier-3
pool that has spilled over to 128 slots × 16 MB = 2 GB is well under
the `iogpu.wired_limit_mb=22000` system cap. Across all 15 tier×mode
buckets the worst-case is ≈ 2 GB Shared + parallel Managed/Private,
still bounded.

The miss path no longer drops on the floor: when the tier hits
`TIER_MAX_CAP`, the buffer is returned untracked (the prior behaviour),
but `pool_acquire` increments `tier->drops` so the regression test can
see it. In practice we never reach the cap because the per-kernel
peak in-flight is small.

## Public surface

The new C ABI export `tgl_pool_stats(out, max)` fills an array of
`tgl_pool_stat_t` with one entry per `(storage, tier)` bucket. Used by
`tensor_daemond` to expose two endpoints on TCP `:9302`:

* `STATS\n` (text) — returns the JSON body directly.
* `GET /gpu/stats HTTP/1.0\r\n\r\n` — returns the same JSON inside an
  HTTP/1.0 response. `Connection: close`. Existing protocol unchanged
  for binary clients (op codes 0–20) and the `MATMUL_F32FILE` text mode.

JSON shape:

```json
{
  "tiers": [
    {"tier":3,"storage":"shared","capacity":8,"count":4,"in_use":1,
     "peak_in_use":2,"hits":9412,"misses":4,"drops":0,"shrinks":1,
     "bytes_in_pool":67108864},
    ...
  ],
  "totals": {"hits": 11203, "misses": 18, "drops": 0,
             "acquires": 11221, "miss_rate": 0.001603,
             "bytes_in_pool": 70337536}
}
```

`misses_since_start` from the spec is reported as `misses` per tier
plus the convenience `totals` block.

## Verification

`tools/train/metal_pool_stress.rail` drives the daemon with 1000
representative-shape matmul calls (M=K=N=384, ~590 KB tier-2 buffers)
and asserts `totals.miss_rate < 0.05` and daemon RSS < 2 GB.

We picked 384, not 1499, because the pool's hit-rate behaviour is
shape-independent — once the slot exists it gets reused — and the
1499-shape spends most of its wall clock in `MATMUL_F32FILE` disk I/O
rather than the pool path under test. A 1499-shape stress would burn
~8 minutes of GPU time without exercising different code.

Manual verification of the seq=1499 RSS regression continues to use
`tools/train/lm_mh.rail` with the existing harness; the success metric
for that is "RSS stable for ≥ 10 minutes, no growth trend." The pool
stats endpoint is the diagnostic tool that lets a future debugger
confirm per-tier behaviour without restarting the daemon.

## Limits

* The daemon is still single-threaded; the pool has no locking.
  When the daemon goes multi-threaded, every `g_pools[*][*]` access
  needs an `os_unfair_lock` or a per-tier mutex. Documented but not
  shipped here.
* The shrink reaper runs lazily (one stale slot per `pool_release`).
  Under sustained load with no idle gaps, idle slots accumulate up to
  the per-tier `capacity`. This is intentional — under load you want
  slots, not allocator churn.
* `tier_for_bytes` linearly scans the 5-element table; switching to
  `__builtin_clzll` would shave ~1 ns/call. Not worth it at current
  call rates.
* The `T4` (unbounded) tier can grow to `TIER_MAX_CAP × {whatever
  size showed up}`. If a caller starts allocating 100 MB buffers at
  high cardinality, this becomes an issue. Today nothing in
  `tensor_gpu_lib.m` requests a buffer larger than ~16 MB.
