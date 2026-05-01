# Session A prompt — Studio (trainer role)

Primary task: **#19 Phase 4a Rail-side fp16 wiring**. The 4 labrat-produced
fp16 matmul kernels already live in `tools/metal/tensor_gpu.metal` (lines
654–802). They are **not callable from Rail yet.** Your job: make them
callable and measure a speedup on a real Rail training step.

Cold-start:

1. Read `docs/plans/SESSION_PROMPT_RAIL_ON_RAIL.md` — overall context.
2. Read `~/.claude/projects/-Users-user/memory/MEMORY.md` — user + project
   memory (quirks, role split, mission).
3. `git rev-parse HEAD` — expect `5b88c2d` or newer.

## What to do (in order)

1. **Foreign decls** — in `stdlib/tensor.rail` near line ~201, mirror the
   existing `tgl_matmul_f64` / `tgl_matmul_relu_f64` / `tgl_matmul_gelu_f64`
   / `tgl_matmul_batched_f64` decls with `_f16` siblings. Keep Rail-side
   types as `float_arr` (native f64) — conversion to/from half happens in
   the dylib. Four new decls total.
2. **Host dispatch** — in `tools/metal/tensor_gpu_lib.m`, add
   `tgl_matmul_f16`, `tgl_matmul_blocked_f16`, `tgl_matmul_bias_relu_f16`,
   `tgl_matmul_bias_gelu_f16` entry points. Pattern to copy: the existing
   `tgl_matmul_f64` (line ~379). Differences:
   - Stage inputs as `uint16_t*` half buffers (use `f64_to_f16` bit-ops —
     see `tools/metal/probes/fp16_probe.m` for `f32_to_f16`, adapt for
     double input).
   - Pipeline key is the `matmul_f16` etc. kernel name.
   - `bias_relu_f16` and `bias_gelu_f16` keep the bias buffer as `float*`
     (fp32) per the v2 task-spec hint that made labrat land the kernel.
3. **Rebuild dylib** using the build line at the top of
   `tensor_gpu_lib.m`:
   ```bash
   cd tools/metal
   clang -shared -fobjc-arc -framework Metal -framework Foundation \
     -install_name /Users/user/projects/rail/tools/metal/libtensor_gpu.dylib \
     tensor_gpu_lib.m -o libtensor_gpu.dylib
   ```
   Note: the existing install_name in the source points at
   `/Users/ledaticempire/...` (Mini's path). Patch it to the Studio path
   **only for the local rebuild** — do not commit that change. Or pass
   `-install_name` override on the command line as shown above.
4. **Smoke test** — write `tools/test/fp16_matmul_smoke.rail` that:
   - allocates two 128×128 `float_arr`s with fixed seeds
   - calls `tgl_matmul_f64` and `tgl_matmul_f16`
   - asserts max-abs diff < 1e-2 (half has ~3 decimal digits)
   - prints "ok fp16" on success
5. **`./rail_native test`** must still be 137/137 (or whatever the
   current baseline is). Rerun once if a count flaps — `/tmp/rail_out`
   race with the other session is possible.
6. **Measure a real training step** — clone `lm_v3_chunked.rail` →
   `/tmp/lm_v3_chunked_f16.rail`, swap the matmul call in
   `m_block_fwd` for the f16 variant, run 10 steps, compare wall-clock
   vs. unchanged f64 baseline. Report speedup.

## Then (if time): start Task #12 4-block depth

Plan at `docs/plans/SESSION_PROMPT_RAIL_ON_RAIL.md` under "Task #12".
Clone `lm_v3_chunked.rail` → `lm_v3_chunked_4block.rail` first so 2-block
stays as the baseline. Stage 10 → 50 → 500 → 3000. Target: eval mean
below d=128×2-block's 2.87.

## Boundaries (don't step on Session B)

- **Session B owns `tools/compile.rail`.** Don't edit it.
- **Session B owns `rail_native` rebuilds.** If Session B commits a new
  compile.rail, you'll pull and rebuild locally — but you don't drive it.
- Everything else (stdlib, tools/metal, tools/train, tools/test) is yours
  unless you hit a file Session B is clearly editing — `git status` on
  Mini (`ssh ledaticempire@mini.tb "cd ~/projects/rail && git status"`)
  before touching anything cross-cutting.

## Commit flow

- No github SSH from Studio. Use Mini proxy per `session_handoff.md`:
  scp changed files → `ssh ledaticempire@mini.tb` → git add/commit/push
  → `git pull --ff-only origin next` back on Studio.
- Commit granularity: one commit per logical unit (foreign decls,
  host dispatch, smoke test, bench result). Prefix `stdlib:` / `metal:`
  / `test:` / `bench:` to match recent history.
- Do NOT commit `rail_native` (toolchain-local).
- Do NOT commit `libtensor_gpu.dylib` (not in git).
- Do NOT commit the install_name patch to `tensor_gpu_lib.m` (Mini's
  path must stay canonical).

## Success criteria

- Foreign decls committed, host dispatch committed, smoke committed.
- f16 smoke passes numerical tolerance.
- 10-step wall-time comparison logged: f16 vs f64.
- `./rail_native test` still green.
- Handoff note appended to this prompt file under a dated
  "Session A result" heading.

## Quirks to respect

- `cp rail_native <x>` invalidates codesign → re-sign with
  `codesign -s - --force <x>`.
- `/usr/bin/time -l peak memory footprint` is the real memory number.
  `ps` RSS lies.
- Helper arity ≤10 params; pack scalar accumulators into `float_arr_new 2`.
- Nullary `let x = float_arr_new ...` re-evaluates on every reference —
  not a cache. Thread as parameter.
- Float `>=` codegen segfaults (reported 2026-04-20 PM). Route via
  `*1000.0 → float_to_int → int >=` if you need it.
- Nested match on multi-ctor ADTs is broken at depth ≥2. Extract inner
  match into helper.

Rail-on-Rail in Rail. Report up.
