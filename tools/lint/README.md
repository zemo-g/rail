# tools/lint — Rail dynamic-typing quirk linter (v0)

A pragmatic static checker for known compile.rail-era hazards. **NOT** a
type checker — Rail shed Hindley-Milner inference at bootstrap, and a real
HM pass inside compile.rail is months of work. This is a text-walking
linter that catches the three classes of bug most likely to bite today.

## Usage

```bash
# Compile the linter once, then run on any .rail file
./rail_native tools/lint/check_quirks.rail
cp /tmp/rail_out /tmp/rail_lint
/tmp/rail_lint <file.rail>
```

Exit code is 0 if no warnings, 1 otherwise.

**Large files**: the linter allocates per-line char lists; running on
`tools/compile.rail` (6,679 lines) blows past the default 1 GB arena and
triggers heavy GC thrashing (~10 min). Bump the arena to clear that:

```bash
RAIL_ARENA_MB=4096 /tmp/rail_lint tools/compile.rail   # ~2 s
```

For typical stdlib/tools files (under ~1,000 lines) the default arena is
fine.

Smoke test:

```bash
./tools/lint/run_lint_smoke.sh
```

## Codes

### Q001 — Heterogeneous numeric literal list

```rail
mixed = [1, 2.5, 3]   -- WARN: int + float literals mixed
```

**Why it matters**: `rail_float_promotion_quirk` — heterogeneous int+float
list literals trip the codegen and segfault.

### Q002 — High-arity helper (>10 params)

```rail
big_helper a b c d e f g h i j k = ...   -- WARN: 11 params
```

**Why it matters**: `rail_quirks` notes "keep helpers ≤10 params; beyond
~10 params compile.rail has known issues". Q002 also recognizes literal
`fn name(p1, p2, ...)` form even though Rail doesn't use that syntax — the
spec required it; cost is one extra scan pass.

### Q003 — Cross-function float return not wrapped at call site

```rail
make_float x = 1.5 + x
user = make_float 2            -- WARN: should be (0.0 + make_float 2)
user_ok = 0.0 + make_float 2   -- OK
```

**Why it matters**: `rail_float_promotion_quirk` — cross-function float
returns silently mistype as int and segfault. Workaround is `0.0 +` at
the call site (see `tools/desk/kill_decision.rail` history).

## Known false positives & limitations (v0, honest)

1. **Q001 false negatives** — only literal lists are scanned. A list
   built up via `cons` or containing variable-typed elements (e.g.,
   `[my_int, my_float]`) is not detected because the linter does not
   track variable types.
2. **Q001 nested-list false negatives** — `[[1, 2.5]]` may be missed if
   the inner `[` is encountered before the outer scan finishes. Nested
   lists are not v0 scope.
3. **Q002 multi-line param lists** — Rail conventions keep params on the
   def line, but if a future style splits params across lines, the count
   will be off.
4. **Q002 ADT type constructors** — `type T = | C a b c d e f g h i j k`
   would parse as 11 "params" because we only check for a leading `=`.
   Workaround: ADT defs start with `type`; check is gated on `is_def_line`
   which requires `=` so `type` lines are not flagged. (Audit if false
   positive rate is high.)
5. **Q003 false positives** — any name that ever holds a float in its
   body is treated as float-returning. Constants without params are
   excluded, but a fn that returns an int via one branch and a float
   via another will be flagged as float-returning. Also, currying-style
   partial application is not modeled.
6. **Q003 wrap detection** — we check the ~16 chars before the call site
   for `0.0 +` or `0.0+`. Patterns like `0.0 + (\n  my_fn 2)` with a
   newline between the wrap and the call are missed.
7. **Comment / string stripping** — basic, single-line. Multi-line
   strings (Rail doesn't have them) are not handled. Escaped quotes in
   strings collapse to spaces.
8. **`Q002` is on the LHS only** — `fn` body-arity issues (e.g., calls
   to `cg_node env ar lc sl tp fs ...`) are not flagged. The hazard is
   about the def, not the call.

## What this linter does NOT do (deferred)

- **Hindley-Milner inference** — months of work inside compile.rail; not
  v0 scope.
- **Type annotations in syntax** — would require lexer/parser changes.
  Out of scope: this is a text walker.
- **Flow-sensitive analysis** — branch-specific types, narrowing on
  pattern match, etc.
- **Gradual typing** — no opt-in `: Float` annotations.
- **Auto-fix mode** — diagnostics first; auto-fix is too risky for v0
  given the false-positive rate documented above.

## When to run

- Before committing edits to compile.rail or stdlib helpers that thread
  floats across function boundaries.
- As a CI gate on PRs touching `stdlib/tensor.rail` /
  `stdlib/transformer.rail` where Q003 has historically bitten.

## Output format

```
<file>:<line>: warning: <code> <one-line message>
[lint] <N> warning(s) in <file>
```

Pipe-friendly. `grep -c Q001 lint.out` for per-code counts.
