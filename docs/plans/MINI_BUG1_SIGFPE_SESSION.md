# Mini Session — Bug #1: SIGFPE in rail_native

You are continuing the Rail compiler project from a fresh context. Read this whole document before touching anything.

## Cold-start (do these first, in order)

1. `git rev-parse HEAD` — expect `0683e76` (or newer on `master`). If not on master, `git checkout master && git pull`.
2. `md5sum rail_native` (or `md5 -q rail_native` on macOS) — must equal `64028b07…` (full hash in prior session notes). If it doesn't match, **stop**; you have the wrong binary and any bug claim is invalid.
3. Read `~/.claude/projects/-Users-user/memory/MEMORY.md` and the memories it points to. Pay special attention to:
   - `rail_native_gotchas.md` — re-sign after `cp`, HEAD `rail_native` linker path quirk
   - `incremental_testing.md` — never launch long runs without staged short tests
4. Read `/tmp/parser_fix_state.md` (left by the prior Mini session) for context on what was attempted and what was honest vs. unreliable. Bug #1 was **not investigated** in that session — your job is to start clean.

## The bug

A SIGFPE (floating-point exception, typically integer divide-by-zero or modulo-by-zero on x86/ARM) is reaching the user from `rail_native` somewhere. **You do not yet have a reproducer.** Your first deliverable is one.

## What to do — in this order, one step at a time

### Phase 1: deterministic repro (don't skip this)

The prior session's failure mode was claiming success without a trustworthy harness. Don't repeat it. Get a one-line command that produces the SIGFPE every time before changing any code.

1. Ask the user (the human) for the exact command(s) or input file(s) that triggered the original SIGFPE. If they don't remember, ask which Rail program they were running when it happened.
2. Write a small shell script `/tmp/sigfpe_repro.sh` that runs that command and grep its exit signal (`echo $?` after a SIGFPE on macOS shows `136` = `128 + 8`).
3. Verify the repro fires deterministically across at least 3 runs.
4. **Do not proceed to Phase 2 until you have a deterministic, one-line repro.** If you can't reproduce it after 30 minutes of trying, stop and write `/tmp/sigfpe_state.md` documenting what you tried, then surface it to the user.

### Phase 2: root-cause analysis

5. Run the repro under `lldb` or with a core dump enabled (`ulimit -c unlimited`). Capture the backtrace.
6. From the backtrace, identify the call site in `tools/compile.rail` (or wherever the divide/modulo lives). Write up the root cause in `/tmp/sigfpe_rca.md` — three sentences max plus the relevant code snippet.

### Phase 3: minimal fix

7. Make the smallest possible change. A SIGFPE almost always means "guard the divisor" — either the bug is a missing zero-check on user input, or it's a logic error producing a zero divisor in a path that shouldn't reach it. Diagnose which before patching.
8. **Do not** add unrelated cleanups, defensive checks elsewhere, or "while I'm here" refactors. One bug, one diff.

### Phase 4: the verification gate (NON-NEGOTIABLE)

This is the gate that the prior session skipped. **Do not claim the bug is fixed until all three of these pass.**

9. Self-bootstrap: build a new `rail_native` from the patched source, then use that new binary to recompile itself. The two binaries (round 1 and round 2) must be **byte-identical**:
   ```
   ./rail_native tools/compile.rail   # produces rail_native_v2 (or wherever your toolchain outputs)
   ./rail_native_v2 tools/compile.rail   # produces rail_native_v3
   md5 -q rail_native_v2
   md5 -q rail_native_v3
   # MUST match
   ```
   If they don't match, the compiler is non-deterministic and your fix is suspect — **stop and investigate** before claiming success.
10. Repro must now exit cleanly (exit code 0, or whatever the program's natural successful exit is — not 136).
11. Run the existing test suite (`tools/labrat/stability_run.sh` if appropriate, plus whatever bench scripts exist). Nothing pre-existing may regress.

### Phase 5: commit + push

12. Commit on `master` with a message in this repo's style: `compile: fix SIGFPE in <symbol> — <one-line cause>`.
13. Push to origin.
14. Update `/tmp/sigfpe_rca.md` with the commit hash and write a one-line summary to `MEMORY.md` if the bug's cause is non-obvious enough to be worth remembering.

## Hard rules

- **No "tests pass" claim without the byte-identical self-bootstrap from step 9.** That's the lesson from the prior session — a 77 KB stub binary "passed tests" because it was running against stale `/tmp/rail_out`. Don't repeat that.
- **Don't touch `compound/parser-multiline` worktree.** That's Bug #2's scope. If your fix conflicts with it, note it and let the next session merge.
- **Don't skip hooks** (`--no-verify`, etc.).
- **Don't `git reset --hard` or `--force` push.**
- If the SIGFPE turns out to be a one-line guard that's already obvious from the backtrace, the whole job should take <1 hour. If you're 2+ hours in and still don't have a fix, stop and write up state — the bug is harder than expected and deserves a fresh look.

## Done criteria

- Deterministic SIGFPE repro documented in `/tmp/sigfpe_repro.sh`
- Fix committed and pushed on `master`
- Byte-identical self-bootstrap verified (md5 match)
- Repro now exits cleanly
- No regressions in existing tests
- Brief writeup in `/tmp/sigfpe_rca.md` with commit hash
