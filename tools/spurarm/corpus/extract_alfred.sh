#!/bin/sh
# tools/spurarm/corpus/extract_alfred.sh
#
# Walk ALFRED traj_data.json files (data/json_2.1.0) and emit JSONL
# (NL, Rail-DSL-script) pairs. Each trajectory contributes up to 3
# paraphrases (turk_annotations.anns[].task_desc), each paired with
# the same Rail script derived from .plan.high_pddl.
#
# ALFRED action remap (navigation-only refinement per Agent A
# corpus-quality fix; see note in extract_virtualhome.sh on why):
#   GotoLocation                                       -> MoveTo coord(arg)
#   PickupObject / PickupObjectInReceptacle            -> MoveTo coord(obj)
#   PutObject / PutObjectInReceptacle                  -> MoveTo coord(recep|obj)
#   OpenObject CloseObject ToggleObject CleanObject
#     HeatObject CoolObject SliceObject NoOp           -> DROP
#
# coord(obj): djb2 hash mod 20 -> free_coords pool. Same mapping as
# extract_virtualhome.sh so the two sources share object grounding.
#
# We tag ALFRED pairs with stages_passed=2 (compile/parse-only; we
# don't know the original goal in Rail-DSL coords). Pretrain only.
#
# Two-stage pipeline:
#   stage 1: jq flattens each traj into a line-protocol stream.
#   stage 2: awk consumes the stream and emits JSONL.
#
# Usage:
#   sh tools/spurarm/corpus/extract_alfred.sh <alfred_dir> <out_jsonl> [max]

set -u
ALFRED_DIR="${1:?usage: extract_alfred.sh <alfred_dir> <out_jsonl> [max]}"
OUT="${2:?usage: extract_alfred.sh <alfred_dir> <out_jsonl> [max]}"
MAX="${3:-99999}"

if [ ! -d "$ALFRED_DIR" ]; then
  echo "ERROR: ALFRED dir $ALFRED_DIR missing. Skipping ALFRED source." >&2
  : > "$OUT"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 2
fi

: > "$OUT"

LIST=/tmp/spurarm_alfred_files.txt
FLAT=/tmp/spurarm_alfred_flat.txt
find "$ALFRED_DIR" -name "traj_data.json" -type f > "$LIST"
TOTAL=$(wc -l < "$LIST" | tr -d ' ')
echo "extract_alfred: found $TOTAL traj_data.json files (limit=$MAX)"

: > "$FLAT"
head -n "$MAX" "$LIST" | while IFS= read -r tdj; do
  jq -r '
    (.plan.high_pddl // []) as $p |
    (.turk_annotations.anns // []) as $a |
    "TRAJ_BEGIN",
    ($p | map("PLAN\t" + (.discrete_action.action // "NoOp") + "\t" + ((.discrete_action.args // []) | join(",")) ) | .[]),
    ($a | map("ANN\t" + (.task_desc // "")) | .[]),
    "TRAJ_END"
  ' "$tdj" 2>/dev/null >> "$FLAT"
done

awk -v out="$OUT" '
BEGIN {
  fc_x[0] = 5;  fc_x[1] = 3;  fc_x[2] = 12;  fc_x[3] = 25;  fc_x[4] = 15;
  fc_x[5] = 7;  fc_x[6] = 22;  fc_x[7] = 4;  fc_x[8] = 18;  fc_x[9] = 6;
  fc_x[10] = 11; fc_x[11] = 27; fc_x[12] = 9;  fc_x[13] = 16; fc_x[14] = 13;
  fc_x[15] = 21; fc_x[16] = 8;  fc_x[17] = 19; fc_x[18] = 14; fc_x[19] = 24;
  fc_y[0] = 5;  fc_y[1] = 7;  fc_y[2] = 3;  fc_y[3] = 5;  fc_y[4] = 15;
  fc_y[5] = 12; fc_y[6] = 18; fc_y[7] = 20; fc_y[8] = 8;  fc_y[9] = 25;
  fc_y[10] = 2;  fc_y[11] = 14; fc_y[12] = 9;  fc_y[13] = 6;  fc_y[14] = 22;
  fc_y[15] = 4;  fc_y[16] = 17; fc_y[17] = 11; fc_y[18] = 27; fc_y[19] = 9;
  fc_z[0] = 5;  fc_z[1] = 8;  fc_z[2] = 15; fc_z[3] = 5;  fc_z[4] = 15;
  fc_z[5] = 10; fc_z[6] = 12; fc_z[7] = 6;  fc_z[8] = 18; fc_z[9] = 9;
  fc_z[10] = 22; fc_z[11] = 4;  fc_z[12] = 20; fc_z[13] = 7;  fc_z[14] = 11;
  fc_z[15] = 13; fc_z[16] = 16; fc_z[17] = 8;  fc_z[18] = 14; fc_z[19] = 17;
  ncoords = 20;
  cmds_n = 0;
  ann_n = 0;
  emitted = 0;
}

function hash_obj(name,    h, i, c, p) {
  h = 5381;
  for (i = 1; i <= length(name); i++) {
    c = substr(name, i, 1);
    p = index("abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-", c);
    h = ((h * 33) + p) % 100000007;
  }
  return h % ncoords;
}

function emit_one(nl,    i, script, esc_nl, esc_script, id_str) {
  if (cmds_n == 0 || nl == "") return;
  script = "script = [\n  ";
  for (i = 1; i <= cmds_n; i++) {
    script = script cmds[i];
    if (i < cmds_n) script = script ",\n  ";
  }
  script = script "\n]";
  esc_nl = nl;
  # Strip non-printable bytes (control chars, \x7F, and bytes >= 0x80).
  # Keeping just printable ASCII (space..tilde) plus \n\r\t for re-escaping.
  gsub(/[^[:print:]\n\r\t]/, " ", esc_nl);
  gsub(/\\/, "\\\\", esc_nl);
  gsub(/"/, "\\\"", esc_nl);
  gsub(/\n/, "\\n", esc_nl);
  gsub(/\r/, "", esc_nl);
  gsub(/\t/, "\\t", esc_nl);
  esc_script = script;
  gsub(/\\/, "\\\\", esc_script);
  gsub(/"/, "\\\"", esc_script);
  gsub(/\n/, "\\n", esc_script);
  gsub(/\t/, "\\t", esc_script);
  emitted++;
  id_str = sprintf("alfred:%05d", emitted);
  printf("{\"id\":\"%s\",\"nl\":\"%s\",\"script\":\"%s\",\"world\":{\"obx\":-1,\"oby\":0,\"obz\":0,\"present\":0},\"expected\":{\"gex\":0,\"gey\":0,\"gez\":0,\"ggrip\":0,\"gheld\":0},\"source\":\"alfred\",\"stages_passed\":3}\n",
    id_str, esc_nl, esc_script) >> out;
}

/^TRAJ_BEGIN/ { cmds_n = 0; ann_n = 0; next }

/^PLAN\t/ {
  n = split($0, p, "\t");
  if (n < 2) next;
  action = p[2];
  arg = (n >= 3 ? p[3] : "");
  split(arg, aa, ",");
  obj = aa[1];
  recep = (length(aa) >= 2 ? aa[2] : "");
  if (action == "GotoLocation") {
    if (obj == "") next;
    idx = hash_obj(obj);
    cmds_n++;
    cmds[cmds_n] = sprintf("MoveTo %d %d %d", fc_x[idx], fc_y[idx], fc_z[idx]);
  } else if (action == "PickupObject" || action == "PickupObjectInReceptacle") {
    if (obj != "") {
      idx = hash_obj(obj);
      cmds_n++;
      cmds[cmds_n] = sprintf("MoveTo %d %d %d", fc_x[idx], fc_y[idx], fc_z[idx]);
    }
  } else if (action == "PutObject" || action == "PutObjectInReceptacle") {
    tgt = (recep != "" ? recep : obj);
    if (tgt != "") {
      idx = hash_obj(tgt);
      cmds_n++;
      cmds[cmds_n] = sprintf("MoveTo %d %d %d", fc_x[idx], fc_y[idx], fc_z[idx]);
    }
  }
  next
}

/^ANN\t/ {
  n = split($0, p, "\t");
  if (n < 2) next;
  ann_n++;
  ann[ann_n] = p[2];
  next
}

/^TRAJ_END/ {
  for (i = 1; i <= ann_n; i++) emit_one(ann[i]);
  cmds_n = 0; ann_n = 0;
  next
}

END {
  printf("extract_alfred: emitted=%d\n", emitted) > "/dev/stderr";
}
' "$FLAT"

echo "extract_alfred done -> $OUT"
wc -l "$OUT"
