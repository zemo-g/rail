#!/bin/bash
# tools/infer/agree_check.sh — two-machine agreement over the attested server.
#
# Sends the IDENTICAL /generate request to two serve_kv endpoints and
# compares output_sha256. Because the engine's contract is same request
# bytes -> same response bytes, ANY disagreement between two machines
# running the same model is an alarm: silent corruption, weight drift, a
# diverged binary, a bad libm -- the class of fault no health check sees.
# Proven basis: Mini (M4 Pro, macOS 26.3) == Studio (M1 Ultra, 26.4.1)
# byte-identical on 2026-08-27.
#
#   ./tools/infer/agree_check.sh http://hostA:9186 http://hostB:9186 \
#       ['{"prompt": "...", "max": N}']
#
# Exit 0 + AGREE, or exit 1 + ALARM with both hashes.
set -u
A=${1:?usage: agree_check.sh urlA urlB [request-json]}
B=${2:?usage: agree_check.sh urlA urlB [request-json]}
REQ=${3:-'{"prompt": "the rail language compiles", "max": 40}'}

RA=$(curl -sm 120 -X POST "$A/generate" -d "$REQ")
RB=$(curl -sm 120 -X POST "$B/generate" -d "$REQ")
HA=$(echo "$RA" | sed -n 's/.*"output_sha256":"\([0-9a-f]*\)".*/\1/p')
HB=$(echo "$RB" | sed -n 's/.*"output_sha256":"\([0-9a-f]*\)".*/\1/p')

if [ -z "$HA" ] || [ -z "$HB" ]; then
  echo "ALARM: an endpoint failed to answer (A='$RA' B='$RB')"; exit 1
fi
if [ "$HA" = "$HB" ]; then
  echo "AGREE $HA"
  exit 0
else
  echo "ALARM: machines disagree on identical input"
  echo "  $A -> $HA"
  echo "  $B -> $HB"
  exit 1
fi
