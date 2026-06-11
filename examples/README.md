# examples/

Every example below was run from this clone on 2026-06-10 with the seed
`rail_native` at the repo root. The "expected output" column is captured from
those runs, not written from memory. Replay any row from the repo root:

```
./rail_native --out-prefix /tmp/rail_ex run examples/<name>.rail
```

(`--out-prefix` keeps your build artifacts out of the default `/tmp/rail_out`
path. The flag goes **before** the subcommand.)

Three of these examples are wired into the claim ledger — see
[PROOFS.md](../PROOFS.md) and run `bash tools/prove/prove.sh` to check them
mechanically: hello (R04), mlp_natural (R07), tco_test (R09), plus the first
of the two bug receipts below (native_closures, R19).

## Working examples

| Example | What it shows | Expected output (last lines) | ~Time |
|---|---|---|---|
| `hello.rail` | first program: print, factorial, function call | `hello, rail` / `3628800` / `42` | 0.4s |
| `calculator.rail` | arithmetic + named functions | `5` `7` `42` `10` `77` `5` (one per line) | <1s |
| `closures.rail` | lambdas, capture, map over closures | `1 4 9 16 25` / `15` / `5` | <1s |
| `fibonacci.rail` | recursion + memoization | `fib(30) = 832040` | <1s |
| `file_processor.rail` | write/read files, string transforms, shell-out | `THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG` / `wc says:` / `9` | <1s |
| `fizzbuzz.rail` | conditionals over a range | 1..30 with `Fizz`/`Buzz`/`FizzBuzz` (30 ends on `FizzBuzz`) | <1s |
| `lists.rail` | cons/head/tail/reverse/map/fold | `2 4 6 8 10` / `15` / `5` | <1s |
| `mlp_natural.rail` | `#grad` autodiff trains a 2-2-1 MLP | `mlp(1.0, 2.0)  = 1.125` / `relu(2.75)     = 2.75` | <1s |
| `pattern_matching.rail` | ADTs + match | `0` / `42` / `99` | <1s |
| `pipes.rail` | `|>` operator chains | `11` `24` `50` `7` `-42` (one per line) | <1s |
| `quicksort.rail` | recursive sort over lists | `1 2 3 4 5 6 7 8 9`, then a 12-element sorted list | <1s |
| `string_processing.rail` | split/join/replace/find + shell `date` | `hello world` / `1` / today's date — the last line is a **live `date` call**, so it is not a pinnable expected output | <1s |
| `tco_test.rail` | tail calls compile to loops: 2M-deep recursion, constant stack | `0` / `500000500000` | <1s |
| `checkpoint_roundtrip.rail` | stdlib checkpoint save/load round-trip, 17 invariants | `passed=17/17` / `PASS 17/17` | ~10s |
| `concurrency.rail` | fibers + channels (`rc_spawn`, `rc_chan_*`) | `hello from fiber 1` / `hello from fiber 2` / `1 2 3 4 5` | <1s |

`concurrency.rail` needs a one-time native build first (the dylib is
gitignored, built per-machine):

```
bash tools/runtime/build_concurrent.sh
```

## Expected-failure examples

| Example | What it shows | Expected behavior |
|---|---|---|
| `error_test.rail` | undefined identifiers fail at link, by design | `ld:` error citing `_RAIL_UNDEFINED_IDENT_y`, exit 1 (compile-only invocation) |

## Known-broken examples (kept on purpose — they are bug receipts)

These stay in the tree because a limits section you can run beats one you can
only read. Both are tracked in [docs/site/TODO.md](../docs/site/TODO.md), and
the first is replayed mechanically by `prove.sh` as R19.

| Example | Status | Detail |
|---|---|---|
| `native_closures.rail` | prints correct output (`10` / `15`), then segfaults | Closure-in-closure capture corrupts the frame on exit. Note: `run` swallows the child exit code (`$?` = 0); execute the binary directly to see exit 139. |
| `tail_calls.rail` | first two demos print (`0`, `500000500000`), then the gcd demo never terminates | Compiler miscompile: division inside a tail-recursive self-call argument re-enters the loop tagged. Root cause + verified workaround in the file header. Working TCO receipt: `tco_test.rail`. |

## Cross-target examples (not runnable on this host)

`apollo2_blink.rail`, `apollo2_uart_hello.rail`, `m4_fib_print.rail`,
`m4_systick.rail`, `m4_uart_echo.rail`, `m4_uart_hello.rail` target Cortex-M4
boards (Apollo2, generic M4). They compile with `./rail_native cortexm <file>`
and need real hardware to run — see the hw tier in `tools/prove/prove.sh`.

## readme/ and wasm/

- `readme/` — the four snippets embedded verbatim in the root README
  (`snippet_adt.rail`, `snippet_hof.rail`, `snippet_float.rail`,
  `snippet_sha256.rail`). prove.sh R16 checks the README blocks stay
  byte-identical to these files and that they run with pinned output.
- `wasm/` — small programs for the WASM backend playground.
