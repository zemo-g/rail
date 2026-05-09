#!/usr/bin/env bash
# tools/garmin/fuzz_harness.sh - eject-cycle parser-fuzz harness for Garmin Instinct.
#
# For each mutation file in the corpus, the harness:
#   1. Records pre-state SHA-256 of every file on the watch volume
#   2. Stages the mutation into /Volumes/GARMIN/GARMIN/NewFiles/
#   3. Prompts user to eject + wait for the watch to reboot and re-mount
#   4. Records post-state, diffs against pre-state
#   5. Pulls /Garmin/Debug/err_log.txt and diffs against pre
#   6. Categorises the cycle: ignored / rejected / crashed / stuck / exploited
#   7. Archives all artefacts to ~/garmin_recon/fuzz/cycle_<n>/
#
# Strict invariants:
#   - We never write outside NewFiles/. The watch is responsible for
#     processing or ignoring the staged file. We never modify the
#     mounted filesystem in ways the device doesn't expect.
#   - We never push a malformed GCD here - GCD-mutation is a separate
#     gated tool. This harness is FAT-data-files only.
#   - The user is in the loop on every cycle: explicit eject + reseat.
#   - 19.10 -> 19.01 backdate path stays available as the recovery if
#     anything goes sideways (but the watch should never accept
#     anything as a firmware update from this directory).
#
# Usage:
#   tools/garmin/fuzz_harness.sh                  # interactive, walk all corpus
#   tools/garmin/fuzz_harness.sh <single.fit>     # single-file mode

set -u

watch="/Volumes/GARMIN"
corpus="${HOME}/garmin_recon/fuzz/fit_corpus"
archive="${HOME}/garmin_recon/fuzz"

if [[ ! -d "$watch/GARMIN" ]]; then
  echo "ERROR: watch not mounted at $watch" >&2
  exit 1
fi
if [[ ! -d "$corpus" ]]; then
  echo "ERROR: corpus dir $corpus missing - run tools/garmin/fuzz_fit.rail first" >&2
  exit 1
fi
mkdir -p "$archive"

snapshot() {
  local out="$1"
  find "$watch/GARMIN" -type f -print0 2>/dev/null | xargs -0 shasum -a 256 > "$out" 2>/dev/null || true
}

err_log_pull() {
  # Snapshot the entire EVNTLOGS dir + Debug dir contents - that's the
  # actual oracle on this device; ERR_LOG.TXT (named in firmware strings)
  # never materialises in normal use. The active event log is a rotating
  # 0000000?.TXT under EVNTLOGS/.
  local out="$1"
  : > "$out"
  if [[ -d "$watch/GARMIN/EVNTLOGS" ]]; then
    for f in "$watch/GARMIN/EVNTLOGS"/*.TXT; do
      [[ -e "$f" ]] || continue
      echo "===== $(basename "$f") =====" >> "$out"
      cat "$f" >> "$out" 2>/dev/null
    done
  fi
  if [[ -f "$watch/GARMIN/Debug/SNS_ERR.TXT" ]]; then
    echo "===== SNS_ERR.TXT =====" >> "$out"
    cat "$watch/GARMIN/Debug/SNS_ERR.TXT" >> "$out" 2>/dev/null
  fi
}

categorise() {
  local pre="$1"; local post="$2"; local err_diff="$3"
  if ! [[ -d "$watch/GARMIN" ]]; then
    echo "stuck"
    return
  fi
  local n_diff
  n_diff=$(comm -3 <(sort "$pre") <(sort "$post") 2>/dev/null | wc -l | tr -d ' ')
  local err_size
  err_size=$(wc -c < "$err_diff" 2>/dev/null | tr -d ' ')
  if [[ "$err_size" -gt 0 ]]; then
    if [[ "$n_diff" -gt 4 ]]; then
      echo "exploited"
    else
      echo "crashed"
    fi
  elif [[ "$n_diff" -gt 0 ]]; then
    echo "rejected"
  else
    echo "ignored"
  fi
}

run_cycle() {
  local mutation_path="$1"
  local strategy
  strategy="$(basename "$mutation_path" .fit)"
  local cycle_dir
  cycle_dir="$archive/cycle_$(date +%Y%m%d_%H%M%S)_${strategy}"
  mkdir -p "$cycle_dir"
  echo "=================================================================="
  echo "  cycle: $strategy"
  echo "  archive: $cycle_dir"
  echo "------------------------------------------------------------------"
  cp "$mutation_path" "$cycle_dir/mutation.fit"
  snapshot "$cycle_dir/pre.sha256"
  err_log_pull "$cycle_dir/pre.err_log.txt"

  echo "  staging $strategy.fit -> $watch/GARMIN/NewFiles/"
  mkdir -p "$watch/GARMIN/NewFiles"
  cp "$mutation_path" "$watch/GARMIN/NewFiles/${strategy}.fit"
  sync

  echo
  echo "  --> EJECT THE WATCH NOW (e.g. 'diskutil eject $watch')"
  echo "  --> wait for the watch to reboot and re-mount"
  echo "  --> press Enter when the watch is back"
  read -r _

  if [[ ! -d "$watch/GARMIN" ]]; then
    echo "  watch did not re-mount on its own."
    echo "  --> reseat the cable; press Enter once it shows up again, or Ctrl-C to bail"
    read -r _
  fi

  snapshot "$cycle_dir/post.sha256"
  err_log_pull "$cycle_dir/post.err_log.txt"
  diff "$cycle_dir/pre.err_log.txt" "$cycle_dir/post.err_log.txt" \
       > "$cycle_dir/err_log.diff" 2>&1 || true

  local verdict
  verdict=$(categorise "$cycle_dir/pre.sha256" "$cycle_dir/post.sha256" "$cycle_dir/err_log.diff")
  echo "  verdict: $verdict"
  echo "$verdict" > "$cycle_dir/verdict"
  if [[ "$verdict" != "ignored" ]]; then
    echo "  --> $cycle_dir/err_log.diff (head):"
    head -10 "$cycle_dir/err_log.diff" | sed 's/^/    /'
  fi
  echo
}

if [[ $# -ge 1 ]]; then
  run_cycle "$1"
else
  for f in "$corpus"/*.fit; do
    [[ -e "$f" ]] || continue
    run_cycle "$f"
    echo "(continue with next mutation? Enter to proceed, Ctrl-C to stop)"
    read -r _
  done
fi

echo "all cycles done. results in $archive/"
