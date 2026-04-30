# Session B prompt — Mini (perf role)

Primary task: **#9 Phase 1d.4 leak fix**. The 3.15 MB/step linear leak
bisected on 2026-04-20 to `_free` being a literal `ret` no-op stub at
`tools/compile.rail:2855`. Sub-64KB chunks from the malloc chain are
never returned. Fix it.

Cold-start:

1. Read `docs/plans/SESSION_PROMPT_RAIL_ON_RAIL.md` — overall context.
2. Read `docs/plans/1D4_MEMORY_LEAK.md` — root-cause analysis and four
   candidate fix paths. **Pick Option A** unless a sharper idea emerges:
   small-block free list in `compile.rail`.
3. Read `~/.claude/projects/-Users-user/memory/MEMORY.md` — user + project
   memory.
4. `cd ~/projects/rail && git rev-parse HEAD` — expect `5b88c2d` or newer.

## What to do (in order)

1. **Design the free list layout** — power-of-two size classes
   (16B/32B/64B/128B/.../32KB/64KB → 12 classes). Each class gets a
   single-linked free-list head stored in the `.bss` section. Chunk
   header is already 16 bytes (`next_link @0, alloc_size @8`) per the
   `d24340c` arena-drain fix.
2. **Rewrite `_free`** (currently at `compile.rail:2855`, literal
   `"_free:\n    ret\n\n"`):
   - Load size from `[x0, -8]` (the size header written by
     `_rail_chained_malloc`).
   - If size > 64KB: `munmap(ptr - 16, size + 16)` via darwin svc #73
     (mirror the drain at line ~2657).
   - Else: round size up to nearest class, compute class-index, push
     chunk onto that class's free-list head via CAS-free single-threaded
     write (no threading in rail_native runtime).
3. **Rewrite `_malloc`** (at `compile.rail:2854`):
   - For size ≤ 64KB, check the size-class free list first. Pop if
     non-empty, re-stamp the size header, return.
   - On empty: fall through to existing bump-alloc path.
   - Large allocations still go through the mmap path unchanged.
4. **Self-compile fixed point**:
   ```bash
   ./rail_native self && cp /tmp/rail_self rail_native
   codesign -s - --force rail_native        # cp invalidates adhoc sig
   ./rail_native test                        # expect 137/137
   ./rail_native self && cmp rail_native /tmp/rail_self
   ```
   Iterate 2–3 rounds until `cmp` is silent.
5. **Reproduce the bisect** — the bisect binary pattern is:
   ```bash
   ./rail_native tools/train/lm_v3_chunked.rail
   cp /tmp/rail_out /tmp/t5_bisect_bin
   /usr/bin/time -l /tmp/t5_bisect_bin 2>&1 | tee /tmp/bisect.log
   ```
   with `max_steps=2000`, `seq_len=1024`, `d=64`. Target: peak RSS < 2 GB
   (vs. 6.99 GB before the fix). If it's still leaking at > 1 MB/step,
   instrument what class is receiving the most allocations that don't
   come back.
6. **Fixed point re-verify** after any post-bisect tweak.

## Boundaries (don't step on Session A)

- **Session A owns `stdlib/tensor.rail`, `tools/metal/*`, training
  scripts.** Don't touch them.
- **Session A will rebuild their local `rail_native` after you push**
  your `compile.rail` change. Tell them explicitly in a commit message
  if the change affects codegen shape (symbol emission, frame layout,
  arity rules).
- Everything in `tools/compile.rail` is yours. Feel free to clean up
  surrounding runtime stubs if it helps the fix, but don't drive-by
  refactor unrelated codegen.

## Commit flow

- You're on Mini. Direct push: `git push origin next` after commit.
  Tell Session A via the handoff channel (or just rely on their
  `git pull --ff-only origin next` at session start).
- Prefer small commits: layout scaffold → `_free` rewrite → `_malloc`
  free-list check → bench result doc.
- After your fix lands and bench confirms, update
  `docs/plans/1D4_MEMORY_LEAK.md` with the actual outcome (before/after
  RSS, which option you picked, any surprises).

## Success criteria

- Fixed-point self-compile holds.
- `./rail_native test` 137/137.
- 2000-step instrumented run: peak RSS < 2 GB, leak rate < 100 KB/step
  (ideally zero-trend).
- A `docs/plans/1D4_FIX_RESULT.md` or equivalent committed alongside.

## Quirks to respect

- Data-section bug — if you need new string literals in the data section
  for labels/assertions, construct them at runtime via `malloc` + byte
  stores, not by adding to the `data` string in `compile_program`. See
  polymorphic `rshow` for the pattern.
- Changes to runtime (rt_core / rt_list / rt_string) require a bootstrap:
  compile with old binary → install → compile again with new binary.
- `cp` invalidates codesign — always re-sign rail_native after install.
- `/usr/bin/time -l peak memory footprint` is authoritative; `ps` RSS
  misleads.

## If the fix lands early

Secondary: **Task #14 Phase 2d.E bench wiring**. Scaffold in
`self_train.rail` already has `harvest_snapshot` / `harvest_rollback` /
`harvest_ab_gate`. Missing piece: parse `flywheel/bench_railnative.rail`
score output in the private repo. Full spec in
`SESSION_PROMPT_RAIL_ON_RAIL.md` under "Task #14". This needs the
private repo clone — likely already at `~/projects/rail-training` on Mini.

Rail-on-Rail in Rail. Report up.
