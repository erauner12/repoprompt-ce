#!/usr/bin/env bash
set -euo pipefail
umask 077

ENDPOINT="${REPOPROMPT_MCP_HTTP_URL:-http://127.0.0.1:4150/mcp}"
TOKEN="${REPOPROMPT_MCP_TOKEN:-}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
[[ -n "$TOKEN" ]] || fail "Set REPOPROMPT_MCP_TOKEN to a Network MCP bearer token copied from RepoPrompt Settings"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/repoprompt-network-mcp-smoke.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

INITIALIZE_BODY="$TMP_DIR/initialize.json"
INITIALIZE_HEADERS="$TMP_DIR/initialize.headers"
INITIALIZE_RESPONSE="$TMP_DIR/initialize.response.json"
TOOLS_RESPONSE="$TMP_DIR/tools.response.json"
CURL_AUTH_CONFIG="$TMP_DIR/curl-auth.cfg"

printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" >"$CURL_AUTH_CONFIG"

cat >"$INITIALIZE_BODY" <<'JSON'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"RepoPrompt Network MCP loopback smoke","version":"1.0"},"capabilities":{}}}
JSON

status="$(env -u REPOPROMPT_MCP_TOKEN curl --silent --show-error --config "$CURL_AUTH_CONFIG" \
  --output "$INITIALIZE_RESPONSE" --dump-header "$INITIALIZE_HEADERS" --write-out '%{http_code}' \
  --request POST "$ENDPOINT" \
  --header 'Content-Type: application/json' \
  --data-binary "@$INITIALIZE_BODY")"
[[ "$status" == "200" ]] || fail "initialize returned HTTP $status: $(cat "$INITIALIZE_RESPONSE")"

SESSION_ID="$(python3 - "$INITIALIZE_HEADERS" <<'PY'
import sys
from pathlib import Path
for line in Path(sys.argv[1]).read_text().splitlines():
    if line.lower().startswith('mcp-session-id:'):
        print(line.split(':', 1)[1].strip())
        break
PY
)"
[[ -n "$SESSION_ID" ]] || fail "initialize response did not include MCP-Session-Id"

python3 - "$INITIALIZE_RESPONSE" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding='utf-8'))
if payload.get('id') != 1 or 'result' not in payload:
    raise SystemExit(f"initialize did not return a JSON-RPC result: {payload}")
PY

notify_status="$(env -u REPOPROMPT_MCP_TOKEN curl --silent --show-error --config "$CURL_AUTH_CONFIG" \
  --output /dev/null --write-out '%{http_code}' \
  --request POST "$ENDPOINT" \
  --header "MCP-Session-Id: $SESSION_ID" \
  --header 'Content-Type: application/json' \
  --data-binary '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}')"
[[ "$notify_status" == "202" ]] || fail "notifications/initialized returned HTTP $notify_status"

tools_status="$(env -u REPOPROMPT_MCP_TOKEN curl --silent --show-error --config "$CURL_AUTH_CONFIG" \
  --output "$TOOLS_RESPONSE" --write-out '%{http_code}' \
  --request POST "$ENDPOINT" \
  --header "MCP-Session-Id: $SESSION_ID" \
  --header 'Content-Type: application/json' \
  --data-binary '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')"
[[ "$tools_status" == "200" ]] || fail "tools/list returned HTTP $tools_status: $(cat "$TOOLS_RESPONSE")"

python3 - "$TOOLS_RESPONSE" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding='utf-8'))
tools = payload.get('result', {}).get('tools')
if not isinstance(tools, list) or not tools:
    raise SystemExit(f"tools/list did not return non-empty tools: {payload}")
print(f"OK: tools/list returned {len(tools)} tool(s); first={tools[0].get('name', '<unnamed>')}")
PY

delete_status="$(env -u REPOPROMPT_MCP_TOKEN curl --silent --show-error --config "$CURL_AUTH_CONFIG" \
  --output /dev/null --write-out '%{http_code}' \
  --request DELETE "$ENDPOINT" \
  --header "MCP-Session-Id: $SESSION_ID")"
[[ "$delete_status" == "200" ]] || fail "DELETE returned HTTP $delete_status"
printf 'OK: DELETE returned HTTP %s\n' "$delete_status"
