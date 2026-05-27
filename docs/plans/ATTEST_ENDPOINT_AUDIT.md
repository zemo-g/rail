# ATTEST ENDPOINT AUDIT — Plan

**Status:** proposal, not started.
**Date:** 2026-05-27
**Owner:** Ledatic (rail / infra lane)
**Tracked task:** #1

## 1. Why

Ledatic's verb is **physicify** — live + attested + self-hosted. The
operational form of that promise is the set of public attestation
endpoints listed in `attestation-infrastructure.md`. Each endpoint
makes a claim: "this surface is live, signed, current, and walks back
to the beacon."

Today nothing actually *tests that claim*. A 60s probe done while
writing this plan already turned up three drift cases:

| Endpoint | Claim | Reality (2026-05-27 18:13 UTC) |
|---|---|---|
| `/attest/badge/builds.json` | `141/141 · pulse <current>` | reports `138/138 · f9d9b3a-dirty · pulse 1438606` (stale by ~12000 pulses) |
| `/attest/badge/selfhost.json` | green when self-compile byte-identical | reports `drift` red, while local `./rail_native self && cmp` returned FIXED-POINT-OK 15 min earlier |
| `/fleet/status.json` | mini/studio/air alive when reachable | mini/studio/air all `alive:false` while this session is running on Mini |

Three display lies on the first probe. The badge is the most visible
piece of attestation we ship; if it's lying, the verb is lying.

This audit makes the endpoint set self-checking: every endpoint becomes
a falsifiable lab entry with kill_target, the walker runs on a cron,
and drift produces signed FALSIFIED records on the chain.

This composes with the Lakes lab plan ([[LAB_CHAIN_INTEGRATION]] in
`~/projects/ledatic-lakes/docs/plans/`) — same kernel, different
namespace.

## 2. Endpoint inventory (verify-before-coding)

Memory phrasing was "14 public endpoints"; the actual current surface
in `attestation-infrastructure.md` is 20 distinct routes (some
parameterized by `<tag>` / `<sha>`). Group them into seven claim
classes so the walker logic doesn't repeat per-route.

| Class | Routes | Claim spec |
|---|---|---|
| **Beacon** | `/entropy/pulse`, `/entropy/frame/current`, `/entropy/frame/latest.attestation.json` | pulse_id advancing every <10s; frame bytes match digest in attestation; signed by fleet0 within last 5min |
| **Witness** | `/witness/fleet0/latest` | latest signed witness pulse within last 5min; sig verifies against `/attest/fleet0.pub.pem` |
| **Fleet status** | `/fleet/status.json` | `asof_unix` within last 120s; node liveness matches actual local probe of fleet HTTP `:9101` |
| **Releases** | `/releases/<tag>/{rail_native,compile.rail,*.attestation.json}` | for every tag in `git tag --list`, artifact downloads, sha256 matches attestation, sig verifies |
| **Builds** | `/builds/<sha>/*`, `/builds/latest/index.json`, `/attest/badge/builds.json` | latest index `sha` == current `origin/master` HEAD; test count == actual `./rail_native test` last line; badge color matches PASS/FAIL |
| **Selfhost** | `/selfhost/<sha>/*`, `/selfhost/latest/index.json`, `/attest/badge/selfhost.json` | latest selfhost sha == origin/master HEAD; result == byte-identical; badge color matches |
| **Static** | `/attest/verify.sh`, `/attest/fleet0.pub.pem` | 200 + non-empty; sha256 matches the on-disk version in this repo at deploy time |
| **DDA** | `/dda/index.json`, `/dda/<model>/<week>/<vertical>/manifest.json`, `/dda/.../*.attestation.json` | every brief in manifest has a sidecar; every sidecar's pulse_id is on-chain; no orphan files |
| **Pages** | `/system`, `/ot`, `/case-campaign-intel` | served 200; embedded `_shared/*-live.js` actually fetches from the endpoints above (i.e. the page is not a static fossil) |

20 routes → 9 walker classes. Far more tractable than 20 per-route checks.

## 3. Walker design

One Rail script — `tools/lab/watchers/attest_endpoint_walk.rail` —
that runs all nine classes in sequence and writes one lab entry per
class. Mirrors the `tools/lab/watchers/jit_v2_baseline.sh` header
convention.

```
─── header ───
goal          : every public attestation endpoint matches its claim spec
hypothesis    : on a given pulse tick T, all nine classes report green
kill_target   : per-class verdict; AGGREGATE PASS iff all nine PASS
counters      : pulse_now, endpoints_probed (20),
                <class>_pass, <class>_fail, <class>_stale_seconds,
                first_failing_endpoint
─── body ───
1. fetch current pulse from /entropy/pulse
2. for each class:
     a. fetch its endpoints
     b. evaluate claim spec (see §2 table)
     c. record verdict + counters
     d. if FAIL: capture first 200 bytes of body for diagnostics
3. compose lab entry; POST to studio :9101 /lab/entry (or write local
   if running on studio)
4. exit code: 0 if AGGREGATE PASS, 1 if any class FAIL, 2 on probe error
```

Walker is **read-only** — does not heal, does not push, does not
deploy. Pure observation. The whole point is that a healer responds
to the chain, not the other way around.

## 4. Kill_targets — falsification spec per class

Each class has a concrete numeric kill criterion. **Stale-tolerance
windows are explicit so a slow tick doesn't flap red.**

| Class | PASS iff | Stale tolerance |
|---|---|---|
| Beacon | `pulse_id` advanced by ≥1 since last walk; frame digest matches sidecar | 30s (one cron period) |
| Witness | latest signed pulse age < 5min; sig verifies | 5min |
| Fleet status | `asof_unix` within 120s; declared `alive` matches `:9101/health` probe | 120s |
| Releases | every tag's sha256(artifact) == sha256 in attestation; ed25519 verify exit 0 | n/a — cryptographic |
| Builds | `builds/latest/index.json sha` == `origin/master HEAD`; badge `message` parses to (sha, X/Y, pulse) where X==Y==local test count | 24h (daily cron) |
| Selfhost | `selfhost/latest/index.json sha` == `origin/master HEAD`; result string == `byte-identical`; badge green | 24h |
| Static | sha256 matches `tools/attest/verify.sh` and `~/.ledatic/witness/fleet0.pub.pem` on disk | n/a — content-addressed |
| DDA | every `manifest.json` entry has matching `*.attestation.json` sidecar reachable 200; no dangling attestations | 7d (per-week granularity) |
| Pages | HTTP 200 + page HTML contains expected `<script src="/_shared/*-live.js">` reference | n/a |

Anything failing → FALSIFIED entry on chain with the specific class
and first failing endpoint as counters.

## 5. Already-known FALSIFIED entries (pre-walker)

Walker will fire these on first run. Pre-listing them so we don't
treat their first appearance as a surprise:

1. **Builds badge stale** — claims `138/138` and a sha that hasn't been
   master for weeks (last few master moves: 9e9fe1c → b5c45f6 →
   7d02396 → 972490e → 8c9bbe4 → 6454e7c → e66e4e7 → c8e22e2 today).
   Likely cause: `com.ledatic.attest_daily` ran with old binary or
   the badge endpoint hasn't been re-published. Need to confirm.
2. **Selfhost badge red ("drift")** — local self-compile is
   byte-identical. Either the daily attest run failed silently or the
   badge color logic is inverted. Inspection required.
3. **Fleet status all-false** — `fleet_status_publisher.sh` is
   probing TB-mesh addresses (10.42.0.1/.2/.3) that may not be
   reachable from where the publisher runs, OR the probe protocol
   broke. Cross-reference with `self_healer` event log.

These three are the **smoke-test** for the walker — if it doesn't
catch them, the walker itself is broken.

## 6. Phased rollout

**Phase 0 — Plan + acceptance (this doc; no code yet)**

Approve the claim specs in §2 and the kill_targets in §4. Decide which
classes are P0 vs P1 (recommendation: all 9 in P0; the build is a
single Rail script).

**Phase 1 — Walker v0 (1 session)**

Implement `tools/lab/watchers/attest_endpoint_walk.rail` covering all
nine classes. Output: stdout report + one local lab entry. Verify on
the three known-FALSIFIED cases.

**Phase 2 — Wire to chain (1 session, blocked by Lakes plan Phase 0)**

POST entries to `:9101/lab/entry` if the Studio endpoint exists
(Lakes plan Phase 0). Otherwise write to local chain. Add namespace
field `"attest"`.

**Phase 3 — Cron (0.5 session)**

LaunchAgent `com.ledatic.attest_endpoint_audit`, fires every 5min.
ThrottleInterval=300. StandardOutPath to `/tmp/attest_audit.log`.

**Phase 4 — Fix the three falsifications (1–3 sessions, depending on
root cause)**

- Builds badge: ensure `daily.sh` actually re-publishes the badge JSON
  with the current sha + test count. Likely 5-line fix.
- Selfhost badge: trace why daily attest ran says drift. Either fix
  the daily run or the badge color logic.
- Fleet status: rework `fleet_status_publisher.sh` to use the
  reachable address space (Tailscale IPs, not TB-mesh) or skip
  unreachable nodes with `witness:none` per the existing failure
  semantics.

**Phase 5 — Surface (optional, 0.5 session)**

`/attest/audit/latest.json` — the walker's latest verdict, public.
"Our own audit, signed, falsifiable." Phase 5 is the trust move:
publishing failed audits is the move no one else makes.

## 7. Open decisions

1. **Tolerance windows in §4** — set these by gut now or measure
   typical drift over a week first? Gut-now is fine; tighten later.

2. **Phase 5 (public audit endpoint)** — same question as Lakes plan
   §8.3: do we publish our own falsifications? Recommend yes —
   asymmetric upside, low downside (we're going to fix the three
   known ones anyway).

3. **Where the walker lives.** Recommend `tools/lab/watchers/` in the
   rail repo (alongside the existing watchers). Alternative:
   `tools/audit/` as a sibling for non-experiment audits. The lab
   convention already covers verdict + chain, so use it.

4. **DDA class** — closed engagement. Worth auditing or skip?
   Recommendation: include — the DDA index/manifest set is durable
   public reputation now. Cheap to walk.

5. **Pages class (W9)** — is checking that `/system` references
   `/_shared/system-live.js` *enough*? Or do we actually need to
   execute the JS and confirm it pulls live data? Recommendation:
   start with the reference check (cheap); upgrade to headless-fetch
   if a page-class FALSIFIED entry appears that the reference check
   missed.

## 8. Composition with Lakes plan

This and `LAB_CHAIN_INTEGRATION.md` share the same Studio HTTP route
(Lakes Phase 0). If Lakes ships first, this plan inherits the
endpoint for free. If this ships first, Lakes inherits it.

Both produce entries in the same chain, distinguished by `namespace`:
`"attest"` here, `"lakes"` there. The chain itself remains one signed
linear history.

## 9. Out of scope

- Healing. Walker observes; humans / self_healer respond.
- Backfilling missing historical attestations.
- Verifier improvements (separate audit, separate plan).
- DDA brief content audit (substrate-content audit; task #6).
