#!/bin/bash
# llm_call.sh — Call local LLM, return content
# Usage: llm_call.sh /tmp/sys.txt /tmp/user.txt temperature
# Reads system prompt from file 1, user prompt from file 2

SYS_FILE="$1"
USER_FILE="$2"
TEMP="$3"

python3 -c "
import json, urllib.request
sys_p = open('$SYS_FILE').read()
usr_p = open('$USER_FILE').read()
body = json.dumps({
    'model': 'default',
    'temperature': float('$TEMP'),
    'max_tokens': 1024,
    'chat_template_kwargs': {'enable_thinking': False},
    'messages': [
        {'role': 'system', 'content': sys_p},
        {'role': 'user', 'content': usr_p}
    ]
})
req = urllib.request.Request(
    'http://localhost:8080/v1/chat/completions',
    data=body.encode(),
    headers={'Content-Type': 'application/json'}
)
resp = json.loads(urllib.request.urlopen(req, timeout=60).read())
print(resp['choices'][0]['message']['content'])
" 2>/dev/null || echo "LLM_ERROR"
