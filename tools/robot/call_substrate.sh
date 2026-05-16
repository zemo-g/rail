#!/bin/sh
# tools/robot/call_substrate.sh
#
# Minimal one-shot caller for the MLX server. Reads system prompt
# from arg1, user prompt from arg2, posts to localhost:$PORT, and
# emits the assistant content on stdout.
#
# Bypasses stdlib/llm.rail (whose escape pipeline produces \<CR>n
# instead of \n in the current build, breaking JSON for any prompt
# that contains a newline).
#
# Usage:
#   sh tools/robot/call_substrate.sh <sys_file> <user_prompt_string>
#
# Env:
#   PORT (default 8082)
#   MAX_TOKENS (default 1024) — must be > thinking tokens or content empty
#   TEMPERATURE (default 0.3)
#   ENABLE_THINKING (default false)

set -u
PORT="${PORT:-8082}"
MAX_TOKENS="${MAX_TOKENS:-1024}"
TEMPERATURE="${TEMPERATURE:-0.3}"
ENABLE_THINKING="${ENABLE_THINKING:-false}"

sys_file="$1"
user_prompt="$2"

# Use jq to construct the JSON payload safely (handles all escaping).
payload=$(jq -n \
  --rawfile sys "$sys_file" \
  --arg user "$user_prompt" \
  --argjson max "$MAX_TOKENS" \
  --argjson temp "$TEMPERATURE" \
  --argjson thinking "$ENABLE_THINKING" \
  '{
    messages: [
      {role: "system", content: $sys},
      {role: "user", content: $user}
    ],
    max_tokens: $max,
    temperature: $temp,
    chat_template_kwargs: {enable_thinking: $thinking}
  }')

# POST and extract content. Keep reasoning OUT (we don't want it in
# the candidate file even when thinking is on).
curl -sS --max-time 120 "http://localhost:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "$payload" \
  | jq -r '.choices[0].message.content // ""'
