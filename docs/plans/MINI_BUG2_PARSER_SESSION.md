# Mini Session — Bug #2: parser rejects multi-line compound expressions

You are continuing the Rail compiler project from a fresh context. **This session must run AFTER Bug #1 (SIGFPE) lands on master**, so you start from a known-good baseline. Read this whole document before touching anything.

## Cold-start (do these first, in order)

1. `git fetch && git checkout master && git pull` — must include the Bug #1 SIGFPE fix.
2. `md5 -q rail_native` (macOS) or `md5sum rail_native` — record the hash. This is your "known-good" baseline.
3. Read `~/.claude/projects/-Users-user/memory/MEMORY.md` and the memories it points to. Pay special attention to:
   - `rail_quirks.md` — multi-line parsing constraints
   - `rail_native_gotchas.md` — re-sign after `cp`, HEAD linker path
   - `incremental_testing.md`
4. Read `/tmp/parser_fix_state.md` from the prior aborted attempt — it documents what was tried, what failed, and where the draft fix lives. The honest summary: a draft fix exists in worktree `compound/parser-multiline`, but it was never trustworthily verified because the rebuild produced a 77 KB stub instead of a real ~920 KB compiler.

## The bug

The Rail parser rejects compound expressions (cons chains, nested function calls, list literals) that span multiple lines. Concrete example from real code:

```rail
all_seeds =
  cons seed1
    (cons seed2
      (cons seed3
        nil))
```

This **does not parse**. The workaround used throughout `tools/train/` is to put the whole cons chain on one line:

```rail
all_seeds = cons seed1 (cons seed2 (cons seed3 nil))
```

That works, but it's an authoring annoyance and limits how the user can structure data.

**Canonical reproducer:** the older version of `tools/train/gen_triples.rail`'s `all_seeds` binding (multi-line cons) is the case I personally hit in the prior Spur work. Find it in git history (`git log -p tools/train/gen_triples.rail`) for the exact code that broke.

## Existing draft fix

The prior session created worktree `compound/parser-multiline` (branched from `origin/master` `d32c337`) with a draft change in `tools/compile.rail`. **Treat this as a starting point, not a known-good fix.** It was never properly verified.

```
git worktree list   # confirm compound/parser-multiline exists
cd <worktree path>
git log --oneline -5
git diff master -- tools/compile.rail   # see what the prior session changed
```

If the worktree is gone, recreate it from `d32c337` and start the parser fix fresh — the draft was incomplete by the prior session's own admission.

## What to do — in this order

### Phase 1: a deterministic repro file

1. Create `/tmp/parser_repro.rail` containing the minimal multi-line compound that fails. Start with the simplest possible case (a 2-element multi-line `cons`). Verify with the **known-good** master `rail_native` that it currently fails to parse (confirm the actual error message — record it).
2. Add 3-4 progressively more complex cases (nested cons, multi-line function call, multi-line list literal). All must currently fail.

### Phase 2: review the draft fix

3. In the `compound/parser-multiline` worktree, read the prior session's diff to `tools/compile.rail`. Understand *what* it tried to change (probably tokenizer/lexer line-handling or parser whitespace rules) and *why*.
4. If the diff makes sense, keep it as a starting point. If it's confused or obviously wrong, **discard it** and start fresh — don't sink time into a flawed approach out of sunk-cost.

### Phase 3: clean rebuild (this is where the prior session went wrong)

The prior session built `rail_native_fixed` and got a 77 KB stub. The real binary is ~920 KB. Diagnosis: this worktree lacks `runtime/llm.o` build artifacts that the main repo (`rail-https`) has. Two options:

5. **Option A (preferred):** copy `runtime/` build artifacts from the main `rail-https` checkout into the worktree before linking, OR symlink:
   ```
   ln -s /path/to/rail-https/runtime ./runtime
   ```
6. **Option B:** abandon the worktree and apply the patch directly inside `rail-https` on a feature branch (`git checkout -b parser-multiline-fix`). This is simpler if the worktree's only advantage was isolation.

7. Build. Confirm the resulting `rail_native_new` is **~920 KB**, not 77 KB. If it's stub-sized, **stop** — you have the wrong link path.

### Phase 4: iterate the fix

8. Run `./rail_native_new /tmp/parser_repro.rail` against each case. Adjust the parser fix until all four cases parse and produce the expected output.
9. Don't broaden scope. The fix should target multi-line compound parsing only — not "while I'm here, also fix indentation handling" or "let me refactor the lexer." One bug, minimal diff.

### Phase 5: the verification gate (NON-NEGOTIABLE — same as Bug #1)

10. **Byte-identical self-bootstrap:**
    ```
    ./rail_native_new tools/compile.rail        # produces rail_native_v2
    ./rail_native_v2 tools/compile.rail         # produces rail_native_v3
    md5 -q rail_native_v2 rail_native_v3        # MUST match
    ```
    If they don't match, the parser fix introduced non-determinism — stop and investigate before claiming success.

11. **Run the full existing test suite.** Whatever `tools/labrat/`, `flywheel/`, and bench scripts exist must all pass. Nothing pre-existing may regress.

12. **Repro file passes:** all 4 cases in `/tmp/parser_repro.rail` now parse and behave correctly.

### Phase 6: commit + push

13. Commit on `master` (or via PR if the user prefers): `compile: parser supports multi-line compound expressions`.
14. Push.
15. Add a note to `MEMORY.md` updating `rail_quirks.md` — the multi-line constraint is gone, so any future code can use natural multi-line cons chains.

## Hard rules

- **Binary size sanity check:** if `rail_native_new` is < 800 KB, **stop**. You're building a stub. Fix the link path before going further.
- **No "tests pass" without byte-identical self-bootstrap from step 10.** This is the exact failure mode that wasted the prior session.
- **Don't touch SIGFPE-related code** — that's Bug #1, already landed before you started. Stay scoped.
- **Don't skip hooks**, no `--force` push, no `--amend` of pushed commits.
- The prior session's `/tmp/parser_fix_state.md` exists for context. Read it; don't delete it.
- If the parser fix turns out to require deep lexer changes (>200 lines of diff), **stop and surface to the user** — that scope creep is a redesign, not a bugfix.

## Done criteria

- All 4 cases in `/tmp/parser_repro.rail` parse correctly
- Byte-identical self-bootstrap verified
- Existing test suite passes with no regressions
- New `rail_native` is real-sized (~920 KB)
- Commit on `master` and pushed
- `rail_quirks.md` updated to reflect the constraint is lifted
