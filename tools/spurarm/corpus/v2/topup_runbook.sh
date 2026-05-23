#!/bin/sh
# Proper 3-phase topup:
#   A) pipeline.sh SKIP_SUBSTRATE=reuse -> regenerate proc/alfred/vh + 69.8k corpus
#   B) substrate top-up (12k more via Qwen3.5-122B)
#   C) pipeline.sh SKIP_SUBSTRATE=reuse -> rebuild final corpus with 24k substrate
set -u
LOG=/tmp/spurarm_v2_pipeline/topup3.log
exec > "$LOG" 2>&1
echo "[$(date +%FT%TZ)] topup3 starting (pid=$$)"
REPO=$HOME/projects/rail-spurarm-cap-h
cd "$REPO"
export PATH=/opt/homebrew/bin:$PATH

# Phase A: regenerate proc/alfred/vh + first-pass corpus
echo "[$(date +%FT%TZ)] === PHASE A: regenerate proc+alfred+vh, first-pass corpus ==="
rm -f /tmp/spurarm_v2_pipeline/alfred_raw.jsonl /tmp/spurarm_v2_pipeline/alfred.jsonl /tmp/spurarm_v2_pipeline/vh.jsonl 2>/dev/null
cp /tmp/spurarm_v2_pipeline/substrate.run1.jsonl /tmp/spurarm_v2_pipeline/substrate.jsonl
PROC_N=35000 ALFRED_CAP=99999 SUBSTRATE_TARGET=12000 SFT_TARGET=20000 EVAL_TARGET=200 SKIP_SUBSTRATE=reuse \
  sh tools/spurarm/corpus/v2/pipeline.sh 2>&1 | tail -25
echo "[$(date +%FT%TZ)] === PHASE A done ==="
wc -l /tmp/spurarm_v2_pipeline/proc_v2.jsonl /tmp/spurarm_v2_pipeline/alfred.jsonl /tmp/spurarm_v2_pipeline/vh.jsonl

# Phase B: build new seed pool + substrate top-up
echo "[$(date +%FT%TZ)] === PHASE B: substrate top-up ==="
TMP_POOL=/tmp/spurarm_v2_pipeline/substrate_seed_pool_v2.jsonl
python3 << 'PYEOF' > "$TMP_POOL"
import random
random.seed(7777)
def pick(path, n):
    with open(path) as f: lines = f.readlines()
    return random.sample(lines, min(n, len(lines)))
out = []
out += pick('/tmp/spurarm_v2_pipeline/proc_v2.jsonl', 1300)
out += pick('/tmp/spurarm_v2_pipeline/alfred.jsonl', 500)
out += pick('/tmp/spurarm_v2_pipeline/vh.jsonl', 200)
random.shuffle(out)
import sys; sys.stdout.writelines(out)
PYEOF
echo "[$(date +%FT%TZ)] seed pool: $(wc -l < $TMP_POOL | tr -d ' ') seeds"

PART2=/tmp/spurarm_v2_pipeline/substrate.part2.jsonl
SUBSTRATE_TARGET=12000 PORT=8082 \
  MODEL=mlx-community/Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq \
  sh tools/spurarm/corpus/v2/synthesize_substrate.sh "$TMP_POOL" "$PART2" 6 2500
PART2_N=$(wc -l < "$PART2" | tr -d ' ')
echo "[$(date +%FT%TZ)] substrate part2: $PART2_N records"

# Concat parts
cat /tmp/spurarm_v2_pipeline/substrate.run1.jsonl "$PART2" > /tmp/spurarm_v2_pipeline/substrate.jsonl
COMBO=$(wc -l < /tmp/spurarm_v2_pipeline/substrate.jsonl | tr -d ' ')
echo "[$(date +%FT%TZ)] combined substrate: $COMBO records"

# Phase C: re-run pipeline to rebuild final corpus on combined substrate
echo "[$(date +%FT%TZ)] === PHASE C: rebuild final corpus ==="
rm -f /tmp/spurarm_v2_pipeline/proc_v2.jsonl /tmp/spurarm_v2_pipeline/alfred_raw.jsonl /tmp/spurarm_v2_pipeline/alfred.jsonl /tmp/spurarm_v2_pipeline/vh.jsonl 2>/dev/null
PROC_N=35000 ALFRED_CAP=99999 SUBSTRATE_TARGET=12000 SFT_TARGET=20000 EVAL_TARGET=200 SKIP_SUBSTRATE=reuse \
  sh tools/spurarm/corpus/v2/pipeline.sh 2>&1 | tail -40
echo "[$(date +%FT%TZ)] === PHASE C done; ALL PHASES COMPLETE ==="
