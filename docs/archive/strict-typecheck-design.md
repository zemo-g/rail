# --strict typecheck flag (A2 design note)

## Why this didn't ship as D2

The type-check warnings (`compile.rail:3337–3354` and similar) are emitted as inline `print` calls scattered across many `tc_infer_*` functions (`tc_infer_op`, `tc_infer_app`, `tc_infer_let`, etc.). Naive `--strict` plumbing needs to either:

1. **Thread a flag** through every `tc_infer*` call site (many sites, easy to miss one) → not minimal.
2. **Refactor to a counter pattern** — introduce `tc_warn ctx msg` helper that increments a counter, then check the counter at typecheck end → cleaner but touches every warning site, plus needs a mutable counter cell (Rail doesn't have ergonomic mutable globals; would need a 1-element array passed through tc_infer's signature).
3. **Capture stdout via shell** — pipe typecheck through `grep -c WARNING` → fragile, parses self-output.

Each is at least D3, not D2.

## Proposed implementation (when picked up)

Refactor pattern (option 2):

1. Add a 1-element array `tc_warn_count` allocated once at start of `compile_program`. Pass it through every `tc_infer_*` call.
2. Replace each inline `print (cat ["  WARNING [typecheck] ..."])` with `tc_warn tc_warn_count fname_ctx msg`.
3. After all type-check passes complete, in `compile_program`, check `arr_get tc_warn_count 0`. If `--strict` was passed in argv and count > 0, emit error and halt before codegen.
4. Plumb the `--strict` flag through `parse_out_prefix` style argv parsing in `main` (line 5879), or via a new `parse_strict` helper.

Estimated touch sites: all `tc_infer_*` callers. ~30–50 sites in `compile.rail`. ~2–4 hours of careful editing + test.

## Suggested first warning class to promote in strict mode

`head`/`tail` on non-list — produces the highest density of "code that segfaults at runtime that should have been a compile error" cases. Add a check in `tc_infer_app` for builtin head/tail receiving a non-list type. Priority over arithmetic-on-string because:

- Easier to detect (single argument type check).
- More common in stdlib code.
- Segfault failure mode is hostile to debugging.

## Status

Deferred — re-classified D3, blocked behind A1/A3 in the runtime correctness tier.
