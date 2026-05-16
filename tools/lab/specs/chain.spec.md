_lab/chain.spec.md — append-only attestable work chain (piece 2 of 3)_

# tools/lab/chain.rail — Storage + Read Layer Spec

Status: SHIPPED v0. Date: 2026-05-15. Author: Lockheed-grade spec for the
attestable-work-chain subsystem. Piece 1 is `tools/lab/entry.rail` (shipped,
22/22); piece 3 is `tools/lab/run.rail` (sketched, depends on this interface).

**Implementation file**: `tools/lab/chain.rail` (~880 lines).
**Acceptance tests**: `tools/lab/test_chain.rail` (12/12 PASS as of
2026-05-15; run via `./rail_native run tools/lab/test_chain.rail`).

## 1. Purpose & scope

`chain.rail` is the **storage + read** half of the attestable-work-chain. It is the
substrate that lets the team ask, hours-or-months later:

  * "Have we already tried this hypothesis?"
  * "Which prior entry does this attempt build on (`parents`)?"
  * "How many times has hypothesis H been falsified?"
  * "Have we given up on goal G?" (i.e. count of GIVE_UP-verdict entries naming G)
  * "Show me the DAG rooted at entry X."

The chain holds *opaque-to-us* entries produced by `entry.rail`. We never re-canonicalize,
re-sign, or re-validate them. Our contract: take a signed-and-canonicalized blob,
durably append it, index it, gossip it, answer queries about it.

### Explicitly NOT in scope

  * Signing / Ed25519 key handling (entry.rail).
  * Canonical-form construction or content-address computation (entry.rail).
  * Schema validation of entry contents (entry.rail validates before handing us a blob).
  * Running experiments / deciding verdicts (piece 3).
  * UI / serving (a `tools/lab/serve.rail` may layer on top later; out of scope here).

## 2. Storage layout

### 2.1 Decision (SHIPPED): **hybrid log-plus-sidecar, rooted at `$RAIL_LAB_HOME`**

```
$RAIL_LAB_HOME/                     -- default: $HOME/.rail/lab  (env override; open() arg override)
  chain/
    log.jsonl                       -- canonical append-only log (ONE entry per line)
    countersigs.jsonl               -- witness countersigns, append-only (separate file)
    index/
      meta.txt                      -- {schema=1, log_sha256=..., entry_count=N}  [text, not JSON]
    LOCK.d/                         -- atomic-mkdir writer lock (replaces flock LOCK file)
      owner.txt                     -- marker string (NOT a pid — see §6)
```

**[CHANGED FROM SKETCH]** Three deviations from the §2.1 sketch:

  1. **Default root**: `$HOME/.rail/lab` (not `./.lab/`). This survives
     `cd`-ing into a workspace; the original `./.lab/` would have created
     fresh chains every directory.
  2. **No JSON sidecars**. `by_id.json` / `by_goal.json` / `parents.json` /
     `children.json` / `verdict_counts.json` are NOT written. Indices are
     in-memory only, rebuilt from `log.jsonl` on every `chain_open`.
     Reason: encoding/decoding those would require `stdlib/json.rail`,
     which has a known parse conflict when co-imported with our crypto
     stack (entry.rail documents the same workaround at line 17-22 of
     its source). Building a JSON encoder inline duplicates entry.rail's
     work for cache files. The performance cost — one O(n) scan per
     open — is sub-second for <10k entries, the expected v0 chain size.
     If/when chains grow past that, the disk-cache path is added behind
     an opt-in.
  3. **Lock is `LOCK.d/` (directory), not `LOCK` (file).** `mkdir(2)` is
     atomic in POSIX and ships everywhere; macOS does not provide
     `/usr/bin/flock`. See §6.

### 2.2 Why this layout

A **single canonical log file** (`log.jsonl`) is the source of truth. JSONL is
already the project's house format for append-only data (see `tools/witness/`,
`stdlib/file.rail::append_line`, harvest pipelines under `tools/domains/`). One
file = one fsync per append, one O(n) recovery scan, trivial to back up or pipe
through `wc -l`.

A **directory-of-`<id>.json`** scheme was considered and rejected: cheaper random
read but explodes inode count, makes filesystem-level tampering harder to detect
(no canonical byte order), and complicates witness gossip (no single file to
hash). Content-addressing already gives us cheap random reads once we have the
in-memory `by_id` offset map.

**Indices are sidecars and explicitly derived.** Any index can be rebuilt from
`log.jsonl` via `chain_rebuild_index`. If `index/` is missing or `meta.json`
disagrees with `log.jsonl`'s sha256, we rebuild without ceremony. This is the
Postgres-WAL discipline: the log is truth, everything else is a cache.

**Countersigns live in their own append-only file**, `countersigs.jsonl`, NOT
inline in the entry. Reason: an entry's content-address (sha256 of canonical body)
is fixed at creation time. Witness countersigns arrive later, sometimes hours
later, sometimes from multiple witnesses. Inlining them would either (a) require
mutating the log (forbidden) or (b) require redefining content-address to exclude
them (entry.rail's problem, and ugly). A sidecar keeps the entry blob immutable
while letting countersigns accrete.

### 2.3 log.jsonl line format

Each line is **exactly** the canonical body bytes produced by entry.rail, followed
by `\n`. No wrapper, no metadata, no leading offset. This means
`sha256(line_without_newline) == id`. Rebuilding the index is a pure stream of
line-reads + sha256 + JSON-parse-for-fields-we-index.

### 2.4 countersigs.jsonl line format

```json
{"id":"<entry_id_hex>","witness":"fleet0","pk_fp":"...","sig":"...","pulse_id":N,"value_hex":"...","witnessed_at":<unix>}
```

Multiple lines per entry id are normal (one per witness × one per pulse). Order
within the file follows append time. Verifiers reading countersigs must dedupe by
`(id, witness, pulse_id)` themselves.

## 3. Public interface (SHIPPED signatures)

All functions return Rail values; errors use the `error "..."` mechanism with
`is_error` / `err_msg`. Pre-conditions failing produce a typed error string,
not a panic.

**Naming convention**: parameters bound to a `ChainHandle` are named `h`
in source. (Rail's parser reserves `handle` as a keyword for effect
handlers; this is the first quirk new readers trip over.)

### 3.1 Handle lifecycle

```rail
chain_open root_dir -> chain_handle
  -- Opens (or creates) chain at root_dir. Loads indices by streaming log.jsonl.
  -- If root_dir is "", falls back to $RAIL_LAB_HOME, then $HOME/.rail/lab.
  -- Pre:  root_dir (or default) is a writable directory path (created if missing).
  -- Post: handle owns advisory lock on $root_dir/chain/LOCK.d/. Indices populated.
  -- Errors: "chain:locked"        — another writer holds LOCK.d.
  --         "chain:corrupt-log"   — log.jsonl line failed entry_deserialize.

chain_open_ro root_dir -> chain_handle
  -- Read-only variant: does NOT acquire the writer lock. Cannot append.

chain_close h -> int
  -- Releases lock (rm -rf LOCK.d/), drops in-memory indices.
  -- Idempotent. Always returns 0.
```

### 3.2 Write (the only mutating function)

```rail
chain_append h entry_blob -> id_string
  -- Append `entry_blob` (the JSON form from entry_serialize entry []) to log.jsonl.
  -- Pre:   entry_blob deserializes via entry.rail; we do NOT re-verify the signature.
  -- Post:  log.jsonl gains one line; in-memory indices on a returned handle
  --        (see chain_append_h below) reflect the new entry.
  -- Returns: hex string id = entry_content_hash entry.
  -- Errors: "chain:duplicate-id"     — id already in this chain.
  --         "chain:parent-missing"   — entry names a parent not yet in the log.
  --         "chain:disk-full"        — write or size-check failed; log truncated
  --                                     back to its pre-call byte length.
  --         "chain:no-lock"          — h is read-only.
  --         "chain:invalid-blob"     — entry_blob did not deserialize.

chain_append_h h entry_blob -> (chain_handle, id_string)            [CHANGED FROM SKETCH]
  -- Mutating-style variant: returns the updated handle alongside the id.
  -- Use this from test/runner code that needs to thread the index forward.
  -- (Rail values are immutable; the sketch's `chain_append handle ...`
  -- returned just the id, which left the caller's in-memory index stale.
  -- This pair-returning sibling is the canonical write API. The
  -- original `chain_append` is kept as a convenience for callers that
  -- intentionally drop the new handle and re-open.)
```

### 3.3 Read by id / DAG walks

```rail
chain_get h id -> entry_blob
  -- Returns the JSON line (string, no trailing newline) for `id`, or
  -- error "chain:not-found". O(1) seek via in-memory by_id offset map.

chain_read h id -> entry_blob                                       [ALIAS for chain_get]
  -- Identical to chain_get. Provided to satisfy run.rail spec §11
  -- which uses chain_read in its sample code.

chain_lookup_prefix h prefix -> string                              [ADDED for run.rail]
  -- Returns the unique full id whose hex prefix matches, or the
  -- literal string "NONE" / "AMBIGUOUS". Used by the `verify <short>`
  -- run.rail command.

chain_walk_parents h id depth -> [id]
  -- BFS via parents edges, up to `depth` levels (depth<0 = unbounded).
  -- Returns ids in BFS order, with the start id at position 0.
  -- Cycle-safe via visited-set.

chain_walk_children h id depth -> [id]
  -- Symmetric. Uses the reverse-edge map computed at open time.
```

### 3.4 Read by substring

```rail
chain_search_goal h needle -> [id]
  -- Case-folded substring search across the `goal` AND `hypothesis`
  -- fields, OR'd, deduped, returned in append order. v0 ships a flat
  -- O(n_entries) scan over the in-memory lowercased text. Spec §10
  -- 6-gram inverted index is deferred.
  --
  -- [WIDENED 2026-05-16 — Path A]: originally goal-only. The name is
  -- kept for API stability (run.rail's `search` subcommand and
  -- step1_show_priors call it unchanged), but the implementation now
  -- ORs goal and hypothesis. Motivation: amendment entries (e.g. an
  -- "Amendment: record hypothesis for genesis <id>" row whose
  -- hypothesis text is the substantive content) were invisible to the
  -- "have we tried this?" lookup. Dedup is implicit because we iterate
  -- `by_id_order` once and OR the two fields per id.
  --
  -- The strict goal-only variant is NOT exported separately; callers
  -- who need it can call entry.rail field accessors directly. The
  -- strict hypothesis-only variant remains as chain_search_hypothesis.

chain_search_hypothesis h needle -> [id]
  -- Strict hypothesis-only substring search. Retained for callers
  -- that explicitly do NOT want goal matches mixed in.
```

### 3.5 Verdict counts

```rail
chain_count_verdict_for_hypothesis h hyp_selector -> [(tag, count)]
  -- hyp_selector is built via the HypSelector ADT:
  --   HypById   id_string    — exact hypothesis-entry id
  --   HypByText substring    — fuzzy match on hypothesis text
  -- Returns EXACTLY THIS SHAPE [CHANGED FROM SKETCH]:
  --   [("FALSIFIED", f), ("INCONCLUSIVE", i), ("PASS", p)]
  -- Tag order is alphabetical and the three tags are always present
  -- (zero-counts inclusive). entry.rail's Verdict ADT enumerates these
  -- three values; GIVE_UP is a chain-layer rollup, see chain_count_give_up_for_goal.

chain_count_give_up_for_goal h goal_substring -> int
  -- Count of entries whose goal substring-matches AND verdict==FALSIFIED.
  -- Operator heuristic for "have we given up?".
```

### 3.6 Index ops

```rail
chain_rebuild_index h -> int
  -- Returns the entry count from the in-memory index (which was already
  -- rebuilt at chain_open). Provided for run.rail's `rebuild-index` cmd.

chain_rebuild_index_h h -> (chain_handle, int)                      [CHANGED FROM SKETCH]
  -- Mutating-style sibling that actually re-streams log.jsonl and
  -- returns a fresh handle. Use this if you suspect index drift.

chain_verify_log h -> int
  -- For each line, parses + recomputes entry_content_hash and confirms
  -- it matches entry_id and appears in by_id. Returns 0 on success,
  -- errors "chain:corrupt-log" on the first mismatch.

chain_verify h id -> bool                                            [ADDED for run.rail]
  -- Single-entry verify: fetches by id, runs entry_verify, returns
  -- true iff signature still validates. False on any error path.

chain_lock_status h -> bool                                          [ADDED for run.rail]
  -- Returns true iff the lock directory exists right now. Cheap.
```

### 3.7 Witness gossip

```rail
chain_gossip_to_witnesses handle id witness_list -> [countersig]
  -- For each witness host in witness_list:
  --   1. POST the entry blob (and its id) to the witness's `/lab/chain/sign`
  --      endpoint (URL shape: `https://<host>/lab/chain/sign`).
  --   2. Witness re-derives id = sha256(blob), signs the canonical message
  --        "labchain|v1|<id>|<pulse_id>|<value_hex>|<witnessed_at>"
  --      using the SAME Ed25519 key it uses for report attestations
  --      (see tools/attest/report_attestation_publisher.sh §4).
  --   3. Witness returns countersig JSON; we append to countersigs.jsonl.
  -- Returns list of accepted countersigs. Offline / timing-out witnesses are
  -- skipped silently (logged to stderr); we DO NOT fail the chain for a missing
  -- witness — at-least-one-witness is the consensus rule (§4).
  --
  -- Errors:
  --   "chain:not-found"      — id not in this chain.
  --   "chain:gossip-all-down"— ZERO witnesses returned a valid countersig.

chain_accept_witness_countersig handle countersig_json -> int
  -- Validates shape (id, witness, sig, pulse_id, value_hex, witnessed_at) and
  -- appends to countersigs.jsonl. Returns 1 if appended, 0 if dedup hit (same
  -- (id, witness, pulse_id) already present). Does NOT verify the Ed25519 sig —
  -- that's a verifier's job, downstream.
```

### 3.8 Countersig read

```rail
chain_countersigs_for handle id -> [countersig_record]
  -- Returns all countersigs whose `id` field matches; deduplicated by
  -- (witness, pulse_id) with the latest-witnessed_at winning.
```

## 4. Witness integration

`tools/witness/` today is JS-shaped (viz.html + consensus_test.js + fixtures). It
defines the classification logic — `consensus`, `divergent`, `partial`,
`value-mismatch`, `behind`, `chain-break`, `no-live` — that we will mirror for
chain entries.

### 4.1 What chain.rail reuses

  * **Witness host list** — read from `tools/witness/fixtures/*.json` to seed
    `witness_list` defaults. (The Ed25519 keys themselves live on the witness
    machines, never in this repo.)
  * **Canonical inner-message format** — `labchain|v1|<id>|<pulse_id>|<value_hex>|<witnessed_at>`,
    same pattern as `report|v2|...` in `tools/attest/report_attestation_publisher.sh`.
    Distinct prefix (`labchain` vs `report`) so a witness can route signing
    domains; we will add a `sign_labchain.sh` next to `sign_attestation.sh` on
    each witness host (out-of-scope deploy, but the protocol shape is fixed
    here).
  * **Consensus classification** — chain.rail does NOT make consensus calls
    inline. It records countersigs; a viewer (analogous to viz.html) classifies
    them using the same `classify(beacon, results)` function from
    `consensus_test.js`. Reusing that function keeps the rule-set
    single-sourced.

### 4.2 Failure mode if a witness is offline

`chain_gossip_to_witnesses` treats each witness independently: 4-second
connect-timeout, then move on. A countersig that never arrives is **not** an
error for the appending agent; it shows up later as `partial` or `no-live`
classification when a reader counts the countersig array.

The only hard error is `chain:gossip-all-down` (zero witnesses signed). Caller
policy decides whether that blocks publication of the chain externally.

### 4.3 "Consensus" definition for a chain entry

An entry `id` is **consensus-witnessed** iff:

  1. countersigs.jsonl contains ≥2 distinct witnesses for `id`, AND
  2. their `(pulse_id, value_hex)` agree, AND
  3. `chain_verified=true` on every countersig record we accept.

One-witness entries are **partial**. Zero-witness entries are **un-witnessed**
(perfectly valid; just not externally provable). The chain still stores all
three states.

## 5. Failure modes table

| Mode | Detection | Response |
|---|---|---|
| Corrupted log.jsonl (partial trailing line) | Last line missing newline OR id-recompute mismatch on rebuild | `chain_open` rolls back the bad partial line (truncate to last full `\n`), logs to stderr, continues. If the truncation would drop a fully-written line whose id is in by_id, error "chain:corrupt-log" — do not auto-heal. |
| Missing index | `index/` dir absent or `meta.json.schema` wrong | Auto-rebuild from log.jsonl on open. No user action needed. |
| Index stale | `meta.json.log_sha256 != sha256(log.jsonl)` | Auto-rebuild on open. |
| Parent-not-found at append | Index lookup miss on declared parent | Strict mode (default): refuse append. Relaxed mode (env `RAIL_LAB_ALLOW_DANGLING_PARENT=1`): append + log warning. Used for bootstrapping or cross-chain references. |
| Duplicate id append | by_id already has key | error "chain:duplicate-id". Idempotency is the caller's job; we surface, we don't swallow. |
| Disk full / write failure | write/fsync returns nonzero | Truncate partial write back to pre-call offset (`ftruncate`). Indices untouched (we update them only after fsync). Error "chain:disk-full". |
| Concurrent write (two processes) | LOCK held | `chain_open` errors "chain:locked". Single-writer policy (§6). |
| Witness countersig replay | Same (id, witness, pulse_id) submitted twice | Dedup in `chain_accept_witness_countersig`. Latest `witnessed_at` wins on conflict; older is discarded. |
| Witness offline | Connect timeout / non-200 | Skip silently in `chain_gossip_to_witnesses`; record absence implicitly by missing countersig. Hard fail only if all witnesses are down. |
| Log truncated externally | sha256(log.jsonl) shorter than meta.json.last_offset | `chain_open` rebuilds from scratch; warns to stderr that chain shrank (potential tampering signal). |

## 6. Concurrency (SHIPPED)

**Decision: single-writer, multi-reader, atomic-mkdir advisory lock.**

  * On `chain_open` the handle calls `mkdir <root>/chain/LOCK.d`. This is
    atomic in POSIX and ships on macOS without external tools (unlike
    `flock(1)`, which is Linux-only). If LOCK.d already exists,
    `chain_open` errors `"chain:locked"`.
  * Readers use `chain_open_ro` which skips the mkdir.
  * **[CHANGED FROM SKETCH]** A crashed writer leaves LOCK.d behind.
    Recovery is one keystroke: `rm -rf <root>/chain/LOCK.d`. We do NOT
    auto-reclaim by PID because Rail's `shell` builtin spawns a child
    shell whose `$$` is the child's PID, not ours — a wrong-positive
    reclaim would race two writers into the same log. A wrong-negative
    leak that requires manual unlock is the safer failure mode.

Justification for single-writer:

  * The chain is small (the *value* compounds; the *bytes* don't). Throughput is
    not a goal. One agent appending while another runs an experiment is fine
    because the experiment doesn't write to the chain — the post-experiment
    summarizer does, serially.
  * Multi-writer would require either a real WAL with sequence-number reservation
    or an external coordinator. Both are 10× the complexity for zero current
    benefit.
  * Witness gossip is read-from-chain + network-out + append-to-countersigs.
    Countersig appends are also serialized by the same writer lock.

If a future use case demands multi-writer, the migration is well-defined: split
`log.jsonl` into per-writer shards with a fan-in compactor. The on-disk format
above is forward-compatible with that.

## 7. Acceptance test plan (SHIPPED, 15/15 PASS as of 2026-05-16)

Tests live at `tools/lab/test_chain.rail`. Exit-code-honest (exit 0 +
last line `PASS`). Run: `./rail_native run tools/lab/test_chain.rail`.

| # | Test name | Falsifies | Maps to invariant |
|---|---|---|---|
| 1 | T-APPEND-GET | append + chain_get returns byte-identical blob | round-trip integrity |
| 2 | T-DUP | second `chain_append` of the same blob → `chain:duplicate-id`; log has 1 line | CHAIN-DUP-REJECTED |
| 3 | T-PARENT-MISSING | dangling parent at append → `chain:parent-missing` | CHAIN-PARENT-DAG (append-time check) |
| 4 | T-PARENT-WALK | 3-entry chain A←B←C; `chain_walk_parents C` returns [C,B,A]; `chain_walk_children A` returns 3 | DAG walks |
| 5 | T-SEARCH-GOAL | 3 entries with overlapping goal substrings; `chain_search_goal` returns the right matches | substring index |
| 6 | T-VERDICT-COUNT | hypothesis H + 3 FALSIFIED children + 1 PASS; `chain_count_verdict_for_hypothesis (HypById H)` returns FALSIFIED=3, PASS=1, INCONCLUSIVE=0 | CHAIN-VERDICT-COUNT |
| 7 | T-INDEX-REBUILD | nuke `index/`, re-open; `chain_get` + `chain_search_goal` still work; entry count preserved | index reconstructibility |
| 8 | T-ATOMIC | failed append (dup-id, then parent-missing) leaves `sha256(log.jsonl)` byte-identical | CHAIN-APPEND-ATOMIC |
| 9 | T-LOCK | second `chain_open` against the same root errors `chain:locked` | concurrency |
| 10 | T-VERIFY-LOG | every line passes content-hash and by_id checks → 0 | log integrity |
| 11 | T-COUNTERSIG | first accept = 1, second accept of same JSON = 0 (dedup); `chain_countersigs_for` lists 1 record | witness dedup |
| 12 | T-SEARCH-HYP | 2 entries whose goal does NOT contain the query but whose hypothesis DOES; `chain_search_goal` returns both ids in append order | Path A widening — hypothesis-reachable search |
| 13 | T-SEARCH-COMBINED | one entry matches goal only, one matches hypothesis only, one matches neither; query returns the first two | Path A widening — goal OR hypothesis |
| 14 | T-SEARCH-DEDUPE | one entry's goal AND hypothesis both contain the query; result has the id exactly once | Path A widening — implicit dedup |
| 15 | T-PREFIX | 12-char unique prefix resolves; missing prefix returns "NONE" | run.rail interface |

T-ATOMIC is the closest we get to a kill-9 simulation from inside Rail.
The append-only-after-write-ok code path is shared between disk-full
and dup-id paths, so a successful T-ATOMIC implies (modulo the
write-then-truncate `head -c` operation) that disk-full would also
leave the log byte-identical. A future test that uses
`tools/runtime/build_concurrent.sh` to spawn a side-process and SIGKILL
it mid-append would close that gap; deferred from v0.

## 8. Interface required FROM entry.rail (sketcher cross-check)

This is the **only coupling** between chain.rail and entry.rail. Cross-checked
against the parallel-sketched `tools/lab/entry.rail` (2026-05-15). Their
contract is RICHER than the opaque-blob model I originally assumed — they
expose a typed `Entry` ADT with field accessors. That changes a few details
below; chain.rail adapts.

### 8.1 Functions chain.rail will call

```rail
-- Constructors / mutators: NOT called by chain.rail (callers above us
-- build entries before handing them down for append).

-- Canonical form & hashing:
entry_canonical_body entry  -> string        -- canonical ASCII pipe-delimited body
entry_content_hash  entry   -> id_string     -- 64-char lowercase hex sha256

-- Verification (called optionally on append for paranoia; spec §3.2 default
-- is to TRUST the caller, but RAIL_LAB_VERIFY_ON_APPEND=1 enables this):
entry_verify        entry   -> int           -- 1=ok, 0=forgery, error=malformed

-- Serialization round-trip (this is what we actually write to the log;
-- see §8.2 below):
entry_serialize     entry witnesses -> string         -- JSON string
entry_deserialize   json_string     -> (entry, [witness])

-- Field accessors (we use these to populate indices):
entry_id            e -> id_string
entry_parents       e -> [id_string]
entry_goal          e -> string
entry_hypothesis    e -> string              -- free text; "" if none
entry_kill_target   e -> string              -- the falsification target / "give-up trigger"
entry_result        e -> Result              -- (Pass | Falsified | Inconclusive, [(name, val_str)])
entry_pulse_id      e -> string
entry_created_at    e -> string

-- Witness ops:
entry_attach_witness entry witnesses key sig witnessed_at -> [witness]
entry_verify_witness entry witness -> int
```

### 8.2 What goes in log.jsonl (revised from §2.3)

Each line is **`entry_serialize entry []`** — i.e. the JSON form of the entry
with an empty witness array. The serialization is canonical (entry.rail's
spec §4.8 owns that). Content-address `id = entry_content_hash entry`, which is
sha256 of `entry_canonical_body` — NOT of the JSON line. The JSON wraps the
canonical body and adds the signature/pubkey; rehydrating an entry from a
log line goes through `entry_deserialize`.

This means our rebuild loop is:

```
for each line in log.jsonl:
    (entry, _witnesses_ignored) = entry_deserialize(line)
    id = entry_id(entry)             -- (already in the JSON; we recompute to verify)
    index.by_id[id] = offset
    index.by_goal += tokens(entry_goal(entry))
    ...
```

Witnesses on the LINE are ignored (they may be empty or stale from an
external import); the authoritative countersigs live in `countersigs.jsonl`.

### 8.3 Verdict-tag mapping (SHIPPED)

entry.rail's `Verdict = Pass | Falsified | Inconclusive` is the ground
truth. **[CHANGED FROM SKETCH]** entry.rail's `verdict_to_string` emits
ALL-CAPS strings (`"PASS"` / `"FALSIFIED"` / `"INCONCLUSIVE"`); chain.rail
preserves those exact tags in its tally output.

**`GIVE_UP` is NOT a verdict** in entry.rail's model; it's a goal-level
condition derived by the reader. `chain_count_give_up_for_goal` (defined in
chain.rail §3.5) is therefore implemented as: count entries where
`entry_goal` substring-matches AND `entry_result` is `Falsified` AND no later
entry whose `parents` references this one with `entry_result = Pass` exists.
The "give up?" heuristic is a chain-layer rollup over hypothesis-falsification
streaks; it is not stored as a first-class verdict.

### 8.4 Hypothesis linkage

entry.rail does NOT carry a `hypothesis_ref` field — falsification linkage is
expressed exclusively via the `parents` list. So
`chain_count_verdict_for_hypothesis` with `HypById h` is implemented as: walk
`children h` (one level), filter to entries whose `entry_result` is non-empty,
and tally their verdict tags.

### 8.5 Degraded modes

  * If `entry_deserialize` errors on a log line → chain marks log corrupt
    (err_corrupt_log) on rebuild; does NOT silently drop the line.
  * If `entry_verify` returns 0 on append in verify-on-append mode → reject
    with err_invalid_blob; signature forgery is a hard error.

### 8.6 Hard requirements summary

chain.rail cannot ship without these from entry.rail:

  1. `entry_serialize` / `entry_deserialize` round-trip (line-orientable: NO
     embedded `\n` in the JSON output, or we length-prefix at chain layer).
  2. `entry_content_hash` (the id we content-address on).
  3. `entry_parents` + `entry_goal` + `entry_hypothesis` + `entry_result`
     (the four fields we index).

Everything else is optional/decorative.

## 9. Non-goals (one more time, because they matter)

  * **We do not sign anything.** Witnesses sign at gossip time; entry.rail signs
    at creation time. chain.rail is signature-free.
  * **We do not validate schema.** If `entry_parse_ok` returns false on a line we
    are about to append, we error `chain:invalid-blob` and refuse — but we do
    not understand WHY it failed; that's entry.rail's diagnostic.
  * **We do not serve HTTP.** A future `tools/lab/serve.rail` may wrap us; not
    here.
  * **We do not run experiments, score them, or decide give-up.** Piece 3.
  * **We do not garbage-collect.** Append-only is the property. If the chain
    grows unmanageable, the response is sharding by date prefix
    (`chain/2026-Q2/log.jsonl`), not deletion. Not in v0 scope.

## 10. Future work (deliberately deferred)

  * 6-gram inverted index inside `by_goal.json` / `by_hypothesis.json` (v0 ships
    flat substring scan; works fine for <10k entries).
  * Cross-machine chain merge (rsync the log, replay through `chain_append` — works
    today but the duplicate-id semantics may want a `chain_import_external` that
    skips dedup-as-error in favor of dedup-as-no-op).
  * Bloom filter on `by_id` for the "have we tried this?" query at scale.
  * Compaction / Merkle-tree summary so a witness can sign a chain *prefix*
    rather than each entry individually.

## 11. Interface contract for run.rail (piece 3)

run.rail's §11 lists the chain-layer functions it expects to call. This
table is the binding answer from the chain-layer side, post-shipping:

| run.rail expectation | chain.rail provides | Status |
|---|---|---|
| `chain_open path -> handle` | `chain_open root_or_empty -> ChainHandle` | OK; pass `path` directly. |
| `chain_append h entry -> id` | `chain_append h entry_blob -> id` | OK. `entry_blob` is the result of `entry_serialize entry []`. |
|  | `chain_append_h h entry_blob -> (h, id)` | **PREFERRED**: returns updated handle so caller can keep using the indexed in-memory state. |
| `chain_search_goal h query opts -> [sum]` | `chain_search_goal h needle -> [id]` | **DIFFERS**: shipped returns ids only; the `entry_summary` (`["sum", id, ts, verdict, goal_prefix]`) shape is run.rail's responsibility to build via `chain_get` + `entry_deserialize` + accessors. The `opts` parameter (since/limit/verdict) is also not in v0; filter in run.rail. |
| `chain_lookup_prefix h prefix -> string` | `chain_lookup_prefix h prefix -> string` | OK. Returns full id, or `"NONE"` / `"AMBIGUOUS"`. |
| `chain_read h id -> entry` | `chain_read h id -> entry_blob` | **DIFFERS**: shipped returns the JSON line (string), not the parsed Entry. run.rail calls `entry_deserialize` on the result. Same blob `chain_get` returns. |
| `chain_verify h id -> bool` | `chain_verify h id -> bool` | OK. |
| `chain_gossip_to_witnesses h id fleet_path -> [n, threshold]` | `chain_gossip_to_witnesses h id witness_list -> [countersig]` | **DIFFERS**: shipped takes a list of witness host strings (not a fleet-config path) and returns the accepted countersigs. run.rail's responsibility: (a) parse `witnesses.toml` into a host list, (b) reduce the returned `[countersig]` to `[responded_count, threshold_implied]`. The reduction is a one-liner. |
| `chain_lock_status h -> bool` | `chain_lock_status h -> bool` | OK. |
| `chain_rebuild_index h from_id -> int` | `chain_rebuild_index h -> int` | **DIFFERS**: no `from_id` parameter (we always rebuild from offset 0). For v0 this is fine; chains <10k entries rebuild in sub-second. If run.rail truly needs incremental, use `chain_rebuild_index_h` and walk only the new tail. |

### 11.1 Witness fleet integration

run.rail's `witnesses.toml` lives in `attest/witnesses.toml`. Each row
has `id`, `endpoint`, `pubkey`. chain.rail's `chain_gossip_to_witnesses`
shells out to `$RAIL_LAB_WITNESS_CMD <host> <id> <pulse_id> <value_hex>
<witnessed_at>` (env-configured). The witness command MUST emit one
countersig JSON line to stdout on success and empty stdout on failure.

If `RAIL_LAB_WITNESS_CMD` is not set, gossip returns `[]` (no error)
and run.rail treats it as "fleet offline". This matches spec §4.2's
"witness offline" failure mode — at-least-one-witness is the consensus
rule, zero witnesses is the fail.

### 11.2 Error tag stability

All error tags use the `chain:` prefix and are exported as Rail
top-level constants (`err_locked`, `err_duplicate_id`, etc.) so
run.rail can compare against them by name or by prefix:

  * `chain:locked`
  * `chain:corrupt-log`
  * `chain:io`
  * `chain:not-found`
  * `chain:duplicate-id`
  * `chain:parent-missing`
  * `chain:disk-full`
  * `chain:no-lock`
  * `chain:gossip-all-down`
  * `chain:invalid-blob`

— end of spec —
