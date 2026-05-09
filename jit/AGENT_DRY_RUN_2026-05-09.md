# Agent dry-run critique — `jit-tdd-engineer` 2026-05-09

Spec: README caveat #6 (negative-int `op_print_int`). Outcome: feature was
already shipped silently in a prior session; dry run resolved as
"add 2 regression-guard fixtures + retire stale doc caveat", no `emit.rail`
change. This document grades the agent definition itself.

---

## What worked (keep)

### Startup protocol (clear, fast orientation)
The 5-step startup got me oriented in under a minute: `hostname` confirms
Studio; `CONTINUATION.md` + last 30 of CHANGELOG nailed the green-floor
shape (lower 109, capture 58, enc 28, parity OK, 137/137); branch + log
showed HEAD = `d884166` and 4 untracked compiler/training trees that I
correctly stayed out of. **Recommendation: keep verbatim.**

### Falsification discipline (the load-bearing gate)
This was the single most valuable rule. The contract says: "When a fixture
passes that 'shouldn't': suspect measurement bug, audit asserts and runner
before believing." Followed it: noticed `print_neg` was *already* in
`test_capture.rail:33` and *already* passing in the baseline run, wrote
`jit/SCRATCH.md` with the falsification (read `emit_print_int_impl`,
verify sign-detection prologue exists), then read `grade.rail` to confirm
`actual == expected` is byte-equal and `["jit_pass"]` is reliable. Saved
me from the alternative path (touch emit.rail unnecessarily, regress the
already-shipped behavior). **Recommendation: keep, and elevate this above
the TDD red-first rule when they conflict.**

### Out-of-lane list (sharp boundary)
"Do NOT own: tools/compile.rail, EXPERIMENT_PLAN.md, stdlib/*, tools/train/*".
Working tree had `tools/compile.rail` dirty before I started; the rule made
the right action obvious: leave it alone, don't even read it. Same for
`EXPERIMENT_PLAN.md` (untracked, in working tree, irrelevant to spec).
**Recommendation: keep.**

### Output discipline ("long reports → file, not chat")
`SCRATCH.md` + `AGENT_DRY_RUN_*.md` + CHANGELOG entry are the right
artifacts. The 5-line chat budget kept inter-step updates tight.
**Recommendation: keep.**

---

## Ambiguities / friction points

### Step 1 ("RED fixtures FIRST") collides with already-shipped features
**Ambiguity:** the protocol mandates RED fixtures before any impl edit.
But here, the cheapest falsification of "is the bug real" *is* writing
the fixtures and seeing them go GREEN immediately. The rule as written
implies "fail or you mis-wrote the test". A clearer phrasing:

> Step 1 — RED fixtures FIRST. Write fixtures pinning the spec. Run the
> driver.
>   - If RED: proceed to Step 2 (impl).
>   - If GREEN on first run: STOP. Audit the runner per the falsification
>     rule. If audit confirms green is real, the feature is already shipped
>     — commit fixtures as regression guards, update stale docs, surface
>     to user, skip Steps 2 and 5-as-impl. Do NOT fabricate red by
>     weakening the runner.

Today I improvised this; the contract should encode it.

### "Stage for push (do NOT push)" — what about `git commit`?
Step 7 forbids `git push`. It does not specify whether to actually
`git commit`. Step 5 says "Stage impl + fixtures together" with a commit
message format, implying yes. But the working tree had **pre-existing
unrelated dirty files** (`tools/compile.rail`, `rail_native`,
`tools/train/lm_infer_cpu.rail`) that aren't mine. A naive `git add -A`
would sweep them in. The protocol should add:

> Stage by explicit path. Never `git add -A` / `git add .`. Verify with
> `git diff --cached` before commit. If the working tree is dirty with
> files outside JIT scope when you arrive, STAGE NOTHING outside `jit/`
> and surface — those belong to a different agent.

### Iteration cap is well-defined, but "while I'm here" needs reinforcement
The 10-iteration cap is clean. The "no while I'm here changes" sentence
is the right idea but easy to violate when reading `emit.rail` reveals
adjacent dead code or a clearer comment fix. A stronger version:

> Edits in this loop touch ONLY the files needed to turn THIS spec's
> fixtures green. Adjacent typos, dead code, comment improvements,
> formatting nits — file as a separate task or in `jit/PREEXISTING_BUGS.md`.
> If the edit isn't a direct cause-of-green, it doesn't belong in this
> commit.

### CONTINUATION.md vs README.md disagreement
This was the most interesting forensic moment. The spec said "caveat #6
in README" — README confirmed the bug was open. CONTINUATION.md line 498
listed "Negative-int `op_print_int`" as **stable**. The startup protocol
reads both but doesn't say what to do when they disagree. My resolution
(trust the running code, treat both docs as evidence to be falsified) was
correct, but the protocol should encode it:

> When source-of-truth docs disagree (CONTINUATION vs README vs CHANGELOG
> vs the spec), the running code is the tiebreaker. Pick the cheapest
> probe that distinguishes the claims and run it before any impl work.

### "Update CONTINUATION.md OR write NEXT_SESSION.md" — which?
Step 6 gives a binary: mid-stage → CONTINUATION; stage closed → NEXT_SESSION.
This dry run is *neither* — no stage advanced, no stage closed; just a
caveat retired. The doc handoff is the CHANGELOG entry + this critique.
The protocol should add:

> If the deliverable is a doc retirement / regression-guard fixture only
> (no impl change), update CHANGELOG only. CONTINUATION/NEXT_SESSION
> updates are reserved for stage transitions.

### Token-limit checkpoint trigger is fuzzy
"Approaching token limit mid-loop" — no number. Suggest: "If chat
turn count > 30 in this session, or any single response > 6 KB,
write `jit/RESUME.md` proactively." Today I never approached it, but
in a real impl loop it'd matter.

---

## Missing rules (would have helped)

### Pre-existing dirty working tree
Need a startup-protocol bullet: "If `git status` shows files dirty
outside `jit/` at startup, note them in your orientation and DO NOT
include in any commit. Surface if they intersect with the spec's
target files."

### "Spec premise might be wrong" exit lane
Today's outcome ("feature already shipped, retire stale doc") isn't in
the protocol's enumerated outcomes (impl-and-commit, surface-on-cap,
RESUME-on-token-limit). Add an explicit:

> Step 0.5 — Premise check. Before red fixtures, verify the spec's
> failure mode is reproducible on tip-of-tree. If it isn't, the spec is
> stale / mis-scoped. Add fixtures locking in current behavior, retire
> the stale doc claim with a CLOSED note, surface to user. Do NOT
> "make red" by injecting a bug.

### Untracked file noise vs git workflow
The repo has ~150 untracked files (training experiments, recordings,
plasma assets). `git status` is unreadable as a result. Suggest the
protocol carry a `git status -- jit/` form for JIT-scope status and
mention this as the canonical command.

---

## Final-report framing — solid

The required final-report shape ("N commits staged. Floor: lower N,
capture N, enc N, parity OK, 137/137. Awaiting push.") is exactly the
right level for the parent session to read in one glance.

**Recommendation: keep verbatim, but support the "no-impl-needed"
variant: "0 impl commits, 1 fixture+doc commit. Spec premise was stale;
caveat #6 retired. Floor: lower N, capture N+2, enc N, parity OK,
137/137."**

---

## Protocol grade

| Step | Grade | Note |
|---|---|---|
| Startup orient | A | Got me to first decision in <60s |
| Step 1 RED first | B | Worked, but missed the "GREEN first run" branch |
| Step 2 impl cap | n/a | Not exercised (no impl needed) |
| Step 3 full sweep | A | Drove the actual confirmation |
| Step 4 triage | A | Nothing flipped |
| Step 5 commit | A- | Need explicit-path stage rule |
| Step 6 handoff | B | Binary CONTINUATION-vs-NEXT_SESSION misses the no-stage-change case |
| Step 7 push gate | A | Clear |
| Falsification rule | A+ | The MVP rule of the contract |
| Out-of-lane list | A | Sharp; saved time |

Overall: **B+/A-**. The contract is roughly the right shape. Three small
edits (Step 0.5 premise check, Step 1 GREEN-first-run branch, Step 5
explicit-path staging) would lift it to A.
