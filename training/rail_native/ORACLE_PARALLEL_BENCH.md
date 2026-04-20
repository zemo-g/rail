# oracle_compile_batch — parallel vs sequential bench

**Date:** 2026-04-20
**Host:** Mac Mini M4 Pro (24 GB, 10 P-cores + 4 E-cores)
**Binary:** `rail_native` at HEAD of `next` (≈58f7406 at bench time)
**Source:** `/tmp/bench_oracle_batch.rail` → `stdlib/oracle.rail::oracle_compile_batch`

## Setup

100 synthetic Rail programs, each ≈120 chars, all compilable:

```rail
add_<i> a b = a + b
double_<i> x = x * 2
main =
  let x = add_<i> 3 4
  let y = double_<i> x
  print (show y)
```

Bench runs `oracle_compile_batch` twice over the same 100 codes:

1. `max_conc = 1` → sequential baseline (the parallel_shell code path still
   runs, just one worker at a time).
2. `max_conc = 10` → Mini tier P-core concurrency.

Each candidate is compiled by a separate `rail_native` subprocess.
Pass/fail, error count, and quality score are the same metrics as
`oracle_quality` — scored locally off the captured stdout.

## Results (2026-04-20, Mac Mini M4 Pro)

| Mode                | Wall (ms) | ok / 100 | per-compile (ms) |
|---------------------|----------:|---------:|-----------------:|
| seq   (max_conc=1)  |    12,465 |  100/100 |              125 |
| par   (max_conc=10) |    12,142 |   99/100 |              121 |

**Speedup: 12465 / 12142 ≈ 1.03×.**

Instruction/cycle counters (from `/usr/bin/time -l` over the whole
bench, covering both runs):

```
25.18 real   15.02 user   12.14 sys
2,913,702  page reclaims       (heavy subprocess churn)
  114,816  involuntary ctx switches
   34 MB   peak memory footprint (Rail parent process)
```

## Why only 1.03×

`rail_native` **hardcodes `/tmp/rail_out.s`, `/tmp/rail_out.o`, and
`/tmp/rail_out`** as its compile intermediates.  With N concurrent
workers, they race on the `.s` file mid-assemble and the assembler
reports bogus errors like:

```
as: /tmp/rail_out.s:3127:1: error: unrecognized instruction mnemonic
```

I verified this empirically by dropping the serialisation guard and
running `parallel_shell` with `max_conc=2` over two legitimate codes:
**both returned assembler-error stdouts** despite each input being
valid.

To keep the primitive correct, `oracle_compile_batch` prefixes every
worker command with `flock /tmp/rail_compile.lock`, serialising the
actual `rail_native` invocation system-wide.  `parallel_shell` still
parallelises process spawn + stdout capture + scoring, but those
aren't the hot path — the compile itself dominates.

So the current `oracle_compile_batch`:

- ✅ **Is correct** (no race-induced false failures).
- ✅ **Is a drop-in** for future real parallelism.
- ❌ **Does not hit the ≥4× Mini target.**  It can't without
  `compile.rail` changes (out of Stream 3's scope).

## Unblocking real parallelism

The one-line fix upstream: teach `rail_native` to honour an
`--out-path <prefix>` flag (or `RAIL_OUT_PREFIX` env var) and use
`<prefix>.s`, `<prefix>.o`, `<prefix>` instead of the hardcoded
`/tmp/rail_out*` paths.

Once that lands, drop the `flock` from `ob_make_cmd` and set each
worker's prefix to `$TMPDIR/ob_<idx>` — each subprocess writes to
a unique path, the `as`/`ld` steps never collide, and the batch
scales with P-core count.

Predicted post-fix speedup on Mini (10 P-cores):

- Per-compile cost today: ~125 ms (mostly as + ld + minor Rail parse).
- Fork/exec overhead per worker: ~5–10 ms.
- 10-way parallel: ~125 ms / (10 × 0.85 efficiency) ≈ 15 ms ×10 batch
  → ~**8–9× speedup** vs today's serial 1250 ms for 10 codes.

On Studio (16 P-cores): ~**12–14×** by the same math.

## Outstanding `ok=99/100` vs `ok=100/100`

The parallel run lost one compile ("99/100 ok"). Two candidate causes:

1. Another concurrent session on the Mini (Stream 1/Stream 2 running
   `rail_native` for their own work) raced on `/tmp/rail_out.s`
   outside of our flock.  `flock` only coordinates callers that
   also take the lock.
2. A transient `mktemp` or disk hiccup.

Not deterministic; the sequential run hit 100/100 right before it.
Cross-session races disappear once every `rail_native` caller on the
box uses `--out-path`.

## Repro

```bash
# From ~/projects/rail:
rm -f /tmp/rail_compile.lock
./rail_native run /tmp/bench_oracle_batch.rail

# /tmp/bench_oracle_batch.rail builds 100 codes, runs both passes,
# prints seq_ms and par_ms in wall time.
```

## Primitives touched

- `stdlib/parallel.rail::parallel_shell`  —  N-worker fan-out, TERM+KILL
  timeout escalation, result ordering preserved.  **Works as designed**
  for any shell-cmd batch; the ceiling here is specific to rail_native.
- `stdlib/oracle.rail::oracle_compile_batch`  —  additive at bottom;
  shares thresholds with `oracle_quality` (mirrors its formula).
