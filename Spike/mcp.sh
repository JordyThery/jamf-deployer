#!/bin/zsh
# Phase 0 helper: call a Jamf Developer MCP tool over HTTPS.
# Usage: mcp.sh <tool-name> '<json-arguments>'
set -euo pipefail
TOOL="$1"
ARGS="${2:-EMPTY}"
if [[ "$ARGS" == "EMPTY" ]]; then ARGS="{}"; fi
curl -s -X POST https://developer.jamf.com/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2025-06-18" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$TOOL\",\"arguments\":$ARGS}}" \
  | sed 's/^data: //' | grep -v '^event:' | python3 -c '
import json, sys
lines = [l for l in sys.stdin if l.strip()]
d = json.loads(lines[0])
if "error" in d:
    print("MCP ERROR:", json.dumps(d["error"]))
    sys.exit(1)
for c in d["result"]["content"]:
    print(c.get("text", json.dumps(c)))
'
