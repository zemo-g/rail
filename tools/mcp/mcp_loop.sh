#!/bin/bash
# mcp_loop.sh — Stdin/stdout framing for rail_mcp.rail
# Reads newline-delimited JSON-RPC from stdin, dispatches to the Rail binary,
# writes responses to stdout. Compile rail_mcp.rail first, then run this.
#
# Usage (in Claude Code settings.json):
#   {
#     "mcpServers": {
#       "rail": {
#         "command": "/Users/ledaticempire/projects/rail/tools/mcp/mcp_loop.sh"
#       }
#     }
#   }

set -euo pipefail

RAIL_DIR="${RAIL_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
MCP_BIN="/tmp/rail_mcp_bin"
REQ_FILE="/tmp/rail_mcp_req.json"

# Compile the Rail MCP server if binary is missing or stale
compile_if_needed() {
  local src="$RAIL_DIR/tools/mcp/rail_mcp.rail"
  if [ ! -f "$MCP_BIN" ] || [ "$src" -nt "$MCP_BIN" ]; then
    "$RAIL_DIR/rail_native" "$src" 2>/dev/null && cp /tmp/rail_out "$MCP_BIN" 2>/dev/null
    if [ ! -f "$MCP_BIN" ]; then
      echo '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Failed to compile rail_mcp.rail"}}' >&2
      exit 1
    fi
  fi
}

compile_if_needed
echo "rail-mcp: starting (Rail)" >&2

while IFS= read -r line; do
  # Skip empty lines
  [ -z "$line" ] && continue

  # Write request to temp file, run Rail binary, capture output
  echo "$line" > "$REQ_FILE"
  response=$("$MCP_BIN" 2>/dev/null || true)

  # Only emit non-empty responses (notifications get no response)
  if [ -n "$response" ]; then
    echo "$response"
  fi
done
