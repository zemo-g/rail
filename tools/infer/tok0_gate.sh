#!/usr/bin/env bash
# tok0_gate.sh — does the Rail tokenizer produce the SAME ids as the
# tokenizer the model was actually trained with?
#
# This is the only check that means anything. Round-tripping
# decode(encode(x)) == x passes even when encode and decode are wrong in
# matching ways, and a self-consistent tokenizer that disagrees with the
# training tokenizer feeds the model ids it has never seen: output becomes
# noise, and every number downstream is measuring the wrong thing while
# looking fine.
#
# So the reference is external. bpe_replica.py is the Python implementation
# the corpus pipeline used, and it is itself gated bit-identical against
# stdlib/bpe.rail. Agreement here means the chain from training bytes to
# served ids is unbroken.
#
# Exit 0 iff every id matches on every case.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
TOKDIR="${TOKDIR:-$HOME/.ledatic/base_run/artifacts/tokenizer}"
REPLICA="$HOME/projects/rail-training/attested-base/pipeline/bpe_replica.py"
pass=0; fail=0
ok(){ printf '  \033[32mok\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31mNO\033[0m  %s\n' "$1"; fail=$((fail+1)); }

[ -f "$TOKDIR/digittok.merges" ] || { echo "no merges at $TOKDIR"; exit 2; }
[ -f "$REPLICA" ] || { echo "no replica at $REPLICA"; exit 2; }

# 0. Is this the tokenizer the model was trained with?
#
# The id-agreement checks below are a DIFFERENTIAL test: Rail and the
# replica both read whatever files are in TOKDIR, so they agree happily on
# a truncated or swapped vocabulary. Found by truncating the merges file by
# 100 lines on 2026-08-28 and watching all seven cases still report ok.
# Differential tests catch implementation bugs; only a hash catches the
# wrong input. Both are needed and neither substitutes.
#
# The run recorded tokenizer.sha256 over digittok.merges alone, so the
# ALPHABET was never covered by anything. It is half the tokenizer: change
# one byte of it and every id shifts while the recorded hash stays valid.
# Pinned here.
ALPHA_SHA=7df3e715200722c1ea0418c1d1ef0788f41bd2a0d6d7583759c68dac5c425b16
if [ -f "$TOKDIR/tokenizer.sha256" ]; then
  want=$(cat "$TOKDIR/tokenizer.sha256")
  got=$(shasum -a 256 < "$TOKDIR/digittok.merges" | cut -d" " -f1)
  [ "$want" = "$got" ] && ok "merges match the run's recorded tokenizer.sha256" \
                       || no "merges do NOT match tokenizer.sha256 (wrong or altered vocabulary)"
else
  no "no tokenizer.sha256 in $TOKDIR: cannot confirm this is the trained vocabulary"
fi
got=$(shasum -a 256 < "$TOKDIR/tok_uniq.cache" | cut -d" " -f1)
[ "$ALPHA_SHA" = "$got" ] && ok "alphabet matches the pinned hash" \
                          || no "alphabet does NOT match the pinned hash (every id would shift)"

# Cases chosen for what breaks byte-level BPE: multi-byte UTF-8 that merges
# may split, digits (this vocab was digit-tuned), long runs that merge
# deeply, and empty input.
mk() { printf '%s' "$2" > "/tmp/tok0_case_$1.txt"; }
mk prose  'The refusal is the product. Not in these documents.'
mk digits 'Invoice 4471 dated 2026-08-28 totals $1,204.50 at 3.7% over 12 months.'
mk utf8   'café naïve µ-seconds 100°C em dash — and a snowman.'
mk runs   'aaaaaaaaaaaaaaaa 1234567812345678 ................ repeat repeat repeat'
mk mixed  'bpc 4.8581 vs floor 12.0546 -> ratio 0.403; "quoted", (paren), [brack]'
mk empty  ''
printf 'line one\nline two\n\nline four with trailing newline\n' > /tmp/tok0_case_lines.txt

for c in prose digits utf8 runs mixed empty lines; do
  f="/tmp/tok0_case_$c.txt"
  ./rail_native --out-prefix "/tmp/tok0_gate_$c" run tools/infer/tok0.rail \
      --text "$f" --ids-out "/tmp/tok0_rail_$c.ids" --tokdir "$TOKDIR" >/dev/null 2>&1
  if [ ! -f "/tmp/tok0_rail_$c.ids" ]; then no "$c: Rail produced no ids"; continue; fi
  py=$(TOKDIR="$TOKDIR" python3 - "$f" <<'PY'
import sys, os
sys.path.insert(0, os.path.expanduser("~/projects/rail-training/attested-base/pipeline"))
import bpe_replica as R
d = os.environ["TOKDIR"]
uniq = list(open(f"{d}/tok_uniq.cache", "rb").read())
merges = [tuple(int(x) for x in l.split()) for l in open(f"{d}/digittok.merges") if l.strip()]
print(" ".join(str(i) for i in R.encode(open(sys.argv[1], encoding="utf-8").read(), uniq, merges)))
PY
)
  rail=$(cat "/tmp/tok0_rail_$c.ids")
  if [ "$rail" = "$py" ]; then
    ok "$c: $(echo "$py" | wc -w | tr -d ' ') ids identical to the training tokenizer"
  else
    no "$c: MISMATCH"
    echo "      rail: $(echo "$rail" | cut -c1-90)"
    echo "      py  : $(echo "$py"   | cut -c1-90)"
  fi
done

echo
echo "passed: $pass   failed: $fail"
[ "$fail" = 0 ]
