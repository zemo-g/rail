---
piece: 3/3 — put-goal runner
file:  tools/lab/run.rail
spec:  v1 (shipped)
author: lab-sketcher-3, refined during implementation
depends_on:
  - tools/lab/specs/entry.spec.md   (piece 1, shipped)
  - tools/lab/specs/chain.spec.md   (piece 2, shipped — §11 used as the
                                     authoritative chain interface for
                                     this file)
status: IMPLEMENTED — tools/lab/run.rail + tools/lab/test_run.rail green
        (8/8). Entry + chain side suites remain green (22/22, 12/12).
---

# `tools/lab/run.rail` — put-goal runner

> The CLI that turns a goal into an experiment, refuses to record fuzzy
> work, and surfaces prior attempts before swinging again.

---

## 1. Purpose & scope

`run.rail` is the *only* sanctioned path for appending experimental work
to the attestable chain. Its job is to make sloppy entries
**impossible** by construction:

- Every entry has a goal, a kill_target, ≥1 declared counter, an exec
  command, and a verdict.
- Every entry is shown its ancestors before being recorded.
- Every entry is signed and gossiped atomically; partial state is
  never written.

What this tool is **not**:

- Not a scheduler. One goal per invocation.
- Not a web UI. Pure terminal.
- Not a retry harness. Crashed experiments yield `INCONCLUSIVE`, not
  re-tries.
- Not a batch runner. No fan-out; that belongs in a separate tool that
  drives `run.rail` as a subprocess.
- Not a verifier of past entries beyond `verify <id>` — full chain
  audits live in `tools/lab/audit.rail` (future).

---

## 2. CLI surface (shipped)

Invocation: `./rail_native run tools/lab/run.rail <subcommand> [args]`
(or, with exit-code propagation: compile once and exec directly — see §13).

| Subcommand | Args | Purpose |
|---|---|---|
| `put-goal "<goal>"` | `--timeout=<seconds>` (default **600**, max 86400), `--no-gossip` (skip witness countersign), `--non-interactive --kill=... --counters=... --cmd=... --parents=... [--hypothesis=...]` (bypass prompts; missing required fields → fatal exit 2; `--hypothesis` is optional and empty when omitted). | Run the 5-step interactive flow, execute, sign, append. |
| `read <id-prefix>` | `--root=<path>` | Print one entry's canonical JSON by id prefix (≥8 hex chars). Prefix must resolve unambiguously. |
| `search <substring>` | `--limit=N` (default 5), `--root=<path>` | Substring-match the goal field. Wraps `chain_search_goal`. Substring semantics: `query` must appear inside the stored goal. |
| `verify <id-prefix>` | `--root=<path>` | Re-verify one entry's signature + content hash. Exit 0 iff valid. |
| `rebuild-index` | `--root=<path>` | Drop and re-stream the chain's in-memory indices. Idempotent. |

Universal flags: `--root=<path>` (default `$RAIL_LAB_HOME` or `~/.rail/lab`),
`--witnesses=<path>` (witnesses.toml-style; default empty → no gossip),
`--key=<path>` (Ed25519 signing key; else env `RAIL_LAB_SIGNING_KEY`),
`--help`, `--version`.

Exit codes (every `put-goal` branch resolves to one of these):

| Code | Meaning |
|---|---|
| 0    | Subcommand succeeded; for put-goal the entry was appended |
| 1    | Generic error (bad args, missing positional, unknown subcommand) |
| 2    | User cancel: empty kill_target / empty counters / Ctrl-C / explicit-N at confirm prompt |
| 3    | Experiment exited non-zero. Entry IS appended (verdict INCONCLUSIVE; runner_error="exec_failed_<rc>") |
| 4    | No verdict sentinel emitted OR multiple counter sentinel blocks OR conflicting/malformed verdict. **Entry NOT appended.** |
| 5    | A declared counter was never reported in the sentinel block. Entry IS appended (verdict overridden to INCONCLUSIVE; runner_error="counter_missing:<names>") |
| 6    | Experiment timed out. Entry IS appended (verdict INCONCLUSIVE; runner_error="timeout_at_<T>s") |
| 7    | Chain locked or unreadable — entry NOT appended |
| 8    | Sign failed (key missing/unreadable/openssl failure) — entry NOT appended |
| 9    | `--require-witnesses=N` set and gossip produced <N countersigs. Primary entry IS appended; non-zero exit signals the gating failure. |

---

## 3. put-goal flow (the 5 steps)

State machine. Each step either advances or fatal-exits. Once we enter
Phase C (exec) no further user input is solicited — the experiment owns
the terminal until completion or timeout.

### Step 1 — Prior-attempt search (MANDATORY)

```
[1/5] Searching chain for prior attempts on this goal...
      2 prior attempts (1 PASS, 1 FALSIFIED, 0 INCONCLUSIVE)
      Top matches:
        a8f3...  2026-05-09T...  PASS       "JIT v1 trampoline overhead..."
        b21c...  2026-05-11T...  FALSIFIED  "direct-call saves nothing..."
```

- Calls `chain_search_goal handle goal_text` (chain.rail returns ids;
  run.rail walks them via `chain_read` + `entry_deserialize` to build
  the rollup).
- Rollup line is ALWAYS shown — even when count == 0 ("0 prior
  attempts"). This is invariant RUN-PRIOR-MANDATORY.
- Match list is shown when count > 0 (max `--limit` entries; default 5).
- chain unreadable → exit 7 before any prompt.

### Step 2 — kill_target (REQUIRED, non-empty)

- Free-text; stored verbatim.
- Whitespace-trimmed length 0 → exit 2 (RUN-KILL-FATAL).
- In non-interactive mode: `--kill='<text>'` flag.

### Step 2.5 — hypothesis (OPTIONAL, free text)

- Stored verbatim in `entry.hypothesis`. Empty when omitted (preserves
  pre-flag behavior).
- Validation is deferred to entry.rail (ASCII-printable + forbidden-bytes
  check); no run.rail-side rules beyond trim.
- In non-interactive mode: `--hypothesis='<text>'` flag.
- Interactive mode: prompted between kill_target and counters; Enter for
  blank.

### Step 3 — counters (REQUIRED, ≥1, each matching `[A-Za-z_][A-Za-z0-9_]*`)

- Comma-separated.
- Empty list → exit 2 (RUN-CTR-FATAL).
- Any invalid identifier → exit 2.
- In non-interactive mode: `--counters='a,b,c'` flag.

### Step 4 — exec command (REQUIRED)

- Free-text shell command. Stored verbatim and executed via `/bin/sh -c`.
- Empty → exit 2.
- In non-interactive mode: `--cmd='./bench --variant=direct'` flag.

### Step 5 — parents (OPTIONAL)

- Each token is an id prefix; resolved via `chain_lookup_prefix`.
- Unknown or ambiguous → exit 2 in non-interactive mode (interactive
  reprompts).
- Blank → no parents.

After step 5, an echo block summarizes the gather, and one `[y/N]`
confirms — `n` → exit 2 with chain.log unchanged.

---

## 4. Counter capture protocol (confirmed)

The experiment MUST emit a single sentinel-bracketed block on stdout.

### Wire format

```
===RAIL_LAB_COUNTERS===
{"counter": "trampoline_us", "value": 87}
{"counter": "direct_us",      "value": 41}
{"counter": "lower_hit_rate", "value": 0.324}
===END===
```

Rules:

- The runner reads stdout in full, scans for the first
  `===RAIL_LAB_COUNTERS===` sentinel and the matching `===END===` after
  it. The block is the text between them.
- Multiple `===RAIL_LAB_COUNTERS===` sentinels → exit 4 ("duplicate
  counters block"), no append.
- Zero `===RAIL_LAB_COUNTERS===` sentinels → treated the same as no
  verdict (exit 4, no append).
- Between sentinels, every line beginning with `{` is parsed as a JSON
  object via a tiny in-file extractor (no `stdlib/json.rail` import — it
  conflicts with the crypto stack). The extractor pulls `"counter"`
  (string) and `"value"` (numeric or string token until comma / `}`).
- Blank lines and `#`-prefixed lines are ignored.
- The same counter name appearing more than once → LAST occurrence wins.
- A declared counter never reported → verdict overridden to
  INCONCLUSIVE, entry IS appended, runner_error =
  `counter_missing:<names>`. Exit 5.
- An undeclared counter that DOES appear → silently kept in the entry.
  Optional, not surfaced (the entry's counters list is whatever the
  experiment emitted).

### Why this format

- One block, one parse. Avoids interleaving with arbitrary application
  logging.
- JSON-line-per-counter lets experiments stream-emit between flushes.
- No new parser dependency: we extract the two keys ourselves.

---

## 5. Verdict protocol (confirmed)

```
===VERDICT=== PASS
===VERDICT=== FALSIFIED
===VERDICT=== INCONCLUSIVE
```

Rules:

- ALL-CAPS, case-sensitive. Only those three tokens are legal.
- Zero verdict sentinels → exit 4 (entry NOT appended), unless exec
  itself failed non-zero — in that case verdict is forced INCONCLUSIVE
  and the entry IS appended (exit 3).
- Multiple verdict sentinels that AGREE → use that verdict.
- Multiple verdict sentinels that DISAGREE → exit 4 ("conflicting
  verdicts"), no append.
- Any token other than the three legal values → exit 4 ("malformed
  verdict").

---

## 6. Side-effect ordering (Phases A-I)

```
Phase A — Prompts                (in-memory only)
Phase B — Confirm                (in-memory only)
Phase C — Exec                   (writes /tmp/rail_lab_run_<pid>/{out,err,ec,cmd.sh})
Phase D — Parse counters+verdict (in-memory only)
Phase E — Build entry            (entry_new + setters; in-memory only)
Phase F — Sign                   (openssl pkeyutl shell-out; in-memory entry mutated)
Phase G — Append                 (chain_append_h: mkdir-LOCK.d + flock-equivalent write)
Phase H — Gossip                 (chain_gossip_to_witnesses; best-effort)
Phase I — Print result + id      (stdout)
```

### Atomicity guarantees

- Phases A-F are fully revertible: if any step errors, we leave nothing
  on disk except the capture dir under `/tmp`, which is moved to
  `<root>/runs_unrecorded/<ts>/` if no append; or to `<root>/runs/<id>/`
  if append succeeded.
- Phase G is the only chain writer. `chain_append_h` returns an error
  on lock contention or duplicate-id — we surface as exit 7 or 1 with
  the log byte-identical (invariant RUN-ATOMIC).
- Phase H is best-effort. A 0-of-N gossip result does NOT roll back
  the append. If `--require-witnesses=N` was set and we got <N
  responses, the primary entry is durable; we exit 9 to signal the
  gate failure (no follow-up `gossip_failed` entry in v1).

### What is NEVER written

- Entries without a verdict (unless exec failed non-zero — then
  INCONCLUSIVE is appended explicitly).
- Entries whose counter sentinel block was missing or duplicated.
- Entries where exec was never attempted (Ctrl-C in prompts).
- Entries that fail to sign.

---

## 7. Timeout policy

- Default timeout: **600 seconds** (10 min). Override with
  `--timeout=<seconds>`. Hard cap: 86400 (24 h) — any larger value is
  rejected at arg-parse time.
- Implementation: the runner wraps the user's command in a sh group
  with a killer subshell: TERM at T, KILL at T+2. When the experiment
  completes normally, we `pkill -P` the killer to reap its sleep
  child (otherwise the wait would block for the full T seconds).
- On timeout: verdict forced INCONCLUSIVE, runner_error =
  `timeout_at_<T>s`, captured counters (if any reached the sentinel
  block before kill) are preserved, exit code 6, **entry IS appended.**

---

## 8. Failure modes

| Mode | Detection | Effect | Exit |
|---|---|---|---|
| exec exits non-zero | child ec ≠ 0 | INCONCLUSIVE appended (`exec_failed_<rc>`) | 3 |
| no verdict sentinel + exec ok | scan empty | NO entry; capture moved to runs_unrecorded | 4 |
| no counter block | scan empty | NO entry | 4 |
| duplicate counter blocks | two sentinels | NO entry | 4 |
| conflicting verdicts | sentinels disagree | NO entry | 4 |
| malformed verdict token | not PASS/FALSIFIED/INCONCLUSIVE | NO entry | 4 |
| declared counter missing | sentinel block parsed, name absent | INCONCLUSIVE appended (`counter_missing:<names>`) | 5 |
| timeout | killer fired | INCONCLUSIVE appended (`timeout_at_Ts`) | 6 |
| chain locked | `chain_open` errors `chain:locked` | NO entry | 7 |
| chain append errors | dup-id / parent-missing / disk | NO entry | 1 or 7 |
| signing key missing/invalid | path_exists / openssl fails | NO entry | 8 |
| witness shortfall | `--require-witnesses=N`, got <N | entry IS appended | 9 |

---

## 9. Acceptance test plan

Tests live in `tools/lab/test_run.rail`. **All 8 tests must pass for
shipping.** Run pattern:

```sh
./rail_native tools/lab/test_run.rail
cp /tmp/rail_out /tmp/rail_test_run_bin
codesign -s - /tmp/rail_test_run_bin 2>/dev/null
/tmp/rail_test_run_bin
# expect: Tests passed: 8 / 8 ; PASS
```

| # | Name | Asserts |
|---|---|---|
| T1 | T-HAPPY-PATH | put-goal with valid inputs → exit 0; chain has 1 entry; `read <prefix>`, `verify <prefix>` both return 0. |
| T2 | T-KILL-FATAL | `--kill=''` → exit 2; chain.log byte-identical (0 lines). |
| T3 | T-CTR-FATAL | `--counters=''` → exit 2; chain.log byte-identical. |
| T4 | T-COUNTER-MISSING | Declared `loss,acc`, sentinel block emits only `loss` → exit 5; entry appended; verdict overridden to INCONCLUSIVE; runner_error contains `counter_missing:acc`. |
| T5 | T-VERDICT-MISSING | Experiment emits counter block but no `===VERDICT===` → exit 4; chain.log byte-identical; capture saved under `runs_unrecorded/`. |
| T6 | T-EXEC-FAIL | Experiment exits 1 (with counters emitted, no verdict) → exit 3; entry appended; verdict INCONCLUSIVE; runner_error contains `exec_failed_1`. |
| T7 | T-PRIOR-SHOWN | Seed two priors that contain the third query as substring; third put-goal output contains `2 prior attempts`, `2 PASS`, `Top matches:`; a fresh-goal call still shows `0 prior attempts`. |
| T8 | T-ATOMIC | `--key=/nonexistent/path.pem` → exit 8; chain.log byte-identical pre/post (no append; entry-sign fails before Phase G). |

T2, T3, T5, T8 are the partial-state guard tests — chain.log bytes-on-
disk must be unchanged.

---

## 10. Non-goals

- Web UI / TUI beyond plain stdin/stdout.
- Cron / scheduled runs.
- Automatic retry on `INCONCLUSIVE`.
- Batch fan-out.
- Cross-chain federation.
- Counter-DSL evaluation of kill_target (deferred).
- Editing or deleting past entries (append-only by construction).
- ANSI escapes in output (plain ASCII only).

---

## 11. Interface assumed from chain.rail / entry.rail (shipped — POST-CHANGE)

Run.rail uses these symbols. **Bold** entries differ from the original
sketch (§11 of the v0 spec); see `[CHANGED]` annotations.

### entry.rail (piece 1)

- `entry_new goal hypothesis kill_target counters cmd created_at -> entry`
- `entry_set_result e Pass|Falsified|Inconclusive numbers -> entry`
- `entry_set_parents e parent_ids -> entry`
- `entry_sign e signer_pubkey_hex signature_hex -> entry`
  **`[CHANGED]` — caller supplies the 128-char hex Ed25519 signature**
  produced over the entry's canonical body (see `entry_canonical_body`).
  Entry.rail does NOT sign internally. Run.rail shells out to
  `openssl pkeyutl -sign -inkey <pem> -rawin -in <body>` to produce the
  signature; the pubkey is extracted from the same PEM via
  `openssl pkey -pubout -outform DER | xxd -p` and the 12-byte
  `302a300506032b6570032100` SPKI prefix is stripped to yield 64-hex.
- `entry_canonical_body e -> string` — used by run.rail to compute the
  bytes that get signed.
- `entry_id e`, `entry_goal e`, `entry_created_at e`, `entry_result e`,
  `verdict_to_string verdict`, `verdict_from_string str` — direct
  accessors used by the search rollup and the read subcommand.
- `entry_serialize e [] -> json_string`
- `entry_deserialize json_string -> (entry, witnesses)`

### chain.rail (piece 2)

- `chain_open root_or_empty -> handle`
  `[CHANGED]` from sketch: takes a single root path (or empty → `$RAIL_LAB_HOME`),
  not a chain.log file path.
- `chain_open_ro root_or_empty -> handle` — read-only opens skip the
  LOCK.d acquisition. Used by `read`, `search`, `verify`.
- `chain_close h -> int`
- `chain_append_h h entry_blob -> (h, id)`
  `[CHANGED]` — IMMUTABLE-style append (the sketch had mutating
  `chain_append`). Returns a fresh handle threaded with the new id.
- `chain_read h id -> string`
  `[CHANGED]` — returns the canonical JSON blob (string), NOT a parsed
  Entry. Run.rail calls `entry_deserialize` on the result itself.
- `chain_search_goal h needle -> [id]`
  `[CHANGED]` — returns ids only, no `entry_summary` records.
  Substring semantics: the needle must appear in the stored goal.
  Run.rail walks the returned ids with `chain_read` +
  `entry_deserialize` to build the user-facing rollup
  (3 PASS, 1 FALSIFIED, …).
- `chain_lookup_prefix h prefix -> string` — returns the full id, or the
  literal `"AMBIGUOUS"` / `"NONE"`.
- `chain_verify h id -> bool` — re-runs `entry_verify` after a
  `chain_read` + `entry_deserialize`. Used by the `verify` subcommand.
- `chain_gossip_to_witnesses h id [host_string] -> [countersig]`
  `[CHANGED]` — takes a STRING LIST of hosts (not a config-path), returns
  the countersig blobs (NOT a `(count, threshold)` tuple). Run.rail
  parses `witnesses.toml` itself (see §12) and reduces countersig-count
  vs. `--require-witnesses=N` threshold.
- `chain_rebuild_index_h h -> (h, count)`
  `[CHANGED]` — full rebuild, no `from_id` arg.
- Verdict tags are ALL-CAPS strings: `"PASS"`, `"FALSIFIED"`,
  `"INCONCLUSIVE"`. `entry.rail`'s `verdict_to_string` is canonical.

### Interface-drift policy

The above is the contract this `run.rail` actually consumes. Any future
divergence in entry/chain must be reconciled here.

---

## 12. Filesystem & key/witness conventions

### Layout

```
<root>/chain/log.jsonl          # canonical append-only log (one entry per line)
<root>/chain/countersigs.jsonl  # witness countersigns (chain.rail manages)
<root>/chain/index/             # in-memory index sidecar (meta.txt only in v0)
<root>/chain/LOCK.d/            # mkdir-based writer lock
<root>/runs/<id>/               # per-recorded-entry capture (cmd.sh, out.txt, err.txt, ec.txt)
<root>/runs_unrecorded/<ts>_<pid>/  # captures for runs that didn't append
```

Root resolution order:
1. `--root=<path>` flag
2. `$RAIL_LAB_HOME` env var
3. `$HOME/.rail/lab`
4. `./.lab`

### Signing key

The key file is an openssl-generated Ed25519 PEM:

```sh
openssl genpkey -algorithm ed25519 -out signing.key
chmod 0600 signing.key
```

Key resolution: `--key=<path>` flag, else `$RAIL_LAB_SIGNING_KEY`.
Missing/unreadable key → exit 8 before Phase G.

The runner produces the 64-char hex pubkey by:

```sh
openssl pkey -in <key> -pubout -outform DER | xxd -p -c 256
```

then stripping the 24-hex SPKI prefix `302a300506032b6570032100`. It
produces the 128-char hex signature by:

```sh
printf '%s' "<canonical body>" > /tmp/body.bin
openssl pkeyutl -sign -inkey <key> -rawin -in /tmp/body.bin | xxd -p -c 256
```

`entry_sign` then injects both into the entry; `entry_verify` (in
piece 1's pure-Rail ed25519_verify) round-trips the signature on read.

### Witness fleet config

`--witnesses=<path>` points at a TOML-flavored file. One witness host
per non-blank, non-comment line; `host =` prefix optional; quotes
optional:

```toml
# fleet config
host = "fleet0.example.org"
"fleet1.example.org"
host = mini.example.org
```

The runner parses each line, strips quotes, drops `#` comments, and
passes the resulting host list to `chain_gossip_to_witnesses`. Gossip
itself is opt-in via `chain.rail`'s `$RAIL_LAB_WITNESS_CMD` env var (the
per-host sign command). Without it, gossip returns `[]` regardless of
hosts in the config — the runner's threshold check still functions, and
`--require-witnesses=N` with `RAIL_LAB_WITNESS_CMD` unset will exit 9
deterministically.

---

## 13. Running tests without losing exit codes

`./rail_native run <file>.rail args` compiles + execs but its
`compile_and_run` wrapper always returns 0 to the caller — the child's
exit code is discarded. Tests that need to observe `run.rail`'s exit
code therefore compile once and exec directly:

```sh
./rail_native tools/lab/run.rail
cp /tmp/rail_out /tmp/rail_run_lab
codesign -s - /tmp/rail_run_lab 2>/dev/null
/tmp/rail_run_lab put-goal "<goal>" --root=... --key=... [...]
echo "exit=$?"
```

`test_run.rail` follows this pattern itself: it compiles `run.rail` once
inside `main`'s setup phase, then shells out to the resulting binary
for each individual test case, comparing stdout + exit code.

---

## 14. End of spec
