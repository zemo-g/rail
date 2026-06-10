#!/usr/bin/env bash
# repro_30of30.sh — one-line reproduction of the canonical 30/30 substrate result.
#
# Auto-detects an environment that can run the bench:
#   1. If a local teacher endpoint is reachable (TEACHER_ENDPOINT, default
#      http://127.0.0.1:8080 — point at any OpenAI-compatible server), runs
#      the canonical probe at tools/train/spec_in_context_probe_full.py.
#   2. Else, if ANTHROPIC_API_KEY is set, runs tools/bench/repro_anthropic.py
#      against claude-opus-4-7 via the Anthropic API.
#   3. Else, prints reproduction instructions for both paths and exits.
#
# Pre-flight: confirms ./rail_native is present and compiles `main = 0`.
# Result: prints `RESULT: <pass>/<total> in <wall_minutes> min` and exits 0
# if 30/30, else exits 1.

set -euo pipefail

# Resolve script-relative repo root so the script works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RAIL_NATIVE="$REPO_ROOT/rail_native"
MLX_PROBE="$REPO_ROOT/tools/train/spec_in_context_probe_full.py"
ANTHROPIC_PROBE="$REPO_ROOT/tools/bench/repro_anthropic.py"
# Local teacher endpoint — point at any OpenAI-compatible server.
# Accepts either the base URL or the full /v1/chat/completions URL.
TEACHER_ENDPOINT="${TEACHER_ENDPOINT:-http://127.0.0.1:8080}"
TEACHER_BASE="${TEACHER_ENDPOINT%/v1/chat/completions}"

usage() {
    cat <<'USAGE'
Usage: tools/bench/repro_30of30.sh [--help]

Reproduces the canonical Rail substrate hard-bench (30 prompts x 6 bands x N=20
rerank). Auto-detects which backend to use:

  Path A (Anthropic API — recommended for external partners):
    Requires ANTHROPIC_API_KEY in env. Runs claude-opus-4-7 by default.
    ~600 API calls, ~$15-20 at current pricing, ~15-25 min wall-clock.

      ANTHROPIC_API_KEY=... tools/bench/repro_30of30.sh

  Path B (local teacher):
    Requires an OpenAI-compatible server reachable at TEACHER_ENDPOINT
    (default http://127.0.0.1:8080). No external cost, ~15 min wall-clock.

      TEACHER_ENDPOINT=http://your-host:8080 tools/bench/repro_30of30.sh

Background: tools/bench/README.md
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

# Pre-flight: rail_native present and runnable.
if [[ ! -x "$RAIL_NATIVE" ]]; then
    echo "ERROR: rail_native not found or not executable at $RAIL_NATIVE" >&2
    echo "  Build with: ./rail_native self && cp /tmp/rail_self rail_native" >&2
    echo "  (or fetch the seed binary; see CLAUDE.md > Rail Compiler)" >&2
    exit 2
fi

SMOKE_FILE="$(mktemp -t repro_30of30_smoke.XXXXXX).rail"
trap 'rm -f "$SMOKE_FILE" "${SMOKE_FILE%.rail}"' EXIT
echo "main = 0" > "$SMOKE_FILE"
if ! "$RAIL_NATIVE" "$SMOKE_FILE" >/dev/null 2>&1; then
    echo "ERROR: rail_native present but failed to compile 'main = 0'" >&2
    echo "  Toolchain check: macOS needs Xcode CLT (as + ld); Linux needs binutils." >&2
    exit 2
fi
echo "[preflight] rail_native compiles main=0: OK"

# Pick backend.
PROBE=""
LABEL=""
if curl -sS --max-time 2 "$TEACHER_BASE/v1/models" >/dev/null 2>&1; then
    PROBE="python3 $MLX_PROBE"
    LABEL="Path B (local teacher @ $TEACHER_BASE)"
    # The probe expects the full chat-completions URL.
    export TEACHER_ENDPOINT="$TEACHER_BASE/v1/chat/completions"
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    PROBE="python3 $ANTHROPIC_PROBE"
    LABEL="Path A (Anthropic API)"
else
    echo
    echo "No backend detected. Two paths to reproduce:"
    echo
    echo "  Path A (Anthropic API):"
    echo "    export ANTHROPIC_API_KEY=sk-ant-..."
    echo "    bash $0"
    echo "    (~600 calls, ~\$15-20, ~15-25 min)"
    echo
    echo "  Path B (local teacher):"
    echo "    Run a 100B+ open-weight model on any OpenAI-compatible endpoint"
    echo "    (MLX, vLLM, etc). By default this script probes http://127.0.0.1:8080."
    echo "    Override: TEACHER_ENDPOINT=http://your-host:port bash $0"
    echo
    echo "  See tools/bench/README.md for full setup."
    exit 3
fi

echo "[backend] $LABEL"
echo "[probe]   $PROBE"
echo

T0=$(date +%s)
# Capture output; tee to stdout so the operator sees progress.
LOG=$(mktemp -t repro_30of30_log.XXXXXX)
trap 'rm -f "$SMOKE_FILE" "${SMOKE_FILE%.rail}" "$LOG"' EXIT
set +e
$PROBE 2>&1 | tee "$LOG"
PROBE_EXIT=${PIPESTATUS[0]}
set -e
T1=$(date +%s)
WALL=$(( T1 - T0 ))
WALL_MIN=$(awk -v w=$WALL 'BEGIN{ printf "%.1f", w/60.0 }')

# Extract overall score: the probes print `Overall: <pass>/<total> (...)`.
SCORE=$(grep -E "^Overall: [0-9]+/[0-9]+" "$LOG" | tail -1 \
        | sed -E 's/^Overall: ([0-9]+\/[0-9]+).*/\1/')
if [[ -z "$SCORE" ]]; then
    SCORE="?/?"
fi

echo
echo "RESULT: $SCORE in $WALL_MIN min"
PASS=$(echo "$SCORE" | cut -d/ -f1)
TOTAL=$(echo "$SCORE" | cut -d/ -f2)
if [[ "$PASS" == "30" && "$TOTAL" == "30" ]]; then
    exit 0
elif [[ $PROBE_EXIT -ne 0 ]]; then
    exit $PROBE_EXIT
else
    exit 1
fi
