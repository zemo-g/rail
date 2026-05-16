# Tests

Rail's test suite runs inside the compiler binary. Source is in
`tools/compile.rail` — each test is a `run_test "name" ...` call
inside the `test_main` function.

```bash
./rail_native test
```

Expected: `140/140` on macOS ARM64. The count fluctuates only when
concurrent sessions collide on `/tmp/rail_out`; rerun to confirm.

## Self-hosting fixed point

After modifying codegen, also verify the byte-identical self-compile:

```bash
./rail_native self
diff rail_native /tmp/rail_self   # must be empty (fixed point)
```

## Test categories

The 140 cases are grouped in `tools/compile.rail` under `test_main`:

- parse / lex / error paths
- ints, floats, mixed-float promotion
- closures, ADTs, pattern match
- GC, TCO, arena mark/reset
- string ops, list ops, array ops
- effect handlers, type checker warnings
