# `tools/lab/entry.rail` — Attestable Experiment Entry (piece 1 of 3)

Status: IMPLEMENTED (2026-05-15). Acceptance tests: `tools/lab/test_entry.rail` — 22/22 PASS.
Author lineage: substrate / attestable-work-chain subsystem.
Companion files (later pieces): `tools/lab/chain.rail` (piece 2 — storage + parent linkage), `tools/lab/witness.rail` (piece 3 — multi-witness countersign + gossip).

Reuses: `stdlib/sha256.rail`, `stdlib/ed25519.rail` (verify-only), `stdlib/sha512.rail`, `stdlib/x25519.rail`, `stdlib/bytes.rail` (transitively via sha256). `stdlib/json.rail` was NOT used — it has a parse-time interaction with our crypto deps; we ship a tightly-scoped JSON encoder + decoder inline. See §8 O-1 / O-5 for the rationale.

---

## 1. Purpose & scope

`entry.rail` owns the **single experiment record** primitive of an attestable work chain. One entry = one experiment: stated bet, falsification criterion, named counters, the exact command that was run, the verdict, and a signature binding all of it to the signer's keypair.

### Owns

- The `Entry` data type and its field shape.
- Canonicalization rules: turning an in-memory `Entry` into the exact byte sequence that gets hashed and signed.
- The required-fields validator: refusing to sign an entry that has no `kill_target` or no `counters`.
- Content addressing: `id = sha256(canonical_body)` rendered as 64-char lowercase hex.
- Serialization / deserialization to JSON.
- Signature attachment (`entry_sign`) and signature verification (`entry_verify`).
- Witness countersignature attachment hooks (the storage of `witnesses[]`; the gossip protocol itself is piece 3).

### Does NOT own

- Persistent storage. (Piece 2: `chain.rail` will keep entries on disk and resolve parent links.)
- Network I/O. No fetch, no PUT, no SSH. Pure in-memory + caller-provided bytes.
- Witness gossip / multi-host coordination. (Piece 3.)
- Pulse fetching from the entropy beacon. Caller passes `pulse_id` as a string.
- Weights hashing. Caller passes `weights_hash` (or empty string).
- Signing-key management or HSM access. `entry_sign` accepts a 64-byte raw signature produced by **any** Ed25519 signer (caller's choice: external `sign_attestation.sh`, future pure-Rail signer, hardware key). See §8 open questions.

---

## 2. Data model

### Rail type

```rail
-- An entry is an ADT with one constructor carrying all 13 fields.
-- This avoids 13-element positional lists at call sites; pattern-match
-- destructure once in helpers.
type Entry = | Entry
    id              -- string, lowercase hex of sha256(canonical_body), 64 chars
    parents         -- list of strings, each a 64-char hex id; may be []
    goal            -- string, ASCII, single line
    hypothesis      -- string, ASCII, single line
    kill_target     -- string, ASCII, single line, REQUIRED (non-empty at sign time)
    counters        -- list of strings, each ASCII identifier; REQUIRED (length >= 1)
    cmd             -- string, ASCII, the exact shell or rail command executed
    result          -- Result ADT (below)
    pulse_id        -- string, decimal digits or empty; optional
    weights_hash    -- string, 64-char lowercase hex, or empty; optional
    created_at      -- string, ISO 8601 UTC "YYYY-MM-DDTHH:MM:SSZ" (no fractional seconds, Z literal)
    sig             -- string, 128-char lowercase hex (64-byte Ed25519 signature), or empty pre-sign
    signer          -- string, 64-char lowercase hex (32-byte Ed25519 public key), or empty pre-sign

-- `witnesses` lives OUTSIDE the canonical body: countersignatures over the
-- already-signed `id`. Attaching/removing a witness must NOT change `id`.
-- Stored alongside the entry but not part of `Entry` ADT; carried as a
-- separate list returned from `entry_attach_witness`.
--
-- A Witness is:
type Witness = | Witness
    key             -- string, 64-char hex public key
    sig             -- string, 128-char hex signature over `id` (the hex string, ASCII bytes)
    witnessed_at    -- string, ISO 8601 UTC
```

### Result ADT

```rail
type Result = | Result
    verdict         -- Verdict ADT (PASS | FALSIFIED | INCONCLUSIVE)
    numbers         -- list of (name, value) pairs; name is string, value is float-as-string
                    --   Stored as string to keep canonical form stable across float printing quirks;
                    --   see §3 canonicalization rule R-NUM.

type Verdict = | Pass | Falsified | Inconclusive
```

### Required-vs-optional matrix

| Field          | Required at `entry_new` | Required at `entry_sign` | Required at `entry_verify` |
|----------------|-------------------------|--------------------------|----------------------------|
| `goal`         | yes, non-empty          | yes                      | yes                        |
| `hypothesis`   | no (may be empty)       | no                       | no                         |
| `kill_target`  | yes, non-empty          | yes                      | yes                        |
| `counters`     | yes, length >= 1        | yes, length >= 1         | yes, length >= 1           |
| `cmd`          | yes, non-empty          | yes                      | yes                        |
| `result`       | no (default Inconclusive, empty numbers) | yes (verdict in {PASS,FALSIFIED,INCONCLUSIVE}) | yes |
| `parents`      | no (may be [])          | no                       | no                         |
| `pulse_id`     | no                      | no                       | no                         |
| `weights_hash` | no                      | no                       | no                         |
| `created_at`   | yes, valid ISO 8601     | yes                      | yes                        |
| `sig`          | populated by `entry_sign` | n/a                    | yes, 128 hex chars         |
| `signer`       | populated by `entry_sign` | n/a                    | yes, 64 hex chars          |
| `id`           | populated by `entry_sign` | n/a                    | recomputed and compared    |

**Definition of "required at sign time":** `entry_sign` MUST return an error and MUST NOT produce any signed output if a required field fails its check. No partial state. No "warning, signing anyway".

---

## 3. Canonical form

Two semantically-equal entries must hash identically. The canonicalization rules below define "semantically equal".

### Canonical body format

The canonical body is a pipe-delimited ASCII string:

```
entry|v1|<goal>|<hypothesis>|<kill_target>|<counters_joined>|<cmd>|<verdict>|<numbers_joined>|<parents_joined>|<pulse_id>|<weights_hash>|<created_at>|<signer>
```

Where:

- `v1` — format version literal. Bump to `v2` on any rule change in §3.
- `<counters_joined>` — counter names sorted ASCII-ascending, joined with `,` (comma, no spaces). Empty list NOT permitted at sign time; if it ever reaches canonicalization the function returns the literal string `<EMPTY-COUNTERS>` so a downstream verifier sees a deterministic poison value rather than silently producing a different hash. (Sign-time validation should catch it first.)
- `<verdict>` — uppercase ASCII: `PASS`, `FALSIFIED`, or `INCONCLUSIVE`. Nothing else.
- `<numbers_joined>` — number entries sorted ASCII-ascending by name, each rendered as `name=value`, joined with `,`. Value is the caller-supplied string verbatim (see R-NUM below). Empty list → empty string between the surrounding pipes.
- `<parents_joined>` — parent ids in caller-supplied order (DAG order matters), joined with `,`. Empty list → empty string.
- `<pulse_id>` / `<weights_hash>` — either the value as-is or the empty string. No `null` literal, no `"-"` placeholder.
- `<created_at>` — exactly `YYYY-MM-DDTHH:MM:SSZ`, 20 ASCII chars. `entry_new` validates the shape.
- `<signer>` — 64-char hex public key. Bound INTO the digest so that swapping the signer field after signing changes the id.
- All field separators are exactly `|` (single ASCII byte 0x7C).
- The body is pure ASCII. Any byte > 0x7E or < 0x20 (except none — newlines/tabs forbidden in fields) is a canonicalization error.

### Canonicalization rules

- **R-VER**: First two fields are always `entry` and `v1`. Verifier rejects anything else.
- **R-ASCII**: All field values are ASCII printable (0x20–0x7E). Reject on encountering `|`, `\n`, `\t`, `\r`, or any byte > 0x7E inside a field.  Reason: pipe-delimited form has no escape syntax — better to reject than to escape.
- **R-COUNTERS-SORT**: Counter list is sorted ASCII-ascending before joining. `["b","a"]` and `["a","b"]` hash identically.
- **R-NUM-SORT**: `numbers` is sorted ASCII-ascending by name before joining.
- **R-NUM**: Number values are stored as ASCII strings by the caller (e.g. `"3.1415"`, `"42"`). The canonicalizer does NOT reformat them. Two entries with `"3.14"` and `"3.140"` for the same counter will hash differently. This is deliberate — round-tripping floats through `show` is not bit-stable across compile.rail versions, and the chain prefers explicit caller control.
- **R-VERDICT-CASE**: Verdict is always uppercase. Lowercase / mixed-case rejected.
- **R-TIME-FMT**: `created_at` matches `YYYY-MM-DDTHH:MM:SSZ` exactly. No `+00:00`, no fractional seconds. Mismatched format rejected.
- **R-PARENT-ORDER**: Parent list order is preserved (semantically meaningful: "this entry tries to falsify X, then Y").

### Examples — entries that MUST hash identically

```
A:  goal="climb",   counters=["loss","acc"],   numbers=[("acc","0.9"),("loss","0.1")]
B:  goal="climb",   counters=["acc","loss"],   numbers=[("loss","0.1"),("acc","0.9")]
```
Both canonicalize to `…|loss|0.1,…` after sorting counters and numbers. Same id.

### Examples — entries that MUST hash differently

```
C:  numbers=[("loss","0.1")]
D:  numbers=[("loss","0.10")]            -- different string, different hash (R-NUM)

E:  parents=["aa…","bb…"]
F:  parents=["bb…","aa…"]                -- order matters (R-PARENT-ORDER)

G:  verdict=PASS
H:  verdict=FALSIFIED                    -- obvious

I:  signer="aa…"
J:  signer="bb…"                         -- signer is inside the digest

K:  created_at="2026-05-15T12:00:00Z"
L:  created_at="2026-05-15T12:00:01Z"
```

---

## 4. Public interface

All functions return either a plain value (success) or an `error "<code>: <detail>"` value (failure). Callers check with `is_error` / `err_msg`. The error code is the first colon-delimited token of `err_msg`; see §5.

**Signatures as shipped (2026-05-15). No deviations from the sketch.** Every signature below matches the implementation byte-for-byte; chain.rail can pin against this section.

### 4.1 `entry_new goal hypothesis kill_target counters cmd created_at`

Build an unsigned `Entry` with `result = Result Inconclusive []`, empty `parents`, empty optional metadata. Use `entry_set_*` helpers (below) to populate result, parents, pulse, weights before signing.

- **Preconditions**:
  - `goal` non-empty ASCII single-line string
  - `kill_target` non-empty ASCII single-line string
  - `counters` is a list with length >= 1, each element a non-empty ASCII identifier `[A-Za-z_][A-Za-z0-9_]*`
  - `cmd` non-empty ASCII (whitespace allowed)
  - `created_at` matches R-TIME-FMT
- **Postconditions**: returns `Entry …` with `sig=""`, `signer=""`, `id=""`.
- **Errors**: `E-MISSING-GOAL`, `E-MISSING-KILL`, `E-EMPTY-COUNTERS`, `E-BAD-COUNTER-NAME`, `E-MISSING-CMD`, `E-BAD-TIME`, `E-NON-ASCII`.

### 4.2 Setters (return a new `Entry`, immutable update)

- `entry_set_result entry verdict numbers` — verdict is one of the three `Verdict` constructors; numbers is `[(name,value_str), …]`.
- `entry_set_parents entry parent_ids`
- `entry_set_pulse entry pulse_id_str`
- `entry_set_weights entry weights_hash_hex`
- `entry_set_hypothesis entry text`

Each setter validates only its own field shape. No required-fields check yet. Errors: `E-BAD-VERDICT`, `E-BAD-PARENT-ID`, `E-BAD-PULSE`, `E-BAD-WEIGHTS`, `E-NON-ASCII`.

### 4.3 `entry_validate_required_fields entry`

Returns `1` if the entry passes all sign-time required-field checks, else an `error` value with the first failing code.

- **Checks performed**: §2 required-at-sign-time column. Includes: goal non-empty, kill_target non-empty, counters length >= 1 with valid names, cmd non-empty, result.verdict in `{PASS, FALSIFIED, INCONCLUSIVE}`, created_at well-formed.
- **Errors**: `E-MISSING-KILL`, `E-EMPTY-COUNTERS`, `E-BAD-VERDICT`, `E-MISSING-GOAL`, `E-MISSING-CMD`, `E-BAD-TIME`.

### 4.4 `entry_canonical_body entry`

Returns the canonical ASCII pipe-delimited string per §3.

- **Preconditions**: entry passes `entry_validate_required_fields`. (Function calls it internally and returns the error if invalid.)
- **Postconditions**: returns string. Same input → same string, byte-for-byte.
- **Errors**: any from §4.3, plus `E-NON-ASCII` if any field contains forbidden bytes.

### 4.5 `entry_content_hash entry`

Returns the 64-char lowercase hex `sha256` of `entry_canonical_body entry`.

- **Errors**: propagates errors from `entry_canonical_body`.

### 4.6 `entry_sign entry signer_pubkey_hex signature_hex`

Bind a caller-produced Ed25519 signature to the entry, fill in `id`, `sig`, `signer`. The signature MUST have been produced over the raw bytes of `entry_canonical_body entry` (NOT over the hex of the id; over the body bytes themselves — `id` is informational).

- **Preconditions**:
  - entry passes `entry_validate_required_fields`
  - `signer_pubkey_hex` is exactly 64 lowercase-hex chars
  - `signature_hex` is exactly 128 lowercase-hex chars
  - **Note**: this function does NOT call any signing primitive. The signature is supplied by the caller (external signer, future pure-Rail signer, HSM, etc.). See §8 open question O-1.
- **Postconditions**: returns a new `Entry` with `signer`, `sig`, and `id` populated. The body bytes used to compute `id` are bound to `signer` (R-SIGNER-IN-BODY), so the signature implicitly attests the signer field too.
- **Errors**: `E-MISSING-KILL`, `E-EMPTY-COUNTERS`, `E-BAD-PUBKEY-HEX`, `E-BAD-SIG-HEX`, plus any from validation.

### 4.7 `entry_verify entry`

Verify the signature against the entry's own canonical body. Pure-Rail check via `ed25519_verify`.

- **Preconditions**:
  - `entry.id` is 64 hex chars
  - `entry.sig` is 128 hex chars
  - `entry.signer` is 64 hex chars
  - entry passes `entry_validate_required_fields` (verify-time check; refuses to verify entries that wouldn't have been signable)
- **Postconditions**: returns `1` if signature is valid AND recomputed canonical-body hash matches `entry.id`. Returns `0` if signature is invalid. Returns an `error` if structural preconditions fail.
- **Errors**: `E-BAD-ID`, `E-BAD-SIG-HEX`, `E-BAD-PUBKEY-HEX`, plus all from `entry_validate_required_fields`.

### 4.8 `entry_serialize entry witnesses`

Render to a JSON string. Format:

```json
{
  "kind": "ledatic.lab.entry",
  "version": 1,
  "id": "...",
  "parents": ["..."],
  "goal": "...",
  "hypothesis": "...",
  "kill_target": "...",
  "counters": ["...", "..."],
  "cmd": "...",
  "result": {
    "verdict": "PASS",
    "numbers": [{"name": "loss", "value": "0.1"}, ...]
  },
  "pulse_id": "...",
  "weights_hash": "...",
  "created_at": "...",
  "signer": "...",
  "sig": "...",
  "witnesses": [{"key":"...","sig":"...","witnessed_at":"..."}]
}
```

- **Preconditions**: none structural; an unsigned entry may be serialized with empty `id`/`sig`/`signer` for debugging.
- **Postconditions**: round-trips through `entry_deserialize`.
- **Errors**: none in v1; JSON encoder must handle empty optional fields gracefully.

### 4.9 `entry_deserialize json_string`

Parse JSON back into `(entry, witnesses)`. Returns a tuple `(Entry, [Witness])`.

- **Errors**: `E-BAD-JSON` (malformed), `E-BAD-KIND` (wrong `kind`/`version`), `E-MISSING-FIELD` (required field absent), `E-NON-ASCII` (string contains non-ASCII bytes).

### 4.10 `entry_attach_witness entry witnesses key sig witnessed_at`

Append a `Witness` to the witnesses list. Witnesses are NOT in the canonical body; attaching does not change `entry.id`.

- **Preconditions**:
  - `entry.id` is populated (entry has been signed)
  - `key` is 64-char hex pubkey
  - `sig` is 128-char hex signature over the ASCII bytes of `entry.id`
  - `witnessed_at` matches R-TIME-FMT
- **Postconditions**: returns updated `[Witness]` list (caller threads through).
- **Errors**: `E-UNSIGNED-ENTRY`, `E-BAD-PUBKEY-HEX`, `E-BAD-SIG-HEX`, `E-BAD-TIME`.

### 4.11 `entry_verify_witness entry witness`

Returns `1` if the witness signed `entry.id` correctly, `0` otherwise.

- **Errors**: `E-UNSIGNED-ENTRY`, `E-BAD-PUBKEY-HEX`, `E-BAD-SIG-HEX`.

### 4.12 Field accessors

`entry_id`, `entry_goal`, `entry_kill_target`, `entry_counters`, `entry_cmd`, `entry_result`, `entry_parents`, `entry_pulse_id`, `entry_weights_hash`, `entry_created_at`, `entry_signer`, `entry_sig`, `entry_hypothesis` — each takes an `Entry` and returns the field. Single-line implementations via pattern match.

---

## 5. Failure modes table

| Code                  | Triggered when                                                              | Recovery                                                                |
|-----------------------|------------------------------------------------------------------------------|-------------------------------------------------------------------------|
| `E-MISSING-GOAL`      | `goal` empty at construction or sign time                                   | Caller must populate `goal`.                                            |
| `E-MISSING-KILL`      | `kill_target` empty at construction or sign time                            | **This is the central constraint of the chain.** Caller MUST define a falsification criterion. No bypass. |
| `E-EMPTY-COUNTERS`    | `counters` empty at construction or sign time                               | Caller MUST name at least one counter. No bypass.                       |
| `E-BAD-COUNTER-NAME`  | Counter name fails `[A-Za-z_][A-Za-z0-9_]*` regex                           | Rename counter.                                                         |
| `E-MISSING-CMD`       | `cmd` empty                                                                 | Provide exact command.                                                  |
| `E-BAD-VERDICT`       | Verdict is not in `{PASS, FALSIFIED, INCONCLUSIVE}`                         | Use a valid verdict.                                                    |
| `E-BAD-TIME`          | `created_at` doesn't match `YYYY-MM-DDTHH:MM:SSZ`                            | Reformat. Use `time_iso8601 0` from `stdlib/time.rail` if available.    |
| `E-NON-ASCII`         | A field contains a byte outside 0x20–0x7E, or contains `|`, `\n`, `\t`, `\r`| Strip / re-encode the field.                                            |
| `E-BAD-PARENT-ID`     | Parent id is not 64 lowercase-hex chars                                     | Verify parent id format.                                                |
| `E-BAD-PULSE`         | `pulse_id` non-empty but contains a non-digit                               | Use decimal integer string.                                             |
| `E-BAD-WEIGHTS`       | `weights_hash` non-empty but not 64-char hex                                | Recompute weights hash.                                                 |
| `E-BAD-PUBKEY-HEX`    | Signer pubkey not 64-char lowercase-hex                                     | Caller provides correct hex.                                            |
| `E-BAD-SIG-HEX`       | Signature not 128-char lowercase-hex                                        | Caller provides correct hex.                                            |
| `E-BAD-ID`            | At verify time, `entry.id` not 64-char hex                                  | Entry is malformed; do not trust.                                       |
| `E-UNSIGNED-ENTRY`    | Attempting witness ops on entry with empty `id`                              | Sign the entry first.                                                   |
| `E-BAD-JSON`          | `entry_deserialize` got malformed JSON                                      | Caller checks input source.                                             |
| `E-BAD-KIND`          | JSON `kind` != `ledatic.lab.entry` or `version` != 1                        | Wrong file or wrong version.                                            |
| `E-MISSING-FIELD`     | Deserialize: required field absent from JSON                                | Source is incomplete; reject.                                           |
| `E-SIG-MISMATCH`      | (Returned as `0` from `entry_verify`, not as error) Signature failed Ed25519 check or recomputed id differs from stored id | Entry has been tampered with or was signed by a different signer than claimed. |

**Bad-signature contract**: `entry_verify` returns `0` (not `error`) on a structurally well-formed entry whose signature simply doesn't verify. This lets callers distinguish "input was malformed" (error) from "input was well-formed and forged" (returns 0). Both are failures, but they're different operational situations.

**Unknown signer pubkey**: `entry.rail` does not maintain a signer registry. `entry_verify` only checks that the signature is valid for the embedded pubkey. Whether that pubkey is trusted is a chain-level (piece 2) or policy-level (caller) decision. This is intentional: entries are self-describing; the trust graph lives elsewhere.

---

## 6. Acceptance test plan — shipped as `tools/lab/test_entry.rail`

Run: `./rail_native run tools/lab/test_entry.rail`. Exit 0 + last-line `PASS` iff every test passes.
Current status: **22/22 PASS** (2026-05-15).

Each test name maps to a Rail expression or shell invocation that the implementer (or CI) can run. All tests assume `tools/lab/entry.rail` is imported.

| Test ID  | Name                                       | Assertion                                                                                            |
|----------|--------------------------------------------|------------------------------------------------------------------------------------------------------|
| T-KILL   | reject_unsigned_no_kill_target             | `entry_new "g" "" "" ["c"] "cmd" "2026-05-15T00:00:00Z"` returns an error with code `E-MISSING-KILL`.|
| T-CTR    | reject_unsigned_no_counters                | `entry_new "g" "" "kill" [] "cmd" "2026-05-15T00:00:00Z"` returns `E-EMPTY-COUNTERS`.                |
| T-CTR-NM | reject_bad_counter_name                    | counter `"1bad"` → `E-BAD-COUNTER-NAME`.                                                              |
| T-ASCII  | reject_non_ascii                           | goal containing `é` (0xC3 0xA9) → `E-NON-ASCII`.                                                      |
| T-TIME   | reject_bad_time_format                     | `created_at = "2026-05-15"` → `E-BAD-TIME`. `"2026-05-15T00:00:00.500Z"` → `E-BAD-TIME`.              |
| T-SIGN-K | sign_time_kill_check                       | Build a valid entry, then mutate (via setter) to empty kill_target by constructing fresh; calling `entry_sign` with empty kill MUST return `E-MISSING-KILL` and MUST NOT produce a signature. |
| T-HASH-1 | canonical_equal_unordered_counters         | Two entries differing only in counter order hash identically.                                        |
| T-HASH-2 | canonical_equal_unordered_numbers          | Two entries differing only in number order hash identically.                                         |
| T-HASH-3 | canonical_diff_parent_order                | Two entries with parents `[A,B]` vs `[B,A]` hash differently.                                        |
| T-HASH-4 | canonical_diff_number_format               | Numbers `"0.1"` vs `"0.10"` hash differently. (Documents R-NUM behavior.)                            |
| T-HASH-5 | canonical_diff_signer                      | Same body, different signer pubkey → different id.                                                   |
| T-RT     | round_trip_serialize_deserialize_verify    | Sign entry; `entry_serialize` → string; `entry_deserialize` → `(entry', witnesses')`; `entry_verify entry' == 1`. |
| T-TAMP-B | tamper_body_detected                       | Take a signed entry, mutate `goal` post-sign, recompute id, leave sig unchanged → `entry_verify == 0`.|
| T-TAMP-S | tamper_signature_detected                  | Flip one bit in `sig` → `entry_verify == 0`.                                                          |
| T-TAMP-P | tamper_signer_detected                     | Replace `signer` with a different pubkey (signature stays) → `entry_verify == 0`.                    |
| T-WIT    | attach_then_verify_witness                 | Attach a witness; `entry_verify_witness == 1`. Mutate witness sig → `entry_verify_witness == 0`. Attaching/removing witness does NOT change `entry.id`. |
| T-VFY-R  | unknown_signer_still_verifies_cryptographically | Verify with a pubkey not in any registry. As long as Ed25519 check passes, `entry_verify == 1`. (Trust is downstream.) |
| T-DSER   | deserialize_rejects_wrong_kind             | JSON with `"kind":"foo"` → `E-BAD-KIND`.                                                              |
| T-DSER-V | deserialize_rejects_wrong_version          | JSON with `"version":2` → `E-BAD-KIND`.                                                              |
| T-DSER-M | deserialize_rejects_missing_field          | JSON without `kill_target` → `E-MISSING-FIELD`.                                                       |

**Live test ↔ function map (`tools/lab/test_entry.rail` as shipped):**

| Test ID            | Function in test file | Verb                                                                  |
|--------------------|-----------------------|-----------------------------------------------------------------------|
| T-KILL             | `t_kill`              | `entry_new "g" "" "" ["c"] "cmd" "..."` → `E-MISSING-KILL`            |
| T-CTR              | `t_ctr`               | `entry_new "g" "" "k" [] "cmd" "..."` → `E-EMPTY-COUNTERS`            |
| T-CTR-NM           | `t_ctr_nm`            | counter `"1bad"` → `E-BAD-COUNTER-NAME`                                |
| T-ASCII            | `t_ascii`             | goal `"gé"` → `E-NON-ASCII`                                           |
| T-TIME             | `t_time`              | `"2026-05-15"` and `"...500Z"` both → `E-BAD-TIME`                    |
| T-SIGN-K           | `t_sign_k`            | hand-craft entry w/ empty kill, call `entry_sign` → `E-MISSING-KILL`  |
| T-SIGN-CTR         | `t_sign_ctr`          | hand-craft entry w/ empty counters, call `entry_sign` → `E-EMPTY-COUNTERS` |
| T-HASH-1           | `t_hash_1`            | counter order does not affect hash                                    |
| T-HASH-2           | `t_hash_2`            | number order does not affect hash                                     |
| T-HASH-3           | `t_hash_3`            | parent order DOES affect hash                                         |
| T-HASH-4           | `t_hash_4`            | `"0.1"` vs `"0.10"` hash differently (R-NUM)                          |
| T-HASH-5           | `t_hash_5`            | signer bound into digest                                              |
| T-CANONICAL        | `t_canonical`         | equal entries (different insertion order) hash identically             |
| T-VERIFY-POS       | `t_verify_pos`        | real openssl-produced signature verifies via `entry_verify` → 1       |
| T-ROUNDTRIP        | `t_roundtrip`         | sign → serialize → deserialize → verify == 1; every field preserved   |
| T-TAMP-B           | `t_tamp_b`            | mutate `goal` post-sign → `entry_verify == 0`                          |
| T-TAMP-S           | `t_tamp_s`            | flip first hex nibble of `sig` → `entry_verify == 0`                  |
| T-TAMP-P           | `t_tamp_p`            | swap `signer` pubkey, keep sig → `entry_verify == 0`                  |
| T-WIT              | `t_wit`               | attach witness; `entry.id` unchanged; witness list grows by one        |
| T-DSER (kind)      | `t_dser_kind`         | JSON with `"kind":"foo"` → `E-BAD-KIND`                                |
| T-DSER (version)   | `t_dser_ver`          | JSON with `"version":2` → `E-BAD-KIND`                                 |
| T-DSER (missing)   | `t_dser_missing`      | JSON without `kill_target` → `E-MISSING-FIELD`                         |

Run:
```bash
./rail_native run tools/lab/test_entry.rail
```
Expected output (verbatim from 2026-05-15):
```
Tests passed: 22 / 22
PASS
```

**Real-signature fixture (T-VERIFY-POS, T-ROUNDTRIP, T-TAMP-*)** uses an Ed25519 keypair generated once at implementation time by `openssl genpkey -algorithm ed25519`. The keypair is NOT committed; only the pubkey + signature are baked into the test file as constants. The signed message is the exact canonical body of the fixture entry (see `build_fixture` in test file). Regenerating the fixture requires:
```bash
openssl genpkey -algorithm ed25519 -out /tmp/ed25519.pem
# pubkey (last 32 bytes of the PKCS#8 wrapper):
openssl pkey -in /tmp/ed25519.pem -pubout -outform DER | tail -c 32 | xxd -p -c 999
# sign the canonical body:
printf '%s' '<canonical_body>' | openssl pkeyutl -sign -inkey /tmp/ed25519.pem -rawin | xxd -p -c 999
```

**Falsification anchor** (mandatory per CLAUDE.md hypothesis discipline): if T-KILL or T-CTR ever return success instead of error, the chain is broken — the constraint that "an entry without a kill criterion cannot be signed" has regressed. CI must surface this loudly. Current implementation: both fail at `entry_new` AND at `entry_sign` (T-SIGN-K, T-SIGN-CTR), so the constraint is double-gated.

---

## 7. Non-goals

- Chain storage, parent-link resolution, "show me all descendants of entry X" → piece 2.
- Witness gossip, peer discovery, multi-host SSH-signing orchestration → piece 3.
- Beacon (pulse) fetching → caller supplies `pulse_id` as a string.
- Trust-graph / signer-registry policy → caller decision; piece 2 may add a default policy.
- Native Ed25519 signing in Rail → not blocking piece 1. `entry_sign` accepts an externally-produced signature. See §8.
- Compression, encryption, network transport.
- Backward-compatible v0 format. v1 is the first version; bump to v2 on any §3 rule change.

---

## 8. Open questions — RESOLVED at implementation

- **O-1 (signer) — RESOLVED: caller-supplied 128-hex signature.** Confirmed by reading `stdlib/ed25519.rail`: it exports only `ed25519_verify pub msg msg_len sig`; there is no signing primitive (no secret-key parsing, no scalar reduction over L, no SHA-512 of the secret). Adding a pure-Rail signer is a multi-day workstream of its own. **Decision:** `entry_sign entry signer_pubkey_hex signature_hex` takes a 64-byte raw Ed25519 signature as 128 hex chars, produced however the caller likes (external `sign_attestation.sh`, openssl, future pure-Rail signer, HSM). The signed message is the raw bytes of `entry_canonical_body`. `entry_verify` calls `ed25519_verify` against those bytes. **Rationale:** keeps piece 1 unblocking pieces 2/3 today; preserves an obvious migration path the day a Rail signer lands (just call it inside the caller before invoking `entry_sign`). The acceptance fixture `T-VERIFY-POS` proves the contract by signing a canonical body with openssl Ed25519 and verifying it via pure-Rail `entry_verify` (returns 1; flipping any byte returns 0).

- **O-2 (number rendering) — RESOLVED: keep caller-supplied strings; enforce strict shape.** Numbers are stored as `(name, value_str)` pairs. Names must match the same `[A-Za-z_][A-Za-z0-9_]*` identifier regex as counter names; values must be ASCII-printable and not contain pipe/newline/tab/CR (rule R-ASCII). No numeric parse is performed: `"3.1415e-2"`, `"42"`, `"true"`, and `"NaN"` all canonicalize bit-identical to themselves. **Rationale:** any in-Rail float renderer (e.g. `show` on a double) drifts as `compile.rail` evolves; a caller string is the only stable substrate. Strict-shape input validation (`field_ascii_ok` on every name/value at `entry_set_result` time and again at `entry_canonical_body` time) closes the "sneak arbitrary text in" hole flagged in the task brief.

- **O-3 (witnesses-in-body) — UNCHANGED, EXPLICIT DOCUMENTATION.** Witnesses are still OUTSIDE the canonical body. Attaching/detaching does NOT change `entry.id` (validated by T-WIT). Piece 1 does NOT attempt a strip-attack fix; that's piece 2's `entry_witnesses_root` (Merkle root over sorted witness keys) or piece 3's gossip-level countersig journal. Documented as a known limitation: at the entry layer, witness-array membership is unauthenticated.

- **O-4 (verify-time required-fields) — RESOLVED: strict.** `entry_verify` runs `entry_validate_required_fields` before any crypto. Reasoning: an entry that would not have been signable today should not verify today. If the validation rules ever loosen, bump `v1` → `v2` (per spec R-VER); the version literal is part of the canonical body and verify-time mismatch yields a fresh-id mismatch → `entry_verify == 0`, not a silent acceptance.

- **O-5 (counter name regex) — RESOLVED: `[A-Za-z_][A-Za-z0-9_]*`, dotless.** Documented and enforced; matches the run.rail spec §3 step 3 regex. If chain.rail or run.rail emit dotted names from production, this becomes a v2 bump (relaxed regex), not a silent change.

- **O-6 (JSON library) — DISCOVERED at implementation; RESOLVED inline.** `import "stdlib/json.rail"` triggers a parser error when loaded alongside `stdlib/sha256.rail` + `stdlib/ed25519.rail` + `stdlib/sha512.rail` + `stdlib/x25519.rail`. The error is in json.rail's encoder helper at `json_encode … (\p -> let (k, v) = p …)` — the lambda-with-destructure parses correctly in isolation but interacts with our import set. **Decision:** ship a 160-line entry-shape-specific JSON encoder + recursive-descent parser inside `entry.rail`. Supports the closed set of JSON shapes the entry schema needs (string, integer, bool, null, array, object) and escapes `"` + `\\` + `\n` + `\t` + `\r`. T-DSER and T-ROUNDTRIP exercise both halves of the bespoke parser. Migration path: once the json.rail interaction is fixed, swap the bespoke parser for the stdlib call — public interface unchanged.

- **O-7 (Rail untagged-register quirk) — DISCOVERED at implementation; documented for test-author lineage.** The compiler stores the first 3 int-typed parameters of a function untagged in x19/x20/x21 (per CLAUDE.md §Performance optimizations). When those params are heap-allocated strings, `a == b` becomes a raw-pointer compare and reports `false` for content-equal strings allocated separately. Standard `if a == b` in 3-arg helpers like `assert_eq_str label a b` silently always-fails. **Workaround in the test file:** every assertion helper is padded with 3 leading underscore-prefixed dummy args so the real operands land at slots 4+. The implementation file itself does NOT need this workaround because its string `==` use is exclusively `<value> == <literal>` (e.g. `s == "PASS"`), where one operand is a data-section pointer and Rail's `==` short-circuits to byte compare. Surface this to chain.rail's implementer: their `chain_get` will be a 2-arg function (handle, id) and may compare ids — that 2-arg shape is safe.

