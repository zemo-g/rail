#!/bin/bash
# check_ident.sh [host[:port]]: the fleet agent's /logs/<svc> and /jobs/<id> take an
# identifier or nothing (safe_ident, 2026-09-14). Run against a live agent with the fleet
# token; exit 1 on any FAIL. Against an agent without the allowlist the injection cases
# come back 200 (proved on the 2026-08-28 build before the fix was deployed).
set -u
H=${1:-127.0.0.1:9101}
TOK=$(cat ~/.fleet/token 2>/dev/null) || { echo "no ~/.fleet/token"; exit 2; }
fails=0
code() { curl -s -m 8 -o /dev/null -w '%{http_code}' --path-as-is -g -H "X-Fleet-Token: $TOK" "http://$H$1"; }
check() {  # check <path> <expected code> <why>; paths are sent RAW (the agent never decodes percent escapes)
  local got; got=$(code "$1")
  if [ "$got" = "$2" ]; then echo "  ok   $3 ($1 -> $got)"; else echo "  FAIL $3 ($1 -> $got, wanted $2)"; fails=$((fails+1)); fi
}
check "/logs/techsix?lines=1"            200 "a plain service name is served"
check "/logs/fleet_agent?lines=1"        200 "underscores are identifiers"
check "/logs/"                           400 "an empty name is refused"
check '/logs/x;id'                       400 "a semicolon is refused (shell injection)"
check '/logs/x$(id)'                     400 "a dollar is refused (command substitution)"
check '/logs/x`id`'                      400 "a backtick is refused"
check '/logs/../../etc/passwd'           400 "dot-dot is refused (path traversal)"
check '/jobs/../../etc/passwd'           400 "dot-dot in a job id is refused"
check '/jobs/abc`id`'                    400 "a backtick in a job id is refused"
check '/jobs/abc|id'                     400 "a pipe in a job id is refused"
check "/jobs/job-2026_09_14.1"           200 "a plain job id is answered (not_found is still a 200)"
echo "check_ident: $fails FAIL"
exit $(( fails > 0 ))
