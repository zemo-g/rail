# DNRA ledger.rail — Contract Spec v0

**Status:** v0 contract. Implementation phased — see §Versioning at bottom.
**Mirrors:** `~/projects/rail/tools/lab/{entry,chain}.rail` on Studio.

---

## Purpose

Append-only hash-chained JSONL ledger for DNRA deliberation events. Two chains, identical envelope, different body kinds:
- `~/.ledatic/dnra/chain/deliberations.jsonl` (`kind = "ledatic.dnra.deliberation"`)
- `~/.ledatic/dnra/chain/outcomes.jsonl` (`kind = "ledatic.dnra.outcome"`)

Record shape is locked in `SCHEMA.md`. This file defines the Rail API + invariants.

---

## Public API

```rail
-- Open a chain by file path. Verifies integrity (hash + parent chain) on load.
-- Returns ChainHandle (opaque) or raises an error on corruption.
open_chain path -> ChainHandle

-- Append a new entry. Computes id, signs with the local signer key,
-- updates parents, writes one JSONL line under flock. Returns new entry id.
append_deliberation handle question triage panel arbiter halt pulse_id weights_hash -> string
append_outcome handle refs_deliberation_id resolution mode_attribution pulse_id -> string

-- Verify the entire chain (re-hashes every body, checks parent chain,
-- checks every signature). Returns true | error.
verify_chain handle -> bool

-- Walk entries in append order. Yields the parsed record (as an opaque
-- handle the caller can query with field accessors below).
iter_entries handle f -- f : EntryHandle -> Unit

-- Field accessors on EntryHandle (returned by iter_entries or get_entry).
entry_id e -> string
entry_kind e -> string
entry_parents e -> [string]
entry_pulse_id e -> string
entry_signer e -> string
entry_body_field e field_name -> string   -- one-level dotted path lookup
```

---

## Invariants (enforced; failure = abort)

1. **Append-only.** No row mutation, no row deletion. Append is the only mutator.
2. **Parent integrity.** `parents == []` iff the entry is genesis. Otherwise `parents == [prior_entry.id]`. No skipping, no branching in v0.
3. **Hash determinism.** `id` is `sha256_hex` of canonical body bytes. Re-serializing must produce identical bytes (canonical key sort, no extraneous whitespace).
4. **Signature validity.** Every entry has a non-empty `signer` + `sig`. `sig` is Ed25519 over the `id` string (with `sha256:` prefix or raw hex — match lab convention exactly; pin in v0).
5. **Locking.** Append acquires an advisory mkdir-style lock (`<chain_dir>/LOCK.d`) before reading the prior id and writing the new line. Release lock after fsync.
6. **Verify-on-open.** `open_chain` reverifies the entire chain. Slow but correct. v0 trades speed for safety; v1 caches verified-up-to-N marker.

---

## File layout

```
~/.ledatic/dnra/
├── chain/
│   ├── deliberations.jsonl       -- one chain, one file
│   ├── outcomes.jsonl            -- second chain, separate file
│   └── LOCK.d/                   -- mkdir-style advisory lock dir (per chain)
├── index/                        -- v1+ cached indices; v0 unused
└── traces/                       -- arbiter dissent traces too big for inline (v1+)
```

Both chains share signer keys but have independent parent histories. Cross-chain references (`outcomes.refs_deliberation`) are hash pointers; integrity verified by looking up the deliberation chain.

---

## Signer key

- Path: `~/.ledatic/dnra/signer/dnra_node.sk` (Ed25519 seed32, raw bytes)
- Path: `~/.ledatic/dnra/signer/dnra_node.pk` (Ed25519 public key, raw bytes)
- Path: `~/.ledatic/dnra/signer/dnra_node.fp` (short fingerprint, hex, for `signer` field)
- First-run: if `dnra_node.sk` doesn't exist, generate one and write all three. Print fingerprint, prompt user to back up `.sk` somewhere safe.
- Single-signer in v0. Multi-witness coalition deferred to v2.

---

## Canonical JSON convention (pin to lab)

- Recursive key sort, ASCII-ascending.
- No whitespace between tokens. `","` separator, `":"` between key/value.
- Strings: only ASCII printable [0x20, 0x7E], excluding `|`, `\n`, `\t`, `\r` (rejected at write, not escaped).
- Numbers: integers as decimal, no leading zeros. Floats prohibited in v0 (use strings for any computed numeric).
- Booleans: `true` / `false`.
- Null: forbidden in v0 (use empty string or omit the key).
- Arrays: order-preserving; nested objects in arrays are themselves canonicalized.

Excerpt: lab/entry.rail uses insertion sort over `(name, value)` pairs (see lines 173-193 of lab/entry.rail). Mirror that.

---

## Versioning + phased implementation

| Phase | Scope | Lines (est) |
|---|---|---|
| **v0.1** | Types, canonical encoder, sha256 hashing, JSONL append, parent chain. **No signing yet.** | ~200 |
| **v0.2** | Add Ed25519 local signing via `stdlib/ed25519_sign.rail`. Auto-generate signer keypair on first run. | +60 |
| **v0.3** | Add verify_chain (re-hash + signature verify on open). | +60 |
| **v0.4** | Add field accessors (entry_body_field) + iter_entries. | +50 |
| **v1.0** | Cached verified-up-to-N marker; faster open. Trace sidecar files for oversized bodies. | tbd |

v0.1 unblocks T3 (arbiter scaffold) immediately — arbiter can write disagreement examples to the chain without signing, prove the pattern, then upgrade.

---

## What lab carries that DNRA does NOT inherit

- **Verdict type** (`Pass | Falsified | Inconclusive`) — lab-specific to falsification experiments. DNRA uses `halt.reason` enum on deliberation entries and `resolution.score` on outcome entries.
- **Counters list** — lab-specific. DNRA uses the structured `panel[*]` and `mode_attribution` fields instead.
- **HTTP-based remote signing via Pi** — lab uses Pi signer on `fleet0:9102` for some flows. DNRA v0 signs locally (Mini-resident key). May add Pi witness later.
- **Witness file (`countersigs.jsonl`)** — lab supports multi-witness gossip. DNRA v0 is single-signer. The `witnesses[]` field exists in the schema but is always empty in v0.

---

## Open implementation questions (resolve during impl)

- **Q-impl-1**: Match lab's raw-hex `id` (e.g., `"8411f81f..."`) or prefixed `"sha256:<hex>"`? Lab sample shows raw. Pin to raw for compatibility with any cross-chain tooling.
- **Q-impl-2**: Inline canonical JSON encoder in ledger.rail, or factor to a separate `tools/dnra/impl/canonical_json.rail` module? Lab inlines. v0 inlines, factor in v0.4 if other DNRA modules need it.
- **Q-impl-3**: Does Rail's `stdlib/ed25519_sign.rail` work cleanly on Mini (M4 Pro)? Last update 2026-05-02 per memory. Test before relying.
- **Q-impl-4**: Lock granularity — one LOCK.d per chain, or one LOCK.d shared across both chains? Per-chain to allow concurrent appends. Pin per-chain in v0.

---

## Test plan (T2 acceptance)

`tools/dnra/impl/test_ledger.rail` must pass:

1. **Genesis** — open empty chain, append first entry, verify `parents == []`.
2. **Linear chain** — append 5 entries, verify each `parents == [prior_id]`.
3. **Hash determinism** — re-serialize body, recompute id, assert equals stored.
4. **Tamper detection** — manually edit one entry's body in the JSONL, verify chain rejects.
5. **Crash safety** — interrupt mid-append (simulated by truncating the file), verify next open detects + refuses to append until reconciled.
6. **Two-chain isolation** — append to deliberations, then to outcomes, verify both chain heads are independent.

All six gate T2 → completed.
