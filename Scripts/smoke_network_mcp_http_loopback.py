#!/usr/bin/env python3
"""Loopback smoke test for RepoPrompt Network MCP Streamable HTTP.

Environment:
  REPOPROMPT_MCP_HTTP_URL                         default: http://127.0.0.1:4150/mcp
  REPOPROMPT_MCP_TOKEN                            required
  REPOPROMPT_MCP_PROTOCOL_VERSION                 default: 2025-11-25
  REPOPROMPT_MCP_SMOKE_CONTEXT_BUILDER            set to 1 to run optional context_builder call
  REPOPROMPT_MCP_SMOKE_CONTEXT_BUILDER_TIMEOUT_SECONDS default: 300
  REPOPROMPT_MCP_SMOKE_CONTEXT_BUILDER_TOLERATE_INCOMPLETE set to 1 to warn instead of fail on incomplete context_builder status
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Dict, List, Optional


DEFAULT_ENDPOINT = "http://127.0.0.1:4150/mcp"
DEFAULT_PROTOCOL_VERSION = "2025-11-25"


class SmokeError(RuntimeError):
    pass


@dataclass(frozen=True)
class HTTPResult:
    status: int
    headers: urllib.response.addinfourl
    body: bytes

    def text(self) -> str:
        return self.body.decode("utf-8", errors="replace")

    def json(self) -> Dict[str, Any]:
        try:
            payload = json.loads(self.body.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise SmokeError(f"response was not valid JSON: {self.text()}") from exc
        if not isinstance(payload, dict):
            raise SmokeError(f"response JSON was not an object: {payload!r}")
        return payload

    def jsonrpc_payloads(self) -> List[Dict[str, Any]]:
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type == "application/json":
            return [self.json()]
        if content_type == "text/event-stream":
            return parse_sse_json_payloads(self.text())
        raise SmokeError(f"response Content-Type was not JSON or SSE: {self.headers.get('Content-Type', '<missing>')}")


@dataclass
class SmokeClient:
    endpoint: str
    token: str
    session_id: Optional[str] = None
    session_closed: bool = False

    def post_json(self, payload: Dict[str, Any], *, timeout: Optional[float] = None) -> HTTPResult:
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.session_id:
            headers["MCP-Session-Id"] = self.session_id
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        return self.request("POST", headers=headers, body=body, timeout=timeout)

    def delete_session(self) -> HTTPResult:
        if not self.session_id:
            raise SmokeError("cannot DELETE before initialize returns MCP-Session-Id")
        return self.request(
            "DELETE",
            headers={
                "Authorization": f"Bearer {self.token}",
                "MCP-Session-Id": self.session_id,
            },
            body=None,
            timeout=30,
        )

    def request(
        self,
        method: str,
        *,
        headers: Dict[str, str],
        body: Optional[bytes],
        timeout: Optional[float],
    ) -> HTTPResult:
        request = urllib.request.Request(
            self.endpoint,
            data=body,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return HTTPResult(
                    status=response.status,
                    headers=response.headers,
                    body=response.read(),
                )
        except urllib.error.HTTPError as exc:
            return HTTPResult(status=exc.code, headers=exc.headers, body=exc.read())
        except urllib.error.URLError as exc:
            raise SmokeError(f"{method} {self.endpoint} failed: {exc.reason}") from exc
        except TimeoutError as exc:
            raise SmokeError(f"{method} {self.endpoint} timed out after {timeout}s") from exc

    def cleanup(self) -> None:
        if self.session_closed or not self.session_id:
            return
        try:
            self.delete_session()
        except Exception:
            pass


def jsonrpc_request(request_id: int, method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    payload: Dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        payload["params"] = params
    return payload


def jsonrpc_notification(method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    payload: Dict[str, Any] = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        payload["params"] = params
    return payload


def parse_sse_json_payloads(text: str) -> List[Dict[str, Any]]:
    payloads: List[Dict[str, Any]] = []
    data_lines: List[str] = []

    def flush_event() -> None:
        if not data_lines:
            return
        data = "\n".join(data_lines)
        data_lines.clear()
        if data == "[DONE]":
            return
        try:
            payload = json.loads(data)
        except json.JSONDecodeError as exc:
            raise SmokeError(f"SSE data frame was not valid JSON: {data}") from exc
        if not isinstance(payload, dict):
            raise SmokeError(f"SSE JSON payload was not an object: {payload!r}")
        payloads.append(payload)

    for line in text.splitlines():
        if line == "":
            flush_event()
        elif line.startswith("data:"):
            value = line[5:]
            if value.startswith(" "):
                value = value[1:]
            data_lines.append(value)
    flush_event()

    if not payloads:
        raise SmokeError(f"SSE response did not contain JSON data frames: {text}")
    return payloads


def require_status(result: HTTPResult, expected: int, label: str) -> None:
    if result.status != expected:
        raise SmokeError(f"{label} returned HTTP {result.status}: {result.text()}")


def require_jsonrpc_result(result: HTTPResult, request_id: int, label: str) -> Dict[str, Any]:
    for payload in result.jsonrpc_payloads():
        if payload.get("id") == request_id and "result" in payload:
            jsonrpc_result = payload["result"]
            if not isinstance(jsonrpc_result, dict):
                raise SmokeError(f"{label} JSON-RPC result was not an object: {payload!r}")
            return jsonrpc_result
    raise SmokeError(f"{label} did not return a JSON-RPC result for id={request_id}: {result.text()}")


def initialize(client: SmokeClient, protocol_version: str) -> None:
    result = client.post_json(
        jsonrpc_request(
            1,
            "initialize",
            {
                "protocolVersion": protocol_version,
                "clientInfo": {
                    "name": "RepoPrompt Network MCP loopback smoke",
                    "version": "1.0",
                },
                "capabilities": {},
            },
        ),
        timeout=30,
    )
    require_status(result, 200, "initialize")
    require_jsonrpc_result(result, 1, "initialize")

    session_id = result.headers.get("MCP-Session-Id")
    if not session_id:
        raise SmokeError("initialize response did not include MCP-Session-Id")
    client.session_id = session_id


def send_initialized(client: SmokeClient) -> None:
    result = client.post_json(
        jsonrpc_notification("notifications/initialized", {}),
        timeout=30,
    )
    require_status(result, 202, "notifications/initialized")


def list_tools(client: SmokeClient) -> None:
    result = client.post_json(jsonrpc_request(2, "tools/list", {}), timeout=30)
    require_status(result, 200, "tools/list")
    payload = require_jsonrpc_result(result, 2, "tools/list")
    tools = payload.get("tools")
    if not isinstance(tools, list) or not tools:
        raise SmokeError(f"tools/list did not return non-empty tools: {payload!r}")
    first = tools[0].get("name", "<unnamed>") if isinstance(tools[0], dict) else "<unnamed>"
    print(f"OK: tools/list returned {len(tools)} tool(s); first={first}")


def run_context_builder(client: SmokeClient, timeout_seconds: float) -> None:
    body = jsonrpc_request(
        3,
        "tools/call",
        {
            "name": "context_builder",
            "arguments": {
                "_rawJSON": True,
                "instructions": "Network MCP loopback smoke: build a concise context summary for the active workspace.",
            },
        },
    )
    started = time.monotonic()
    result = client.post_json(body, timeout=timeout_seconds)
    elapsed = time.monotonic() - started
    require_status(result, 200, "context_builder tools/call")
    payload = require_jsonrpc_result(result, 3, "context_builder tools/call")
    try:
        content = payload["content"]
        text = content[0]["text"]
        tool_result = json.loads(text)
    except (KeyError, IndexError, TypeError, json.JSONDecodeError) as exc:
        raise SmokeError(f"context_builder did not return raw JSON result content: {payload!r}") from exc

    status = tool_result.get("status")
    tolerate_incomplete = os.environ.get("REPOPROMPT_MCP_SMOKE_CONTEXT_BUILDER_TOLERATE_INCOMPLETE", "0") == "1"
    if status != "completed":
        if not tolerate_incomplete:
            raise SmokeError(f"context_builder did not complete successfully: {tool_result!r}")
        print(
            "WARNING: context_builder did not complete successfully; continuing because "
            "REPOPROMPT_MCP_SMOKE_CONTEXT_BUILDER_TOLERATE_INCOMPLETE=1 "
            f"(status={status})",
            file=sys.stderr,
        )
    if not tool_result.get("context_id"):
        raise SmokeError(f"context_builder result did not include context_id: {tool_result!r}")
    print(
        "OK: context_builder tools/call completed "
        f"with status={status} context_id={tool_result.get('context_id')}"
    )
    print(f"OK: context_builder synchronous tools/call returned in {elapsed:.3f}s")


def parse_timeout_seconds(value: str) -> float:
    try:
        timeout = float(value)
    except ValueError as exc:
        raise SmokeError("REPOPROMPT_MCP_SMOKE_CONTEXT_BUILDER_TIMEOUT_SECONDS must be numeric") from exc
    if timeout <= 0:
        raise SmokeError("REPOPROMPT_MCP_SMOKE_CONTEXT_BUILDER_TIMEOUT_SECONDS must be positive")
    return timeout


def run() -> None:
    endpoint = os.environ.get("REPOPROMPT_MCP_HTTP_URL", DEFAULT_ENDPOINT)
    token = os.environ.get("REPOPROMPT_MCP_TOKEN", "")
    protocol_version = os.environ.get("REPOPROMPT_MCP_PROTOCOL_VERSION", DEFAULT_PROTOCOL_VERSION)
    if not token:
        raise SmokeError("Set REPOPROMPT_MCP_TOKEN to a Network MCP bearer token copied from RepoPrompt Settings")

    client = SmokeClient(endpoint=endpoint, token=token)
    try:
        initialize(client, protocol_version)
        send_initialized(client)
        list_tools(client)

        if os.environ.get("REPOPROMPT_MCP_SMOKE_CONTEXT_BUILDER", "0") == "1":
            timeout_seconds = parse_timeout_seconds(
                os.environ.get("REPOPROMPT_MCP_SMOKE_CONTEXT_BUILDER_TIMEOUT_SECONDS", "300")
            )
            run_context_builder(client, timeout_seconds)
        else:
            print(
                "SKIP: set REPOPROMPT_MCP_SMOKE_CONTEXT_BUILDER=1 to run the optional "
                "synchronous context_builder smoke over Streamable HTTP SSE (requires an active "
                "default workspace and provider credentials)."
            )

        delete_result = client.delete_session()
        require_status(delete_result, 200, "DELETE")
        client.session_closed = True
        print(f"OK: DELETE returned HTTP {delete_result.status}")
    finally:
        client.cleanup()


def main() -> int:
    try:
        run()
        return 0
    except SmokeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
