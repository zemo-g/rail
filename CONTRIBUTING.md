# Contributing to Rail

Rail is a self-hosting programming language. The compiler is written in Rail and compiles itself to ARM64 native code. Contributions are welcome.

## Prerequisites

- Apple Silicon Mac (ARM64 macOS)
- Xcode command-line tools (`xcode-select --install`) -- provides `as` and `ld`
- No other dependencies

## Getting Started

```bash
git clone https://github.com/zemo-g/rail
cd rail

# The seed binary is already in the repo. Test it:
./rail_native test          # should be 70/70
./rail_native run examples/hello.rail
```

## Building from Source

Rail is self-hosting. The seed binary (`rail_native`) compiles the compiler source (`tools/compile.rail`) to produce a new binary:

```bash
./rail_native self                    # compiles itself -> /tmp/rail_self
cp /tmp/rail_self ./rail_native       # install the new binary
./rail_native test                    # verify 70/70 tests pass
```

The self-compiled binary must be byte-identical to itself when it compiles the compiler again. This is the **fixed-point property** -- the compiler is a fixed point of itself.

## Running Programs

```bash
./rail_native run file.rail           # compile + execute
./rail_native file.rail               # compile only -> /tmp/rail_out
```

## Running Tests

```bash
./rail_native test                    # run the full 70-test suite
```

All 70 tests should pass. If any fail, do not submit a PR until you've fixed the regression.

## Modifying the Compiler

The compiler lives in `tools/compile.rail` (~1,979 lines). After making changes, you **must** verify the fixed-point property:

```bash
# 1. Compile with the current binary
./rail_native self                    # produces /tmp/rail_self

# 2. Install the new binary
cp /tmp/rail_self ./rail_native

# 3. Compile again with the new binary
./rail_native self                    # produces /tmp/rail_self

# 4. Verify fixed point (output must be byte-identical)
diff /tmp/rail_self /tmp/rail_out
# Must produce NO output

# 5. If not identical, repeat steps 2-4 until stable

# 6. Run the test suite
./rail_native test                    # must be 70/70
```

If the diff is not empty, your change is not yet a fixed point. Keep iterating (install new binary, self-compile, diff) until the output stabilizes.

## Adding a Test

Tests are embedded in the compiler's test harness. Look at the `test` command handling in `tools/compile.rail` to understand the pattern, then add your test case following the same structure. Every test must pass deterministically.

## Adding an Example

Examples live in `examples/`. Each should be:

1. **Self-contained** -- no imports or external files required
2. **Compilable and runnable** -- `./rail_native run examples/yourfile.rail` must succeed
3. **Commented** -- header comment explaining what the example demonstrates
4. **Small** -- under 50 lines is ideal; showcase one or two features

Test your example before submitting:

```bash
./rail_native run examples/yourfile.rail
```

## Code Style

Rail uses a terse, functional style:

- **Short function names**: `add`, `fib`, `eval`, not `addTwoNumbers`
- **Functions before main**: all named functions are defined before `main =`
- **`let _ =` for side effects**: `let _ = print "hello"` (since Rail is expression-oriented)
- **Named predicates over lambdas in filter**: `filter isEven xs` not `filter (\x -> ...) xs` (lambdas in filter can segfault at runtime)
- **`show` for int-to-string**: `show 42` produces `"42"`
- **Comments**: `-- single line comment`

## Known Limitations

Be aware of these when writing Rail code:

- `split` is **single-character only**: `split "abc" s` splits on each of `a`, `b`, `c` individually, not the substring `"abc"`
- `show` works on integers and floats
- Lambdas in `filter` can segfault -- use named predicate functions instead
- Partial application of multi-arg functions may segfault in some contexts
- WASM backend compiles but has runtime issues

## Project Structure

```
rail_native              # seed binary (ARM64 Mach-O, ~329K)
tools/compile.rail       # the compiler (1,979 lines of Rail)
runtime/gc.c             # garbage collector (conservative mark-sweep)
runtime/llm.c            # LLM builtin (calls local inference servers)
stdlib/                  # 22 stdlib modules (json, http, sqlite, etc.)
examples/                # example programs
```

## Submitting Changes

1. Fork the repo and create a feature branch
2. Make your changes
3. Verify the fixed-point property (if you touched the compiler)
4. Run `./rail_native test` -- 70/70
5. Test any new examples with `./rail_native run`
6. Open a pull request with a clear description of what changed and why

## License

Rail is licensed under the Business Source License 1.1 (BSL 1.1). It converts to MIT on 2030-03-14. By contributing, you agree that your contributions will be licensed under the same terms. See [LICENSE](LICENSE) for details.
