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
Compiling examples/error_test.rail (206 chars)...
  as: OK
  ld: Undefined symbols for architecture arm64:
/bin/sh: /tmp/rail_out: No such file or directory
```

The assembler accepts the code (because Rail emits a label reference for `y` without checking), and the linker (`ld`) is the one that catches the missing symbol. The trailing `/bin/sh: /tmp/rail_out: ...` is the driver trying to execute a binary that was never produced.

In normal practice, parse errors are caught earlier with `file:line:col: error:` formatting before assembly. This example demonstrates the late-stage "undefined symbol" path.
