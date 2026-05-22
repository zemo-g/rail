# DNRA Chain Schema v1

Hash-chained Ed25519-signed JSONL ledger for deliberation events. Two append-only chains:

- `~/.ledatic/dnra/chain/deliberations.jsonl` — one entry per deliberation event (immutable)
- `~/.ledatic/dnra/chain/outcomes.jsonl` — one entry per outcome resolution, refs deliberation by id

Both chains follow the same record envelope (`kind`/`version`/`id`/`parents`/`signer`/`sig`/...); only the body fields differ.

The schema deliberately mirrors `~/projects/rail/tools/lab/` (the `/lab` Ed25519-signed work-chain), with deliberation-specific body fields drawn from Oversight's causal cocoon shape (event → snapshot → computed correlation, restated for deliberations).

---

## Deliberation entry (`kind = "ledatic.dnra.deliberation"`)

```json
{
  "kind": "ledatic.dnra.deliberation",
  "version": 1,
  "id": "sha256:<canonical-json-hash-of-body>",
  "parents": ["sha256:<prior-entry-id>"],

  "question": {
    "text": "<the user-or-system question>",
    "features": {
      "category": "rail_code|reasoning|open_ended",
      "complexity_hint": "trivial|medium|hard",
      "has_oracle": true,
      "oracle_kind": "compiler|falsification_set|user|none"
    },
    "asked_at": "2026-05-22T15:33:00Z"
  },

  "triage": {
    "path": "fast|deliberate",
    "reason": "R0_trivial|R1_rail_compiler_oracle|R2_rail_invariant_or_specialist|R3_reasoning|R4_open_ended|R5_fallback",
    "selected_panel": ["deductive", "empirical", "adversarial"]
  },

  "panel": [
    {
      "mode": "deductive",
      "position": "<the panelist's claim>",
      "rail_claim": "<optional Rail source as falsifiable claim, empty string if none>",
      "confidence_self": 0.0,
      "responded_at": "..."
    }
  ],

  "arbiter": {
    "decision": "<final synthesized answer or 'no consensus'>",
    "method": "consensus|debate_as_code|halt_on_disagreement|user_escalated",
    "dissent_trace": [
      {"mode": "adversarial", "objection": "<what they pushed back on>", "resolved": false}
    ],
    "decided_at": "..."
  },

  "halt": {
    "reason": "converged|timeout|contradiction|escalated",
    "rounds": 1
  },

  "pulse_id": "<entropy beacon pulse_id at write time>",
  "weights_hash": "<sha256 of panelist weight files joined by mode order; empty if no models>",
  "created_at": "2026-05-22T15:33:00Z",
  "signer": "<ed25519 pubkey fingerprint>",
  "sig": "<ed25519 signature hex over the canonical id>",
  "witnesses": []
}
```

## Outcome entry (`kind = "ledatic.dnra.outcome"`)

```json
{
  "kind": "ledatic.dnra.outcome",
  "version": 1,
  "id": "sha256:<canonical-json-hash-of-body>",
  "parents": ["sha256:<prior-entry-id-in-outcomes-chain>"],
  "refs_deliberation": "sha256:<deliberation-entry-id>",

  "resolution": {
    "result": "<the actual outcome — value, score, text>",
    "scored_by": "compiler_oracle|falsification_set|user_feedback|self_check",
    "score": 1,
    "score_scale": "binary|0-1|0-100|categorical",
    "lag_seconds": 7200,
    "resolved_at": "2026-05-22T17:33:00Z"
  },

  "mode_attribution": {
    "deductive":   {"agreed_with_outcome": true, "weight_in_decision": 0.45},
    "empirical":   {"agreed_with_outcome": true, "weight_in_decision": 0.35},
    "adversarial": {"agreed_with_outcome": true, "weight_in_decision": 0.20}
  },

  "pulse_id": "<entropy beacon pulse_id at write time>",
  "created_at": "...",
  "signer": "<ed25519 pubkey fingerprint>",
  "sig": "<ed25519 signature hex>",
  "witnesses": []
}
```

---

## Hash construction rules

1. Build the **body** by taking the full record JSON and removing the fields `id`, `sig`, `witnesses`.
2. Canonicalize: equivalent of `json.dumps(body, sort_keys=True, separators=(",", ":"))` — recursive key sort, no whitespace.
3. Compute `sha256(canonical_body_utf8_bytes)` → that's the `id` (prefixed `sha256:`).
4. Sign the `id` string (prefix included) with Ed25519 key → that's the `sig` (hex).
5. Witnesses can append additional signatures over the same `id` later without altering it.

Genesis entry: `parents: []`. Every subsequent entry: `parents: [<prior_id>]`.

---

## Verification protocol (run on every `open_chain()`)

For each entry e_i in chain order:

1. Recompute body hash, assert it equals `e_i.id`. → tamper-evidence
2. Verify `e_i.sig` against `e_i.signer` over `e_i.id`. → authenticity
3. Assert `e_i.parents == [e_{i-1}.id]` for i > 0, `e_i.parents == []` for i == 0. → order integrity
4. Optionally: verify `e_i.pulse_id` exists in the entropy beacon archive (proves temporal order vs. publication time of that pulse).

Any failure → chain is invalid → reject subsequent appends until reconciled.

---

## Field semantics + design notes

### `question.features`
- `category` is the Convener routing primitive — used to decide deliberate-vs-fast and which panel.
- `has_oracle` flags whether outcome resolution can be auto-scored. Determines training-data viability for the meta-cognition layer.
- `complexity_hint` is Convener's pre-deliberation estimate; ground truth comes from outcomes.

### `triage.reason`
- Drawn from a **closed terminal-label set** defined by `design/CONVENER.v0.spec.md`: `R0_trivial`, `R1_rail_compiler_oracle`, `R2_rail_invariant_or_specialist`, `R3_reasoning`, `R4_open_ended`, `R5_fallback`. Auditability invariant — the Convener's behavior is `grep`-able across the chain.
- Free-form `reason` strings are rejected by the acceptance harness (`impl/test_convener.rail`).

### `panel[*].position` and `panel[*].rail_claim`
- `position` is the panelist's prose claim.
- `rail_claim` is the **debate-as-code path** — a Rail expression/program that, if executed, proves or instantiates the position. Empty string in v1 prose-only mode; the differentiator at scale.
- Other panelists can attempt to execute each other's `rail_claim` and append a counter-claim in `dissent_trace`.

### `arbiter.dissent_trace`
- Always populated, even on consensus (with `resolved: true`). Captures the *shape* of agreement, not just the answer.
- Cannot be empty if `method == "halt_on_disagreement"`.

### `outcome.resolution.lag_seconds`
- The analog of Oversight's `lag_hours` in causal cocoon edge_draft. Used downstream for "which modes are trustworthy at what time horizons."

### `outcome.mode_attribution`
- `agreed_with_outcome` is computed by comparing each panelist's `position` to the realized outcome (oracle-scored or hand-graded).
- `weight_in_decision` is what the arbiter actually used (sums to 1.0 for that deliberation). Tracking both surfaces calibration drift: are weighted-heaviest panelists also right most often? If no, the arbiter's weighting is mis-calibrated.

### Privacy
- `signer` is the local node's Ed25519 key. Different nodes have different keys. Cross-node deliberations can have multiple `witnesses` (deferred — single-signer for v1).

---

## What's deliberately NOT in the schema

- **No `direction` (TIGHTEN/LOOSEN)** — trading-specific. Replaced with reasoning_stage semantics implicit in panel positions.
- **No `win_rate` / `dead_pool_count`** — trading metrics. Replaced with outcome `score` on a problem-specific scale.
- **No Pearson r at fixed lags** in the chain — that's an analytics projection, not a chain primitive. Computed weekly into the SQLite index (deferred).
- **No `confidence` scalar at the entry level** — DNRA's thesis is that confidence is *structural*, not scalar. Per-panelist `confidence_self` is allowed because it's self-reported, not the system's claim. Aggregate confidence is read off the disagreement geometry, not stored as a number.

---

## Migration path to SQLite index (deferred)

When the chain has ~1000 deliberation entries, project into a SQLite DB for analytics queries:

- `deliberation_event` — one row per chain entry (question + arbiter columns)
- `panel_response` — one row per panelist per deliberation
- `outcome_event` — one row per outcome chain entry
- `mode_correlation` — computed: mode × outcome correlation at various lag windows, weekly upsert with `UNIQUE(mode, outcome_kind, lag_bucket)`

Projection is one-way and reproducible from the chain. SQLite is the index, not the source of truth.

---

## Next ticket

**T2** — `tools/dnra/impl/ledger.rail` — implements `open_chain`, `append_entry`, `verify_chain`, `iter_entries`. Crib structure from `~/projects/rail/tools/lab/` (already proven on `/lab`). Uses `stdlib/ed25519_sign.rail` for signing, and either `stdlib/json.rail` for canonicalization or a small custom canonicalizer if json.rail doesn't sort keys deterministically.
