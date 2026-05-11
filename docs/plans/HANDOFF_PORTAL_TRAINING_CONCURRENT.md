# Handoff — Auto-attestation is live + Portal/Training concurrent-resource analysis

**Date:** 2026-05-11
**Authored after:** v54 sweep paused (PID 63928 STAT=T), DDA report delivered, user asked "what about #1".

---

## Status: Provenance auto-attestation is ALREADY integrated

`provenance_tier_shipped_2026-05-09.md` lists "DDA portal `/attest` integration"
as Phase 2 deferred. **That's stale.** The integration shipped the same day. Verified
2026-05-11.

### What's live

- `dda_portal_server.py:_attest_response` (line 337) calls
  `~/projects/dda-poc/tools/report_attestation_publisher.sh` after every
  successful job
- Background job thread invokes it (line 402-407), folds `verify_url` /
  `manifest_url` into the `/dda_job/<id>` GET response (line 487)
- Each report gets `report_id = rep_<job_id>` and a manifest at
  `https://ledatic.org/provenance/manifest/<id>` plus `/verify/<id>`
- Recent operational evidence: log lines like
  `2026-05-09 13:50:30 INFO attest fbe5462d893a499c ok: https://ledatic.org/verify/rep_fbe5462d893a499c`
- End-to-end curl verified 2026-05-11 — manifest endpoint returns 200 JSON,
  verify page returns 200 HTML, weights_hash matches the live 122B model

**Action:** Update `provenance_tier_shipped_2026-05-09.md` to reflect "live"
status. Mark Phase 2 done. The actual remaining Phase 2 items are
multi-witness (for the Audit tier) and the affidavit template generator.

### Latent concern — NameError on weights_hash fallback

`_resolve_weights_hash` (line 119) can hit the `log.warning` calls inside
its except clause. `log` is defined at line 116, so this works in the
current version of the file. The traceback in `~/Library/Logs/ledatic/dda_portal.err`
showing `NameError: name 'log' is not defined` is from a historical pre-fix
run — every restart since 2026-05-09 13:47 has resolved weights_hash
successfully via SSH to Studio. Not action-needed but worth knowing.

### Operational note

Latest `/dda_health` ping returned 401 (auth-required, which is correct —
the endpoint expects a token). That's not a regression.

---

## Portal + Training concurrent: resource analysis

### Studio inventory (M1 Ultra, 64 GB unified memory)

| Component | Memory | GPU |
|---|---:|---|
| OS + headroom | ~8 GB | idle |
| 122B teacher (MLX server, port 8082) | ~16 GB | bursts during inference (30 s – 2 min per query) |
| v54 trainer (d=256, 2-block, fp16 weights) | ~6-10 GB | sustained, moderate (matmul-heavy) |
| Buffer | ~30-34 GB | shared bandwidth |

Memory: comfortably under half utilized. **No memory pressure risk.**

### GPU contention model

- **Portal queries:** sporadic. Production traffic the last week is
  ~5-10 queries/day per `~/.ledatic/dda_portal/questions.jsonl`.
  Each query holds GPU for `elapsed_ms` in the log (typically 3-120 seconds).
- **Training:** continuous matmul during forward + backward. Saturates
  ~50-70% of GPU when alone; drops to ~30-50% when a portal query is in flight.
- **Studio panic precedent** (per `studio_panic_pattern.md`): historical
  panics were `parallel_rerank N=20 bench × concurrent training` — both
  sustained heavy loads. Portal traffic is **bursty**, not sustained.

### Empirically observed today

When I ran the bench loop yesterday (sustained 25-45 min runs) concurrent
with d=384 training, the bench slowed to ~2.5× normal wall-clock but no
panic occurred. That tells us **bench × training is the higher-risk stack**
than portal × training.

### Recommendation

**Safe to resume the v54 seed sweep concurrent with portal:**

1. The sweep is 4 sequential trainings, no bench in the inner loop.
   Each training holds the GPU at ~50% utilization for ~84 min.
2. Portal queries arrive sporadically. Expected impact: a single query
   adds ~1-3 min to the affected training (it pauses-equivalent during
   GPU contention, then catches up).
3. Watchpoint: if portal traffic surges (>10 queries/hour for sustained
   period), pause the sweep via `kill -STOP <pid>` until traffic returns
   to baseline.

**Stop conditions for the sweep:**
- Studio panic (configd watchdog) — kill both, restart serial
- Any training step NaN — kill the affected seed, move to the next
- Portal latency p95 climbs above its baseline by 2× sustained — pause
  training, the user may have a client demo in progress

### What's running right now (paused, ready to resume)

- v54 sweep orchestrator: PID 63928 (STAT=T, run_v54_sweep.sh)
- seed=100 trainer: PID 63975 (STAT=T, /tmp/train_v54_s100)
- d=384 training: KILLED earlier (PID 63461 terminated)
- DDA portal: still running on Mini :9105, healthy

To resume: `kill -CONT 63928 63975`

To resume from a fresh start (e.g. if the seed=100 state was corrupted):
- `pkill -9 -f train_v54_s100`
- `pkill -9 -f run_v54_sweep`
- `/tmp/run_v54_sweep.sh > /tmp/v54_sweep.log 2>&1 &`

---

## Memory entries to update

- `provenance_tier_shipped_2026-05-09.md` — strike "DDA portal /attest
  integration deferred to Phase 2"; replace with "integrated 2026-05-09,
  live verified 2026-05-11"

## What we're NOT doing this session (per the user's "weigh continuing")

- Distillation harvest from live 122B traffic (option 2 from the ranked
  next-work list)
- Compile-loss using 122B as oracle (option 3)
- Multi-witness for Audit tier (option 4)
- Portal hardening / rate limits (option 5)

Those wait on the user's call.
