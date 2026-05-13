# error_test — what a Rail error looks like

This program is *supposed* to fail — it references an undefined variable `y`. The point is to see how Rail surfaces the error.

**Source** (`examples/error_test.rail`):

```rail
-- Error test: demonstrates line:col in error messages
-- Run with: rail run examples/error_test.rail
-- Check with: rail check examples/error_test.rail

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
