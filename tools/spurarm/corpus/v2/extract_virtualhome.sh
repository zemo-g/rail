#!/bin/sh
# tools/spurarm/corpus/v2/extract_virtualhome.sh
#
# v2 VirtualHome extractor. Same verb-remap logic as v1 (Walk / Find /
# Run / PutIn / PutBack / PutOn / Put / Grab / PickUp -> MoveTo coord;
# everything else dropped). Spec §6 calls for "expand to broader VH
# directories" -- in practice the supplied
# programs_processed_precond_nograb_morepreconds.zip only contains
# `withoutconds/`; we walk all .txt files under the supplied dir
# recursively, which already broadens vs v1's named subset.
#
# Usage:
#   sh tools/spurarm/corpus/v2/extract_virtualhome.sh <vh_dir> <out_jsonl> [max_files]

set -u
VH_DIR="${1:?usage: extract_virtualhome.sh <vh_dir> <out_jsonl> [max]}"
OUT="${2:?usage: extract_virtualhome.sh <vh_dir> <out_jsonl> [max]}"
MAX="${3:-99999}"

if [ ! -d "$VH_DIR" ]; then
  echo "ERROR: VH dir $VH_DIR missing. Skipping VH source." >&2
  : > "$OUT"
  exit 0
fi

: > "$OUT"

# Broader walk: any .txt under VH_DIR recursively. v1 was scoped to a
# fixed `withoutconds/` subdir; this picks up `executable_programs/`,
# `initstate/`, `state_list/` if those subtrees were also extracted.
find "$VH_DIR" -type f -name "*.txt" > /tmp/spurarm_v2_vh_files.txt
TOTAL=$(wc -l < /tmp/spurarm_v2_vh_files.txt | tr -d ' ')
echo "extract_virtualhome (v2): found $TOTAL .txt files (limit=$MAX)"

head -n "$MAX" /tmp/spurarm_v2_vh_files.txt | tr '\n' '\0' | xargs -0 awk -v out="$OUT" '
BEGIN {
  fc[0] = "5,5,5";    fc[1] = "3,7,8";    fc[2] = "12,3,15";
  fc[3] = "25,5,5";   fc[4] = "15,15,15"; fc[5] = "7,12,10";
  fc[6] = "22,18,12"; fc[7] = "4,20,6";   fc[8] = "18,8,18";
  fc[9] = "6,25,9";   fc[10] = "11,2,22"; fc[11] = "27,14,4";
  fc[12] = "9,9,20";  fc[13] = "16,6,7";  fc[14] = "13,22,11";
  fc[15] = "21,4,13"; fc[16] = "8,17,16"; fc[17] = "19,11,8";
  fc[18] = "14,27,14"; fc[19] = "24,9,17";
  ncoords = 20;
  rec_id = 0;
  emitted = 0;
}

function hash_obj(name,    h, i, c) {
  h = 5381;
  for (i = 1; i <= length(name); i++) {
    c = substr(name, i, 1);
    h = ((h * 33) + index("abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-", c)) % 100000007;
  }
  return h % ncoords;
}

function flush(    n, i, script, esc_nl, esc_script, id_str) {
  if (cur_cmds_n == 0 || cur_nl == "") {
    return;
  }
  script = "script = [\n  ";
  for (i = 1; i <= cur_cmds_n; i++) {
    script = script cur_cmds[i];
    if (i < cur_cmds_n) script = script ",\n  ";
  }
  script = script "\n]";
  esc_nl = cur_nl;
  gsub(/[^[:print:]\n\r\t]/, " ", esc_nl);
  gsub(/\\/, "\\\\", esc_nl);
  gsub(/"/, "\\\"", esc_nl);
  gsub(/\t/, "\\t", esc_nl);
  esc_script = script;
  gsub(/\\/, "\\\\", esc_script);
  gsub(/"/, "\\\"", esc_script);
  gsub(/\n/, "\\n", esc_script);
  gsub(/\t/, "\\t", esc_script);
  rec_id++;
  id_str = sprintf("vh:%05d", rec_id);
  printf("{\"id\":\"%s\",\"nl\":\"%s\",\"script\":\"%s\",\"world\":{\"obx\":-1,\"oby\":0,\"obz\":0,\"present\":0},\"expected\":{\"gex\":0,\"gey\":0,\"gez\":0,\"ggrip\":0,\"gheld\":0},\"source\":\"vh\",\"stages_passed\":3}\n",
    id_str, esc_nl, esc_script) >> out;
  emitted++;
}

FNR == 1 {
  flush();
  cur_nl = "";
  cur_cmds_n = 0;
  state = "title";
}

{
  line = $0;
  sub(/[ \t\r]+$/, "", line);
  if (state == "title") {
    if (line ~ /^\[[A-Za-z]/) {
      state = "actions";
    } else if (cur_nl == "" && length(line) > 0) {
      cur_nl = line;
      next;
    } else {
      next;
    }
  }
  if (state == "actions" && line ~ /^\[[A-Za-z]/) {
    if (match(line, /^\[[A-Za-z]+\]/)) {
      verb = substr(line, RSTART + 1, RLENGTH - 2);
    } else {
      verb = "";
    }
    arg = "";
    rest = substr(line, RLENGTH + 1);
    if (match(rest, /<[^>]+>/)) {
      arg = substr(rest, RSTART + 1, RLENGTH - 2);
    }
    if (verb == "Walk" || verb == "Find" || verb == "Run" || verb == "PutIn" || verb == "PutBack" || verb == "PutOn" || verb == "Put" || verb == "Grab" || verb == "PickUp") {
      if (arg == "") next;
      idx = hash_obj(arg);
      coord = fc[idx];
      split(coord, cc, ",");
      cur_cmds_n++;
      cur_cmds[cur_cmds_n] = sprintf("MoveTo %s %s %s", cc[1], cc[2], cc[3]);
    }
  }
}

END {
  flush();
  printf("extract_virtualhome (v2): emitted=%d files=%d\n", emitted, rec_id) > "/dev/stderr";
}
'

echo "extract_virtualhome (v2) done -> $OUT"
wc -l "$OUT"
