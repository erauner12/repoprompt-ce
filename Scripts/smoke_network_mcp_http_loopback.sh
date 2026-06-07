#!/usr/bin/env bash
set -euo pipefail
umask 077

ENDPOINT="${REPOPROMPT_MCP_HTTP_URL:-http://127.0.0.1:4150/mcp}"
TOKEN="${REPOPROMPT_MCP_TOKEN:-}"
RUN_CONTEXT_BUILDER="${REPOPROMPT_MCP_SMOKE_CONTEXT_BUILDER:-0}"
CONTEXT_BUILDER_START_MAX_SECONDS="${REPOPROMPT_MCP_SMOKE_CONTEXT_BUILDER_START_MAX_SECONDS:-3}"
CONTEXT_BUILDER_WAIT_DEADLINE_SECONDS="${REPOPROMPT_MCP_SMOKE_CONTEXT_BUILDER_WAIT_DEADLINE_SECONDS:-180}"

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
JOB_ID=""
JOB_SERVER_INSTANCE_ID=""
JOB_WINDOW_ID=""
JOB_COMPLETED=0
CURL_AUTH_CONFIG=""

cleanup() {
  if [[ "$RUN_CONTEXT_BUILDER" == "1" && -n "${JOB_ID:-}" && "$JOB_COMPLETED" != "1" && -n "${SESSION_ID:-}" && -f "${CURL_AUTH_CONFIG:-}" ]]; then
    local cancel_body="$TMP_DIR/context-builder-cancel.json"
    printf '{"jsonrpc":"2.0","id":98,"method":"tools/call","params":{"name":"context_builder","arguments":{"_rawJSON":true,"op":"cancel","job_id":"%s"}}}\n' "$JOB_ID" >"$cancel_body"
    env -u REPOPROMPT_MCP_TOKEN curl --silent --show-error --config "$CURL_AUTH_CONFIG" \
      --output /dev/null --request POST "$ENDPOINT" \
      --header "MCP-Session-Id: $SESSION_ID" \
      --header 'Content-Type: application/json' \
      --data-binary "@$cancel_body" >/dev/null 2>&1 || true
  fi

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
CONTEXT_BUILDER_START_BODY="$TMP_DIR/context-builder-start.json"
CONTEXT_BUILDER_START_RESPONSE="$TMP_DIR/context-builder-start.response.json"
CONTEXT_BUILDER_WAIT_BODY="$TMP_DIR/context-builder-wait.json"
CONTEXT_BUILDER_WAIT_RESPONSE="$TMP_DIR/context-builder-wait.response.json"
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
  cat >"$CONTEXT_BUILDER_START_BODY" <<'JSON'
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"context_builder","arguments":{"_rawJSON":true,"op":"start","instructions":"Network MCP loopback smoke: build a concise context summary for the active workspace."}}}
JSON

  start_result="$(env -u REPOPROMPT_MCP_TOKEN curl --silent --show-error --config "$CURL_AUTH_CONFIG" \
    --output "$CONTEXT_BUILDER_START_RESPONSE" --write-out '%{http_code} %{time_total}' \
    --request POST "$ENDPOINT" \
    --header "MCP-Session-Id: $SESSION_ID" \
    --header 'Content-Type: application/json' \
    --data-binary "@$CONTEXT_BUILDER_START_BODY")"
  start_status="${start_result%% *}"
  start_seconds="${start_result#* }"
  [[ "$start_status" == "200" ]] || fail "context_builder op=start returned HTTP $start_status: $(cat "$CONTEXT_BUILDER_START_RESPONSE")"

  start_metadata="$(python3 - "$CONTEXT_BUILDER_START_RESPONSE" "$CONTEXT_BUILDER_START_MAX_SECONDS" "$start_seconds" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding='utf-8'))
max_seconds = float(sys.argv[2])
elapsed = float(sys.argv[3])
if elapsed > max_seconds:
    raise SystemExit(f"context_builder op=start took {elapsed:.3f}s, above {max_seconds:.3f}s")
try:
    text = payload['result']['content'][0]['text']
    envelope = json.loads(text)
except Exception as exc:
    raise SystemExit(f"context_builder op=start did not return raw JSON envelope: {payload!r} ({exc})")
if envelope.get('kind') != 'mcp_resumable_job':
    raise SystemExit(f"context_builder op=start returned non-job envelope: {envelope}")
if envelope.get('status') not in ('queued', 'running', 'completed'):
    raise SystemExit(f"context_builder op=start returned unexpected status: {envelope}")
job_id = envelope.get('job_id')
if not job_id:
    raise SystemExit(f"context_builder op=start did not return job_id: {envelope}")
server_instance_id = envelope.get('server_instance_id') or ''
window_id = envelope.get('window_id')
print(job_id)
print(server_instance_id)
print('' if window_id is None else window_id)
PY
)"
  JOB_ID="$(printf '%s\n' "$start_metadata" | sed -n '1p')"
  JOB_SERVER_INSTANCE_ID="$(printf '%s\n' "$start_metadata" | sed -n '2p')"
  JOB_WINDOW_ID="$(printf '%s\n' "$start_metadata" | sed -n '3p')"
  printf 'OK: context_builder op=start returned job_id=%s in %ss\n' "$JOB_ID" "$start_seconds"

  deadline=$((SECONDS + CONTEXT_BUILDER_WAIT_DEADLINE_SECONDS))
  while :; do
    python3 - "$CONTEXT_BUILDER_WAIT_BODY" "$JOB_ID" "$JOB_SERVER_INSTANCE_ID" "$JOB_WINDOW_ID" <<'PY'
import json, sys
body = {
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": {
        "name": "context_builder",
        "arguments": {
            "_rawJSON": True,
            "op": "wait",
            "job_id": sys.argv[2],
            "timeout": 25,
        },
    },
}
arguments = body["params"]["arguments"]
if sys.argv[3]:
    arguments["server_instance_id"] = sys.argv[3]
if sys.argv[4]:
    arguments["window_id"] = int(sys.argv[4])
with open(sys.argv[1], 'w', encoding='utf-8') as handle:
    json.dump(body, handle, separators=(',', ':'))
PY

    wait_status="$(env -u REPOPROMPT_MCP_TOKEN curl --silent --show-error --config "$CURL_AUTH_CONFIG" \
      --output "$CONTEXT_BUILDER_WAIT_RESPONSE" --write-out '%{http_code}' \
      --request POST "$ENDPOINT" \
      --header "MCP-Session-Id: $SESSION_ID" \
      --header 'Content-Type: application/json' \
      --data-binary "@$CONTEXT_BUILDER_WAIT_BODY")"
    [[ "$wait_status" == "200" ]] || fail "context_builder op=wait returned HTTP $wait_status: $(cat "$CONTEXT_BUILDER_WAIT_RESPONSE")"

    wait_summary="$(python3 - "$CONTEXT_BUILDER_WAIT_RESPONSE" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding='utf-8'))
try:
    envelope = json.loads(payload['result']['content'][0]['text'])
except Exception as exc:
    raise SystemExit(f"context_builder op=wait did not return raw JSON envelope: {payload!r} ({exc})")
status = envelope.get('status')
wait_result = (envelope.get('wait') or {}).get('result')
print(f"{status} {wait_result or ''}".strip())
if status == 'completed':
    if not envelope.get('result_available') or not isinstance(envelope.get('result'), dict):
        raise SystemExit(f"context_builder completed without nested result object: {envelope}")
    raise SystemExit(0)
if status in ('failed', 'cancelled', 'expired', 'not_found', 'server_restarted'):
    raise SystemExit(f"context_builder ended with terminal status {status}: {envelope}")
raise SystemExit(2)
PY
)" && wait_code=0 || wait_code=$?
    printf 'context_builder op=wait: %s\n' "$wait_summary"
    [[ "$wait_code" -eq 0 ]] && break
    [[ "$wait_code" -eq 2 ]] || fail "$wait_summary"
    [[ "$SECONDS" -lt "$deadline" ]] || fail "context_builder op=wait did not complete within ${CONTEXT_BUILDER_WAIT_DEADLINE_SECONDS}s"
  done
  JOB_COMPLETED=1
  printf 'OK: context_builder op=wait completed resumable job %s\n' "$JOB_ID"
else
  printf 'SKIP: set REPOPROMPT_MCP_SMOKE_CONTEXT_BUILDER=1 to run the optional resumable context_builder smoke (requires an active default workspace and provider credentials).\n'
fi

delete_status="$(env -u REPOPROMPT_MCP_TOKEN curl --silent --show-error --config "$CURL_AUTH_CONFIG" \
  --output /dev/null --write-out '%{http_code}' \
  --request DELETE "$ENDPOINT" \
  --header "MCP-Session-Id: $SESSION_ID")"
[[ "$delete_status" == "200" ]] || fail "DELETE returned HTTP $delete_status"
SESSION_CLOSED=1
printf 'OK: DELETE returned HTTP %s\n' "$delete_status"
