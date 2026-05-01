# Session handoff — 2026-04-27 PM (bench-broken — P0 fix needed)

**Headline:** As of ~22:30 local, **`bench_railnative.rail` produces 0–1/30 against every checkpoint on disk, including the historically-shipped Spur-0.1 (was 25/30 with rerank, 13/30 single).** Every model now generates `"<prompt> <single-char>\n\n\n…"` (collapsed to 1 non-newline char + ~250 newlines). Six training experiments tonight (v0.4b, v0.4b', v0.4c, v0.4d, v0.4e + v0.2 reproduction) all scored 0–1/30 — and this is now indistinguishable from "models are fine but bench is broken." Tonight's apparent training failures are **not validated** — the inference path itself is regressed.

## What you must do first next session (P0)

Diagnose and fix the inference collapse, in that order. Until that's done, no training experiment can earn signal.

**Most likely culprit (untested but well-fingered):** `tools/metal/libtensor_gpu.dylib` is the NEW 106960-byte build from this morning's rebuild experiment (mtime 2026-04-27 10:55). The user's "restored old dylib" message did not actually take — the file on disk is still the new one. The `.pre-rebuild` backup is gone; only `.mini-reference` (88672 bytes) remains and it is symbol-incompatible with current inference code (swapping it in produced empty output instead of collapse).

Steps:

1. Rebuild `libtensor_gpu.dylib` from the Metal source in `tools/metal/`. Find the build script (probably a `build.sh` or `Makefile` in `tools/metal/` or `tools/labrat/`). After build, codesign with `codesign --sign - --force tools/metal/libtensor_gpu.dylib`.
2. Sanity check inference: `/tmp/rail_bench_rn_gen --prefix training/rail_native/checkpoints/d256_half_step3000 --max 128 --k 10 --temp 0.8 --seed 100 --prompt "fact n = if n <= 1 then 1 else n * fact (n - 1)\nmain = "` should produce a multi-line continuation, NOT `"main = t" + 250 newlines`.
3. Re-bench Spur-0.1: should hit ≥13/30 single-sample (the historical floor). If not, dig deeper — could be a stdlib regression, sampler regression, or codegen regression in the rebuilt rail_native.

## What I ruled out tonight

- **rail_native binary**: swapped in `rail_native.new` (Apr 19, the `aea87f` build the gotchas memory recommends as "use this on Studio"). Same broken inference output. Restored.
- **lm_infer_v3_half.rail**: git-checkout 9fe736a (the previous commit before `--no-ws-first` landed). Same broken output. Restored.
- **Sampling parameters**: tried temp 0.8/1.0, k 1/10, --no-ws-first 0/16, multiple seeds. Always collapses.
- **Stdlib transformer/optim/tokenizer/checkpoint**: git log shows none touched since the 25/30 flagship was scored.
- **Mini-reference dylib**: symbol-incompatible with current inference. Reverted.

State on disk is now byte-identical to the start of the session (verified via md5 on rail_native + libtensor_gpu.dylib).

## Tonight's training experiments — what was actually run

All trained, all checkpoints committed, all benched at 0–1/30 on the broken bench. Re-bench all of these as the FIRST thing after fixing inference; at least one of v0.4d / v0.4e may turn out to be positive.

| Variant | Recipe | Final loss | Bench (broken) | Re-test priority |
|---|---|---|---|---|
| v0.4b | LR=0.005 × 500 finetune from Spur-0.1, full mask | 3.78 | 1/30 | low (mask design likely flawed regardless) |
| v0.4b' | LR=5e-4 × 500 finetune from Spur-0.1, full mask | 3.62 | 1/30 | low |
| v0.4c | LR=0.02 × 3000 from-scratch, no-mask, v3 corpus (57% triples) | 3.79 | 1/30 | medium |
| v0.4d | LR=0.02 × 3000 from-scratch, no-mask, v3d corpus (30% triples, subsampled) | 3.25 | 1/30 | **HIGH** — best loss, plausible candidate |
| v0.4e | LR=0.02 × 3000 from-scratch, no-mask, v3e corpus (10% triples, subsampled = v0.2 ratio) | 3.23 | 0/30 | **HIGH** — exact-ratio control |
| Spur-Fix v0.2 (historical, re-benched) | LR=0.02 × 3000 from-scratch, no-mask, v1 corpus | (n/a) | 0/30 | **CRITICAL** — must reproduce 14/30 to validate restored bench |
| Spur-0.1 (historical, re-benched) | base | (n/a) | 0/30 | **CRITICAL** — must reproduce 13/30 to validate restored bench |

Re-bench order: **Spur-0.1 first** (sanity check on bench surface), then **v0.2** (sanity check on training surface), then **v0.4d / v0.4e** (the real candidates).

## Assets shipped tonight (durable, regardless of bench fix)

- `tools/train/harvest_inference.rail` — model-failure-driven triple harvester. Loops bench-like prompts through Spur-0.1 inference at temp=1.0 max=256, compiles each candidate, calls Qwen-3.6 35B teacher for failures, validates and emits triples. Includes rejection-reason instrumentation (codes 1=kept / 0=clean / -1=no-diag / -2=teacher-empty / -3=teacher-fix-broken). 20 seed prompts (12 short + 8 longer/harder). Smoke-tested when bench was broken — yielded only 2 triples from 120 candidates because most candidates were collapsed-1-char outputs that compile cleanly. Re-run after inference fix.
- `training/corpus_mixed_v3d.txt` — stdlib + 910 v2 triples = 780 KB, ~30% triples. Subsampled to dodge the float-arr-new bus error at 3.97 MB.
- `training/corpus_mixed_v3e.txt` — stdlib + 247 v2 triples = 607 KB, ~10% triples. Exact-ratio control vs v0.2.
- `tools/train/lm_v3_rebalance_20.rail` + `lm_v3_rebalance_10.rail` — training scripts. Includes the **scaling fix**: removed `fill_range_arr` (redundant — `float_arr_new n v` initializes to v) and `mask_sum_loop` (redundant — kept_total = corpus_len for no-mask) so they don't segfault past ~1.5M iters. Note: the bus error at 3.97 MB still exists; cap corpus ≤1.5 MB for now.
- `training/triples_v2_910.txt` and `triples_v2_247.txt` (in `/tmp/`, may need rebuild from `triples_v2.txt` by `awk` on `<END>` count).
- `tools/train/harvest_teacher.rail` — fixed CLI parsing: `cli_args` was the v1 bug; the Rail magic identifier is `args`. `to_int` is float→int, not string→int — inlined `parse_int_str` (same shape as stdlib/socket.rail's `parse_int`).

## Memory updates

- `masked_finetune_broken.md` — caveated, since v0.4b/v0.4b' bench scores were under broken bench
- `float_tco_scaling.md` — new: float-bearing self-loops segfault past ~1.5M iters; also unrelated bus error at 32MB float_arr_new
- `dylib_rebuild_hang.md` — saved earlier per user request
- `bench_inference_collapse_2026-04-27.md` — new, the headline finding
- `MEMORY.md` index updated

## Cleanup the user should consider

Five Spur-Fix v0.4 ckpts on disk, each 5–6 MB × 20 weights + 20 Adam m + 20 Adam v ≈ ~250 MB total. Will not delete without approval — re-bench them after the inference fix first; the ones that turn out negative can be dropped then.

Also `rail_native.new` (Apr 19), `rail_native.pre_1a.bak` (Apr 20) — historical backups, keep.
