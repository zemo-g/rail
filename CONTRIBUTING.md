# Contributing to Rail

Rail is a real project with a narrow but honest feature set. Contributions are welcome — this file covers build, test, and the practical bar for a patch that lands.

## Build + test in 30 seconds

```bash
git clone https://github.com/zemo-g/rail
cd rail

./rail_native test       # 116/116 core tests
./rail_native self       # self-compile → /tmp/rail_self
cmp rail_native /tmp/rail_self
# ↑ should be silent; the output is byte-identical to the binary
#   that produced it. This is the "fixed-point" property.
```

If any of those three fails on `master`, that's a bug — please open an issue.

## Prerequisites

- Apple Silicon Mac (ARM64 macOS) is the primary development target.
- Xcode command-line tools for `as` + `ld` (`xcode-select --install`).
- No other dependencies. Rail builds with just `as`, `ld`, and the kernel.

Linux ARM64 and Linux x86_64 work as cross-compile targets; WASM too. See `./rail_native linux`, `./rail_native x86`, `./rail_native wasm`.

## The bar for a compiler patch

The compiler is `tools/compile.rail` (~4,687 lines of Rail). It compiles itself. Every change goes through this loop:

```bash
# 1. Edit tools/compile.rail.

# 2. Compile the compiler with the OLD binary.
./rail_native self                        # → /tmp/rail_self

# 3. Install the new binary.
cp /tmp/rail_self ./rail_native

# 4. Verify the test suite still passes.
./rail_native test                        # must be 116/116

# 5. Verify the fixed-point property.
./rail_native self
cmp rail_native /tmp/rail_self            # must be silent
```

Step 5 is the hard part. If the new binary doesn't produce byte-identical output on the second pass, iterate (`cp /tmp/rail_self rail_native && ./rail_native self`) until it does. One or two extra passes is normal; three or more means something in the codegen is non-deterministic and wants investigation.

If you change the runtime — `rt_core`, `rt_list`, `rt_string`, the GC embedded in `compile.rail` — the old binary generates the old runtime. You have to bootstrap twice: compile, install, compile again with the new binary.

## The bar for an stdlib patch

Adding or modifying `stdlib/*.rail`:

- **Test it.** Put a standalone test under `tools/tls/` or a new directory. "Standalone" means `./rail_native run tools/whatever/my_test.rail` prints `PASS` when it works. That's the assertion contract.
- **Crypto code validates against an RFC or NIST vector.** Hand-derived expected values introduced bugs twice on the TLS branch; canonical data is load-bearing.
- **Respect the import graph.** Rail imports don't dedupe. Two textual imports of the same module cause duplicate-symbol link errors. When in doubt, imitate existing modules: leaf modules import nothing and rely on the caller's chain to provide `hex_to_bytes`, `sha_copy_bytes`, etc.

## Parser quirks you will hit

The full list lives in `CLAUDE.md`. The top five:

1. **No hex literals.** `0xFF` silently parses as `0`. Use `hex_to_bytes "ff"` for crypto constants.
2. **Leading `+` on a continuation line is a parse error.** Keep multi-line arithmetic on one physical line or parenthesise: `(a + b)\n(+ c)` fails, `(a + b) + c` on one line works.
3. **Deeply-nested `if / else` with side-effecting `let`s** between them can trigger an "expected decl" parse error or a multi-minute compile hang. Factor the deep arms into separate helper functions.
4. **`split` is single-character.** `split "abc" s` splits on `a`, `b`, `c` individually. Use `str_split` for multi-char delimiters.
5. **`to_int` is float-only.** For string → int use `parse_int` (walks `chars` via `char_to_int`).

## Code style (soft)

Rail codebases tend to use a terse functional style:

- Short, lowercase function names: `add`, `fib`, `eval` — not `addTwoNumbers`.
- Named functions defined before `main =`.
- `let _ = print "..."` for side-effect expressions.
- `show n` for int-to-string; `show_float` for floats.
- Single-line comments with `-- ` prefix.
- Named predicates preferred over lambdas in `filter` (lambdas in filter have segfault history).

## Submitting changes

1. Fork and make a feature branch.
2. Run `./rail_native test` and, if you touched the compiler, the fixed-point dance.
3. Open a PR with a clear description of what changed and why.
4. If you added crypto, point at the RFC section your test vector is from.

For bigger changes, opening an issue first to talk about the approach saves time.

## Reporting security issues

See [SECURITY.md](SECURITY.md). Rail v3.0.0 is **not** constant-time and has no side-channel-resistance guarantees. Don't deploy the crypto to side-channel-sensitive environments; that's not what it's for.

## License

By contributing, you agree your contributions are licensed under the same terms as Rail (Business Source License 1.1, converts to Apache 2.0 on 2030-04-06). See [LICENSE](LICENSE).
