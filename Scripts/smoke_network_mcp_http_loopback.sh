#!/usr/bin/env bash
set -euo pipefail
umask 077

ENDPOINT="${REPOPROMPT_MCP_HTTP_URL:-http://127.0.0.1:4150/mcp}"
TOKEN="${REPOPROMPT_MCP_TOKEN:-}"
RUN_CONTEXT_BUILDER="${REPOPROMPT_MCP_SMOKE_CONTEXT_BUILDER:-0}"
CONTEXT_BUILDER_TIMEOUT_SECONDS="${REPOPROMPT_MCP_SMOKE_CONTEXT_BUILDER_TIMEOUT_SECONDS:-300}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
[[ -n "$TOKEN" ]] || fail "Set REPOPROMPT_MCP_TOKEN to a Network MCP bearer token copied from RepoPrompt Settings"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/repoprompt-network-mcp-smoke.XXXXXX")"
SESSION_ID=""
SESSION_CLOSED=0
CURL_AUTH_CONFIG=""

cleanup() {
  if [[ "$SESSION_CLOSED" != "1" && -n "${SESSION_ID:-}" && -f "${CURL_AUTH_CONFIG:-}" ]]; then
    env -u REPOPROMPT_MCP_TOKEN curl --silent --show-error --config "$CURL_AUTH_CONFIG" \
      --output /dev/null --request DELETE "$ENDPOINT" \
      --header "MCP-Session-Id: $SESSION_ID" >/dev/null 2>&1 || true
  fi

  rm -rf "$TMP_DIR"
}
trap 'status=$?; cleanup; exit "$status"' EXIT

INITIALIZE_BODY="$TMP_DIR/initialize.json"
INITIALIZE_HEADERS="$TMP_DIR/initialize.headers"
INITIALIZE_RESPONSE="$TMP_DIR/initialize.response.json"
TOOLS_RESPONSE="$TMP_DIR/tools.response.json"
CONTEXT_BUILDER_BODY="$TMP_DIR/context-builder.json"
CONTEXT_BUILDER_RESPONSE="$TMP_DIR/context-builder.response.json"
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

if [[ "$RUN_CONTEXT_BUILDER" == "1" ]]; then
  cat >"$CONTEXT_BUILDER_BODY" <<'JSON'
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"context_builder","arguments":{"_rawJSON":true,"instructions":"Network MCP loopback smoke: build a concise context summary for the active workspace."}}}
JSON

  context_builder_result="$(env -u REPOPROMPT_MCP_TOKEN curl --silent --show-error --config "$CURL_AUTH_CONFIG" \
    --max-time "$CONTEXT_BUILDER_TIMEOUT_SECONDS" \
    --output "$CONTEXT_BUILDER_RESPONSE" --write-out '%{http_code} %{time_total}' \
    --request POST "$ENDPOINT" \
    --header "MCP-Session-Id: $SESSION_ID" \
    --header 'Content-Type: application/json' \
    --data-binary "@$CONTEXT_BUILDER_BODY")"
  context_builder_status="${context_builder_result%% *}"
  context_builder_seconds="${context_builder_result#* }"
  [[ "$context_builder_status" == "200" ]] || fail "context_builder tools/call returned HTTP $context_builder_status: $(cat "$CONTEXT_BUILDER_RESPONSE")"

  python3 - "$CONTEXT_BUILDER_RESPONSE" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding='utf-8'))
try:
    text = payload['result']['content'][0]['text']
    result = json.loads(text)
except Exception as exc:
    raise SystemExit(f"context_builder did not return raw JSON result content: {payload!r} ({exc})")
if result.get('status') not in ('completed', 'cancelled') and not str(result.get('status', '')).startswith('failed:'):
    raise SystemExit(f"context_builder returned unexpected status: {result}")
if not result.get('context_id'):
    raise SystemExit(f"context_builder result did not include context_id: {result}")
print(f"OK: context_builder tools/call completed with status={result.get('status')} context_id={result.get('context_id')}")
PY
  printf 'OK: context_builder synchronous tools/call returned in %ss\n' "$context_builder_seconds"
else
  printf 'SKIP: set REPOPROMPT_MCP_SMOKE_CONTEXT_BUILDER=1 to run the optional synchronous context_builder smoke over Streamable HTTP SSE (requires an active default workspace and provider credentials).\n'
fi

delete_status="$(env -u REPOPROMPT_MCP_TOKEN curl --silent --show-error --config "$CURL_AUTH_CONFIG" \
  --output /dev/null --write-out '%{http_code}' \
  --request DELETE "$ENDPOINT" \
  --header "MCP-Session-Id: $SESSION_ID")"
[[ "$delete_status" == "200" ]] || fail "DELETE returned HTTP $delete_status"
SESSION_CLOSED=1
printf 'OK: DELETE returned HTTP %s\n' "$delete_status"
