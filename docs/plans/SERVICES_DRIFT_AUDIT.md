# SERVICES DRIFT AUDIT — Plan

**Status:** proposal.
**Date:** 2026-05-27
**Owner:** Ledatic (infra lane)
**Tracked task:** #7 (originally scoped narrowly to `com.ledatic.sitestats`;
broadened on discovery that CLAUDE.md's full service table has drifted.)

## 1. Why

Task #7 originally asked for a source-of-truth trace on
`com.ledatic.sitestats`. The first probe surfaced something bigger:

- `~/Library/LaunchAgents/_disabled.com.ledatic.sitestats.plist`
  exists, mtime **2026-03-07** (81 days ago)
- the plist's `WorkingDirectory` references `~/ledatic-site/`,
  which moved to `~/projects/ledatic-site/` in the 2026-04-20 repo
  split — so even if re-enabled, it would fail
- `~/CLAUDE.md` still lists `com.ledatic.sitestats` under
  "Currently running"

That third bullet is the structural issue. The CLAUDE.md services
table is dated as a "2026-04-16 snapshot" but has been treated as
ground truth in every session since. If sitestats has drifted off
the list, others have too.

The narrow task #7 is solved by removing sitestats from the table.
The broader audit is **CLAUDE.md services drift detector** — extract
every service the doc claims is running, cross-check against
launchctl reality, report the diff.

## 2. What the audit asserts

For each `com.ledatic.*` mentioned in CLAUDE.md's "Currently running"
section:

| Class | PASS iff |
|---|---|
| **launchctl_loaded** | `launchctl list` returns a row for the service |
| **plist_present** | `~/Library/LaunchAgents/<service>.plist` exists (not `_disabled.*`) |
| **plist_paths_valid** | every `WorkingDirectory` / `ProgramArguments` path in the plist resolves to an existing file/dir |

Inverse class:

| Class | PASS iff |
|---|---|
| **claimed_running_actually_running** | every claimed-running service is loaded in launchctl |

The dual side (services running on the machine but not mentioned in
CLAUDE.md) is also a useful audit but defer — CLAUDE.md lists Apple
+ third-party services too; needs a filter.

## 3. Walker design

`tools/audit/services_drift_audit.sh`:

```
1. grep CLAUDE.md "Currently running" section for com.ledatic.*
2. For each service name:
     a. Check `launchctl list | grep <name>` returns a row
     b. Check ~/Library/LaunchAgents/<name>.plist exists (no _disabled prefix)
     c. If plist exists, parse WorkingDirectory + ProgramArguments and check paths
3. Report per-service status
4. PASS iff every claimed-running service is loaded + has a valid plist
```

## 4. Expected first-run findings

- `com.ledatic.sitestats` — disabled, plist references missing path
- Likely others: `com.ledatic.signalbot` (parked per same section),
  `com.ledatic.salsa` (paused), `com.ledatic.trader` (paused)
- The CLAUDE.md table already separates "Currently running" from
  "Paused / parked" — the audit should only fail when "Currently
  running" entries are NOT running. Paused entries are correctly
  listed as paused.

The whole point: when CLAUDE.md says "currently running" and the
reality is "disabled 81 days ago," fix the doc.

## 5. The right resolution

Two paths:

### Path A — Audit-only

Walker reports the drift. Human edits CLAUDE.md to move sitestats
(and any other drifted service) from "Currently running" to "Paused"
or "Retired".

### Path B — Auto-regenerate

CLAUDE.md's service table becomes generated from launchctl reality
on a cron. Pros: never drifts. Cons: loses the human curation
(some services have rich notes; auto-gen would either preserve them
fragilely or lose them).

**Recommend Path A.** CLAUDE.md is curated documentation; let the
audit be the alarm and humans the editor. Path B is overkill.

## 6. Phased rollout

**Phase 1 — Walker v0** (this session): extract claimed-running
services from CLAUDE.md, cross-check launchctl, report.

**Phase 2 — Plist path validation:** for each loaded plist, verify
the paths referenced still exist. Catches the sitestats case
even if it were re-enabled.

**Phase 3 — Edit CLAUDE.md based on findings** (separate task):
remove drifted services from the "Currently running" list.

## 7. Open decisions

1. **Scope of CLAUDE.md to scan.** Just `~/CLAUDE.md`? Also
   `~/empire/CLAUDE.md`? Project-local CLAUDE.md files in
   `~/projects/*/`? Recommend: the top-level `~/CLAUDE.md` only;
   it's the canonical infra doc.

2. **Treat the inverse drift (running services not in CLAUDE.md)?**
   Useful but needs an allow-list to filter Apple + third-party.
   Defer to a Phase 2 enhancement.

3. **Cron the audit?** Yes — drift accumulates silently. Daily
   would be plenty; the cron output goes into a lab entry once the
   Studio HTTP endpoint exists.

## 8. Out of scope

- Auto-regenerating CLAUDE.md
- Auditing project-local CLAUDE.md files
- Editing CLAUDE.md based on findings (separate human pass)
- Re-enabling drifted services (separate decision per service)
