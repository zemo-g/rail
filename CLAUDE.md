# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Rail Compiler

Self-hosting programming language. Compiler written in Rail, compiles itself to ARM64.

- **Compiler source**: `tools/compile.rail` (~1,900 lines)
- **Seed binary**: `rail_native` (~304K ARM64) — checked into repo, self-compile produces byte-identical output (fixed point)
- **Runtime**: C files in `runtime/` (gc.c, llm.c) linked into every compiled program
- **GC**: Conservative mark-sweep garbage collector (`runtime/gc.c`). Scans ARM64 stack frames, marks reachable tagged objects, sweeps into free list. Triggered when 1GB arena bump-alloc fails. Programs can now allocate well beyond 1GB total.
- **Allocator**: 1GB bump arena + GC free list + malloc fallback. `arena_mark`/`arena_reset` still work (clear free list on reset).
- **Tests**: `./rail_native test` — 70 tests, should be 70/70. Stable since GC + 1GB allocator.

### Key Commands

```bash
./rail_native test                    # run 70-test suite
./rail_native self                    # self-compile → /tmp/rail_self (must be byte-identical)
./rail_native run file.rail           # compile + execute
./rail_native file.rail               # compile only → /tmp/rail_out
```

### Rail Syntax Quick Reference

```rail
-- Comments start with --
add a b = a + b                       -- named function (BEFORE main)
main = let _ = print (show (add 3 4)) -- main returns int
  0

type Option = | Some x | None         -- ADT definition
getOrDefault opt = match opt           -- pattern match (NO 'with' keyword)
  | Some x -> x
  | None -> 0

fold add 0 [1,2,3,4,5]               -- fold (use named 2-arg functions, NOT nested lambdas)
map f list, filter f list             -- list ops
head xs, tail xs, length xs, reverse xs, cons x xs
range N                               -- [0..N-1]
\x -> x + 1                          -- single lambda OK
\a -> \b -> a + b                    -- nested lambdas work (flattened to multi-param)
write_file path content, read_file path
let _ = shell "command"
join sep list, split "c" str          -- split is per-character, NOT substring
show n                                -- int to string
x |> f                                -- pipe operator (f x)
```

### Known Compiler Limitations

- **`split` is single-character**: `split "abc" s` splits on `a`, `b`, and `c` individually
- **Single lambdas in filter can segfault at runtime**: `filter (\x -> x > 3) list` compiles but crashes (runtime filter dispatch bug). Workaround: use named predicate functions.
- **WASM backend**: compiles but segfaults at runtime (heap limit)
- **Exhaustiveness warnings**: Non-exhaustive `match` on ADT types emits a compiler warning (not error). Missing constructors are listed.

### What's Fixed (v1.4.0)

- **Nested lambdas**: `\a -> \b -> a + b` compiles correctly. Flattened to multi-param closures. Direct application beta-reduced.
- **Multi-capture closures**: Closures with 2+ captured variables now load all captures (up to 4).
- **GC**: Conservative mark-sweep garbage collector. Programs can allocate well beyond 1GB total. The 65K char limit and 300-line program limit are eliminated.
- **Exhaustiveness checking**: Compiler warns on non-exhaustive ADT pattern matches.

### Modifying the Compiler

After editing `tools/compile.rail`:
1. `./rail_native self` — compile with old binary
2. `cp /tmp/rail_self rail_native` — install new binary
3. `./rail_native self` — compile with new binary
4. Compare: `diff /tmp/rail_self /tmp/rail_out` — must be empty (fixed point)
5. If not identical, repeat step 2-4 until stable
6. `./rail_native test` — verify 70/70

## Flywheel (Self-Training System)

Compiler-verified self-training loop. The compiler is the oracle — generate code, compile to verify, harvest successes as training data.

### Architecture

```
self_train.rail (orchestrator)
  → LLM generates Rail code (via llm builtin → MLX server on :8080)
  → rail_native compiles it (oracle verification)
  → Passes get harvested to training/self_train/harvest.jsonl
  → 25 levels, auto-advance at 80%+ for 3 consecutive rounds
  → Falls back on 2 consecutive 0% rounds

dataset.rail (data pipeline)
  → Merges 10 JSONL sources → SHA-256 dedup → 90/5/5 split
  → Output: /tmp/rail_flywheel_data/{train,valid,test}.jsonl

train_cuda.py (CUDA trainer on Razer)
  → QLoRA on Qwen3.5-4B, BitsAndBytes 4-bit
  → Targets self_attn + DeltaNet layers (Qwen3.5 hybrid architecture)
  → device_map="auto" (NOT {"": 0} — that OOMs)

bench.rail (benchmark)
  → 30 tasks, 6 bands, output-verified where possible
  → Logged to flywheel/bench_log.txt

waterfall.rail (cross-node orchestrator)
  → Coordinates Mini (inference) + Razer (training)
```

### Flywheel Commands

```bash
./rail_native run tools/train/self_train.rail        # compile self-train binary
./tools/train/run_training.sh                         # immortal training loop (one round per process)
./rail_native run flywheel/dataset.rail prepare       # full data pipeline: dedup → merge → split
./rail_native run flywheel/bench.rail                 # 30-task benchmark
cat training/self_train/progress.txt                  # check training state
tail -20 /tmp/rail_training.log                       # recent round results
```

### MLX Server (Inference)

```bash
# Current: 4B + v5 adapter
/Users/ledaticempire/homebrew/bin/python3.11 -m mlx_lm.server \
  --model /Users/ledaticempire/models/Qwen3.5-4B-4bit \
  --adapter-path training/adapters_4b_v5_mlx \
  --host 0.0.0.0 --port 8080 --trust-remote-code --max-tokens 2048

# Watchdog (auto-restart + proactive restart every 30min):
./tools/train/mlx_watchdog.sh
```

### PEFT → MLX Adapter Conversion

PEFT adapters from Razer need conversion for MLX serving:
1. **Key prefix**: `base_model.model.model.layers.N` → `language_model.model.layers.N`
2. **Key suffix**: `.lora_A.weight` → `.lora_a`, `.lora_B.weight` → `.lora_b`
3. **Transpose**: all weight matrices need `.T`
4. **Scale**: `lora_alpha / rank` (e.g., 16/8 = 2.0)

### Adapters

| Adapter | Model | Source | Status |
|---------|-------|--------|--------|
| `training/adapters_st/` | 9B | MLX-trained on Mini | Working but 9B crashes under load |
| `training/adapters_4b_v4_mlx/` | 4B | PEFT→MLX converted | Deployed, stable |
| `training/adapters_4b_v5_mlx/` | 4B | PEFT→MLX converted (v5, more data) | Current |
| `training/adapters_4b_v5_cuda/` | 4B | Raw PEFT from Razer | For conversion |

### Training Data Sources

Merged by `dataset.rail` from `training/` and `training/self_train/`:
- `harvest.jsonl` — compiler-verified examples from self-training
- `repairs.jsonl` — compiler error → fix pairs
- `train.jsonl` — handwritten examples
- `real_programs.jsonl` — real Rail programs from the repo
- `git_harvest.jsonl` — harvested from git history
- Cloud-generated data is compiler-verified before inclusion (previous unverified cloud data was 78% poison — deleted)

### Qwen3.5-4B Hybrid Architecture

32 layers: 8 full self-attention + 24 Gated DeltaNet. LoRA must target both:
- Self-attention: `q_proj, k_proj, v_proj, o_proj` (layers 3,7,11,15,19,23,27,31)
- DeltaNet: `in_proj_qkv, in_proj_z, in_proj_b, in_proj_a, out_proj` (all other layers)
- MLP modules (`gate_proj, up_proj, down_proj`) cause PEFT to hang on 4-bit models — don't include

## Compute Fleet

| Node | Role | Access |
|------|------|--------|
| Mac Mini M4 Pro (24GB) | Inference, compilation, orchestration | local |
| Razer3070 (RTX 3070 8GB) | CUDA QLoRA training | `ssh Detro@100.109.63.37` (Tailscale) |

### Razer Operational Notes

- **Windows + Git Bash SSH** — `/F` flags get mangled, use `cmd.exe /c` or dash-style args
- **Tailscale requires user login** — after reboot, SSH won't connect until someone logs into Windows
- **GPU memory leaks on OOM** — crashed CUDA processes leak VRAM permanently on WDDM. Only fix: reboot.
- **Background processes**: `nohup ... &` can fail. Use wrapper scripts:
  ```bash
  ssh Razer 'cat > ~/script.sh << "EOF"
  #!/bin/bash
  cd ~/rail_training && python train_cuda.py ...
  EOF
  chmod +x ~/script.sh && nohup ~/script.sh &'
  ```
- **Training takes ~10h** for 3000 iters on 4B model

## Site Generation

```bash
./rail_native run tools/deploy/gen_site.rail              # regenerate ledatic.org (auto-deploys)
./rail_native run tools/deploy/gen_mission_control.rail    # mission control page
./rail_native run tools/deploy/cf_deploy.rail FILE KEY     # deploy specific file to Cloudflare KV
```
