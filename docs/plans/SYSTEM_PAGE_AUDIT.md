# SYSTEM PAGE AUDIT — Plan

**Status:** proposal.
**Date:** 2026-05-27
**Owner:** Ledatic (site lane)
**Tracked task:** #2

## 1. Why

`/system` is the mission-control page — the first surface a prospect
reads. The endpoint walker (task #1) already audits the live endpoints
it pulls from. This plan handles the *other* class of claims on the
same page: **static strings hand-edited into `system.html` that
depend on substrate state**.

The page lives at `~/projects/ledatic-site/system.html` (244 lines,
hand-authored per the ledatic-site repo's CLAUDE.md). Updates are
manual edits. That is the audit gap: nothing checks the strings.

A 60-second probe surfaced one drift already:

| Static string in `system.html` | Substrate truth |
|---|---|
| `RAIL v5.1.0 · 140/140` (page header) | `RAIL v5.1.0 · 141/141` (t135 added 2026-05-22) |

One discovered drift is enough to justify the audit. Others likely
exist — version pins, byte sizes, file paths — and they'll be
catalogued by the walker's first run.

This plan composes with task #1: the endpoint walker covers live
attestation surfaces; this walker covers hand-edited page strings.
Same chain, different namespace (`"site"`).

## 2. What counts as a substrate-dependent claim

A claim is **substrate-dependent** iff there exists a programmatic
truth-source against which it can be compared. Pure-prose claims
("Detroit, MI" as HQ) are *not* substrate-dependent — they're
identity, not state.

Substrate-dependent claim classes on `/system`:

| Class | Example string on page | Truth source |
|---|---|---|
| **Rail version** | `RAIL v5.1.0` | latest git tag `v*` in `~/projects/rail` |
| **Test count** | `140/140` | `./rail_native test` last-line `141/141 tests passed` |
| **Stdlib module count** | "94 modules" (if present) | `ls stdlib/*.rail | wc -l` |
| **Compiler LOC** | "6,923 lines of Rail" (if present) | `wc -l tools/compile.rail` |
| **Compiler function count** | "335 functions" (if present) | `grep -c ' =$' tools/compile.rail` or similar |
| **Public-key fingerprint** | `cac5f21a70564aeb` | `~/.ledatic/witness/pk_fp` or derive from `fleet0.pub.pem` |
| **Verifier command example** | `/tmp/v.sh /tmp/rn /tmp/rn.att.json` | `tools/attest/verify.sh` exists + accepts those args |
| **Endpoint references** | `/witness/fleet0/latest` etc. | endpoint resolves 200 |

Out of scope for this audit (covered elsewhere):
- Live JS-fetched values (walker v0)
- Page liveness as a whole (walker v0 `pages` class)
- Prose narrative ("the company physicifies things"; not substrate-checkable)

## 3. Walker design

`tools/audit/system_page_audit.sh` — shell, same convention as
`attest_endpoint_walk.sh`. Reads `system.html`, extracts each claim
class with a tagged regex, looks up the truth, compares.

Pseudo-shape (not code):

```
fetch https://ledatic.org/system → /tmp/system.html

for each (class, regex, truth_cmd) in CLAIM_TABLE:
  page_value = regex_extract /tmp/system.html
  truth_value = $(truth_cmd)
  if page_value == truth_value: PASS
  else: FAIL, log (class, page, truth)
```

Walker is **read-only**. It does NOT auto-update the HTML. The fix
is a human edit + ledatic-site deploy. The audit is the alarm, not
the actuator.

## 4. Kill_target per claim class

Each class has an exact-match kill_target (no tolerance — these are
discrete claims, not noisy measurements).

| Class | PASS iff | Notes |
|---|---|---|
| Rail version | page string equals latest git tag | tolerate "v5.1.0" vs "v5.1.0 · 141/141" (header has version + count, split first) |
| Test count | page X/Y matches `./rail_native test` last-line X/Y | run test once per audit; cheap (~30s) |
| Stdlib count | exact integer match | n/a |
| Compiler LOC | within ±50 lines of substrate (compile.rail churns) | small tolerance for cosmetic edits |
| Compiler function count | exact integer match | n/a |
| Public-key fingerprint | exact hex match | n/a |
| Verifier command example | each path mentioned exists; verify.sh is executable | static-asset class on walker v0 already verifies sha |
| Endpoint references | each referenced path resolves 200 | redundant with walker v0 `pages` but cheap to recheck |

## 5. Phased rollout

**Phase 0 — Catalogue all substrate-dependent strings in system.html
(this plan; manual eyeball pass).** Done at §2; may grow on first
walker run.

**Phase 1 — Walker v0** (this session)

Implement `tools/audit/system_page_audit.sh` covering at least the
two classes confirmed substrate-dependent today: Rail version + test
count. Stub the others with TODO comments. First-run target: catch
the `140/140 → 141/141` drift.

**Phase 2 — Expand class coverage** (followup)

Catalogue the rest of `system.html` line by line, add a class per
substrate-dependent string. Likely 6–8 total.

**Phase 3 — Wire to chain** (gated on Lakes plan §4 Studio endpoint)

Lab entry per audit run, `namespace: "site"`.

**Phase 4 — Fix the 140/140 drift** (5min, but separately because
fixing it requires a ledatic-site deploy and that needs the
`CF_TOKEN`)

Edit `system.html`, change `140/140 → 141/141`, deploy via
`./deploy.sh`. Could also be done first to clear the noise floor
before the walker runs.

**Phase 5 — Generator instead of hand-edit (optional, larger)**

If the audit catches multiple drifts, the right long-term answer is
that `system.html` should be *generated* (from a `gen_system.rail`
in `tools/deploy/`) instead of hand-edited, with substrate values
baked in at deploy time. That converts the drift class from "human
forgot to edit" to "deploy didn't run." Defer until the audit
proves this is a recurring pain.

## 6. Open decisions

1. **Tolerance on LOC counts.** `compile.rail` churns; an exact
   match is brittle. ±50 lines? ±10%? Recommend ±50 absolute; it's
   coarse enough to ignore comment edits but tight enough to catch
   "we restructured the compiler and forgot to update the page."

2. **Should the audit also fix?** No — match the walker v0 pattern.
   Audits observe; humans/deploys fix. Auto-fixing the HTML would
   couple the audit to deploy auth (CF_TOKEN), which is the wrong
   shape.

3. **One walker per page or one walker for all pages?** Recommend
   one per page for now (`system_page_audit.sh`, later `ot_page_audit.sh`,
   etc.). Cleaner, but maybe consolidate when patterns stabilize.

4. **Deploy on every Rail tag bump?** If we move to a generator
   (Phase 5), each tag-bump should auto-redeploy `system.html`.
   Not in scope here; gated on Phase 5 being decided.

## 7. Out of scope

- `/ot`, `/case-campaign-intel`, and other pages (separate audits if
  needed)
- Cloudflare Worker / KV path mappings (walker v0 covers liveness)
- Prose-narrative claims that don't have a substrate
- The "live" panels on `/system` populated by `system-live.js`
  (walker v0 covers those endpoints)
