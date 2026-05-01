# Session handoff — 2026-04-29 (continued: all-three P0 attempt)

**Headline:** Tackled all three P0 candidates from morning's handoff (fp16 hypothesis, distill harvest, compile-loss). Two are blocked on external state (mini-reference dylib turned out to be f64-only; teacher 27B is offline). Third (compile-loss scaffolding) shipped and ran a real measurement — confirming the compile-zero wall holds at scale (0/50 against v0.7 BEST). Net: actionable scaffolding + sharp clarity on the unblock path.

## Track 1 — fp16 hypothesis (P0a from morning handoff)

**Goal:** restore old (~Apr 22) dylib state and re-bench to test if fp16 was the historical 13/30 lever.

**Finding (blocking):** `tools/metal/libtensor_gpu.dylib.mini-reference` (Apr 27 10:16, the only on-disk backup) is **f64-only** — no `tgl_*_half_host` symbols at all. So the historical fp16 lever isn't recoverable from binary backups. The current dylib HAS the fp16 path but a sequential-call bug. Inspected matmul_f16 kernel at `tools/metal/tensor_gpu.metal:678` — bounds checks are correct. Sequential bug is in op-sequence interaction (likely buffer-pool reuse in `tgl_*_half_host` wrappers, but not obvious from code review).

**Status:** Deferred. Real test requires systematic per-op isolation in the C dylib, which is a multi-hour debug session. Not on critical path while CPU substrate works.

## Track 2 — distill harvest (P0b)

**Goal:** push from 47 → 500+ programs via teacher distillation.

**Finding (blocking):** Studio's Claude-distilled Qwen-27B at `10.42.0.2:8080` is **OFFLINE** (connection refused). Only `10.42.0.2:8081` (35B thinking-mode model) is up. Tested 35B at max_tokens=3000 with `enable_thinking=False` and `/no_think` directive — burned all 3000 tokens on reasoning, content empty (10507 chars in `reasoning` field). Server doesn't honor the disable flag.

**Status:** Blocked on user restarting Claude-distilled 27B at port 8080.

## Track 3 — compile-loss-during-training (P0c) — **SHIPPED**

**What's on disk:**
- `tools/train/rollout_harvest.sh` — sidecar harvester. Spawns 5 prompts × N seeds in parallel via `/tmp/rail_infer_cpu`, compiles each, appends survivors to corpus. Always exit 0; output line is `harvest: pass=X/Y appended_bytes=Z corpus=PATH wall=Ns`. Trainer-friendly.
- `docs/plans/COMPILE_LOSS_DESIGN.md` — concrete integration plan. Online RFT design (positive-only training on model's own compilable rollouts), corpus-doubling-buffer (B2) approach for in-place corpus growth, failure-mode mitigations (dedup, mode-collapse caps).

**Empirical validation (measured this session):**
```
$ tools/train/rollout_harvest.sh
harvest: pass=0/50 appended_bytes=0 corpus=training/corpus_self_distill.txt wall=1020s
```
v0.7 BEST at N=50 rollouts (5 prompts × 10 seeds), max=64, k=10, temp=0.8, no_ws=16. Wall 17 min under load avg ~56.

**Implication:** Sidecar is correct (end-to-end execution clean). But online RFT requires non-zero base compile rate to bootstrap. With 0/50, the corpus doesn't grow on first invocation, and v0.8 with compile-loss enabled would just train as v0.7 redux.

**Unblock paths (any one of):**
1. Restore fp16 dylib (track 1) — if fp16 sharpening is real, base rate becomes non-zero
2. Seed `corpus_self_distill.txt` from teacher harvest (track 2) — external positives bootstrap the loop
3. Weaken compile criterion to parse-pass or syntax-pass — cheaper, lower-quality signal but non-zero rate

## Standings (unchanged from morning)

v0.7 BEST (`spur_v07_d384_best`) remains the strongest by mini-bench shape (5/5). Compile rate at single-sample is now empirically validated at 0/50 across the bench-band prompts.

## Pickup playbook

```bash
cd ~/projects/rail
ls tools/metal/.no_gpu              # exists
ls /tmp/rail_infer_cpu              # exists
ls tools/train/rollout_harvest.sh   # NEW — chmod +x'd

# Test the sidecar against any ckpt:
CKPT=spur_v07_d384_best N_SEEDS=10 MAX=64 \
  OUT_CORPUS=training/corpus_self_distill.txt \
  tools/train/rollout_harvest.sh
# expect "harvest: pass=0/50 ..." until the wall breaks.

# Quick check: is the teacher back up?
curl -s -m 5 http://10.42.0.2:8080/v1/models | head
```

## Next-session decision

Path (3) — weaken to parse-pass — was attempted this session and **falsified**. Parse-pass gives 5/5 but the model emits `main = <random_letters>` which Rail's parser accepts as identifier expressions. Link fails, and training on these positives would teach the model to emit MORE garbage identifiers. Structured-pass (parse + Rail keyword in continuation) gave 0/5 because continuations are pure char-level noise (`nb-eolnb`, `adpldlid`). The wall is at the character distribution, not at the criterion. Sidecar retains MODE=parse and MODE=structured for future, but MODE=compile is the only meaningful criterion.

Pick ONE of (path 3 removed):
1. **Restart teacher + run harvest** (~3 hr): unblocks track 2, gives external positives to seed corpus, then v0.8 compile-loss has fuel.
2. **Debug fp16 dylib sequential bug** (4-8 hr): unblocks track 1 + the bench fast-path. Highest-EV if the fp16 sharpening hypothesis is real.

(1) is moderate cost, well-understood. (2) is biggest payoff but biggest unknown.

## Memory written this session

- `compile_loss_scaffolding.md` (NEW) — sidecar shipped + empirical 0/50 finding + unblock paths
- `MEMORY.md` (updated) — pointer added

## What NOT to do

- Don't fork v0.8 with compile-loss enabled until base compile rate > 0. The training will silently reduce to v0.7 baseline.
- Don't trust `libtensor_gpu.dylib.mini-reference` as a "working fp16 path" — it's f64-only.
- Don't burn time on the 35B at port 8081 as a teacher — it can't be coerced out of thinking mode.
