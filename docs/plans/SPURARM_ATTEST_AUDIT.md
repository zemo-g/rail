# SPURARM ATTEST AUDIT — Plan

**Status:** proposal.
**Date:** 2026-05-27
**Owner:** Ledatic (arm lane)
**Tracked task:** #3

## 1. Why

The `Ledatic-Empire/ledatic-arm` README (public, BSL 1.1) claims at
line 72–73:

> every commanded pose carries an attestation tuple
> `(state, action, model_hash, kernel_hash, beacon_pulse)`. Auditable
> [...]

This is the embodied-AI thesis at its most concrete: a robotic arm
whose every motion is cryptographically signed against the public
beacon. If true, no one else has it. If false, the thesis is
unbacked and the README is a [[feedback_no_synthetic_evidence]]
violation on a public surface.

A 30-second probe of the substrate revealed the gap:

**Actual chain record** (latest in `~/.ledatic-arm/chain/armsim_chain.jsonl`,
2026-05-15 last write):

```
{"idx", "t", "kind", "params", "state", "prev_sha", "sha"}
```

**README tuple:** `(state, action, model_hash, kernel_hash, beacon_pulse)`

Of the 5 fields the README promises, only 2 are present:
- `state` ✓
- `action` ≈ (encoded as `params` — same semantic, different name)
- **`model_hash`** ✗ (zero source mentions in `armsim.rail`)
- **`kernel_hash`** ✗ (zero source mentions in `armsim.rail`)
- **`beacon_pulse`** ✗ (per-action; *head* can be anchored on demand
  via `/anchor` but not per-record)

The chain has hash linkage (`prev_sha` + `sha`) — that part is real.
But three of the five tuple components in the README are
unimplemented. The web UI at `web/index.html:2620` even contains the
giveaway:

```js
const pulse = a.pulse_id || a.pulse || a.beacon_pulse_id || "(unknown)";
```

It falls through three field names before defaulting to "(unknown)" —
which is what it would render in practice given the current chain
schema.

Plus, per `ledatic-arm-bootstrap-2026-05-15.md` memory:
> Open: fleet0 sign_token rotation breaks /anchor

So even the per-head anchor mechanism is currently broken.

## 2. What the audit will assert

A single kill_target: **every field in the README's tuple appears
in the latest chain record.** If not, FALSIFIED. The README and the
substrate must agree.

This audit is structurally different from #1 and #2: those compare
deployed claims to deployed substrate. This compares a *promise* to
its *implementation*. Static check, no runtime probe needed.

## 3. Walker design

`tools/audit/spurarm_chain_schema_audit.sh`:

```
1. Extract the tuple field list from README.md line 73 (regex)
2. Read the last record from ~/.ledatic-arm/chain/armsim_chain.jsonl
3. For each field in the tuple:
     - Check it exists as a JSON key in the record (literal or aliased)
     - "action" aliases "params" (allowed alias)
4. PASS iff every tuple field is present (or aliased)
5. Additionally report: chain age (last write), anchor status,
   number of records
```

Run from the local machine — no network, no arm hardware needed.

## 4. Falsification cases (predictions for first run)

The walker will report on first run:

| Field | Present? | Notes |
|---|---|---|
| `state` | YES | `"state":"550,520,700,1500,0"` |
| `action` | YES (as `params`) | `"params":"p1=550&p2=520&time_ms=600"` |
| `model_hash` | **NO** | zero source mentions |
| `kernel_hash` | **NO** | zero source mentions |
| `beacon_pulse` | **NO** | head-anchor only, not per-record |

Expected verdict: **FALSIFIED**, missing 3 of 5 fields.

Secondary alarm: chain age (12 days since last write — the arm hasn't
been used since 2026-05-15) — but that's not a falsification of the
claim, just a freshness signal.

## 5. The fix — two paths

Once the walker confirms the gap, the response is a product decision:

### Path A — Update the README (smaller, dishonest if we don't follow through)

Edit `Ledatic-Empire/ledatic-arm/README.md` lines 70–75 to state
what actually exists:

> every commanded pose carries a tamper-evident chain record
> `(state, action, prev_sha, sha)`. The chain head can be anchored
> on demand to the public entropy beacon via `/anchor`.

Honest, but it gives up the differentiated story we want to tell
about Ledatic. This is a step backward from the public claim.

### Path B — Implement the missing fields (larger, the thesis play)

Add to each chain record:
- `model_hash` — sha256 of the LLM weights file at inference time
  (Qwen3.5-122B at Studio :8082; ~245GB so cache the hash at server
  start, embed per-record)
- `kernel_hash` — sha256 of the JIT-emitted MSL kernel (if any) that
  produced the action; null when no GPU kernel involved (sim mode)
- `beacon_pulse` — fetch latest pulse_id from
  `/entropy/pulse` at the moment the action is committed; embed
  inline

This makes the README claim load-bearing. It's the right call if we
ever sell on the audit story.

**Tradeoff:** Path B requires `armsim.rail` changes (~50–100 lines)
plus a 245GB sha256 walk on first run (cache after). Path A is one
README commit.

**Recommendation:** **Path B**, but only if and when the arm is back
on rotation. Right now (2026-05-27) the chain hasn't been written
to in 12 days; spending effort on an idle subsystem is the wrong
priority. Run the audit now to make the gap visible; revisit Path B
when arm work resumes.

## 6. Phased rollout

**Phase 1 — Walker v0** (this session)

Build `tools/audit/spurarm_chain_schema_audit.sh`. Confirm the 3
missing fields. FALSIFIED verdict is the expected and correct
outcome.

**Phase 2 — Decision** (offline, user)

Pick Path A or Path B for resolution. The audit doesn't force a
choice; it makes the choice visible.

**Phase 3 — Re-audit after fix** (post-decision)

Whichever path is taken, rerun walker. PASS verifies the README
and substrate agree.

## 7. Open decisions

1. **README change before audit ships?** No — the audit's value is
   exactly to surface this gap. Fixing the README without the audit
   trail means the next drift won't be caught either.

2. **Should the walker tolerate aliases (params ↔ action) or
   require strict field-name match?** Recommend tolerate, with the
   alias map documented in the script. The semantic is the same;
   the rename is cosmetic.

3. **Cron this audit or one-shot?** One-shot for now. The chain
   schema doesn't change between deploys; cron'ing it would just
   produce identical FALSIFIED entries until the fix lands. Make
   it part of the pre-tag checklist for ledatic-arm.

4. **Tie this to a lab entry?** Yes — once Lakes plan §4 (Studio
   HTTP endpoint) is up, this audit's verdict becomes a chain entry
   with `namespace: "arm"`.

## 8. Out of scope

- Hardware runtime audit (does the arm physically move when the
  chain says it did?)
- Performance audit (is the inference loop actually using the JIT
  kernels claimed by the lab chain's Phase 2 entries?)
- `/anchor` endpoint repair (sign_token rotation issue) —
  separate task
- spurarm/cap-h training-side audits (different repo, separate
  thread)
