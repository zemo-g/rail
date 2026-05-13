# Next-session agent prompts — tighten dual-backend (Phase 1 of strategic arc 2026-05-13)

**Initiative:** close the 8 remaining x86 failures + bit-op cascade + parallel-safety + first-run UX + last manual docs step. Land the **dual-backend milestone**: byte-identical self-host on ARM64 AND x86 with zero manual steps.

**Reference:** see `MEMORY.md` entries `strategic_arc_2026-05-13`, `session_handoff` (prev), `parallel_v0_workflow`, `x86_backend_status`, `rail_emit_gotchas`, `feedback_rail_test_tmp_race`, `docs_deploy_rail`.

**Floors to protect:** ARM64 140/140, x86 71/79, byte-identical bootstrap (cycle 2), all deployed URLs (`/`, `/rail`, `/rail/docs/`, `/mobile.html`, `/live4k.html`, `/holo.html`, `/verify/<id>`, `/entropy/pulse`).

---

## Decomposition

4 parallel agents (A, B, C, D) in worktrees, then integration + E. Collision audit:

| Agent | Files touched | Collides with |
|---|---|---|
| A | `tools/compile.rail` (2 edits: ELF-prefix, mktemp .o) | none — serialized inside A |
| B | `tools/x86_rt.s` (append-only) | none if append-only |
| C | ARM64 runtime asm (append-only) | none if append-only |
| D | Mini `~/git/rail.git/hooks/post-receive` + `tools/docs/gen_stdlib_ref.rail` invocation site | none |

Agents B and C may need compile.rail dispatch entries for new builtins — if so, **append only at the bottom of the dispatch chain in compile.rail**, and integration resolves any overlap. Each prompt explicitly warns about this.

---

## Agent A — ELF-prefix bug + `/tmp/rail_out.o` mktemp race

```
Goal: close 3 x86 ffi-libc failures AND fix parallel-agent test races. Two surgical edits to tools/compile.rail.

Strategic context: ELF-prefix bug is a 22-day-old documented mystery, now precisely localized at compile.rail:5632 — `foreign <name>` emits `_<name>` symbol which fails on Linux ELF (Mach-O prefixes underscore, ELF doesn't). Fix: strip the leading underscore when target is x86_64-linux. Likely also closes 4 ARM64 tensor_* failures that depend on `_atof` per the prev session's Agent E observation — verify after fix. Second edit: `./rail_native test` is currently unsafe to run concurrently because the build path writes to a fixed `/tmp/rail_out.o`. mktemp it.

Branch: feat/a-elf-prefix-and-mktemp-v0
Worktree: worktree-agent-a

Scope:
  - tools/compile.rail:5632 (ELF-prefix fix — gate on target-is-linux)
  - tools/compile.rail build path (`/tmp/rail_out.o` → mktemp)
  - Hard constraint: NO changes to runtime asm files, stdlib, or docs.

Smokes (all must pass):
  1. `./rail_native test` → 140/140 (or higher if tensor_* now pass; report any delta)
  2. `bash tools/test/x86_conformance.sh` → ≥74/79 (was 71/79; expect 3 ffi-libc tests to pass)
  3. Concurrent-test smoke: in two terminals run `./rail_native test` simultaneously — both finish without `/tmp/rail_out.o` race-failing the 4 tensor_* tests
  4. Byte-identical bootstrap: `./rail_native self && cmp rail_native /tmp/rail_self` after one self-compile cycle

Report (in this exact structure):
  - Files changed + LOC delta
  - Smoke transcripts (all 4)
  - tensor_* delta on ARM64 (closed by ELF-prefix fix, or still failing?)
  - Honest deferred list (anything you discovered but didn't fix)
  - Branch + final SHA

Constraints (carry these mentally):
  - verify removals empirically (feedback_verify_removals)
  - diagnostics first, optimization second (feedback_diagnostics_first)
  - real output, not "would work"
```

---

## Agent B — x86 runtime: str-runtime + bit-op symbols

```
Goal: append 11 runtime symbols to tools/x86_rt.s. Close 5 x86 str-runtime failures + unblock 21 bit-op deferred-symbol tests.

Strategic context: x86 conformance is gated by missing runtime symbols. Per Agent D's classification from prev session, _rail_str_{find,contains,sub,split,replace} blocks 5 named tests + cascades into ~20 deferred-symbol tests; _rail_bit_{and,or,xor,shl,shr,rotl} blocks 21 named tests. Both families are append-only additions to tools/x86_rt.s — no other files unless you discover a missing compile.rail dispatch entry, in which case append it at the bottom of the dispatch chain and flag it loudly in your report.

Branch: feat/b-x86-runtime-symbols-v0
Worktree: worktree-agent-b

Scope:
  - tools/x86_rt.s (append-only) — 5 str-runtime + 6 bit-op symbols
  - Hard constraint: NO compile.rail edits unless empirically required (a test parse-fails because the builtin isn't dispatched). If forced, append dispatch entries only at the bottom.
  - Hard constraint: ARM64 runtime asm is Agent C's scope. Don't touch.

Reference for signatures: read the ARM64 runtime asm to see how matching ARM64 symbols (if any exist) are wired — match calling convention. If neither side has them yet, propose the signature based on existing _rail_str_* / _rail_bit_* in x86_rt.s.

Smokes:
  1. `bash tools/test/x86_conformance.sh` → ≥76/79 from str-runtime additions, then ≥79/79 with bit-ops if all bit-op tests are in the portable set
  2. List the 21 bit-op tests by name from prev session's t73-t131 classification; confirm at least 15 of them now pass (some may need stdlib bindings that aren't in scope)
  3. ARM64 floor: `./rail_native test` still 140/140 (your changes are x86-only, so this must hold)

Report structure:
  - Files changed + LOC delta (expect ~150-300 LOC of x86_rt.s additions)
  - Symbol-by-symbol: signature, lines added, test that exercises it
  - Smoke transcripts
  - Honest deferred (any symbol you didn't get to, with reason)
  - Branch + final SHA

Constraints: verify removals empirically; diagnostics first; honest backlog.
```

---

## Agent C — ARM64 runtime: str-runtime + bit-op symbols (parity with B)

```
Goal: append the same 11 runtime symbols (5 str + 6 bit-op) to the ARM64 runtime asm so both backends have parity.

Strategic context: ARM64 is currently 140/140 so these symbols may already exist in the ARM64 runtime — your FIRST step is to grep the ARM64 runtime asm for each symbol and report what's already there. Only add what's missing. Goal is BACKEND PARITY so that the same source compiles identically on both. If everything already exists on ARM64, your output is a short audit report confirming that and your branch is empty — that's a valid outcome.

Branch: feat/c-arm64-runtime-parity-v0
Worktree: worktree-agent-c

Scope:
  - ARM64 runtime asm (likely tools/rail_rt.s or similar — confirm by grepping for an existing `_rail_str_*` symbol)
  - Hard constraint: x86 runtime is Agent B's scope. Don't touch tools/x86_rt.s.
  - Hard constraint: NO compile.rail edits unless empirically required.

Reference for signatures: must MATCH whatever Agent B is doing on x86. Coordinate by reading the same builtin dispatch entries in compile.rail to see what signature is expected.

Smokes:
  1. `./rail_native test` → 140/140 (no regression — ARM64 already passes these)
  2. Audit report: for each of the 11 symbols, state "already present at line N" or "added at line N" or "not needed, ARM64 emits inline"
  3. Byte-identical bootstrap: `./rail_native self && cmp rail_native /tmp/rail_self` (if your changes are runtime-only, no compile.rail edit, the gen2 fixed point should still be byte-identical)

Report structure:
  - Audit table for all 11 symbols (present / added / not-needed)
  - Files changed + LOC delta
  - Smoke transcripts
  - Honest deferred (any signature mismatch with Agent B's x86 work)
  - Branch + final SHA (may be empty if everything was already present — that's fine, say so)
```

---

## Agent D — stdlib auto-regen hook

```
Goal: extend Mini's post-receive hook so docs deploys regenerate stdlib.md before building the docs site. Closes the last manual step in the docs flow.

Strategic context: Prev session's Agent F shipped post-receive auto-deploy for docs/site/ changes. But docs/site/stdlib.md is currently manually regenerated on Studio via `./rail_native run tools/docs/gen_stdlib_ref.rail`. After this fix, pushing a stdlib/*.rail change auto-regens stdlib.md AND deploys the docs site.

Branch: feat/d-stdlib-auto-regen-v0
Worktree: worktree-agent-d

Scope:
  - Mini bare relay's `~/git/rail.git/hooks/post-receive` (SSH to mini.tb via `ssh <user>@<host>`)
  - May require staging `tools/docs/gen_stdlib_ref.rail` to a Mini-resident location, OR running it via rail_native checkout on Mini, OR keeping it Studio-side and triggering via SSH back to Studio.
  - Choose the simplest path that doesn't require Studio to be reachable from Mini's hook (so it works when user is remote from Studio).

Smokes:
  1. Trivially edit `stdlib/<some>.rail` (e.g., add a comment to stdlib/list.rail), commit, push to origin. Verify:
     - Mini log `ssh mini.tb tail ~/log/rail-docs-deploy.log` shows stdlib regen step running
     - `curl -s https://ledatic.org/rail/docs/stdlib | grep <comment-marker>` confirms the regen reached production
  2. No regression on docs/site/* push: a plain markdown edit still auto-deploys without the stdlib regen step
  3. Hook failure mode: if stdlib regen fails, the rest of the deploy SHOULD still run, with a loud error in the log (don't gate the whole deploy on stdlib regen succeeding)

Report structure:
  - Files changed (Mini-side hook, any Studio-side scaffolding)
  - Smoke transcripts
  - Failure-mode test result
  - Branch + final SHA
```

---

## Integration plan (Agent E equivalent — done by orchestrator, not a parallel agent)

After A/B/C/D all land:

1. `git checkout next && git pull && git checkout -b feat/tighten-dual-backend-2026-05-XX`
2. Merge A/B/C/D each with `--no-ff` (in that order: A first because compile.rail edit baselines everything; B and C interleave; D last because it's infra).
3. Re-run smokes on integrated branch:
   - `./rail_native test` → expect 140-144/140 (with tensor_* deltas from A)
   - `bash tools/test/x86_conformance.sh` → expect ≥79/79
   - Concurrent-test smoke (2 terminals) → no race
   - `./rail_native self && cmp rail_native /tmp/rail_self` → byte-identical after one cycle
4. **Milestone declaration step:** re-seed shipped `rail_native` at gen2 fixed point so first-time contributors get byte-identical on cycle 1. Update `CLAUDE.md` guidance from "may need 2-3 rounds" to "byte-identical on first self-compile cycle". Update `bootstrap_2cycle_limit` memory entry to note the re-seed.
5. Push trivial docs edit to verify D's hook fires end-to-end on production.
6. Merge to `next`, push via Mini relay.
7. Update `session_handoff.md` to reflect the milestone, archive `strategic_arc_2026-05-13` Phase 1 as DONE, mark Phase 2 (developer surface) as ACTIVE.
8. Update landing page copy if user wants the milestone publicly framed.

---

## Pre-flight checklist (do before dispatching agents)

- [ ] `cd ~/projects/rail && git status -sb` clean on `next`
- [ ] Worktrees from prev renovate session cleaned up: `git worktree list` shows only main
- [ ] Colima up: `colima status` or `colima start --arch x86_64 --vm-type=vz --vz-rosetta`
- [ ] Baseline smokes confirmed pre-dispatch: 140/140 + 71/79 + cycle-2 byte-identical
- [ ] Mini reachable: `ssh <user>@<host> true`
