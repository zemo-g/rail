# BEACON CHAIN AUDIT — Plan

**Status:** proposal.
**Date:** 2026-05-27
**Owner:** Ledatic (beacon lane)
**Tracked task:** #5

## 1. Why

The entropy beacon is the foundational substrate of "physicify" —
every attestation across the stack derives from it. A 60-second probe
turned up two facts:

1. **The public surface (`/entropy/pulse`) only exposes the current
   pulse.** Endpoints like `/entropy/chain`, `/entropy/history`,
   `/entropy/pulse/<N>` all return the 200 home-page fallback. There
   is no public chain-walk surface.

2. **The real chain of record is the Pi fleet0 witness log**:
   `~/.ledatic/witness/log.jsonl` (67,294 active records) + three
   rotated `.jsonl.gz` archives going back to 2026-04-20. Every
   record carries `pulse_id`, `value_hex`, `prev_hex`, `gap`,
   `witnessed_at`, `sig`.

3. **The witness records but does not verify.** Every record has
   `"chain_verified": null`. The witness signs the pulses it sees;
   nothing currently checks that consecutive witnessed pulses link
   correctly via `prev_hex` → `value_hex`.

So the claim "continuous pulse, walkable chain" is asserted by the
existence of the witness log but never *checked* against the log's
own contents. That's the audit gap.

## 2. What the audit asserts

Three kill_targets on a sample window of the witness log:

| Class | PASS iff | Notes |
|---|---|---|
| **monotonicity** | every record's `pulse_id` strictly greater than the previous | catches duplicates, replays, clock-resets |
| **linkage** | for every consecutive pair `(A, B)` where `B.gap == 1`, `B.prev_hex == A.value_hex` | direct chain-walk; non-tight gaps are unverifiable from witness alone |
| **gap-shape** | `max_gap` over the window below a threshold (default 1000) | catches huge skips that indicate beacon outage |

The witness's `chain_verified: null` field is the cleanest place to
write the audit verdict back, but writing to Pi from this walker
crosses a trust line we don't want yet. v0 reads only.

## 3. Inherent limitations

- **No genesis walk.** The witness skips pulses (rate-controls); not
  every beacon pulse is recorded. Linkage can only be checked on
  consecutive witnessed pulses where `gap == 1`.
- **Rotated logs are gzipped on Pi.** v0 walks only the active
  `log.jsonl`. Phase 2 expands to `gunzip -c | walk`.
- **Cannot detect tampering on the Pi.** If the witness key is
  compromised, a tampered chain would still verify. Cross-witness
  is the right answer (multi-node Ed25519 cosignature, per the
  beacon's roadmap) — out of scope here.

## 4. Walker design

`tools/audit/beacon_chain_audit.sh`:

```
1. Pull last N records from Pi via ssh (default N=200)
2. For each consecutive pair (A, B):
     - Check B.pulse_id > A.pulse_id (else FAIL: monotone)
     - If B.gap == 1: check B.prev_hex == A.value_hex (else FAIL: linkage)
     - Record gap into counters
3. Report:
     - records_walked, gap1_pairs_checked, gap1_pairs_linked
     - max_gap, min_gap, mean_gap
     - first_failure (if any)
4. PASS iff monotone everywhere AND all gap-1 pairs linked
```

Reads only. No write to Pi.

## 5. Expected first-run result

Best guess from the two sample records I saw (pulse_ids 1346690 and
1346712 with gaps 2 and 22 respectively):
- Monotone: should PASS (no replay history seen)
- Linkage: many sample pairs likely have `gap > 1`, so the linkage
  check covers a subset. The subset should all PASS if the beacon
  is honest.
- Gap shape: gap of 22 is fine; needs window-wide stats to know if
  worse exists.

If the audit catches a real failure, that's a beacon-integrity
incident — far above routine drift.

## 6. Phased rollout

**Phase 1 — Walker v0** (this session): N=200 sample from active
log; reports the three kill_targets.

**Phase 2 — Wider window:** stream the active log + rotated archives;
verify monotone + linkage across the whole recorded history (since
2026-04-20). Costs minutes of network + Pi CPU; do as a one-shot
historical check, not a cron.

**Phase 3 — Write `chain_verified`:** flip `null` → `true|false` per
record after audit. Requires a Pi-side writer process — the audit
runs from Mini, signals a Pi job to update its own records.

**Phase 4 — Cross-witness:** the beacon's stated v2 goal in the
public pulse comment is "multi-witness Ed25519 cosignature." Until
that exists, the audit only validates a single-witness self-
consistent chain.

## 7. Open decisions

1. **N for the v0 sample.** 200 records covers a few minutes of
   wall-clock. 2000 covers ~30min. Recommend 200 — cheap, catches
   ongoing drift; do larger walks ad-hoc.

2. **Pull-mode (ssh + tail) vs cache-mode (rsync once, audit
   locally).** Recommend pull — fresher, no stale cache to manage.

3. **Run on Mini or Studio?** Either; just needs ssh access to Pi.
   Mini is fine for v0.

4. **What's a tolerable `max_gap`?** Beacon is single-node currently;
   restarts of `com.ledatic.mhd` produce gaps. Default 1000
   (~minutes of outage). If exceeded, FALSIFIED → escalates to a
   look-at-this. Tunable.

## 8. Out of scope

- Genesis walk (structurally impossible from the witness)
- Tampering detection (cross-witness only)
- Public chain-walk endpoint (separate site work; would expose the
  rotated logs as `/entropy/chain/<rotation>.jsonl.gz`)
- Ed25519 sig verification per record (already covered by existing
  `tools/attest/verify.sh`; not the audit's job to duplicate)
