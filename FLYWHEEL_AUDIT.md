# Flywheel Data Pipeline Audit — 25 Issues Found

This is the result of a deep audit of the Rail flywheel self-training data pipeline (2026-03-20). Every issue below has been verified by reading the source code. Use this document to fix the flywheel.

## Critical Context

The flywheel is a compiler-as-oracle self-training loop:
- LLM generates Rail code → compiler verifies → successes harvested as JSONL → shipped to Razer RTX 3070 for QLoRA training → adapter deployed back to Mini for inference → repeat
- Academic research (ICLR 2025 "Beyond Model Collapse") proves this architecture is theoretically optimal IF the data pipeline is clean
- Right now, the data pipeline has 25 bugs ranging from training on garbage data to losing a third of all examples

## File Locations

| File | Path | Lines |
|------|------|-------|
| self_train.rail | `tools/train/self_train.rail` | 889 |
| build_training_data.rail | `tools/train/build_training_data.rail` | ~250 |
| dataset.rail | `flywheel/dataset.rail` | 114 |
| waterfall.rail | `flywheel/waterfall.rail` | 274 |
| train_cuda.py | `flywheel/train_cuda.py` | 253 |
| harvest_git.py | `tools/train/harvest_git.py` | — |

## Data Inventory (current state)

| Source | Path | Entries | Quality |
|--------|------|---------|---------|
| Base training | `training/train.jsonl` | 921 | 63 programs × 15 variants — **inflated** |
| Self-train raw | `training/self_train/harvest.jsonl` | 2,520 | 94.3% good, **5.7% no-main garbage** |
| Self-train clean | `training/self_train/harvest_clean.jsonl` | 1,800 | SHA-256 deduped |
| Cloud harvest | `training/self_train/cloud_harvest.jsonl` | 580 | Not compiler-verified |
| Cloud repairs | `training/self_train/cloud_repairs.jsonl` | 112 | Unverified |
| Repairs | `training/self_train/repairs.jsonl` | 15 | Low quality — trivial rewrites |
| Synthetic repairs | `training/self_train/synthetic_repairs.jsonl` | 205 | Synthetic broken→fixed |
| Git harvest | `training/git_harvest.jsonl` | 348 | ~116 programs × 3 variants |
| Real programs | `training/real_programs.jsonl` | 40 | High quality |
| Handcrafted | `training/handcrafted_l2_l5.jsonl` | 50 | High quality |
| Session harvest | `training/self_train/session_harvest.jsonl` | ~137KB | **ORPHANED — not in any pipeline** |
| **TOTAL** | | **~6,591** | |

---

## P0 — CRITICAL (fix these first)

### Issue 1: Levels 11-25 have compile-only verification
**File**: `tools/train/self_train.rail`, lines 58-74
**Problem**: The `verify` function checks expected output for levels 1-10 but levels 11-25 have `expected=""`. Any program that compiles and prints *anything* passes. `main = let _ = print "hello"\n  0` passes a task asking to build an HTTP server.
**Evidence**: Lines 69-71: `if expected == "" then if actual != "" then "success" else "runtime_fail"`
**Impact**: Levels 11-25 harvest data is semantically unverified. The model learns that printing anything = success.
**NOTE (2026-03-20)**: Levels 6-10 seeds now have expected outputs in tab-separated format — fixed in cycles 4-6. The gap is 150 seeds (11-25), not 200.

### Issue 2: 304 no-main garbage entries across ALL sources (not just harvest)
**File**: All training JSONL files
**Problem**: 7% of entries (304 programs) across all sources lack a `main` function. The original count of 144 was harvest.jsonl only — the full count across train.jsonl, git_harvest.jsonl, cloud_harvest.jsonl etc. is 304. They passed compile-only verification because the Rail compiler accepts code without `main`.
**Fix**: Filter ALL JSONL sources for `main`, not just harvest.jsonl. 144 already purged from harvest.jsonl (2026-03-20), remaining 160 in other sources.
**NOTE (2026-03-20)**: harvest.jsonl cleaned (144 removed, 2521 remain). Still need to clean: train.jsonl, git_harvest.jsonl, cloud_harvest.jsonl, session_harvest.jsonl.

### Issue 11: `dataset.rail` merge missing 5+ data sources
**File**: `flywheel/dataset.rail`, lines 52-56
**Problem**: `run_merge` only merges 3 sources: `base_train + git_harvest + clean_harvest`. Missing: `repairs.jsonl`, `cloud_harvest.jsonl`, `cloud_repairs.jsonl`, `synthetic_repairs.jsonl`, `real_programs.jsonl`, `handcrafted_l2_l5.jsonl`, `session_harvest.jsonl`. That's ~1,002 entries excluded — nearly a third of all data.
**Fix**: Add all sources to the merge list on line 54.

### Issue 17: max_seq_length=256 is catastrophically short
**File**: `flywheel/train_cuda.py`, line 26 (default) and Razer command line
**Problem**: Rail programs are routinely 100-500+ lines. At 256 tokens, the model only sees the first ~50-80 lines of code, learning that programs just stop mid-function. The 9 tool-file entries from `build_training_data.rail` (gen_site.rail etc.) are brutally truncated. The waterfall orchestrator uses 1024 (line 159 of waterfall.rail) but manual Razer runs use 256.
**Fix**: Default to 512 minimum. Use 1024 for all Razer runs. Filter out examples that would be >80% truncated.

### Issue 22: waterfall merge uses non-deterministic hash()
**File**: `flywheel/waterfall.rail`, line 52
**Problem**: The inline Python dedup uses `h=hash(l)` — Python's built-in hash is randomized since Python 3.3 (PYTHONHASHSEED). Two identical lines can hash differently between runs. Dedup is unreliable.
**Fix**: Replace `hash(l)` with `hashlib.sha256(l.encode()).hexdigest()`.

### Issue 23: waterfall merge references nonexistent path
**File**: `flywheel/waterfall.rail`, line 52
**Problem**: Reads from `/tmp/rail_train_clean/train.jsonl` which doesn't exist in any pipeline. The actual base data is at `training/train.jsonl`. This means `merge_data` silently produces partial data.
**Fix**: Change path to `training/train.jsonl`.

### Issue 24: waterfall only merges 2 of 9+ data sources
**File**: `flywheel/waterfall.rail`, line 52
**Problem**: Same as Issue 11 but in the orchestrator that pushes data to the Razer. The Razer has been training on incomplete data.
**Fix**: Align waterfall's merge with the full source list from Issue 11.

### Issue 26: post_train.sh references wrong adapter path + Linux-only stat
**File**: `tools/train/post_train.sh`, lines 27 and 33
**Problem**: Line 27 references `adapters_4b_v2` which doesn't exist — should be `adapters_4b_clean` (or whatever the Razer is actually using). Line 33 uses `stat -c` which is Linux syntax and doesn't work on the Windows Razer (needs `stat` or PowerShell equivalent).
**Fix**: Update adapter path to match Razer's actual output. Replace `stat -c` with a cross-platform check.

### Issue 27: Benchmark (bench.rail) has no output verification
**File**: `flywheel/bench.rail`
**Problem**: The verify function in bench.rail only checks compile + exit code 0, never checks stdout against expected output. Benchmark scores are inflated — a program that compiles and exits 0 scores as "pass" even if it prints garbage. This means curriculum advancement decisions are based on unreliable data.
**Fix**: Add expected outputs to benchmark tasks (same tab-separated format as self_train seeds). Use the same verify-with-expected pattern.

### Issue 28: train_cuda.py missing encoding='utf-8' on file open
**File**: `flywheel/train_cuda.py`, line 82
**Problem**: File open without explicit encoding. Fixed on Razer already, but the local copy at `flywheel/train_cuda.py` still has the bug. Will crash on any training data containing non-ASCII characters.
**Fix**: Add `encoding='utf-8'` to the open() call on line 82.

### Issue 29: 420 trivial examples (9%) — ≤2 lines of actual code
**Problem**: 420 entries across all sources contain programs with 2 or fewer lines of actual code (excluding comments/blanks). These teach the model that tiny programs are acceptable answers to complex tasks.
**Fix**: Filter based on **line count** not character count. The min-length filter in Phase 3.2 should count non-blank, non-comment lines. Threshold: level 1-2 = 2+ lines, level 3-5 = 4+ lines, level 6+ = 6+ lines.

### Issue 30: 6 different system prompts in the data
**Problem**: Training data contains 6 different system prompt personas across sources. The model sees inconsistent instructions about who it is and what it should do.
**Fix**: Standardize to 2 system prompts: one for code generation ("You are a Rail language expert...write correct Rail code"), one for repair ("You are a Rail debugging expert...fix the broken code"). Run a pass across all JSONL to normalize.

---

## P1 — IMPORTANT (fix after P0s)

### Issue 9: No code-length-to-task-complexity check
**File**: `tools/train/self_train.rail`, `harvest` function at line 584
**Problem**: `harvest()` accepts any code that passes verification regardless of length. A 3-line program that hardcodes the expected output passes a level-5 "implement quicksort" task.
**Fix**: Add minimum code length thresholds per level: level 1-2 = 20 chars, level 3-5 = 50 chars, level 6+ = 100 chars.

### Issue 13: 15:1 variant inflation is pure waste with prompt masking
**File**: `tools/train/build_training_data.rail`, `write_variants` at line 31
**Problem**: 63 test cases × 15 prompt phrasings = 945 entries, but with prompt masking enabled (which `train_cuda.py` uses by default), loss is only computed on assistant tokens — which are identical across all 15 variants. The model trains on the same gradient 15× per epoch.
**Fix**: Reduce to 1-3 variants. With prompt masking, variant inflation has zero benefit and wastes training compute.

### Issue 14: Grammar/reference entries are natural language, not code
**File**: `tools/train/build_training_data.rail`, lines 123-134
**Problem**: 12 entries where assistant response is English text explaining Rail syntax, not Rail code. These poison a code-generation model's output distribution.
**Fix**: Either remove them or convert to code examples that demonstrate each concept.

### Issue 16: Tool file entries are truncated at max_seq_length
**File**: `tools/train/build_training_data.rail`, lines 214-236
**Problem**: 9 entries embedding entire tool source files (hundreds of lines each). At max_seq_length=256, the model sees only the first ~100 lines. Learns that programs end abruptly.
**Fix**: Either increase max_seq_length to 2048+ or exclude these entries (or split them into smaller logical chunks).

### Issue 18: Only 8 of 32 layers get LoRA adapters
**File**: `flywheel/train_cuda.py`, `apply_lora` at line 57
**Problem**: Despite `--num-layers 16`, only 8 attention layers were found by the module name filter. The `layers_to_transform` in the saved config is `[3,7,11,15,19,23,27,31]`. Research suggests 50-75% of layers for code tasks.
**Fix**: Debug the layer selection logic. Likely need to adjust the `self_attn` filter or increase coverage.

### Issue 19: No validation loss tracking
**File**: `flywheel/train_cuda.py`
**Problem**: No eval loop exists. Training loss only. With 268 repair examples and 1000 iters, overfitting is near-certain. Loss went from 2.29→0.79 in 500 iters — suspiciously fast.
**Fix**: Add periodic eval on valid.jsonl every N steps. Log validation loss. Implement early stopping if val_loss increases for K consecutive evals.

### Issue 21: Batch=1 + grad_ckpt + 4bit still OOMs on 8GB VRAM
**File**: Razer training environment
**Problem**: The repair training run OOM'd at iter ~1000 of 4000. Only the 1000-iter checkpoint was saved. The Razer has 8GB VRAM — already at minimum viable config.
**Fix**: Reduce max_seq_length to 128 for the repair adapter (repair examples are short). Or use gradient accumulation with smaller effective batch.

---

## P2 — NICE TO HAVE

### Issue 3: Massive variant inflation in git harvest (3:1)
**File**: `tools/train/harvest_git.py`
**Problem**: 116 real programs × 3 prompt phrasings = 348 entries. Same waste as Issue 13.

### Issue 4: Repair data is low quality
**File**: `training/self_train/repairs.jsonl` (15 entries)
**Problem**: "Fixes" are complete rewrites, not diagnosis+repair. Model learns to throw away broken code and write something trivially simple.

### Issue 5: Weak inline dedup uses first 80 chars only
**File**: `tools/train/self_train.rail`, `harvest` at line 586
**Problem**: `take_str code 80` as fingerprint. False positives and false negatives.

### Issue 6: Round counter never increments (bug)
**File**: `tools/train/self_train.rail`
**Problem**: Progress always shows `round=1`. The shell wrapper doesn't increment between restarts. Makes log analysis useless.

### Issue 7: No cross-source dedup at ingest time
**Problem**: Overlap between sources only resolved by manual `dataset.rail merge`.

### Issue 8: Exit code check is dead code in verify
**File**: `tools/train/self_train.rail`, line 68
**Problem**: `let exit_check = trim (shell "echo $?")` captures the exit code of `echo`, not the binary. Never used. Programs that segfault with partial stdout are marked "success".

### Issue 10: Stretch tasks pollute curriculum pass rate
**File**: `tools/train/self_train.rail`, lines 798-806
**Problem**: 2 stretch tasks from level+1 mixed in, but their pass/fail counts toward current level's rate.

### Issue 12: build_training_data.rail hardcodes split sizes
**File**: `tools/train/build_training_data.rail`, lines 245-247
**Problem**: Split at line 936/50/rest instead of computing from actual count.

### Issue 15: Error/fix entries have comment prefixes in code
**File**: `tools/train/build_training_data.rail`, lines 139-157
**Problem**: Assistant responses start with `-- Error: ...` comments. Trains model to emit comments before code.

### Issue 20: LR inconsistency between training runs
**Problem**: Repair run uses 1e-5, code gen uses 2e-5. No documented justification.

### Issue 25: Cycle command hardcodes single training objective
**File**: `flywheel/waterfall.rail`, line 215
**Problem**: Always trains 4B for 2000 iters. No support for repair adapter or switching objectives.
