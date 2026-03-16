# META BUILD LOG — Rail Compiler Implementation

*An observational record of the Rail compiler's evolution through its implementation phases.
Maintained by a meta-observer studying build progression, complexity trajectory, and deviations from the plan.*

Reference: `IMPLEMENTATION_PLAN.md` (13 phases, targeting 5K LOC / 130 tests / 500KB binary at completion)

---

## Entry 0 — Baseline Snapshot

**Date**: 2026-03-16
**Phase**: Pre-Phase 0 (starting point)

### Vital Statistics

| Metric | Value |
|--------|-------|
| Total LOC | 1,077 |
| Tests | 37/37 passing |
| Binary size | 207KB |
| Self-compile | Fixed-point proven |
| Targets | 1 (macOS ARM64) |
| FFI wrappers | 0 |
| TCO | Proven (50K recursion, constant stack) |

### Structural Breakdown

The compiler is a single file (`tools/compile.rail`) divided into seven logical sections:

| Section | Lines | Span | Notes |
|---------|-------|------|-------|
| Header | 6 | 1-6 | Usage comment |
| LEXER | 107 | 7-113 | Character classification, tokenizer (tail-recursive, accumulator style) |
| PARSER | 274 | 115-388 | Recursive descent; tuples, match arms, ADT/type declarations |
| ARM64 CODEGEN | 410 | 390-799 | String escaping, operator/builtin dispatch, atoms, binops, let/list/tuple/app/lambda, match arms, stack helpers |
| FUNCTION + PROGRAM COMPILATION | 128 | 801-928 | Function compilation, constructor encoding, runtime stubs (type dispatch, string ops, show), full-program assembly |
| BUILD (assemble + link) | 16 | 930-945 | Shell out to `as` + `ld` |
| TESTS | 103 | 947-1049 | 37 test cases with expected output, test runner |
| MAIN/CLI | 28 | 1050-1077 | argv handling, `test`/`self`/file dispatch |

**Codegen dominates** at 38% of total LOC (410/1077). Parser is second at 25% (274/1077). Tests are 10% (103/1077). The runtime is remarkably thin -- embedded as string literals within the FUNCTION + PROGRAM section (~37 lines of assembly emitted as Rail strings).

### Architecture Observations

1. **Monolithic single-file design**: Everything from lexer to linker invocation in one 1,077-line file. This is both a strength (self-hosting simplicity, no module system needed) and a constraint (will get unwieldy past ~3K lines).

2. **Bump allocator only**: 256MB arena, no reset, no GC. Works because compilation is a batch process -- allocate forward, exit. Long-running services would OOM.

3. **Tagged pointer scheme**: Integers are immediate (odd-tagged), heap objects are pointer-aligned (even). Floats, records, and other types will need new tags or boxing.

4. **Runtime is inline assembly strings**: The runtime (print, show, string ops) is emitted as ARM64 assembly text by Rail string concatenation. No separate runtime library. This keeps the toolchain minimal (`as` + `ld` only) but makes runtime changes labor-intensive.

5. **No negative literals, no floats, no string escapes**: Phase 0 targets exactly the gaps that make the compiler fragile for real-world use.

6. **Test suite is self-contained**: Tests are Rail programs compiled and executed, with stdout + exit code checked. No external test framework.

### Phase 0 Expectations (from plan)

Phase 0 targets ~250 LOC additions across 6 sub-tasks:

| Sub-task | Est. LOC | Blocks |
|----------|----------|--------|
| 0.1 Negative number literals | ~15 | Everything using negative numbers |
| 0.2 Float literals + arithmetic | ~150 | Scientific/financial computation |
| 0.3 String escape sequences | ~30 | JSON, CSS, braces in strings |
| 0.4 Multi-line list literals | ~10 | Large data structures |
| 0.5 read_line builtin | ~20 | REPL, interactive tools |
| 0.6 Integer literals > 65535 | ~25 | Large constants |

**Exit criteria**: 43+ tests passing (net +6 from 37).

### Complexity Trajectory Predictions

The plan targets these milestones:

| Phase | Target LOC | Growth | Cumulative Tests |
|-------|-----------|--------|-----------------|
| 0 (foundations) | ~1,327 | +250 | 43 |
| 1 (FFI) | ~1,692 | +365 | 50 |
| 2 (memory) | ~1,832 | +140 | 55 |
| 3 (patterns) | ~2,182 | +350 | 65 |
| 4 (modules) | ~2,312 | +130 (+300 stdlib) | 75 |
| 8 (AI tooling) | ~3,500 | — | 105 |
| 13 (final) | ~5,000 | — | 130 |

The plan's 10K LOC ceiling is conservative -- the current density (37 features in 1,077 lines) suggests Rail is terse enough to stay well under. The real risk is codegen section bloat: at 410 lines it already dominates, and every new type/feature adds dispatch branches there.

---

## Entry 1 — Phase 0 + Phase 1 + Phase 3/4 (2026-03-16)

### What was achieved:
- **Phase 0**: Negative number literals, f64 float type (boxed heap objects tag=6), `\{`/`\}` string escapes, runtime arithmetic dispatch via bl calls
- **Phase 1**: FFI via `foreign` declarations. Auto-untag int args (branchless csel). Int-returning (`foreign name args`) and pointer-returning (`foreign name args -> str/ptr`). Tested: abs, strlen, getenv all work.
- **Phase 3 partial**: Wildcard `_` patterns in match expressions
- **Phase 4 partial**: `import "path.rail"` — reads, parses, merges imported declarations

### LOC delta:
- Planned Phase 0: ~250 lines. Actual: ~100 lines (runtime strings are dense)
- Planned Phase 1: ~500 lines. Actual: ~30 lines (simpler than expected — no ABI hell, no callbacks yet)
- Total: 1,077 → 1,208 lines (+131 lines for 4 major features)

### Test count: 37 → 47 (+10 tests)
### Binary size: 207KB → 222KB (+15KB for runtime dispatch)

### Surprises:
1. Float printf on macOS ARM64 requires pushing float args to stack (variadic convention), not d0 register
2. FFI return value tagging was a bug factory — raw C returns have bit 0 that looks like tagged ints
3. Branchless csel approach for FFI arg untagging eliminates label collision problem
4. Module imports took only 10 lines — read_file + tokenize + pprog + append

### Deviations from plan:
- Phase 0.2 (floats) was much larger than estimated due to runtime function rewrites
- Phase 0.4 (multi-line lists) was already working — no changes needed
- Phase 1 skipped callbacks, pin mechanism, and external library linking (deferred)
- Phase 2 (memory model) and Phase 3 deep patterns deferred
- Phase 4 implemented minimal imports (no qualified, no export control)

### Compiler complexity trajectory:
| Metric | Baseline | After P0-P4 | Plan target |
|--------|----------|-------------|-------------|
| LOC | 1,077 | 1,208 | 2,500 (Phase 4) |
| Tests | 37 | 47 | 75 (Phase 4) |
| Binary | 207KB | 222KB | 300KB (Phase 4) |
