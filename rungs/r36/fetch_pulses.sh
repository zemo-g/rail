#!/usr/bin/env bash
# RUNG 36 pulse fetch + pin. Composes rung 28's live-beacon binding into the RSI admission protocol.
#
# Pins FOUR pulse references the RSI chain consumes:
#   commit_pulse_id.txt   -- the pulse id at the moment M0 SIGNS the frozen gate (the gate is sealed
#                            HERE; the future pulse used for admission must be STRICTLY LATER)
#   m0_pulse_hex.txt      -- the pulse M0's init derives from (rung-28 not-before binding for M0)
#   future_pulse_id.txt   -- the ADMISSION pulse id (must be > commit_pulse_id): unforeseeable when
#   future_pulse_hex.txt     M0 sealed the gate -> the M1 acceptance margin + holdout cannot be gamed
#   future_pulse_id2.txt  -- the M2 admission pulse (a still-later pulse)
#   future_pulse_hex2.txt
#
# The pulse is PUBLIC READ-ONLY INPUT, not a signing surface. The whole point of rung 36's "missing
# teeth" fix: the acceptance bar is seeded from a FUTURE pulse fetched AT ADMISSION TIME, so M0 (who
# sets M1's bar and may generate M1's corpus) cannot pre-tune a self-favorable bar or overfit the
# holdout -- it did not exist when M0 committed the gate.
#
# Reproducibility: the trainer + both witnesses consume the SAME pinned pulses (the ledger header
# records every pulse hex). "Fetch live, then freeze." If offline, falls back to recorded fixtures
# (logged loudly; provenance is then the fixtures', clearly stated, never silently faked).
#
# Usage: bash rungs/r36/fetch_pulses.sh

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO" || exit 1
mkdir -p rungs/r36/out
OUT="rungs/r36/out"

PULSE_URL="https://ledatic.org/entropy/pulse"

extract() { printf '%s' "$1" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$2',''))"; }

fetch_one() { # echoes "id hex" or empty on failure
  local j
  if j=$(curl -fsS --max-time 8 "$PULSE_URL" 2>/dev/null) && [ -n "$j" ]; then
    local pid phex
    pid=$(extract "$j" pulse_id); phex=$(extract "$j" value_hex)
    if printf '%s' "$pid" | grep -Eq '^[0-9]+$' && printf '%s' "$phex" | grep -Eq '^[0-9a-f]{64}$'; then
      printf '%s %s' "$pid" "$phex"; return 0
    fi
  fi
  return 1
}

# If the live beacon is reachable, fetch a SEQUENCE of pulses (the protocol needs a commit pulse, an
# M0 pulse, and two strictly-later future pulses). A single endpoint advances ~every few seconds; we
# sample it across short waits to get a monotone id sequence. If unreachable, use recorded fixtures.
if first=$(fetch_one); then
  echo "[fetch_pulses] LIVE beacon reachable; sampling a monotone pulse sequence"
  cid=${first%% *}; chex=${first#* }
  printf '%s' "$cid"  > "$OUT/commit_pulse_id.txt"
  printf '%s' "$chex" > "$OUT/m0_pulse_hex.txt"     # M0 init pulse == commit-era pulse
  # admission pulse 1 (strictly later): re-fetch; if id hasn't advanced, derive a later id and a fresh
  # hex from the next sample. We loop briefly to guarantee future_id > commit_id.
  fid=$cid; fhex=$chex
  for _ in 1 2 3 4 5 6; do
    sleep 2
    if nxt=$(fetch_one); then nid=${nxt%% *}; nhex=${nxt#* };
      if [ "$nid" -gt "$cid" ]; then fid=$nid; fhex=$nhex; break; fi
    fi
  done
  printf '%s' "$fid"  > "$OUT/future_pulse_id.txt"
  printf '%s' "$fhex" > "$OUT/future_pulse_hex.txt"
  fid2=$fid; fhex2=$fhex
  for _ in 1 2 3 4 5 6; do
    sleep 2
    if nxt=$(fetch_one); then nid=${nxt%% *}; nhex=${nxt#* };
      if [ "$nid" -gt "$fid" ]; then fid2=$nid; fhex2=$nhex; break; fi
    fi
  done
  printf '%s' "$fid2"  > "$OUT/future_pulse_id2.txt"
  printf '%s' "$fhex2" > "$OUT/future_pulse_hex2.txt"
  echo "[fetch_pulses] pinned LIVE: commit=$cid future=$fid future2=$fid2"
else
  echo "[fetch_pulses] WARNING: live beacon unreachable/offline." >&2
  echo "[fetch_pulses] FALLING BACK to recorded fixtures (provenance = fixtures', logged)." >&2
  printf '%s' "1000" > "$OUT/commit_pulse_id.txt"
  printf '%s' "a3f1c09b2d4e5f6071829304a5b6c7d8e9f0010211223344556677889900aabb" > "$OUT/m0_pulse_hex.txt"
  printf '%s' "1042" > "$OUT/future_pulse_id.txt"
  printf '%s' "7c2e91d4b6a8035f1e9d2c4b6a80f3e5d7c9b1a3f5e7d9c1b3a5f7e9d1c3b5a7f" > "$OUT/future_pulse_hex.txt"
  printf '%s' "1088" > "$OUT/future_pulse_id2.txt"
  printf '%s' "3b5d7f9120436587a9cbed0f2143658779a9bbcddff10322546688aacce0f1234" > "$OUT/future_pulse_hex2.txt"
  echo "[fetch_pulses] pinned FIXTURE: commit=1000 future=1042 future2=1088"
fi

# invariant the protocol depends on: the admission (future) pulse MUST be strictly later than commit
CID=$(cat "$OUT/commit_pulse_id.txt"); FID=$(cat "$OUT/future_pulse_id.txt"); FID2=$(cat "$OUT/future_pulse_id2.txt")
if [ "$FID" -le "$CID" ] || [ "$FID2" -le "$FID" ]; then
  echo "[fetch_pulses] FATAL: pulse ordering broken (need commit < future < future2; got $CID < $FID < $FID2)" >&2
  exit 1
fi
echo "[fetch_pulses] ordering OK: commit=$CID < future=$FID < future2=$FID2"
