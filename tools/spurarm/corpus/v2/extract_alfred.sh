#!/bin/sh
# tools/spurarm/corpus/v2/extract_alfred.sh
#
# v2 ALFRED extractor. Same shape as v1 (navigation-only verb remap,
# 3 turk paraphrases per trajectory), but with the v2 modifications:
#
#   * Default cap raised from 12000 -> 20000 (per SPEC §6 mix).
#   * Same djb2 -> 20-coord pool object grounding; same SetGrip drop
#     per Agent A's "navigation-only refinement" earned lesson.
#   * Source tag is the same "alfred" so downstream tools don't have
#     to special-case v1 vs v2.
#
# Usage:
#   sh tools/spurarm/corpus/v2/extract_alfred.sh <alfred_dir> <out_jsonl> [max]

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

LIST=/tmp/spurarm_v2_alfred_files.txt
FLAT=/tmp/spurarm_v2_alfred_flat.txt
find "$ALFRED_DIR" -name "traj_data.json" -type f > "$LIST"
TOTAL=$(wc -l < "$LIST" | tr -d ' ')
echo "extract_alfred (v2): found $TOTAL traj_data.json files (limit=$MAX)"

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
  fc_x[0]=20; fc_x[1]=23; fc_x[2]=7; fc_x[3]=18; fc_x[4]=7; fc_x[5]=17; fc_x[6]=7; fc_x[7]=22; fc_x[8]=8; fc_x[9]=3; fc_x[10]=19; fc_x[11]=23; fc_x[12]=17; fc_x[13]=18; fc_x[14]=1; fc_x[15]=24; fc_x[16]=27; fc_x[17]=12; fc_x[18]=5; fc_x[19]=6; fc_x[20]=19; fc_x[21]=17; fc_x[22]=5; fc_x[23]=21; fc_x[24]=7; fc_x[25]=25; fc_x[26]=8; fc_x[27]=6; fc_x[28]=4; fc_x[29]=7; fc_x[30]=23; fc_x[31]=11; fc_x[32]=16; fc_x[33]=24; fc_x[34]=4; fc_x[35]=19; fc_x[36]=12; fc_x[37]=16; fc_x[38]=3; fc_x[39]=5; fc_x[40]=16; fc_x[41]=4; fc_x[42]=19; fc_x[43]=7; fc_x[44]=2; fc_x[45]=26; fc_x[46]=4; fc_x[47]=8; fc_x[48]=22; fc_x[49]=21; fc_x[50]=3; fc_x[51]=2; fc_x[52]=18; fc_x[53]=18; fc_x[54]=2; fc_x[55]=7; fc_x[56]=27; fc_x[57]=16; fc_x[58]=21; fc_x[59]=17; fc_x[60]=7; fc_x[61]=25; fc_x[62]=11; fc_x[63]=21; fc_x[64]=1; fc_x[65]=7; fc_x[66]=17; fc_x[67]=13; fc_x[68]=14; fc_x[69]=14; fc_x[70]=1; fc_x[71]=2; fc_x[72]=5; fc_x[73]=15; fc_x[74]=28; fc_x[75]=12; fc_x[76]=9; fc_x[77]=4; fc_x[78]=18; fc_x[79]=23; fc_x[80]=1; fc_x[81]=27; fc_x[82]=19; fc_x[83]=12; fc_x[84]=18; fc_x[85]=19; fc_x[86]=21; fc_x[87]=7; fc_x[88]=4; fc_x[89]=14; fc_x[90]=0; fc_x[91]=2; fc_x[92]=16; fc_x[93]=28; fc_x[94]=9; fc_x[95]=8; fc_x[96]=23; fc_x[97]=8; fc_x[98]=22; fc_x[99]=21; fc_x[100]=16; fc_x[101]=2; fc_x[102]=26; fc_x[103]=0; fc_x[104]=20; fc_x[105]=23; fc_x[106]=17; fc_x[107]=17; fc_x[108]=18; fc_x[109]=13; fc_x[110]=9; fc_x[111]=21; fc_x[112]=11; fc_x[113]=19; fc_x[114]=27; fc_x[115]=5; fc_x[116]=8; fc_x[117]=12; fc_x[118]=6; fc_x[119]=11; fc_x[120]=7; fc_x[121]=12; fc_x[122]=27; fc_x[123]=11; fc_x[124]=30; fc_x[125]=28; fc_x[126]=11; fc_x[127]=13; fc_x[128]=8; fc_x[129]=0; fc_x[130]=11; fc_x[131]=19; fc_x[132]=16; fc_x[133]=10; fc_x[134]=17; fc_x[135]=13; fc_x[136]=19; fc_x[137]=12; fc_x[138]=9; fc_x[139]=13; fc_x[140]=14; fc_x[141]=21; fc_x[142]=21; fc_x[143]=16; fc_x[144]=2; fc_x[145]=21; fc_x[146]=25; fc_x[147]=15; fc_x[148]=14; fc_x[149]=15; fc_x[150]=4; fc_x[151]=24; fc_x[152]=5; fc_x[153]=1; fc_x[154]=14; fc_x[155]=21; fc_x[156]=28; fc_x[157]=14; fc_x[158]=20; fc_x[159]=14; fc_x[160]=7; fc_x[161]=10; fc_x[162]=4; fc_x[163]=12; fc_x[164]=22; fc_x[165]=13; fc_x[166]=17; fc_x[167]=1; fc_x[168]=15; fc_x[169]=9; fc_x[170]=15; fc_x[171]=13; fc_x[172]=12; fc_x[173]=23; fc_x[174]=29; fc_x[175]=4; fc_x[176]=5; fc_x[177]=12; fc_x[178]=14; fc_x[179]=8; fc_x[180]=8; fc_x[181]=15; fc_x[182]=20; fc_x[183]=24; fc_x[184]=6; fc_x[185]=19; fc_x[186]=4; fc_x[187]=14; fc_x[188]=24; fc_x[189]=19; fc_x[190]=18; fc_x[191]=18; fc_x[192]=2; fc_x[193]=3; fc_x[194]=11; fc_x[195]=21; fc_x[196]=16; fc_x[197]=0; fc_x[198]=22; fc_x[199]=5; fc_x[200]=14; fc_x[201]=10; fc_x[202]=8; fc_x[203]=7; fc_x[204]=18; fc_x[205]=10; fc_x[206]=27; fc_x[207]=15; fc_x[208]=25; fc_x[209]=8; fc_x[210]=17; fc_x[211]=2; fc_x[212]=15; fc_x[213]=22; fc_x[214]=14; fc_x[215]=2; fc_x[216]=12; fc_x[217]=9; fc_x[218]=15; fc_x[219]=13; fc_x[220]=11; fc_x[221]=8; fc_x[222]=7; fc_x[223]=10; fc_x[224]=6; fc_x[225]=8; fc_x[226]=3; fc_x[227]=9; fc_x[228]=5; fc_x[229]=22; fc_x[230]=8; fc_x[231]=17; fc_x[232]=3; fc_x[233]=18; fc_x[234]=15; fc_x[235]=3; fc_x[236]=12; fc_x[237]=18; fc_x[238]=4; fc_x[239]=2; fc_x[240]=17; fc_x[241]=19; fc_x[242]=24; fc_x[243]=9; fc_x[244]=9; fc_x[245]=20; fc_x[246]=21; fc_x[247]=7; fc_x[248]=5; fc_x[249]=14; fc_x[250]=9; fc_x[251]=9; fc_x[252]=2; fc_x[253]=13; fc_x[254]=20; fc_x[255]=26; fc_x[256]=1; fc_x[257]=19; fc_x[258]=14; fc_x[259]=14; fc_x[260]=19; fc_x[261]=2; fc_x[262]=18; fc_x[263]=15; fc_x[264]=18; fc_x[265]=2; fc_x[266]=13; fc_x[267]=21; fc_x[268]=10; fc_x[269]=9; fc_x[270]=14; fc_x[271]=8; fc_x[272]=24; fc_x[273]=13; fc_x[274]=16; fc_x[275]=20; fc_x[276]=6; fc_x[277]=22; fc_x[278]=17; fc_x[279]=16; fc_x[280]=13; fc_x[281]=15; fc_x[282]=17; fc_x[283]=6; fc_x[284]=26; fc_x[285]=23; fc_x[286]=27; fc_x[287]=17; fc_x[288]=10; fc_x[289]=27; fc_x[290]=18; fc_x[291]=1; fc_x[292]=12; fc_x[293]=4; fc_x[294]=27; fc_x[295]=3; fc_x[296]=0; fc_x[297]=13; fc_x[298]=2; fc_x[299]=10; fc_x[300]=20; fc_x[301]=20; fc_x[302]=7; fc_x[303]=13; fc_x[304]=14; fc_x[305]=28; fc_x[306]=10; fc_x[307]=9; fc_x[308]=13; fc_x[309]=16; fc_x[310]=5; fc_x[311]=19; fc_x[312]=14; fc_x[313]=28; fc_x[314]=2; fc_x[315]=18; fc_x[316]=22; fc_x[317]=27; fc_x[318]=12; fc_x[319]=3; fc_x[320]=18; fc_x[321]=22; fc_x[322]=8; fc_x[323]=7; fc_x[324]=19; fc_x[325]=20; fc_x[326]=9; fc_x[327]=1; fc_x[328]=23; fc_x[329]=23; fc_x[330]=6; fc_x[331]=16; fc_x[332]=26; fc_x[333]=25; fc_x[334]=2; fc_x[335]=0; fc_x[336]=14; fc_x[337]=18; fc_x[338]=3; fc_x[339]=15; fc_x[340]=20; fc_x[341]=20; fc_x[342]=9; fc_x[343]=3; fc_x[344]=12; fc_x[345]=18; fc_x[346]=1; fc_x[347]=6; fc_x[348]=3; fc_x[349]=1; fc_x[350]=2; fc_x[351]=20; fc_x[352]=1; fc_x[353]=7; fc_x[354]=2; fc_x[355]=18; fc_x[356]=10; fc_x[357]=8; fc_x[358]=4; fc_x[359]=25; fc_x[360]=18; fc_x[361]=5; fc_x[362]=4; fc_x[363]=16; fc_x[364]=15; fc_x[365]=16; fc_x[366]=14; fc_x[367]=14; fc_x[368]=1; fc_x[369]=13; fc_x[370]=15; fc_x[371]=2; fc_x[372]=10; fc_x[373]=19; fc_x[374]=12; fc_x[375]=14; fc_x[376]=3; fc_x[377]=13; fc_x[378]=13; fc_x[379]=12; fc_x[380]=10; fc_x[381]=21; fc_x[382]=2; fc_x[383]=25; fc_x[384]=21; fc_x[385]=11; fc_x[386]=11; fc_x[387]=7; fc_x[388]=11; fc_x[389]=3; fc_x[390]=18; fc_x[391]=0; fc_x[392]=0; fc_x[393]=2; fc_x[394]=12; fc_x[395]=10; fc_x[396]=9; fc_x[397]=28; fc_x[398]=5; fc_x[399]=21; fc_x[400]=14; fc_x[401]=15; fc_x[402]=13; fc_x[403]=24; fc_x[404]=11; fc_x[405]=9; fc_x[406]=16; fc_x[407]=1; fc_x[408]=19; fc_x[409]=6; fc_x[410]=24; fc_x[411]=9; fc_x[412]=0; fc_x[413]=5; fc_x[414]=17; fc_x[415]=16; fc_x[416]=2; fc_x[417]=13; fc_x[418]=29; fc_x[419]=18; fc_x[420]=22; fc_x[421]=9; fc_x[422]=0; fc_x[423]=7; fc_x[424]=16; fc_x[425]=27; fc_x[426]=7; fc_x[427]=2; fc_x[428]=16; fc_x[429]=11; fc_x[430]=7; fc_x[431]=8; fc_x[432]=19; fc_x[433]=14; fc_x[434]=4; fc_x[435]=15; fc_x[436]=25; fc_x[437]=11; fc_x[438]=9; fc_x[439]=26; fc_x[440]=19; fc_x[441]=14; fc_x[442]=10; fc_x[443]=16; fc_x[444]=14; fc_x[445]=22; fc_x[446]=1; fc_x[447]=14; fc_x[448]=11; fc_x[449]=12; fc_x[450]=21; fc_x[451]=2; fc_x[452]=17; fc_x[453]=9; fc_x[454]=10; fc_x[455]=4; fc_x[456]=9; fc_x[457]=20; fc_x[458]=16; fc_x[459]=11; fc_x[460]=6; fc_x[461]=16; fc_x[462]=21; fc_x[463]=19; fc_x[464]=5; fc_x[465]=23; fc_x[466]=13; fc_x[467]=14; fc_x[468]=7; fc_x[469]=11; fc_x[470]=14; fc_x[471]=24; fc_x[472]=27; fc_x[473]=20; fc_x[474]=9; fc_x[475]=8; fc_x[476]=26; fc_x[477]=26; fc_x[478]=29; fc_x[479]=1; fc_x[480]=7; fc_x[481]=11; fc_x[482]=25; fc_x[483]=1; fc_x[484]=14; fc_x[485]=28; fc_x[486]=8; fc_x[487]=3; fc_x[488]=7; fc_x[489]=1; fc_x[490]=19; fc_x[491]=20; fc_x[492]=22; fc_x[493]=13; fc_x[494]=7; fc_x[495]=5; fc_x[496]=16; fc_x[497]=1; fc_x[498]=11; fc_x[499]=11;
  fc_y[0]=3; fc_y[1]=8; fc_y[2]=4; fc_y[3]=13; fc_y[4]=16; fc_y[5]=6; fc_y[6]=14; fc_y[7]=13; fc_y[8]=4; fc_y[9]=11; fc_y[10]=8; fc_y[11]=14; fc_y[12]=9; fc_y[13]=6; fc_y[14]=21; fc_y[15]=9; fc_y[16]=7; fc_y[17]=8; fc_y[18]=11; fc_y[19]=21; fc_y[20]=20; fc_y[21]=23; fc_y[22]=14; fc_y[23]=10; fc_y[24]=26; fc_y[25]=10; fc_y[26]=2; fc_y[27]=20; fc_y[28]=8; fc_y[29]=23; fc_y[30]=18; fc_y[31]=7; fc_y[32]=15; fc_y[33]=1; fc_y[34]=20; fc_y[35]=2; fc_y[36]=19; fc_y[37]=8; fc_y[38]=9; fc_y[39]=14; fc_y[40]=24; fc_y[41]=11; fc_y[42]=10; fc_y[43]=1; fc_y[44]=23; fc_y[45]=2; fc_y[46]=21; fc_y[47]=16; fc_y[48]=9; fc_y[49]=20; fc_y[50]=7; fc_y[51]=10; fc_y[52]=17; fc_y[53]=7; fc_y[54]=22; fc_y[55]=2; fc_y[56]=10; fc_y[57]=7; fc_y[58]=15; fc_y[59]=4; fc_y[60]=25; fc_y[61]=13; fc_y[62]=13; fc_y[63]=20; fc_y[64]=12; fc_y[65]=6; fc_y[66]=14; fc_y[67]=5; fc_y[68]=7; fc_y[69]=25; fc_y[70]=20; fc_y[71]=29; fc_y[72]=13; fc_y[73]=6; fc_y[74]=1; fc_y[75]=0; fc_y[76]=13; fc_y[77]=6; fc_y[78]=23; fc_y[79]=10; fc_y[80]=18; fc_y[81]=5; fc_y[82]=2; fc_y[83]=3; fc_y[84]=19; fc_y[85]=2; fc_y[86]=18; fc_y[87]=8; fc_y[88]=21; fc_y[89]=10; fc_y[90]=14; fc_y[91]=17; fc_y[92]=8; fc_y[93]=7; fc_y[94]=5; fc_y[95]=3; fc_y[96]=17; fc_y[97]=9; fc_y[98]=10; fc_y[99]=20; fc_y[100]=15; fc_y[101]=20; fc_y[102]=8; fc_y[103]=10; fc_y[104]=8; fc_y[105]=14; fc_y[106]=0; fc_y[107]=1; fc_y[108]=17; fc_y[109]=4; fc_y[110]=11; fc_y[111]=7; fc_y[112]=24; fc_y[113]=23; fc_y[114]=5; fc_y[115]=23; fc_y[116]=5; fc_y[117]=27; fc_y[118]=26; fc_y[119]=9; fc_y[120]=0; fc_y[121]=10; fc_y[122]=2; fc_y[123]=20; fc_y[124]=0; fc_y[125]=8; fc_y[126]=23; fc_y[127]=19; fc_y[128]=1; fc_y[129]=16; fc_y[130]=13; fc_y[131]=10; fc_y[132]=9; fc_y[133]=12; fc_y[134]=4; fc_y[135]=21; fc_y[136]=18; fc_y[137]=17; fc_y[138]=9; fc_y[139]=25; fc_y[140]=14; fc_y[141]=6; fc_y[142]=2; fc_y[143]=21; fc_y[144]=26; fc_y[145]=9; fc_y[146]=6; fc_y[147]=19; fc_y[148]=13; fc_y[149]=12; fc_y[150]=20; fc_y[151]=13; fc_y[152]=25; fc_y[153]=17; fc_y[154]=4; fc_y[155]=16; fc_y[156]=5; fc_y[157]=8; fc_y[158]=7; fc_y[159]=2; fc_y[160]=8; fc_y[161]=28; fc_y[162]=4; fc_y[163]=22; fc_y[164]=6; fc_y[165]=13; fc_y[166]=14; fc_y[167]=6; fc_y[168]=0; fc_y[169]=24; fc_y[170]=7; fc_y[171]=15; fc_y[172]=10; fc_y[173]=5; fc_y[174]=4; fc_y[175]=27; fc_y[176]=1; fc_y[177]=10; fc_y[178]=10; fc_y[179]=24; fc_y[180]=26; fc_y[181]=0; fc_y[182]=2; fc_y[183]=0; fc_y[184]=26; fc_y[185]=4; fc_y[186]=15; fc_y[187]=22; fc_y[188]=11; fc_y[189]=19; fc_y[190]=0; fc_y[191]=21; fc_y[192]=18; fc_y[193]=22; fc_y[194]=17; fc_y[195]=11; fc_y[196]=20; fc_y[197]=27; fc_y[198]=4; fc_y[199]=23; fc_y[200]=13; fc_y[201]=27; fc_y[202]=28; fc_y[203]=24; fc_y[204]=19; fc_y[205]=0; fc_y[206]=10; fc_y[207]=6; fc_y[208]=8; fc_y[209]=28; fc_y[210]=0; fc_y[211]=7; fc_y[212]=17; fc_y[213]=15; fc_y[214]=25; fc_y[215]=9; fc_y[216]=22; fc_y[217]=21; fc_y[218]=17; fc_y[219]=23; fc_y[220]=22; fc_y[221]=9; fc_y[222]=3; fc_y[223]=3; fc_y[224]=6; fc_y[225]=23; fc_y[226]=26; fc_y[227]=7; fc_y[228]=9; fc_y[229]=17; fc_y[230]=1; fc_y[231]=9; fc_y[232]=27; fc_y[233]=9; fc_y[234]=14; fc_y[235]=26; fc_y[236]=15; fc_y[237]=20; fc_y[238]=4; fc_y[239]=7; fc_y[240]=24; fc_y[241]=19; fc_y[242]=16; fc_y[243]=27; fc_y[244]=18; fc_y[245]=6; fc_y[246]=2; fc_y[247]=5; fc_y[248]=0; fc_y[249]=22; fc_y[250]=1; fc_y[251]=22; fc_y[252]=21; fc_y[253]=3; fc_y[254]=4; fc_y[255]=4; fc_y[256]=5; fc_y[257]=23; fc_y[258]=3; fc_y[259]=2; fc_y[260]=8; fc_y[261]=7; fc_y[262]=1; fc_y[263]=16; fc_y[264]=13; fc_y[265]=15; fc_y[266]=10; fc_y[267]=3; fc_y[268]=13; fc_y[269]=21; fc_y[270]=2; fc_y[271]=10; fc_y[272]=12; fc_y[273]=1; fc_y[274]=11; fc_y[275]=14; fc_y[276]=8; fc_y[277]=5; fc_y[278]=0; fc_y[279]=22; fc_y[280]=26; fc_y[281]=7; fc_y[282]=4; fc_y[283]=29; fc_y[284]=0; fc_y[285]=9; fc_y[286]=4; fc_y[287]=15; fc_y[288]=17; fc_y[289]=6; fc_y[290]=12; fc_y[291]=10; fc_y[292]=21; fc_y[293]=16; fc_y[294]=3; fc_y[295]=16; fc_y[296]=23; fc_y[297]=27; fc_y[298]=15; fc_y[299]=19; fc_y[300]=2; fc_y[301]=21; fc_y[302]=23; fc_y[303]=3; fc_y[304]=5; fc_y[305]=0; fc_y[306]=25; fc_y[307]=11; fc_y[308]=4; fc_y[309]=13; fc_y[310]=5; fc_y[311]=21; fc_y[312]=8; fc_y[313]=9; fc_y[314]=14; fc_y[315]=9; fc_y[316]=8; fc_y[317]=9; fc_y[318]=27; fc_y[319]=7; fc_y[320]=11; fc_y[321]=9; fc_y[322]=0; fc_y[323]=20; fc_y[324]=8; fc_y[325]=3; fc_y[326]=25; fc_y[327]=18; fc_y[328]=4; fc_y[329]=13; fc_y[330]=4; fc_y[331]=16; fc_y[332]=5; fc_y[333]=3; fc_y[334]=25; fc_y[335]=8; fc_y[336]=11; fc_y[337]=12; fc_y[338]=21; fc_y[339]=0; fc_y[340]=2; fc_y[341]=13; fc_y[342]=15; fc_y[343]=7; fc_y[344]=14; fc_y[345]=23; fc_y[346]=22; fc_y[347]=14; fc_y[348]=21; fc_y[349]=12; fc_y[350]=21; fc_y[351]=20; fc_y[352]=25; fc_y[353]=4; fc_y[354]=26; fc_y[355]=6; fc_y[356]=24; fc_y[357]=27; fc_y[358]=17; fc_y[359]=5; fc_y[360]=10; fc_y[361]=8; fc_y[362]=23; fc_y[363]=3; fc_y[364]=14; fc_y[365]=18; fc_y[366]=16; fc_y[367]=20; fc_y[368]=15; fc_y[369]=21; fc_y[370]=22; fc_y[371]=28; fc_y[372]=19; fc_y[373]=20; fc_y[374]=19; fc_y[375]=16; fc_y[376]=25; fc_y[377]=14; fc_y[378]=10; fc_y[379]=13; fc_y[380]=13; fc_y[381]=8; fc_y[382]=13; fc_y[383]=4; fc_y[384]=3; fc_y[385]=27; fc_y[386]=3; fc_y[387]=27; fc_y[388]=27; fc_y[389]=24; fc_y[390]=7; fc_y[391]=5; fc_y[392]=5; fc_y[393]=23; fc_y[394]=13; fc_y[395]=5; fc_y[396]=23; fc_y[397]=1; fc_y[398]=24; fc_y[399]=2; fc_y[400]=21; fc_y[401]=19; fc_y[402]=8; fc_y[403]=16; fc_y[404]=13; fc_y[405]=21; fc_y[406]=21; fc_y[407]=7; fc_y[408]=1; fc_y[409]=9; fc_y[410]=4; fc_y[411]=10; fc_y[412]=15; fc_y[413]=4; fc_y[414]=22; fc_y[415]=17; fc_y[416]=12; fc_y[417]=0; fc_y[418]=2; fc_y[419]=13; fc_y[420]=20; fc_y[421]=3; fc_y[422]=30; fc_y[423]=13; fc_y[424]=2; fc_y[425]=9; fc_y[426]=10; fc_y[427]=16; fc_y[428]=16; fc_y[429]=23; fc_y[430]=3; fc_y[431]=6; fc_y[432]=4; fc_y[433]=24; fc_y[434]=14; fc_y[435]=14; fc_y[436]=8; fc_y[437]=16; fc_y[438]=14; fc_y[439]=9; fc_y[440]=19; fc_y[441]=18; fc_y[442]=19; fc_y[443]=4; fc_y[444]=3; fc_y[445]=2; fc_y[446]=7; fc_y[447]=16; fc_y[448]=11; fc_y[449]=13; fc_y[450]=19; fc_y[451]=10; fc_y[452]=21; fc_y[453]=8; fc_y[454]=2; fc_y[455]=19; fc_y[456]=17; fc_y[457]=21; fc_y[458]=11; fc_y[459]=9; fc_y[460]=7; fc_y[461]=24; fc_y[462]=10; fc_y[463]=12; fc_y[464]=5; fc_y[465]=14; fc_y[466]=11; fc_y[467]=19; fc_y[468]=17; fc_y[469]=21; fc_y[470]=24; fc_y[471]=12; fc_y[472]=8; fc_y[473]=15; fc_y[474]=2; fc_y[475]=14; fc_y[476]=13; fc_y[477]=14; fc_y[478]=0; fc_y[479]=12; fc_y[480]=12; fc_y[481]=7; fc_y[482]=4; fc_y[483]=9; fc_y[484]=19; fc_y[485]=2; fc_y[486]=6; fc_y[487]=24; fc_y[488]=9; fc_y[489]=7; fc_y[490]=17; fc_y[491]=16; fc_y[492]=4; fc_y[493]=0; fc_y[494]=18; fc_y[495]=21; fc_y[496]=11; fc_y[497]=20; fc_y[498]=8; fc_y[499]=25;
  fc_z[0]=3; fc_z[1]=10; fc_z[2]=6; fc_z[3]=4; fc_z[4]=3; fc_z[5]=16; fc_z[6]=11; fc_z[7]=13; fc_z[8]=9; fc_z[9]=14; fc_z[10]=4; fc_z[11]=6; fc_z[12]=14; fc_z[13]=5; fc_z[14]=10; fc_z[15]=5; fc_z[16]=6; fc_z[17]=17; fc_z[18]=14; fc_z[19]=11; fc_z[20]=8; fc_z[21]=10; fc_z[22]=15; fc_z[23]=4; fc_z[24]=4; fc_z[25]=15; fc_z[26]=9; fc_z[27]=18; fc_z[28]=7; fc_z[29]=11; fc_z[30]=16; fc_z[31]=7; fc_z[32]=5; fc_z[33]=6; fc_z[34]=8; fc_z[35]=15; fc_z[36]=17; fc_z[37]=3; fc_z[38]=16; fc_z[39]=3; fc_z[40]=8; fc_z[41]=8; fc_z[42]=18; fc_z[43]=10; fc_z[44]=18; fc_z[45]=7; fc_z[46]=18; fc_z[47]=16; fc_z[48]=15; fc_z[49]=14; fc_z[50]=10; fc_z[51]=3; fc_z[52]=10; fc_z[53]=3; fc_z[54]=4; fc_z[55]=4; fc_z[56]=5; fc_z[57]=11; fc_z[58]=9; fc_z[59]=18; fc_z[60]=18; fc_z[61]=9; fc_z[62]=16; fc_z[63]=6; fc_z[64]=13; fc_z[65]=9; fc_z[66]=7; fc_z[67]=11; fc_z[68]=5; fc_z[69]=6; fc_z[70]=3; fc_z[71]=10; fc_z[72]=18; fc_z[73]=15; fc_z[74]=8; fc_z[75]=15; fc_z[76]=18; fc_z[77]=12; fc_z[78]=4; fc_z[79]=4; fc_z[80]=18; fc_z[81]=5; fc_z[82]=10; fc_z[83]=10; fc_z[84]=4; fc_z[85]=16; fc_z[86]=13; fc_z[87]=15; fc_z[88]=12; fc_z[89]=5; fc_z[90]=6; fc_z[91]=9; fc_z[92]=7; fc_z[93]=14; fc_z[94]=17; fc_z[95]=6; fc_z[96]=7; fc_z[97]=9; fc_z[98]=9; fc_z[99]=11; fc_z[100]=11; fc_z[101]=16; fc_z[102]=4; fc_z[103]=7; fc_z[104]=8; fc_z[105]=16; fc_z[106]=6; fc_z[107]=14; fc_z[108]=7; fc_z[109]=4; fc_z[110]=4; fc_z[111]=6; fc_z[112]=16; fc_z[113]=7; fc_z[114]=8; fc_z[115]=13; fc_z[116]=6; fc_z[117]=4; fc_z[118]=17; fc_z[119]=10; fc_z[120]=9; fc_z[121]=11; fc_z[122]=11; fc_z[123]=15; fc_z[124]=6; fc_z[125]=8; fc_z[126]=13; fc_z[127]=6; fc_z[128]=16; fc_z[129]=9; fc_z[130]=5; fc_z[131]=6; fc_z[132]=16; fc_z[133]=12; fc_z[134]=9; fc_z[135]=15; fc_z[136]=12; fc_z[137]=3; fc_z[138]=9; fc_z[139]=13; fc_z[140]=17; fc_z[141]=18; fc_z[142]=12; fc_z[143]=13; fc_z[144]=10; fc_z[145]=10; fc_z[146]=7; fc_z[147]=5; fc_z[148]=9; fc_z[149]=10; fc_z[150]=3; fc_z[151]=10; fc_z[152]=17; fc_z[153]=10; fc_z[154]=17; fc_z[155]=13; fc_z[156]=18; fc_z[157]=10; fc_z[158]=11; fc_z[159]=12; fc_z[160]=13; fc_z[161]=5; fc_z[162]=10; fc_z[163]=7; fc_z[164]=5; fc_z[165]=13; fc_z[166]=16; fc_z[167]=16; fc_z[168]=14; fc_z[169]=15; fc_z[170]=11; fc_z[171]=3; fc_z[172]=15; fc_z[173]=17; fc_z[174]=3; fc_z[175]=17; fc_z[176]=11; fc_z[177]=9; fc_z[178]=13; fc_z[179]=16; fc_z[180]=5; fc_z[181]=4; fc_z[182]=4; fc_z[183]=10; fc_z[184]=3; fc_z[185]=10; fc_z[186]=6; fc_z[187]=11; fc_z[188]=8; fc_z[189]=6; fc_z[190]=12; fc_z[191]=15; fc_z[192]=10; fc_z[193]=12; fc_z[194]=16; fc_z[195]=5; fc_z[196]=13; fc_z[197]=16; fc_z[198]=16; fc_z[199]=11; fc_z[200]=11; fc_z[201]=10; fc_z[202]=17; fc_z[203]=17; fc_z[204]=15; fc_z[205]=18; fc_z[206]=8; fc_z[207]=14; fc_z[208]=13; fc_z[209]=11; fc_z[210]=9; fc_z[211]=16; fc_z[212]=10; fc_z[213]=18; fc_z[214]=3; fc_z[215]=10; fc_z[216]=10; fc_z[217]=14; fc_z[218]=14; fc_z[219]=13; fc_z[220]=17; fc_z[221]=11; fc_z[222]=9; fc_z[223]=8; fc_z[224]=18; fc_z[225]=12; fc_z[226]=9; fc_z[227]=14; fc_z[228]=3; fc_z[229]=7; fc_z[230]=4; fc_z[231]=7; fc_z[232]=3; fc_z[233]=18; fc_z[234]=13; fc_z[235]=5; fc_z[236]=5; fc_z[237]=4; fc_z[238]=12; fc_z[239]=6; fc_z[240]=16; fc_z[241]=10; fc_z[242]=15; fc_z[243]=16; fc_z[244]=4; fc_z[245]=11; fc_z[246]=8; fc_z[247]=5; fc_z[248]=16; fc_z[249]=18; fc_z[250]=10; fc_z[251]=12; fc_z[252]=10; fc_z[253]=10; fc_z[254]=11; fc_z[255]=5; fc_z[256]=12; fc_z[257]=12; fc_z[258]=17; fc_z[259]=4; fc_z[260]=3; fc_z[261]=3; fc_z[262]=8; fc_z[263]=17; fc_z[264]=18; fc_z[265]=14; fc_z[266]=13; fc_z[267]=8; fc_z[268]=18; fc_z[269]=15; fc_z[270]=13; fc_z[271]=6; fc_z[272]=3; fc_z[273]=9; fc_z[274]=18; fc_z[275]=4; fc_z[276]=7; fc_z[277]=12; fc_z[278]=16; fc_z[279]=11; fc_z[280]=18; fc_z[281]=17; fc_z[282]=15; fc_z[283]=7; fc_z[284]=12; fc_z[285]=18; fc_z[286]=17; fc_z[287]=14; fc_z[288]=15; fc_z[289]=10; fc_z[290]=10; fc_z[291]=18; fc_z[292]=7; fc_z[293]=13; fc_z[294]=17; fc_z[295]=17; fc_z[296]=7; fc_z[297]=7; fc_z[298]=11; fc_z[299]=15; fc_z[300]=13; fc_z[301]=12; fc_z[302]=5; fc_z[303]=6; fc_z[304]=12; fc_z[305]=4; fc_z[306]=4; fc_z[307]=14; fc_z[308]=10; fc_z[309]=8; fc_z[310]=5; fc_z[311]=10; fc_z[312]=3; fc_z[313]=8; fc_z[314]=14; fc_z[315]=16; fc_z[316]=17; fc_z[317]=9; fc_z[318]=18; fc_z[319]=15; fc_z[320]=12; fc_z[321]=3; fc_z[322]=4; fc_z[323]=9; fc_z[324]=7; fc_z[325]=4; fc_z[326]=17; fc_z[327]=14; fc_z[328]=5; fc_z[329]=8; fc_z[330]=14; fc_z[331]=11; fc_z[332]=11; fc_z[333]=17; fc_z[334]=15; fc_z[335]=6; fc_z[336]=11; fc_z[337]=14; fc_z[338]=10; fc_z[339]=13; fc_z[340]=17; fc_z[341]=6; fc_z[342]=6; fc_z[343]=7; fc_z[344]=14; fc_z[345]=7; fc_z[346]=14; fc_z[347]=17; fc_z[348]=14; fc_z[349]=11; fc_z[350]=9; fc_z[351]=3; fc_z[352]=13; fc_z[353]=9; fc_z[354]=9; fc_z[355]=10; fc_z[356]=7; fc_z[357]=7; fc_z[358]=11; fc_z[359]=6; fc_z[360]=3; fc_z[361]=4; fc_z[362]=16; fc_z[363]=5; fc_z[364]=14; fc_z[365]=6; fc_z[366]=10; fc_z[367]=3; fc_z[368]=15; fc_z[369]=6; fc_z[370]=17; fc_z[371]=5; fc_z[372]=7; fc_z[373]=13; fc_z[374]=12; fc_z[375]=16; fc_z[376]=6; fc_z[377]=10; fc_z[378]=17; fc_z[379]=6; fc_z[380]=13; fc_z[381]=14; fc_z[382]=6; fc_z[383]=4; fc_z[384]=16; fc_z[385]=16; fc_z[386]=9; fc_z[387]=6; fc_z[388]=14; fc_z[389]=11; fc_z[390]=16; fc_z[391]=11; fc_z[392]=7; fc_z[393]=9; fc_z[394]=17; fc_z[395]=14; fc_z[396]=13; fc_z[397]=7; fc_z[398]=4; fc_z[399]=11; fc_z[400]=16; fc_z[401]=17; fc_z[402]=9; fc_z[403]=6; fc_z[404]=6; fc_z[405]=18; fc_z[406]=12; fc_z[407]=15; fc_z[408]=3; fc_z[409]=9; fc_z[410]=11; fc_z[411]=6; fc_z[412]=16; fc_z[413]=15; fc_z[414]=10; fc_z[415]=14; fc_z[416]=4; fc_z[417]=17; fc_z[418]=13; fc_z[419]=15; fc_z[420]=16; fc_z[421]=15; fc_z[422]=13; fc_z[423]=15; fc_z[424]=15; fc_z[425]=13; fc_z[426]=8; fc_z[427]=6; fc_z[428]=9; fc_z[429]=7; fc_z[430]=7; fc_z[431]=8; fc_z[432]=5; fc_z[433]=17; fc_z[434]=5; fc_z[435]=12; fc_z[436]=4; fc_z[437]=5; fc_z[438]=17; fc_z[439]=5; fc_z[440]=15; fc_z[441]=4; fc_z[442]=18; fc_z[443]=4; fc_z[444]=13; fc_z[445]=8; fc_z[446]=17; fc_z[447]=8; fc_z[448]=12; fc_z[449]=13; fc_z[450]=4; fc_z[451]=6; fc_z[452]=15; fc_z[453]=7; fc_z[454]=7; fc_z[455]=5; fc_z[456]=15; fc_z[457]=16; fc_z[458]=3; fc_z[459]=8; fc_z[460]=7; fc_z[461]=4; fc_z[462]=7; fc_z[463]=7; fc_z[464]=8; fc_z[465]=4; fc_z[466]=10; fc_z[467]=12; fc_z[468]=10; fc_z[469]=17; fc_z[470]=12; fc_z[471]=16; fc_z[472]=4; fc_z[473]=14; fc_z[474]=8; fc_z[475]=7; fc_z[476]=5; fc_z[477]=14; fc_z[478]=16; fc_z[479]=14; fc_z[480]=5; fc_z[481]=3; fc_z[482]=7; fc_z[483]=18; fc_z[484]=3; fc_z[485]=3; fc_z[486]=7; fc_z[487]=12; fc_z[488]=6; fc_z[489]=16; fc_z[490]=3; fc_z[491]=10; fc_z[492]=12; fc_z[493]=14; fc_z[494]=16; fc_z[495]=5; fc_z[496]=5; fc_z[497]=15; fc_z[498]=3; fc_z[499]=5;
  ncoords = 500;
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
  printf("extract_alfred (v2): emitted=%d\n", emitted) > "/dev/stderr";
}
' "$FLAT"

echo "extract_alfred (v2) done -> $OUT"
wc -l "$OUT"
