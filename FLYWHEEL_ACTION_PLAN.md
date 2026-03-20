# Flywheel Action Plan — Fix the Data Pipeline

You are fixing the Rail flywheel self-training data pipeline. Read `FLYWHEEL_AUDIT.md` first for full context on every issue. This document tells you exactly what to do, in order.

All work is in `~/projects/rail/`. The compiler binary is `./rail_native`. Test suite: `./rail_native test` (must stay 67/67). Self-compile: `./rail_native self`.

**IMPORTANT**: Rail uses a bump allocator with no GC. Large string operations can segfault. Use incremental file writes (write to temp file, shell cat >> target). The `split` builtin is single-char only — for multi-char patterns use `perl -i -pe` or `sed`.

**PRIORITY (2026-03-20)**: Start with Phase 1 (clean the data) and Phase 2 (fix merge pipelines). **Skip Phases 3-5 for now** — the Razer is already training on clean data pushed manually. Focus effort on getting the data pipeline right so the next training cycle uses clean, merged, deduplicated data.

---

## Phase 1: Fix the Data (no code changes needed)

### 1.1 Clean ALL JSONL sources — remove no-main garbage
**harvest.jsonl DONE** (2026-03-20): 144 entries removed, 2521 remain. Backup at harvest.jsonl.bak.
**real_programs.jsonl DONE** (2026-03-20): 6 broken entries removed (3 code + 3 explain), 34 remain.

**Still need to clean** (304 total no-main across all sources, 144 already done = 160 remaining):
```bash
cd ~/projects/rail
for f in training/train.jsonl training/git_harvest.jsonl training/self_train/cloud_harvest.jsonl training/self_train/session_harvest.jsonl training/self_train/synthetic_repairs.jsonl; do
  [ -f "$f" ] || continue
  cp "$f" "${f}.pre_clean_$(date +%s)"
  python3 -c "
import json, sys
kept, removed = 0, 0
with open('$f') as fh: lines = fh.readlines()
with open('$f', 'w') as fh:
    for line in lines:
        line = line.strip()
        if not line: continue
        try:
            obj = json.loads(line)
            code = ''
            for m in obj.get('messages', []):
                if m.get('role') == 'assistant': code = m.get('content', '')
            if 'main' not in code or len(code) < 20:
                removed += 1; continue
            fh.write(line + '\n'); kept += 1
        except: pass
print(f'$f: kept {kept}, removed {removed}')
"
done
```

### 1.1b Filter trivial examples (≤2 lines of code)
420 examples (9%) have 2 or fewer actual lines of code. Filter by **line count**, not character count:
```bash
python3 -c "
import json
for fname in ['training/train.jsonl', 'training/self_train/harvest.jsonl', 'training/git_harvest.jsonl']:
    # Count non-blank, non-comment lines per entry
    entries = [json.loads(l) for l in open(fname)]
    trivial = sum(1 for e in entries
        for code in [[m['content'] for m in e['messages'] if m['role']=='assistant'][0]]
        if len([l for l in code.split(chr(10)) if l.strip() and not l.strip().startswith('--')]) <= 2)
    print(f'{fname}: {trivial} trivial of {len(entries)}')
"
```

### 1.1c Standardize system prompts to 2
6 different system prompts in the data. Normalize to:
- Code gen: `You are a Rail language expert. Rail is a pure functional language that compiles to native ARM64 and Metal GPU shaders. Write correct Rail code.`
- Repair: `You are a Rail debugging expert. Fix the broken Rail code below. Output only the corrected code.`

### 1.2 Deduplicate properly
```bash
cd ~/projects/rail && ./rail_native run flywheel/dataset.rail dedup
```
Verify: `wc -l training/self_train/harvest_clean.jsonl` should be < 2520.

### 1.3 Run the full merge (after fixing dataset.rail in Phase 2)
After Phase 2.1 is done:
```bash
cd ~/projects/rail && ./rail_native run flywheel/dataset.rail prepare
```

---

## Phase 2: Fix the Merge Pipelines (P0 code fixes)

### 2.1 Fix `flywheel/dataset.rail` — add all sources to merge

In `run_merge` (around line 52), change the source list in the Python inline from:
```
['training/train.jsonl', 'training/git_harvest.jsonl', 'training/self_train/harvest_clean.jsonl']
```
to:
```
['training/train.jsonl', 'training/git_harvest.jsonl', 'training/self_train/harvest_clean.jsonl', 'training/real_programs.jsonl', 'training/self_train/repairs.jsonl', 'training/self_train/cloud_harvest.jsonl', 'training/self_train/cloud_repairs.jsonl', 'training/self_train/synthetic_repairs.jsonl', 'training/handcrafted_l2_l5.jsonl', 'training/self_train/session_harvest.jsonl']
```
Each source is wrapped in try/except already, so missing files are safe.

### 2.2 Fix `flywheel/waterfall.rail` — 3 bugs in merge_data

In `merge_data` (line 52), fix the inline Python:

1. **Replace `hash(l)` with `hashlib.sha256(l.encode()).hexdigest()`** — add `import hashlib` to the imports
2. **Replace `/tmp/rail_train_clean/train.jsonl`** with `training/train.jsonl`
3. **Add all sources** — same list as 2.1. Change the `cat` command to include all JSONL files:
```
cat training/train.jsonl training/git_harvest.jsonl training/self_train/harvest_clean.jsonl training/real_programs.jsonl training/self_train/repairs.jsonl training/self_train/cloud_harvest.jsonl training/self_train/cloud_repairs.jsonl training/self_train/synthetic_repairs.jsonl training/handcrafted_l2_l5.jsonl training/self_train/session_harvest.jsonl 2>/dev/null
```

### 2.3 Fix `flywheel/train_cuda.py` — change default max_seq_length + encoding fix

Line 26: change `default=256` to `default=512`.
**Line 82**: Add `encoding='utf-8'` to the file open. Already fixed on Razer, local copy still has the bug.

Also add a validation eval loop. After the training loop in `train()`, add periodic eval every `report_every` steps on `valid.jsonl`. Log both train and val loss. Print a warning if val_loss > train_loss * 1.5 (overfitting signal).

### 2.4 Fix `tools/train/post_train.sh` — wrong adapter path + Linux stat

**Line 27**: References `adapters_4b_v2` which doesn't exist. Change to `adapters_4b_clean` (or whatever the Razer is currently outputting to).
**Line 33**: Uses `stat -c` which is Linux-only syntax. The Razer runs Windows — replace with a cross-platform check or use PowerShell equivalent.

### 2.5 Fix `flywheel/bench.rail` — add output verification

The benchmark verify function only checks compile + exit code 0, never checks stdout. Benchmark scores are inflated. Add expected outputs to benchmark tasks using the same tab-separated format as self_train seeds. Use the verify-with-expected pattern from self_train.rail.

---

## Phase 3: Fix the Self-Training Loop

### 3.1 Add output verification for levels 6-10 — DONE (2026-03-20)

**COMPLETED**: All 100 seeds across levels 1-10 now have deterministic expected outputs in tab-separated format. Levels 6-10 were added in cycles 4-6. Each seed is `"N\ttask\texpected_output"` and verify() checks stdout.

**NOTE**: self_train.rail must stay ≤65K chars or the compiler silently miscompiles (bump allocator overflow). Originally had 15 seeds/level which pushed to 72K and produced a broken binary. Trimmed to 10 seeds/level (65K) — compiles clean.

**Remaining gap**: Levels 11-25 still compile-only (150 seeds). For tasks at these levels where exact output is hard to predict, use a two-phase approach:
1. First, have the LLM generate the program + an assertion: "Write a Rail program that does X. The program MUST print 'OK' as its last line if successful."
2. Then verify that stdout ends with "OK".

### 3.2 Add minimum code **line count** filter to harvest

In `tools/train/self_train.rail`, modify the `harvest` function (line 584). Filter on **line count** not character count — 420 trivial programs (9%) have ≤2 actual lines. Before the dedup check, add:
```
let lines = split "\n" code
let real_lines = filter (\l -> length l > 0) lines
let line_count = length real_lines
let min_lines = if level <= 2 then 2 else if level <= 5 then 4 else 6
if line_count < min_lines then
  let _ = print "    (too short — skipped)"
  0
else
```
This prevents trivial `main = let _ = print "expected"\n  0` programs from being harvested at higher levels.

### 3.3 Fix the round counter bug

In `tools/train/self_train.rail`, the `round` variable is loaded from progress.txt but never incremented before writing back. In the `run_loop` function, before the final `write_progress` call (around line 860), change:
```
let _ = write_progress round level harvested since_retrain consecutive_pass consecutive_zero
```
to:
```
let _ = write_progress (round + 1) level harvested since_retrain consecutive_pass consecutive_zero
```

### 3.4 Fix inline dedup — use full code hash, not first 80 chars

In `tools/train/self_train.rail`, `harvest` function (line 586). Replace the 80-char fingerprint with a shell-computed SHA-256:
```
let fingerprint = trim (shell (cat ["echo ", q, json_esc code, q, " | shasum -a 256 | cut -d' ' -f1"]))
let already = trim (shell (cat ["grep -cF ", q, fingerprint, q, " ", harvest_file, " 2>/dev/null || echo 0"]))
```
Note: this approach has its own escaping risks with large code. An alternative is to write code to a temp file and hash that:
```
let _ = write_file "/tmp/rail_st_dedup.txt" code
let fingerprint = trim (shell "shasum -a 256 /tmp/rail_st_dedup.txt | cut -d' ' -f1")
```

### 3.5 Fix stretch task scoring

In `tools/train/self_train.rail`, around line 800, separate stretch task results from the main batch. Don't count stretch pass/fail toward the curriculum advancement counters. Harvest stretch successes but don't let them affect `consecutive_pass` or `consecutive_zero`.

### 3.6 Fix exit code check in verify

In `tools/train/self_train.rail`, line 66-68. The current code runs the binary and captures stdout, but never checks if the process crashed. Replace:
```
let run_out = shell "perl -e 'alarm 5; exec @ARGV' /tmp/rail_st_test_bin 2>&1"
let actual = trim run_out
let exit_check = trim (shell "echo $?")
```
with:
```
let run_out = shell "perl -e 'alarm 5; exec @ARGV' /tmp/rail_st_test_bin > /tmp/rail_st_run_out.txt 2>&1; echo $? > /tmp/rail_st_exit.txt"
let actual = trim (shell "cat /tmp/rail_st_run_out.txt")
let exit_code = trim (shell "cat /tmp/rail_st_exit.txt")
```
Then check `if exit_code != "0" then "runtime_fail"` before checking output.

---

## Phase 4: Fix the Training Config

### 4.1 Reduce base data inflation from 15x to 3x

In `tools/train/build_training_data.rail`, replace the `write_variants` function. Instead of 15 prompt phrasings, use 3:
```
write_variants file name src exp =
  let _ = write_entry file (entry sys (cat ["Write a Rail program that outputs ", exp]) src)
  let _ = write_entry file (entry sys (cat ["Implement ", name, " in Rail"]) src)
  let _ = write_entry file (entry sys (cat ["Rail program: ", name, " (expected: ", exp, ")"]) src)
  3
```
Then regenerate: `./rail_native run tools/train/build_training_data.rail`

Update the hardcoded split sizes (lines 245-247) to compute from actual line count:
```
let total = trim (shell "wc -l < /tmp/rail_training_all.jsonl")
let n = parse_digits total
let train_n = n * 9 / 10
let valid_n = n / 20
```

### 4.2 Remove NL reference entries or convert to code

In `tools/train/build_training_data.rail`, lines 123-134: either remove the 12 grammar/reference entries (they teach the model to output English, not code) or convert each one to a code example. For instance:
- "What is Rail's syntax for functions?" → show a code example with multiple functions
- "What types does Rail support?" → show a code example using each type

### 4.3 Remove comment prefixes from error/fix entries

In `tools/train/build_training_data.rail`, lines 139-157: remove the `-- Error: ...` comment lines from the assistant responses. The fix code should be pure code, matching what the model is expected to produce in the self-training loop.

### 4.4 Increase Razer training seq length

When launching Razer training from waterfall.rail (line 159), ensure `--max-seq-length 512` minimum. For the repair adapter (short examples), 256 is fine. For code gen, use 1024.

### 4.5 Fix LoRA layer coverage

In `flywheel/train_cuda.py`, line 59: the layer filter `"self_attn" in n` may not be matching all attention layers in Qwen3.5-4B. Debug by printing `all_layers` and `layer_indices`. If only 8 layers are found despite 32 transformer blocks, the module naming convention may differ. Fix the filter to match the actual module names.

---

## Phase 5: Verify Everything

After all changes:

1. **Compiler tests**: `./rail_native test` → must be 67/67
2. **Self-compile**: `./rail_native self` → must reach fixed point
3. **Regenerate base data**: `./rail_native run tools/train/build_training_data.rail`
4. **Run full data pipeline**: `./rail_native run flywheel/dataset.rail prepare`
5. **Check stats**: `./rail_native run flywheel/dataset.rail stats`
6. **Verify merged data**: `wc -l /tmp/rail_flywheel_merged.jsonl` — should be significantly more than current (was merging ~3700, should be ~4500+)
7. **Push to Razer**: `./rail_native run flywheel/waterfall.rail sync`
8. **Start training**: `./rail_native run flywheel/waterfall.rail razer`

---

## What NOT to Change

- Do NOT modify `tools/compile.rail` (the compiler itself)
- Do NOT modify `rail_native` (the seed binary)
- Do NOT delete any `.jsonl` files — always backup first with `.pre_clean_$(date +%s)` suffix
- Do NOT change the 25-level curriculum structure — it's well-designed
- Do NOT remove prompt masking from train_cuda.py — it's the single biggest quality improvement
- Do NOT increase batch_size on Razer above 1 — it will OOM (8GB VRAM)
