# Phase-2 Milestone — Public Rail Playground v0

**Status:** [ ] DEPLOYED  (mark `[x]` ONLY after deploy_playground.sh
completes successfully and tests/playground_acceptance.sh returns 0
from a non-Studio machine.)

**Date:** TBD (fill in at deploy time, ISO 8601, e.g. 2026-05-13T18:00-04:00)

## Deploy fingerprint

| Field             | Value                                                                |
|-------------------|----------------------------------------------------------------------|
| Rail commit       | TBD (cd /Users/user/projects/rail && git rev-parse HEAD at deploy)   |
| ledatic-site SHA  | TBD (cd /Users/user/projects/ledatic-site && git rev-parse HEAD)     |
| Worker version    | TBD (Cloudflare-assigned ID; capture from deploy_worker.sh output)   |
| Mini binary mtime | TBD (`ssh mini.tb stat -f %Sm tools/playground/compile_server`)      |
| Public URL        | https://ledatic.org/playground                                       |
| API endpoint      | https://ledatic.org/api/playground/compile                           |
| Backend (private) | http://100.79.50.108:8090 (Mini Tailscale, com.ledatic.playground)   |
| Metrics endpoint  | https://ledatic.org/api/playground/metrics  (Bearer API_BEARER)      |

## Acceptance test results

Run from a NON-Studio machine (per spec). Paste the tail here:

```
$ bash tests/playground_acceptance.sh
Endpoint: https://ledatic.org/api/playground/compile

  [case] echo + arithmetic
    PASS  exit=0 stdout_len=...
  [case] recursive factorial
    PASS  exit=0 stdout_len=...
  [case] ADT pattern match
    PASS  exit=42 stdout_len=...

Result: PASS=3 FAIL=0
PHASE-2 MILESTONE: MET
```

## Verification matrix

- [ ] `curl -sI https://ledatic.org/playground` → HTTP 200, content-type text/html
- [ ] `curl -X POST https://ledatic.org/api/playground/compile -d '{"src":"main = 42"}' -H 'content-type: application/json'` → `{"ok":true,"wasm_b64":"...","build_ms":N}`
- [ ] Browser test on Air (or non-Studio Mac): load /playground, click Run, verify output area shows expected stdout for each starter
- [ ] Rate limit smoke: 11 rapid POSTs from one IP → 11th returns HTTP 429
- [ ] Sanitizer smoke: POST `{"src":"main = let _ = shell \"x\" in 0"}` → `{"ok":false,"error":"sanitize: banned token: shell"}`
- [ ] Metrics endpoint reachable with bearer: `curl -H "Authorization: Bearer $API_BEARER" https://ledatic.org/api/playground/metrics` → counters JSON
- [ ] Mini service auto-restart: `ssh mini.tb killall -9 python3` then re-curl /api/playground/compile within 30s — should succeed (KeepAlive respawned)

## Session C deliverables shipped (staged for deploy)

- `tools/http_server.py` — recv-loop fix (32 KB body cap, was 8 KB single recv)
- `tools/playground/com.ledatic.playground.plist` — Mini launchd agent
- `tools/test/playground_recv_loop_smoke.sh` — local 20 KB POST round-trip test
- `worker/worker.js` — KV-backed rate limiter + metrics inline + /api/playground/metrics route
- `worker/playground_metrics.js` — standalone reference for the metrics module (kept in sync with inline)
- `tests/playground_rate_limit_smoke.mjs` — 12 jsc-runnable assertions on limiter+metrics
- `deploy_playground.sh` — orchestration with --dry-run, --rollback, --from-step
- `tests/playground_acceptance.sh` — phase-2 milestone gate

## What this unblocks (phase 3)

- **External pilots can now run.** Anyone with the URL can paste a Rail
  program, run it in their browser, see output. No accounts. No
  install. No GitHub. The sole on-ramp from "heard about Rail" to
  "ran a Rail program" is now ≤ 30 s and zero credentials.
- **Pitchable surface.** `https://ledatic.org/playground` is the
  artifact for `notes/phase3_external_pilot_pitch_v0.md` — that doc
  can stop being theoretical.
- **Honest dogfood loop.** Spec authors / docs writers can paste
  examples directly into the playground to verify they compile, instead
  of running `./rail_native wasm` locally. The playground IS the docs'
  test harness.

## What's still gated on user authorization

Run from Studio (or wherever has SSH to Mini and CF_TOKEN):

```bash
bash /Users/user/projects/ledatic-site/deploy_playground.sh
# verify this looks right; then on a non-Studio Mac:
bash /Users/user/projects/ledatic-site/tests/playground_acceptance.sh
# if PASS=3 FAIL=0, edit this file's [ ] DEPLOYED -> [x] DEPLOYED
# and fill in the TBD fingerprint fields above.
```

If anything fails, rollback:

```bash
bash /Users/user/projects/ledatic-site/deploy_playground.sh --rollback
```

## Known v0 limitations (carried forward from Sessions A + B)

- Browser 5 s timeout uses `Promise.race`; cannot preempt sync wasm
  infinite loops. The Worker's 8 s upstream `AbortSignal.timeout`
  + Session A's 5 s subprocess cap are the real backstops. Tail
  latency capped at 8 s; client UI may freeze briefly on sync-heavy
  programs. Acceptable for v0.
- Rate limiter is best-effort (KV last-writer-wins); a couple of
  concurrent requests could each see N and both write N+1. Strictly
  under-rejects (looser than 10/min, never tighter). Acceptable.
- Metrics also KV-backed and best-effort; treat as ballpark.
