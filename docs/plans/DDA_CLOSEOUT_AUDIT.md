# DDA CLOSEOUT AUDIT — Plan

**Status:** proposal.
**Date:** 2026-05-27
**Owner:** Ledatic (DDA lane, closed engagement)
**Tracked task:** #6

## 1. Why

The DDA engagement closed 2026-05-12. The vault at
`~/ledatic-clients/dda/reports/` is private; the public attestation
surface at `https://ledatic.org/dda/...` is durable reputation —
anyone Reilly forwards the engagement summary to can probe it.

A 30-second probe surfaced one already:

```
$ curl -s https://ledatic.org/dda/index.json
  "generated_at": "2026-05-05T21:10:22Z",
  "total_briefs": 12,
  "latest_delivered_at": "2026-05-04T12:50:42Z",
  rows: POC-W02 (4 briefs) + POC-W03 x4 (8 briefs total) = 12
```

The engagement was a 30-day POC across **four weeks** (W01–W04).
Only W02 and W03 are represented in the public index. W01 and W04
are missing — including the closeout week.

This isn't necessarily wrong (W01 may have predated the attestation
infrastructure being wired), but it's worth flagging. The public
index claims this is the full DDA record; if a prospect downloads
and inspects, they'll see only two of four weeks.

The audit:
1. Walks the public DDA attestation surface as a hermetic web of
   index → manifests → sidecars
2. Checks internal consistency (every brief in a manifest has a
   sidecar; sidecar fields well-formed)
3. Reports coverage gaps against the engagement timeline

## 2. What the audit asserts

| Class | PASS iff | Notes |
|---|---|---|
| **index coverage** | every week mentioned in vault has a row in `/dda/index.json` | reads vault dir names; out-of-scope if vault private |
| **manifest reachable** | every row in index has a fetchable `manifest.json` at `/dda/<model>/<week>/<vertical>/manifest.json` | |
| **sidecar coverage** | for every brief listed in a manifest, the corresponding `*.attestation.json` returns 200 | |
| **sidecar well-formed** | each sidecar has all of: `pulse_id`, `sig`, `pk_fp`, `witnessed_at`, `value_hex` | structural check; no crypto verification (that's `verify.sh`'s job) |
| **total_briefs consistency** | `index.total_briefs` == sum of `brief_count` across rows | catches stale index |
| **freshness vs vault** | `latest_delivered_at` within 7 days of vault's most recent brief mtime | freshness only when local vault accessible |

## 3. Walker design

`tools/audit/dda_closeout_audit.sh`:

```
1. Fetch /dda/index.json
2. Verify total_briefs == sum(rows.brief_count)
3. For each row:
     a. Fetch /dda/<model>/<week>/<vertical>/manifest.json
     b. For each brief in manifest:
          - Fetch <brief>.<ext>.attestation.json
          - Check 200 + JSON-well-formed + required fields present
4. Local-only addition: enumerate ~/ledatic-clients/dda/reports/
   weeks, compare to index rows; report any week present locally
   but missing from index
5. Emit per-class verdicts + counts
```

## 4. Phased rollout

**Phase 1 — Walker v0** (this session): index → manifest → sidecar
coverage + well-formedness. Local vault coverage cross-check
optional.

**Phase 2 — Cryptographic verification** (followup): for each
sidecar, run `tools/attest/verify.sh` to confirm Ed25519 signature
holds. Phase 1 only checks structure; Phase 2 adds the cryptographic
truth.

**Phase 3 — Beacon chain cross-check** (followup): every sidecar
references a `pulse_id`. Verify each pulse_id is actually on the
beacon chain (cross with beacon_chain_audit.sh).

**Phase 4 — Brief content groundedness** (out of v0 scope):
Hardest audit class. Each brief is 122B-generated; "grounded" means
its numeric claims trace to the ad-intel scraper output and source
data. Requires NLP-grade extraction. Defer until needed.

## 5. Open decisions

1. **Should the walker have access to the local vault?** Yes for
   the coverage cross-check; the vault is on Mini already.
   Recommend: run audit from Mini, vault read-only.

2. **What's a tolerable absence in the index?** If POC-W01 was
   pre-attestation, document that explicitly in the index rather
   than silently omit. Recommend: audit reports the gap; user
   decides whether to backfill or annotate.

3. **Cron this or one-shot?** Engagement is closed. One-shot for
   v0; revisit if DDA work resumes or another POC modeled on the
   same surface starts.

4. **Brief content groundedness (Phase 4) — worth the effort?**
   The hardest audit class in the whole suite. Probably not worth
   it for a closed engagement. The bar is "if a prospect inspects,
   what do they find?" — the public surface + signed sidecars
   already meet that bar.

## 6. Out of scope

- Vault content audit (Phase 4 above)
- Cryptographic verification of sidecars (Phase 2)
- Re-deriving the briefs from substrate
- Verifying brief delivery to the client (commitments.md tracks
  that; separate audit if needed)
