# error_test — what a Rail error looks like

This program is *supposed* to fail — it references an undefined variable `y`. The point is to see how Rail surfaces the error.

**Source** (`examples/error_test.rail`):

```rail
-- Error test: intentionally references an undefined variable `y`.
-- Run with: ./rail_native run examples/error_test.rail
-- Expected failure: an `ld: Undefined symbols` link error — the unbound
-- identifier passes parse-check and is only caught at link time.

bad_func x =
  x + y

main =
  bad_func 42
```

**Run:**

```bash
./rail_native run examples/error_test.rail
```

**Output:**

```
Compiling examples/error_test.rail (318 chars)...
  as: OK
  ld: Undefined symbols for architecture arm64:
  "_RAIL_UNDEFINED_IDENT_y", referenced from:
      _bad_func in rail_build_XXXXXX.o
ld: symbol(s) not found for architecture arm64
```

The assembler accepts the code (because Rail emits a label reference for `y` without checking), and the linker (`ld`) is the one that catches the missing symbol — note the symbol name itself tells you what went wrong: `_RAIL_UNDEFINED_IDENT_y`, i.e. the undefined identifier was `y`, referenced from `bad_func`.

In normal practice, parse errors are caught earlier with `file:line:col: error:` formatting before assembly. This example demonstrates the late-stage "undefined symbol" path.
