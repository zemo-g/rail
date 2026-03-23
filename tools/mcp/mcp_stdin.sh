#!/bin/bash
# mcp_stdin.sh — Read one line from stdin, write to temp file.
# Used by rail_mcp.rail since Rail has no native stdin reading.
# Returns exit code 1 on EOF.
IFS= read -r line
if [ $? -ne 0 ]; then
  exit 1
fi
echo "$line"
