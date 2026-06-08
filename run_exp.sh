#!/usr/bin/env bash
# run_exp.sh EXP_ID D HIDDEN NH EPOCHS LR CORPUS ARENA_MB  -> prints one RESULT line (also to log).
# Portable 3-slot mkdir semaphore: at most 3 experiments compile+run concurrently per host.
set -u
EXP_ID="$1"; D="$2"; HIDDEN="$3"; NH="$4"; EPOCHS="$5"; LR="$6"; CORPUS="$7"; ARENA="$8"
NSLOTS=3
cd ~/rail-reward || { echo "$EXP_ID RESULT status=FAIL_CD"; exit 0; }
SLOT=""
for t in $(seq 1 900); do
  for s in $(seq 1 $NSLOTS); do mkdir "/tmp/r24slot.$s" 2>/dev/null && { SLOT=$s; break; }; done
  [ -n "$SLOT" ] && break; sleep 8
done
[ -n "$SLOT" ] && trap "rmdir /tmp/r24slot.$SLOT 2>/dev/null" EXIT
EXPDIR="rungs/r24/$EXP_ID"; rm -rf "$EXPDIR"; mkdir -p "$EXPDIR"
cp rungs/r24/r24_attested_holdout.rail "$EXPDIR/trainer.rail"
perl -0777 -pi -e "s/  let d = 8 in/  let d = $D in/; s/  let hidden = 64 in/  let hidden = $HIDDEN in/; s/  let epochs = 40 in/  let epochs = $EPOCHS in/; s/  let lr = 209715 in/  let lr = $LR in/;" "$EXPDIR/trainer.rail"
[ "$NH" != "2" ] && perl -0777 -pi -e "s/^lm10_nh = 2\$/lm10_nh = $NH/m" "$EXPDIR/trainer.rail"
[ "$CORPUS" = "big" ] && perl -0777 -pi -e 's{rungs/r24/r24_train_corpus\.txt}{rungs/r24/big_train_corpus.txt}g; s{rungs/r24/r24_overfit_corpus\.txt}{rungs/r24/big_overfit_corpus.txt}g' "$EXPDIR/trainer.rail"
perl -0777 -pi -e "s{rungs/r24/out/}{$EXPDIR/}g" "$EXPDIR/trainer.rail"
if ! ./rail_native --out-prefix "$EXPDIR/bin" "$EXPDIR/trainer.rail" > "$EXPDIR/compile.log" 2>&1; then
  echo "$EXP_ID RESULT status=COMPILE_FAIL :: $(tail -1 "$EXPDIR/compile.log")"; exit 0; fi
RAIL_ARENA_MB="$ARENA" "./$EXPDIR/bin" > "$EXPDIR/run.log" 2>&1; RC=$?
ECHO=$(grep -oE "HONEST model echo acc = [0-9]+/[0-9]+" "$EXPDIR/run.log" | tail -1 | grep -oE "[0-9]+/[0-9]+")
FULL=$(grep -oE "HONEST model full acc = [0-9]+/[0-9]+" "$EXPDIR/run.log" | tail -1 | grep -oE "[0-9]+/[0-9]+")
VERD=$(grep -E "^PASS|^FAIL" "$EXPDIR/run.log" | tail -1 | cut -c1-4)
[ -z "$ECHO" ] && { echo "$EXP_ID RESULT status=RUN_INCOMPLETE rc=$RC :: $(tail -1 "$EXPDIR/run.log")"; exit 0; }
echo "$EXP_ID RESULT status=DONE cfg[d=$D hidden=$HIDDEN nh=$NH ep=$EPOCHS lr=$LR corpus=$CORPUS] echo=$ECHO full=$FULL verdict=$VERD"
