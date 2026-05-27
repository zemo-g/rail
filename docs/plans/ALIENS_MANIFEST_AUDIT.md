# ALIENS MANIFEST AUDIT — Plan

**Status:** proposal.
**Date:** 2026-05-27
**Owner:** Ledatic (site lane)
**Tracked task:** #4

## 1. Why

`ledatic.org/aliens` mirrors 219 government UAP records (FBI / DOE /
DOW / CIA / ODNI). The manifest at `/pursue/manifest.jsonl` claims:

- byte-identical mirror of the original government release
- `sha256` recorded at ingest
- full attestation tuple at ingest: `(pulse_id, value_hex, sig,
  pk_fp, witnessed_at)`

This is the strongest existing example of Ledatic's "physicify" verb
in the wild — every record has a signed beacon-anchored sidecar.

The audit gap: **nothing periodically re-hashes the R2 objects**. If
an R2 object is corrupted, replaced, or silently truncated, the
manifest still says the original sha256 — and no one notices until
a user actually downloads + verifies.

This is precisely the [[feedback_display_lies_audit_pattern]]
substrate-honest / surface-lying class: the substrate (R2 storage)
could drift while the surface (manifest) stays static.

## 2. What the audit asserts

For a sampled record from the manifest:

1. **Size check** — `HEAD /pursue/files/<local_path>` returns
   `Content-Length` matching `size_bytes`.
2. **Hash check** — `GET` the object, compute sha256, compare to
   manifest's `sha256`.
3. **Attestation reachability** — sidecar attestation can be derived
   from the manifest record itself (the attestation is embedded
   inline, not a separate file — so this is structural, not
   network).

Kill_target per record: all three checks PASS.

## 3. Sampling strategy

Full walk of 219 records is **2.3 GB of downloads** per audit. Not
appropriate for a 5-minute cron.

Two-tier strategy:

- **Tier 1 — daily cheap walk:** size-only check on all 219 records
  (HEAD requests). ~30 seconds.
- **Tier 2 — weekly deep walk:** full sha256 verification on a
  rotating sample of 5 records. 1 GB / week. Over 44 weeks, every
  record gets re-hashed once.

For v0: walker covers a **single sample** with the full sha256 check
to prove the pattern. Tier 1 / Tier 2 cadence is a later wiring
detail.

## 4. Walker design

`tools/audit/aliens_manifest_audit.sh`:

```
1. Fetch manifest.jsonl
2. Pick the smallest record by size_bytes (cheapest sha256 walk)
3. HEAD the file URL; verify Content-Length == size_bytes
4. GET the file to /tmp; compute sha256
5. Compare to manifest sha256
6. Emit PASS/FAIL
```

`--sample N` flag for larger sample walks.

## 5. Phased rollout

**Phase 1 — Walker v0** (this session): single-sample audit, proves
the pattern, exits non-zero on drift.

**Phase 2 — Tier 1 + Tier 2 wiring:** add `--head-only` mode for
size-only walk; rotation logic for which 5 records to deep-walk
this week.

**Phase 3 — Chain entry per audit run** (gated on Studio HTTP
endpoint, Lakes plan §4): one lab entry per audit, namespace
`"aliens"`.

**Phase 4 — Public audit endpoint** (optional): `/pursue/audit/latest.json`
exposes the most recent verdict. This is the trust move — proving
to a researcher that the mirror has been continuously verified.

## 6. Open decisions

1. **Run on Mini or as a worker job?** R2 → Mini → R2 verification
   is fine for a 5-record weekly walk. Larger samples would be
   better done as a Worker cron pulling directly within
   Cloudflare's edge. Defer to Phase 2.

2. **Treat missing thumbnail as FAIL?** Manifest also records
   `thumbnail_sha256` per record. For v0, audit only the main file.
   Thumbnail re-hash is a Phase 2 addition.

3. **Alert channel for drift?** Slack via existing
   `stdlib/slack_client.rail`? Email? Lab chain only?
   Recommendation: lab chain only for v0, add Slack alert when a
   drift is actually detected (don't pre-wire on hypothetical
   alarm).

## 7. Out of scope

- Verifying that R2 content matches the **original** government
  source (that would re-hit war.gov for every record — denial-of-
  service risk on the federal side and unhelpful to the audit
  goal). The manifest's `sha256` IS the original, captured at
  ingest. Audit only verifies "what we mirrored still matches what
  we said we mirrored."
- The attestation Ed25519 signature verification (separate audit;
  reuses `tools/attest/verify.sh`)
- Wave 2 path differences (`/medialink/ufo/052226/release_02/`
  vs Wave 1's `/release_1/`) — covered automatically by reading
  `local_path` from the manifest, not assuming a URL structure
