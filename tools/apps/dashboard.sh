#!/bin/bash
cd ~/projects/rail
PORT=9090
DIR=training/self_train
touch $DIR/{progress,log,config,goals}.txt $DIR/harvest.jsonl

./rail_native tools/train/train_dashboard.rail 2>/dev/null && cp /tmp/rail_out /tmp/rail_dash_bin
echo "Rail Self-Training Dashboard → http://localhost:$PORT"
open "http://localhost:$PORT" 2>/dev/null &

while true; do
  /tmp/rail_dash_bin 2>/dev/null

  REQ=$(
    { printf "HTTP/1.1 200 OK\nContent-Type: text/html\nConnection: close\n\n"
      cat $DIR/dashboard.html
    } | nc -l $PORT 2>/dev/null
  )

  URL=$(echo "$REQ" | head -1 | cut -d' ' -f2)

  # Debounce: only act on recognized actions, ignore favicon etc
  case "$URL" in
    *"?start"*)
      if ! pgrep -f self_train > /dev/null 2>&1; then
        nohup ./rail_native run tools/train/self_train.rail > $DIR/stdout.log 2>&1 &
        echo "  ▶ Started (PID $!)"
      else
        echo "  ▶ Already running"
      fi ;;
    *"?stop"*)
      pkill -f self_train 2>/dev/null; pkill -f rail_st 2>/dev/null
      echo "  ■ Stopped" ;;
    *"?savegoals="*)
      # Extract and decode goals from URL
      ENCODED=$(echo "$URL" | sed 's/.*?savegoals=//')
      /usr/bin/python3 -c "import urllib.parse,sys;print(urllib.parse.unquote_plus('$ENCODED'),end='')" > $DIR/goals.txt 2>/dev/null
      echo "  ✓ Goals saved" ;;
  esac
done
