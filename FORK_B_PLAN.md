# Fork B — Rail Self-Trains on Metal (ULTRAPLAN)

**Status**: **M1-M5 shipped 2026-04-15** (same day as plan written). See
CHANGELOG.md v2.17.0-v2.21.0 for the landed commits. Strategic frame
held; tactical details deviated — daemon turned orthogonal, compiler
unblocks were the real wins. Next workflow queued below at
"Post-M5 next steps."
**Decision**: Fork B. Rail-native training, Metal dispatch, zero Python in the inner training loop.
**Machine split**: Mini owns training. Studio owns inference (DDA, Qwen3.5-27B on 10.42.0.2:8080). Razer idle.

## Delivered vs planned

| Milestone | Planned | Delivered | Status |
|---|---|---|---|
| M1 | Clear stale banners, rerun gradchecks | `autograd.rail` + `DLOPEN_STATUS.md` banners cleared; attention 18/18, layernorm 9/9 | ✅ |
| M2 | `lm_transformer` ≤ 2.10 on Shakespeare | 2.098 at d=16, 2000 steps | ✅ |
| M3 | Rail-native Metal daemon | `tensor_daemond` shipped; but turned out unnecessary — in-process dylib works from Rail once `DLOPEN_STATUS` (stale) was re-tested | ✅ (scope shifted) |
| M4 | Unattended launchd loop + kill switch | `rail_native_loop.sh` + `com.ledatic.rail_train.plist` ready (not bootstrapped; awaiting checkpoint persistence) | ✅ partial |
| M5 | First real scaled-up train | d=64, loss 1.796 in 500 steps (6× faster than d=16 baseline). Shakespeare corpus still — Rail stdlib pivot queued. | ✅ partial |

## Load-bearing unlocks this session (compiler)

Three compiler fixes earned all the downstream wins:

1. **v2.18 — arity-gate channel `send`/`recv`**: 2-arg `send`/1-arg `recv` → channel dispatch, else → foreign FFI. Rail sockets work at all.
2. **v2.19 — batched f32 file I/O**: `_rail_float_arr_to_f32_file` emitted 1 syscall per float (16K syscalls per 64KB); switched to malloc-buffer + single syscall. 11× faster.
3. **v2.20 — simplify `gpu_matmul_dispatch`**: the `ensure_dylib` cache was hitting the top-level nullary re-eval bug (below), so every matmul paid a shell `test -f` check. Fixed by trusting `tgl_init` idempotency. 60× over CPU at 256×256.

## Known latent compiler bug

Top-level `name = expr` bindings (no args) are re-evaluated per reference instead of memoized. Affects any global cache pattern. Worked around twice this session. Proper fix queued.

## Post-M5 next steps (queued for next session)

1. **Full 2000-step d=64 run** → definitive loss curve + model card.
2. **Sample generation path** → feed trained weights back to forward, extract completions. Needed for model card.
3. **Pivot corpus Shakespeare → Rail stdlib** (`training/rail_native/data/corpus.txt`, 553KB prebuilt). Strategic goal per original plan §M7+ (compile-as-oracle setup).
4. **Checkpoint save/resume** via `stdlib/checkpoint.rail` — blocks the 24h unattended soak.
5. **Eval split** (last 10% of corpus held out) + val loss at checkpoint boundaries.
6. **Bootstrap launchd, 24h soak** — once #4 + #5 land.
7. **Fix top-level nullary memoization** in compile.rail (clean up the workarounds).
8. **Scale gate M6** — decide multi-head / multi-block / wider d after M5 ships.

## Ground truth established by running, not reading (2026-04-15)

| Claim (pre-audit) | Reality (verified) |
|---|---|
| "Metal matmul 474 GFLOPS on M4 Pro" | **True from C, false from Rail.** `libtensor_gpu.dylib` benches at 0.29ms/call from `test_dylib.c`. **Segfaults when called from Rail** due to ObjC runtime / signal handler conflict. Documented in `tools/metal/DLOPEN_STATUS.md` (2026-04-13). |
| "Autograd 13-primitive gap" | **Stale.** All 13 primitives implemented in `stdlib/tensor.rail:669–948`. |
| "Transformer training stack shipped" | **Partially true.** `tools/train/lm_transformer.rail` runs end-to-end but does **not** converge to its own stated target. Final loss 2.90 on 500 steps; v2.3 bigram baseline is 2.10. Beats uniform, does not beat bigram, does not beat v2.4 attn-only (2.62). |
| "XOR converges" | **True.** Loss → 0 at step 100. |
| "Attention backward correct" | **True.** `tools/train/attention_gradcheck.rail` → 18/18 PASS against finite diff. |
| "Metal dispatch already wired in tensor.rail" | **True in source** (`gpu_matmul_dispatch` at line 234 of tensor.rail tries dylib → binary file → text file fallback) **but the dylib path is dead on arrival** for Rail process, so matmul always falls through to file-mode (~50ms/call) or CPU loop. |

The plan below reflects reality, not the optimistic read.

## The three real blockers, in order

### Blocker 1: The transformer doesn't train well enough

`tools/train/lm_transformer.rail` ends at loss 2.90 on a 383-char Shakespeare excerpt, d=16, d_ff=64, 500 steps, cosine LR peak=0.05 warmup=30. The v2.5 commit message implies it was designed to beat 2.10. Today it doesn't. Options:

- **Steps insufficient.** 500 may be too few for a transformer on 382-token seq. Try 2000, 5000.
- **LR regression.** peak=0.05 with warmup=30 may have been tuned for an earlier version and silently broken.
- **Init regression.** `init_weight` uses seed-indexed init (seeds 1–7 for the 7 weight tensors). One of them may be producing a bad starting point.
- **A silent gradient bug introduced after the gradcheck was last run.** Unlikely but possible — layernorm gradcheck should be rerun.

**No Fork B move matters until this is fixed.** Training a model that doesn't train better than random bigrams is not progress. Fork B's success criteria all presume this converges.

### Blocker 2: Rail cannot call Metal dylib directly

`DLOPEN_STATUS.md` documents four paths forward:

| Path | Pros | Cons |
|---|---|---|
| **A. `__attribute__((constructor))` + CFTypeRef refactor** (no ARC) | Keeps Rail → dylib direct FFI. Fastest. | Already partially attempted (constructor in tensor_gpu_lib.m); still segfaults. ObjC/signal handler conflict may be fundamental. |
| **B. Fork worker process** (tensor_daemon.py today, Rail-native tomorrow) | Isolates ObjC runtime. Already implemented in Python as a working reference. | Adds IPC cost (~0.1–1ms/call). If Python stays, "no Python in loop" story dies. |
| **C. Subprocess per call (file-mode)** | Works today. No new code. | ~50ms/call. Kills any hope of 5× speedup target. Unusable for real training. |
| **D. Rewrite Metal binding in Rail against Metal C ABI directly** | Pure Rail. No ObjC runtime. | Large engineering lift. Metal.framework's C ABI is undocumented and may not exist cleanly. |

**Recommendation: Path B with a Rail-native daemon.** Write a small Objective-C binary that listens on a Unix socket, keeps Metal state warm, and dispatches kernel calls. Rail talks to it via `stdlib/socket.rail`. No Python in the loop. Keeps the ObjC runtime hermetic in a separate process.

The existing `tensor_daemon.py` + `tensor_gpu` binary is a working reference for the protocol. Porting the daemon harness from Python to a 200-line ObjC binary is straightforward. The actual Metal kernels already live in `tensor_gpu_lib.m` — just wrap them in a socket server instead of a dylib.

### Blocker 3: No unattended loop, no measurement infrastructure

No launchd plist, no checkpoint cadence, no log rotation, no kill switch, no resume-from-last, no eval split. The training directory has `railml_ane_ckpts_v1` through `v12` — evidence someone was iterating manually — but no durable loop.

## Milestones — concrete

### M1 — Re-audit + fix stale docs (half day)

**Owner**: anyone. **Unblocks**: M2.

```bash
# Rerun all gradchecks. Record pass/fail.
cd ~/projects/rail
./rail_native run tools/train/attention_gradcheck.rail      # already 18/18 on 2026-04-15
./rail_native run tools/train/layernorm_gradcheck.rail      # need to verify
# If there's no softmax gradcheck, add one before M2.
```

Then edit `stdlib/autograd.rail:6` — delete the "EXPERIMENTAL — INCOMPLETE — KNOWN LINK GAP" banner. The 13-primitive gap is closed. Leave a dated line: "2026-04-15: all 13 primitives implemented in tensor.rail:669–948."

Edit `tools/metal/DLOPEN_STATUS.md` — refresh with today's re-verification if still relevant. Add a clear verdict at the top: "Path B (daemon) is the adopted solution. Path A (direct dlopen) is archived."

### M2 — Make lm_transformer actually beat its baselines (1–2 days, CPU only)

**Owner**: Claude + Reilly. **Unblocks**: M3 (no point benchmarking Metal on a broken training loop).

Success bar: `lm_transformer.rail` ends at loss ≤ 2.10 on the Shakespeare corpus. Prefer ≤ 2.00.

Experiment sequence, each a single edit + run:

1. **Bump steps 500 → 2000.** Measure loss curve every 100 steps. If monotone decrease, we're just undertraining. CPU cost: 500 steps = 2m54s, so 2000 steps ≈ 12 min.
2. **If still stuck**: LR sweep. Try peak_lr ∈ {0.01, 0.02, 0.1} × warmup ∈ {10, 30, 100}. 6 runs × 2000 steps = ~70 min.
3. **If still stuck**: seed sweep. The init seeds 1–7 may be pathological. Try seeds 11–17.
4. **If still stuck**: run `layernorm_gradcheck.rail`. If it fails, a gradient bug landed after v2.5. Fix it.
5. **If still stuck**: instrument — print max(|grad|), max(|weight|), Adam's effective step size per 100 iters. Look for exploding/vanishing gradients, dead neurons, LayerNorm collapse.

Deliverable: `FORK_B_M2_NOTES.md` with the final hyperparams, the loss curve, and a commit bumping the default in lm_transformer.rail. Commit title: `rail vX.Y.Z: lm_transformer beats bigram baseline (loss N.NN)`.

### M3 — Rail-native Metal daemon (2–3 days)

**Owner**: Claude + Reilly. **Unblocks**: M4.

Deliverable: `tools/metal/tensor_daemond` — a standalone ObjC binary that:
- Listens on `/tmp/rail_tensord.sock` (Unix socket, not TCP — faster, simpler permission model).
- Keeps `MTLDevice`, `MTLCommandQueue`, compiled pipelines warm.
- Speaks a binary protocol: `[op_id:u8, arg_count:u8, arg_sizes:u32[], arg_payloads:bytes[]]` → `[status:u8, result_size:u32, result:bytes]`.
- Supports all 23 ops currently in `libtensor_gpu.dylib` (enumerate: matmul, matmul_relu, matmul_gelu, matmul_batched, add, mul, scale, relu, relu_backward, sigmoid, exp, tanh, softmax_rows, softmax_backward, ce_softmax_backward, transpose, sgd_update, adam_update, cross_entropy, layernorm_backward, sum, unary_from_source, init).
- Ships with a launchd plist for auto-start, but also supports manual `./tensor_daemond &`.

Rail side: update `stdlib/tensor.rail` so `gpu_matmul_dispatch` tries daemon socket **first** (new path 0), dylib **second** (existing path 1, still dead but leave for future), binary file **third** (existing fallback). Pattern already exists in the file, just insert a new branch at the top.

Build command:

```bash
cd ~/projects/rail/tools/metal
clang -fobjc-arc -framework Metal -framework Foundation \
  tensor_daemond.m -o tensor_daemond
```

Benchmark: with daemon running, rerun M2's final lm_transformer config. Compare wall-clock to CPU baseline. **Target: ≥ 5× speedup on 500-step run.** 2m54s CPU → ≤ 35s daemon. If it's < 3×, IPC overhead is dominating — batch more work per call, or move to shared-memory mmap instead of socket.

### M4 — Unattended training loop (1–2 days)

**Owner**: Claude. **Unblocks**: M5.

Deliverables:

1. **`tools/train/rail_native_loop.rail`** — the outer loop. Reads `training/rail_native/state.toml`, resumes or starts fresh, trains N steps, checkpoints, evals on holdout, logs, repeats.
2. **`~/Library/LaunchAgents/com.ledatic.rail_train.plist`** — launchd plist. `RunAtLoad=false` initially (manual start via `launchctl bootstrap gui/$(id -u) ...`). `KeepAlive=true` so it restarts on crash. `ThrottleInterval=30` so it doesn't crash-loop.
3. **Kill switch** — file at `~/.ledatic/data/.rail_train_kill`. Checked at top of each step. If present, clean-exit. Matches trading stack's pattern.
4. **Directory layout**:
   ```
   training/rail_native/
     state.toml            -- step, epoch, best_val_loss, hyperparams
     checkpoints/
       step_001000.weights
       step_002000.weights
       best.weights         -- symlink to best-val checkpoint
     logs/
       train.log            -- per-step loss, lr, wall-clock
       eval.log             -- per-checkpoint val loss
     data/
       corpus.txt           -- the training corpus (see M5 for choice)
       tokenizer.json
   ```
5. **Log rotation**: `train.log` cycles at 100MB. Keep last 3.
6. **Dependency on tensor daemon**: the plist sets `EnvironmentVariables.RAIL_TENSORD_SOCK=/tmp/rail_tensord.sock`. If the daemon isn't up, training fails fast with a clear error — does NOT silently fall back to CPU, because that burns power on a useless run.

Kill-switch check (insert at top of the inner train step):

```rail
is_kill_requested _ =
  let kill_path = "/Users/ledaticempire/.ledatic/data/.rail_train_kill"
  match stat kill_path
  | Ok _ -> true
  | Err _ -> false
```

### M5 — First real train run (1 day)

**Owner**: Claude + Reilly. **Unblocks**: M6 decision.

Corpus decision (open question from prior plan, resolve here):

**Recommendation: Rail stdlib source.** ~30k lines, ~1MB of text. Teaches the model the language it runs in. Aligns with "cumulative — everything we build serves a purpose." Sets up M7+ (compile-as-oracle) naturally because the student is learning the oracle's input language.

Alternative considered: TinyStories subset. Easier learning signal, more conventional LM eval, but no cumulative-growth leverage. Pass.

Corpus prep:

```bash
cd ~/projects/rail
cat stdlib/*.rail tools/*.rail examples/*.rail | \
  head -c 1000000 > training/rail_native/data/corpus.txt
# ~1MB corpus, BPE tokenize (tokenizer.json)
```

Model: scale lm_transformer up incrementally. Start d=64, d_ff=256, single block, single head (because multi-head is v2.12 but hasn't been stress-tested yet). Vocab via BPE at 4096 tokens.

Train budget: 10k steps. At post-M3 daemon speed (estimated < 0.1s/step), ~15 minutes. If it works, scale to 100k steps for overnight run. If it doesn't work after 10k, back to M2 — the model is broken, not slow.

Deliverable: a model card at `training/rail_native/MODEL_CARD_v0.1.md` with:
- Architecture (d, d_ff, heads, blocks, vocab_size)
- Corpus (size, source, dedup status)
- Hyperparameters (lr schedule, optimizer, batch)
- Final loss, val loss, wall-clock total
- Metal GPU utilization during training (powermetrics sample)
- Sample generation: 3 prompts × 3 completions, pasted verbatim

### M6 — Scale gate (decision, not a workstream)

Post-M5, review the model card. Decide:

- **Scale up?** Add blocks (single → 4), add heads (single → 4), widen (d=64 → d=256). Mini's 22GB wired cap keeps us well under 100M params.
- **Scale data?** Expand corpus. Rail stdlib + `tools/` + `examples/` + `flywheel/*.rail`.
- **Stay small, optimize?** Focus on Metal utilization, batch size, multi-stream async.

Defer this decision to post-M5 real data. No speculation.

### M7+ — Oracle re-integration (deferred)

Out of this plan's scope. Pointer only:

When M5's model is good enough to generate Rail code that *sometimes compiles*, revive the compile-as-oracle loop:

1. Rail-native model proposes code for a prompt.
2. `./rail_native` compiles it. Success or error message is the signal.
3. Successful generations → retrain corpus.
4. Errors → teach the model about its own error output.

This is where Flywheel's 501 harvested examples get replayed. The curriculum file at `training/self_train/` is preserved, not deleted. Compile-as-oracle returns, just with a Rail-native student instead of Qwen.

## What's out of scope (deliberately)

- Touching Studio. It's serving DDA. Don't.
- Reviving `com.ledatic.mlx*` on Mini. Inference stays off the training node.
- Razer CUDA training. Fork A is suspended.
- Multi-block or multi-head transformer scale-up before M5. v2.12 multi-head exists, but is untested under sustained training. Use single-block single-head for M5, scale in M6.
- Rail-native tokenizer training. Use the existing BPE tokenizer in `stdlib/tokenizer.rail` for M5. Rolling our own tokenizer is a separate project.
- Path A / Path D in the dylib table above. Path B is the bet.

## Risks + explicit mitigations

| Risk | Likelihood | Detection | Mitigation |
|---|---|---|---|
| M2 never converges — transformer has a latent gradient bug | Medium | `layernorm_gradcheck` fails, or `max(|grad|)` instrumentation shows explosion/vanishing | Fall back to multi-block MLP as the M5 target; transformer ships in a later milestone |
| Tensor daemon IPC overhead dominates — no 5× speedup | Medium-high | M3 benchmark returns < 3× | Move to shared-memory mmap instead of socket; batch ops per call (one roundtrip per training step, not per matmul) |
| Metal daemon leaks memory over long runs | Medium | Activity Monitor on tensor_daemond shows RSS growth during M5 | Daemon restarts every 1000 training steps (launchd respawn); or explicit autoreleasepool per request |
| Rail's 256MB thread stack overflows during long training | Low | Segfault after N steps, reproducible | `arena_mark`/`arena_reset` at the top of each training step to free intermediate tensors |
| Mini thermal throttles under sustained load | Low-medium | `powermetrics --samplers thermal` shows CPU throttle events during M5 | Add duty cycling — 10 min train, 30s idle; check GPU temp before each step |
| Training loop dies silently | Medium | No new entries in `train.log` for 5 min | launchd `KeepAlive=true` respawns; `com.ledatic.rail_train_watchdog.plist` checks log mtime every 5 min, nags via `osascript display notification` if stale |
| DDA briefs on Studio break during Mini's training runs | Low | DDA Monday brief fails or is visibly degraded | The two machines are on different GPUs and don't share RAM; zero contention expected. But if it happens, kill Mini's loop via `.rail_train_kill`. DDA wins over Fork B. |

## Success criteria for Fork B — all five, or not shipped

1. **`lm_transformer.rail` beats v2.3 bigram baseline (2.10).** Loss ≤ 2.10 on Shakespeare corpus with the committed hyperparams. (M2)
2. **Metal daemon on hot path, measured.** `tensor_daemond` running, matmul dispatched through it, ≥ 5× wall-clock speedup vs CPU on the same config. Benchmarked and logged. (M3)
3. **Unattended loop for ≥ 24h on Mini.** Zero human intervention. Zero re-enabling of inference services on Mini. Checkpoint cadence respected. Log rotation works. Kill switch verified. (M4)
4. **Trained checkpoint + model card committed** to `training/rail_native/`. Sample generations pasted in the card. (M5)
5. **No regression**: `./rail_native test` → 106/106. `./rail_native self` → fixed-point. (Every milestone.)

## Open questions to resolve before M5 kicks off

1. **BPE vocab size.** 4096 proposed. Larger = better fit, harder train. Smaller = easier, more surprising. Leaning 4096.
2. **Checkpoint cadence.** Every 1000 steps for M5's 10k target. Every 5000 for the 100k overnight run. Keep best-val always.
3. **Eval split.** Last 10% of corpus held out. No cross-file boundary issues because Rail source is line-oriented.
4. **Tokenizer training.** Reuse existing tokenizer (see `tokenizer.json` in `training/`) or train fresh BPE on the Rail corpus? Leaning fresh — Rail syntax has a different token distribution than English.
5. **GPU utilization measurement.** `powermetrics --samplers gpu_power` sampled at 1s cadence during training. Log to `training/rail_native/logs/gpu.log`. Correlate with step timings.

## Execution sequence — as a linear todo list

If executed in order, these are the commits that land.

1. M1 — rerun gradchecks, delete stale banners, commit. `docs: clear stale autograd/dlopen banners`
2. M2 — step sweep. Commit `rail vX.Y.Z: lm_transformer hits <2.10 loss (hyperparam tune)`
3. M3.a — write `tensor_daemond.m`. Commit `tools/metal: add Rail-native Metal daemon (no Python in the loop)`
4. M3.b — update `stdlib/tensor.rail:gpu_matmul_dispatch` to try socket first. Commit `stdlib/tensor: prefer daemon socket, fall back to binary`
5. M3.c — benchmark. Commit a `FORK_B_M3_BENCH.md` with numbers.
6. M4 — loop + plist + kill switch + dir layout. Commit `training: rail_native training loop (M4)`
7. M5 — corpus + first real run. Commit `training: first rail_native LM run (M5 — model card)`
8. M6 — decision doc, no code.

Eight commits. The last seven tell the story of Fork B shipping.
