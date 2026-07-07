#!/usr/bin/env python3
"""Live Director/Coordinator mission E2E runner.

The script intentionally asserts structured invariants from coordinator_chat
status payloads instead of transcript text.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable


TERMINAL_STATUSES = {"completed", "stopped", "cancelled", "skipped"}
STATUS_RANK = {
    "pending": 0,
    "running": 1,
    "blocked": 1,
    "completed": 2,
    "skipped": 2,
    "cancelled": 2,
}


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


class E2EFailure(AssertionError):
    """Raised for scenario assertion failures."""


@dataclass
class CommandRecord:
    index: int
    label: str
    argv: list[str]
    returncode: int
    stdout: str
    stderr: str


@dataclass
class Observation:
    index: int
    compact: dict[str, Any]
    full: dict[str, Any]
    observed_at: str = field(default_factory=utc_now_iso)

    @property
    def fingerprint(self) -> str:
        return str(self.compact.get("fingerprint") or "")

    @property
    def plan(self) -> dict[str, Any]:
        return self.compact.get("plan") or {}

    @property
    def status(self) -> str:
        return str(self.plan.get("status") or "")

    @property
    def nodes(self) -> list[dict[str, Any]]:
        return list(self.full.get("nodes") or [])


@dataclass
class RunArtifacts:
    root: Path
    command_records: list[CommandRecord] = field(default_factory=list)
    observations: list[Observation] = field(default_factory=list)
    checkpoints: list[str] = field(default_factory=list)
    features: dict[str, dict[str, Any]] = field(default_factory=dict)
    timings: dict[str, str] = field(default_factory=dict)
    violations: list[dict[str, Any]] = field(default_factory=list)
    mission_events: list[dict[str, Any]] = field(default_factory=list)
    event_since_seq: int = 0
    report: dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root / "statuses").mkdir(exist_ok=True)

    def record_command(self, record: CommandRecord) -> None:
        self.command_records.append(record)
        append_jsonl(self.root / "commands.jsonl", {
            "index": record.index,
            "label": record.label,
            "argv": record.argv,
            "returncode": record.returncode,
            "stdout": record.stdout,
            "stderr": record.stderr,
        })

    def record_observation(self, observation: Observation) -> None:
        self.observations.append(observation)
        write_json(self.root / "statuses" / f"{observation.index:03d}-compact.json", observation.compact)
        write_json(self.root / "statuses" / f"{observation.index:03d}-full.json", observation.full)
        append_jsonl(self.root / "status_history.jsonl", {
            "index": observation.index,
            "observed_at": observation.observed_at,
            "fingerprint": observation.fingerprint,
            "signature": observation_signature(observation),
            "compact": observation.compact,
        })

    def add_checkpoint(self, name: str) -> None:
        if name not in self.checkpoints:
            self.checkpoints.append(name)
            self.record_timing(name)
            print(f"[visual-checkpoint] {name}", flush=True)

    def record_timing(self, name: str) -> None:
        self.timings[name] = utc_now_iso()
        write_json(self.root / "timings.json", self.timings)

    def record_feature(self, name: str, available: bool, detail: str | None = None) -> None:
        self.features[name] = {
            "available": available,
            "detail": detail,
            "checked_at": utc_now_iso(),
        }
        write_json(self.root / "features.json", self.features)

    def feature_available(self, name: str) -> bool | None:
        current = self.features.get(name)
        if current is None:
            return None
        return bool(current.get("available"))

    def record_event(self, event: dict[str, Any]) -> None:
        self.mission_events.append(event)
        append_jsonl(self.root / "events.jsonl", event)

    def record_violation(self, violation: dict[str, Any]) -> None:
        self.violations.append(violation)
        append_jsonl(self.root / "violations.jsonl", violation)

    def finalize(self, passed: bool, scenario: str, extra: dict[str, Any] | None = None) -> None:
        final_compact = self.observations[-1].compact if self.observations else None
        final_full = self.observations[-1].full if self.observations else None
        receipt = (final_compact or {}).get("receipt_ready_summary")
        self.report = {
            "scenario": scenario,
            "passed": passed,
            "artifact_dir": str(self.root),
            "observation_count": len(self.observations),
            "checkpoints": self.checkpoints,
            "features": self.features,
            "timings": self.timings,
            "violation_count": len(self.violations),
            "violations": self.violations,
            "final_compact": final_compact,
            "final_full": final_full,
            "receipt_ready_summary": receipt,
        }
        if extra:
            self.report.update(extra)
        write_json(self.root / "report.json", self.report)
        if receipt:
            write_json(self.root / "receipt_ready_summary.json", receipt)


class RpcClient:
    def __init__(self, cli: str, window: int, repo_root: Path, artifacts: RunArtifacts):
        self.cli = cli
        self.window = window
        self.repo_root = repo_root
        self.artifacts = artifacts

    def run(self, label: str, argv: list[str], timeout: int = 120) -> str:
        proc = subprocess.run(
            argv,
            cwd=self.repo_root,
            text=True,
            capture_output=True,
            timeout=timeout,
        )
        record = CommandRecord(
            index=len(self.artifacts.command_records),
            label=label,
            argv=argv,
            returncode=proc.returncode,
            stdout=proc.stdout,
            stderr=proc.stderr,
        )
        self.artifacts.record_command(record)
        if proc.returncode != 0:
            detail = "\n".join(part for part in [proc.stderr.strip(), proc.stdout.strip()] if part)
            raise E2EFailure(f"{label} failed with exit {proc.returncode}: {detail[:4000]}")
        return proc.stdout

    def exec_text(self, label: str, expression: str, timeout: int = 120) -> str:
        return self.run(label, [self.cli, "-w", str(self.window), "-e", expression], timeout=timeout)

    def call(self, command: str, payload: dict[str, Any], timeout: int = 120) -> dict[str, Any]:
        routed = dict(payload)
        routed["_windowID"] = self.window
        stdout = self.run(
            f"{command}:{payload.get('op', 'op')}",
            [self.cli, "-w", str(self.window), "-c", command, "-j", json.dumps(routed)],
            timeout=timeout,
        )
        return parse_cli_json(stdout)

    def coordinator(self, payload: dict[str, Any], timeout: int = 120) -> dict[str, Any]:
        return self.call("coordinator_chat", payload, timeout=timeout)

    def try_coordinator(self, payload: dict[str, Any], timeout: int = 120) -> tuple[bool, dict[str, Any]]:
        try:
            return True, self.coordinator(payload, timeout=timeout)
        except E2EFailure as exc:
            message = str(exc)
            if coordinator_op_unsupported(message):
                return False, {"error": message}
            raise


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def append_jsonl(path: Path, value: Any) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(value, sort_keys=True) + "\n")


def coordinator_op_unsupported(message: str) -> bool:
    lowered = message.lower()
    unsupported_markers = [
        "unsupported coordinator_chat op",
        "unknown coordinator_chat op",
        "unknown operation",
        "invalid arguments",
        "invalid enum value",
        "allowed values",
        "expected one of",
        "op must be one of",
        "not supported",
    ]
    return any(marker in lowered for marker in unsupported_markers)


def parse_cli_json(stdout: str) -> dict[str, Any]:
    stripped = stdout.strip()
    if not stripped:
        raise E2EFailure("CLI returned empty output")
    try:
        parsed = json.loads(stripped)
        if isinstance(parsed, dict):
            return parsed
    except json.JSONDecodeError:
        pass
    for line in stripped.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            parsed = json.loads(line)
            if isinstance(parsed, dict):
                return parsed
        except json.JSONDecodeError:
            continue
    match = re.search(r"(\{.*\})", stripped, flags=re.DOTALL)
    if match:
        try:
            parsed = json.loads(match.group(1))
            if isinstance(parsed, dict):
                return parsed
        except json.JSONDecodeError:
            pass
    raise E2EFailure(f"Could not parse JSON from CLI output: {stripped[:500]}")


def resolve_debug_cli() -> str:
    override = os.environ.get("REPOPROMPT_DEBUG_CLI_INSTALL_PATH")
    candidates = [
        Path(override).expanduser() if override else None,
        Path(shutil.which("rpce-cli-debug")).expanduser() if shutil.which("rpce-cli-debug") else None,
        Path.home() / "Library/Application Support/RepoPrompt CE/repoprompt_ce_cli_debug",
        Path.home() / "Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/repoprompt-mcp",
    ]
    for candidate in candidates:
        if candidate and candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    raise E2EFailure("Could not resolve rpce-cli-debug. Run make install-debug-cli or set REPOPROMPT_DEBUG_CLI_INSTALL_PATH.")


def ensure_workspace(client: RpcClient, workspace: str) -> None:
    client.run("windows", [client.cli, "-e", "windows"])
    try:
        client.exec_text("workspace switch", f"workspace switch {workspace}")
    except E2EFailure as exc:
        if f'Already on workspace "{workspace}"' not in str(exc):
            raise


def tree_roots_text(client: RpcClient) -> str:
    return client.exec_text("tree roots", "tree --type roots")


def visible_workspace_roots(tree_roots_output: str) -> list[Path]:
    roots: list[Path] = []
    for line in tree_roots_output.splitlines():
        candidate = line.strip()
        if "→" in candidate:
            candidate = candidate.rsplit("→", 1)[1].strip()
        if not candidate.startswith("/"):
            continue
        roots.append(Path(candidate).expanduser().resolve())
    return roots


def sandbox_is_visible_from_roots(sandbox_root: Path, roots: Iterable[Path]) -> bool:
    resolved = sandbox_root.expanduser().resolve()
    return any(resolved == root or root in resolved.parents for root in roots)


def sandbox_is_visible(client: RpcClient, sandbox_root: Path) -> bool:
    return sandbox_is_visible_from_roots(sandbox_root, visible_workspace_roots(tree_roots_text(client)))


def git_status(root: Path) -> list[str]:
    proc = subprocess.run(["git", "status", "--short"], cwd=root, text=True, capture_output=True, timeout=30)
    if proc.returncode != 0:
        raise E2EFailure(f"git status failed in {root}: {proc.stderr.strip()}")
    return [line for line in proc.stdout.splitlines() if line.strip()]


def assert_clean_git(root: Path) -> None:
    lines = git_status(root)
    if lines:
        raise E2EFailure(f"Sandbox/root is not clean before read-only run: {lines}")


def sandbox_clean_is_safe(root: Path, repo_root: Path) -> bool:
    resolved = root.expanduser().resolve()
    repo_resolved = repo_root.expanduser().resolve()
    if "director-e2e" not in resolved.name and resolved.name != "e2e-sandbox":
        return False
    try:
        rel = resolved.relative_to(repo_resolved)
        return len(rel.parts) >= 2 and rel.parts[0] == "tmp"
    except ValueError:
        pass
    return any(part in {"tmp", "Temp", "TemporaryItems"} for part in resolved.parts)


def clean_sandbox(root: Path, repo_root: Path, allow_outside_tmp: bool = False) -> None:
    resolved = root.expanduser().resolve()
    if not (resolved / ".git").exists():
        raise E2EFailure(f"Refusing to clean non-git sandbox: {resolved}")
    if not allow_outside_tmp and not sandbox_clean_is_safe(resolved, repo_root):
        raise E2EFailure(
            f"Refusing to clean suspicious sandbox path: {resolved}. "
            "Use --allow-clean-outside-tmp only for an intentional throwaway repo."
        )
    commands = [["git", "clean", "-fdx"]]
    tracked = subprocess.run(["git", "ls-files"], cwd=resolved, text=True, capture_output=True, timeout=30)
    if tracked.returncode != 0:
        raise E2EFailure(f"git ls-files failed in {resolved}: {tracked.stderr.strip() or tracked.stdout.strip()}")
    if tracked.stdout.strip():
        commands.insert(0, ["git", "checkout", "--", "."])
    for command in commands:
        proc = subprocess.run(command, cwd=resolved, text=True, capture_output=True, timeout=60)
        if proc.returncode != 0:
            raise E2EFailure(f"{' '.join(command)} failed in {resolved}: {proc.stderr.strip() or proc.stdout.strip()}")


def marker_paths(root: Path, names: set[str]) -> dict[str, list[str]]:
    found = {name: [] for name in names}
    for path in root.rglob("*"):
        if ".git" in path.parts:
            continue
        if path.is_file() and path.name in names:
            found[path.name].append(str(path.relative_to(root)))
    return found


def assert_exact_marker_files(root: Path) -> None:
    expected = {"A.md", "B.md", "SUMMARY.md"}
    found = marker_paths(root, expected)
    missing = sorted(name for name, paths in found.items() if not paths)
    duplicates = {name: paths for name, paths in found.items() if len(paths) > 1}
    if missing or duplicates:
        raise E2EFailure(f"Marker files mismatch. missing={missing} duplicates={duplicates}")
    status_paths = {line[3:] if len(line) > 3 else line for line in git_status(root)}
    unexpected = sorted(path for path in status_paths if Path(path).name not in expected)
    if unexpected:
        raise E2EFailure(f"Unexpected sandbox git changes: {unexpected}")


def compact_status(client: RpcClient, session_id: str) -> dict[str, Any]:
    response = client.coordinator({
        "op": "mission_status",
        "coordinator_session_id": session_id,
        "compact": True,
    })
    status = response.get("mission_status")
    if not isinstance(status, dict):
        raise E2EFailure("mission_status compact response did not include mission_status object")
    return status


def full_status(client: RpcClient, session_id: str) -> dict[str, Any]:
    response = client.coordinator({
        "op": "mission_status",
        "coordinator_session_id": session_id,
        "compact": False,
    })
    status = response.get("mission_status")
    if not isinstance(status, dict):
        raise E2EFailure("mission_status response did not include mission_status object")
    return status


def observe(client: RpcClient, artifacts: RunArtifacts, session_id: str) -> Observation:
    obs = Observation(
        index=len(artifacts.observations),
        compact=compact_status(client, session_id),
        full=full_status(client, session_id),
    )
    artifacts.record_observation(obs)
    return obs


def wait_for_update(client: RpcClient, session_id: str, fingerprint: str, timeout_seconds: int) -> dict[str, Any] | None:
    wait_seconds = min(max(timeout_seconds, 1), 25)
    response = client.coordinator({
        "op": "wait_for_update",
        "coordinator_session_id": session_id,
        "since_fingerprint": fingerprint,
        "timeout_seconds": wait_seconds,
        "compact": True,
    }, timeout=wait_seconds + 10)
    if response.get("timed_out") is True:
        return None
    status = response.get("mission_status")
    if not isinstance(status, dict):
        raise E2EFailure("wait_for_update response did not include mission_status object")
    return status


def _stable_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), default=str)


def observation_signature(obs: Observation, extra: Any | None = None) -> dict[str, Any]:
    compact_plan = obs.compact.get("plan") or {}
    recent_events = obs.compact.get("recent_events") or obs.compact.get("events_recent") or []
    routing = obs.compact.get("routing_decisions_recent") or obs.full.get("routing_decisions_recent") or []
    nodes = []
    for node in obs.nodes:
        nodes.append({
            "id": str(node.get("id") or ""),
            "status": str(node.get("status") or ""),
            "depends_on": list(node.get("depends_on") or []),
            "dependencies_satisfied": node.get("dependencies_satisfied"),
        })
    return {
        "fingerprint": obs.fingerprint,
        "plan_status": str(compact_plan.get("status") or ""),
        "plan_revision": compact_plan.get("revision") or compact_plan.get("plan_revision"),
        "node_counts": obs.compact.get("node_counts") or {},
        "ready_node_ids": list(obs.compact.get("ready_node_ids") or []),
        "active_nodes": obs.compact.get("active_nodes") or [],
        "warnings": obs.compact.get("liveness_warnings") or obs.compact.get("warnings") or [],
        "recent_event_ids": [
            event.get("id") or event.get("event_id") or event.get("seq")
            for event in recent_events
        ],
        "routing_ids": [
            item.get("id") or item.get("routing_decision_id") or item.get("decision_id")
            for item in routing
        ],
        "nodes": sorted(nodes, key=lambda item: item["id"]),
        "extra": extra,
    }


def progress_probe_signature(probe: Callable[[], Any] | None) -> Any:
    if probe is None:
        return None
    return probe()


class ProgressTracker:
    def __init__(self, idle_timeout_seconds: int, start_time: float):
        self.idle_timeout_seconds = max(idle_timeout_seconds, 0)
        self.last_signature: str | None = None
        self.last_progress_at = start_time

    def update(self, signature: dict[str, Any], now: float) -> bool:
        encoded = _stable_json(signature)
        if self.last_signature is None or encoded != self.last_signature:
            self.last_signature = encoded
            self.last_progress_at = now
            return True
        return False

    def idle_seconds(self, now: float) -> float:
        return max(now - self.last_progress_at, 0)

    def should_fail_idle(self, obs: Observation, now: float) -> bool:
        if self.idle_timeout_seconds <= 0:
            return False
        if self.idle_seconds(now) < self.idle_timeout_seconds:
            return False
        if terminal_completed(obs) or obs.status in TERMINAL_STATUSES:
            return False
        return not has_running_work_that_could_still_complete(obs)


class InvariantWatcher:
    def __init__(self, artifacts: RunArtifacts):
        self.artifacts = artifacts
        self.last_by_node: dict[str, str] = {}

    def check(self, obs: Observation) -> None:
        max_concurrent = int((((obs.compact.get("plan") or {}).get("policy_snapshot") or {}).get("max_concurrent")) or 3)
        if running_count(obs) > max_concurrent:
            self._fail(obs, "cap_violation", f"running count {running_count(obs)} exceeds cap {max_concurrent}")
        by_id = nodes_by_id(obs)
        for node in obs.nodes:
            node_id = str(node.get("id") or "")
            status = str(node.get("status") or "")
            previous = self.last_by_node.get(node_id)
            if previous in TERMINAL_STATUSES and status != previous:
                self._fail(obs, "terminal_status_changed", f"node {node_id} moved from {previous} to {status}")
            if previous and STATUS_RANK.get(status, 0) < STATUS_RANK.get(previous, 0):
                self._fail(obs, "status_regressed", f"node {node_id} regressed from {previous} to {status}")
            self.last_by_node[node_id] = status
            if "dependencies_satisfied" in node:
                deps = [str(dep) for dep in (node.get("depends_on") or [])]
                if deps:
                    deps_done = all((by_id.get(dep) or {}).get("status") == "completed" for dep in deps)
                    if bool(node.get("dependencies_satisfied")) != deps_done:
                        self._fail(
                            obs,
                            "dependency_consistency",
                            f"node {node_id} dependencies_satisfied={node.get('dependencies_satisfied')} but deps_done={deps_done}",
                        )

    def _fail(self, obs: Observation, kind: str, message: str) -> None:
        violation = {
            "kind": kind,
            "message": message,
            "observation_index": obs.index,
            "fingerprint": obs.fingerprint,
            "observed_at": obs.observed_at,
        }
        self.artifacts.record_violation(violation)
        raise E2EFailure(message)


def wait_until(
    client: RpcClient,
    artifacts: RunArtifacts,
    session_id: str,
    predicate: Callable[[Observation], bool],
    timeout_seconds: int,
    idle_timeout_seconds: int = 120,
    max_updates: int = 60,
    progress_probe: Callable[[], Any] | None = None,
    events_mode: str = "auto",
    watcher: InvariantWatcher | None = None,
) -> Observation:
    deadline = time.monotonic() + timeout_seconds
    tracker = ProgressTracker(idle_timeout_seconds, time.monotonic())
    watcher = watcher or InvariantWatcher(artifacts)
    obs = observe(client, artifacts, session_id)
    watcher.check(obs)
    capture_mission_events(client, artifacts, session_id, events_mode)
    tracker.update(observation_signature(obs, progress_probe_signature(progress_probe)), time.monotonic())
    if predicate(obs):
        return obs
    for _ in range(max_updates):
        remaining = int(deadline - time.monotonic())
        if remaining <= 0:
            break
        wait_for_update(client, session_id, obs.fingerprint, remaining)
        obs = observe(client, artifacts, session_id)
        watcher.check(obs)
        capture_mission_events(client, artifacts, session_id, events_mode)
        now = time.monotonic()
        tracker.update(observation_signature(obs, progress_probe_signature(progress_probe)), now)
        if predicate(obs):
            return obs
        if tracker.should_fail_idle(obs, now):
            warnings = obs.compact.get("liveness_warnings") or obs.compact.get("warnings") or []
            raise E2EFailure(
                "Condition made no observable progress for "
                f"{int(tracker.idle_seconds(now))}s. status={obs.status} "
                f"running={running_count(obs)} ready={obs.compact.get('ready_node_ids') or []} "
                f"warnings={warnings} artifacts={artifacts.root}"
            )
    raise E2EFailure(f"Condition was not reached within {timeout_seconds}s; artifacts={artifacts.root}")


def capture_mission_events(client: RpcClient, artifacts: RunArtifacts, session_id: str, mode: str) -> None:
    if mode == "snapshot":
        artifacts.record_feature("mission_events", False, "snapshot mode selected")
        return
    current = artifacts.feature_available("mission_events")
    if current is False and mode != "required":
        return
    ok, response = client.try_coordinator({
        "op": "mission_events",
        "coordinator_session_id": session_id,
        "since_seq": artifacts.event_since_seq,
        "limit": 200,
        "compact": True,
    }, timeout=60)
    if not ok:
        detail = str(response.get("error") or "mission_events unsupported")
        artifacts.record_feature("mission_events", False, detail)
        if mode == "required":
            raise E2EFailure(f"mission_events required but unavailable: {detail}")
        return
    artifacts.record_feature("mission_events", True, None)
    events = response.get("events") or response.get("mission_events") or []
    if not isinstance(events, list):
        raise E2EFailure(f"mission_events returned non-list events: {response}")
    for event in events:
        if isinstance(event, dict):
            artifacts.record_event({"source": "mission_events", **event})
    next_seq = response.get("next_seq") or response.get("next_sequence") or response.get("last_seq")
    if isinstance(next_seq, int):
        artifacts.event_since_seq = next_seq
    elif events:
        seqs = [event.get("seq") for event in events if isinstance(event, dict) and isinstance(event.get("seq"), int)]
        if seqs:
            artifacts.event_since_seq = max(max(seqs), artifacts.event_since_seq)


def capture_receipt(client: RpcClient, artifacts: RunArtifacts, session_id: str, mode: str) -> None:
    if mode == "summary":
        artifacts.record_feature("receipt_markdown", False, "summary mode selected")
        return
    ok, response = client.try_coordinator({
        "op": "receipt",
        "coordinator_session_id": session_id,
        "format": "markdown",
    }, timeout=60)
    if not ok:
        detail = str(response.get("error") or "receipt markdown unsupported")
        artifacts.record_feature("receipt_markdown", False, detail)
        if mode == "required":
            raise E2EFailure(f"receipt markdown required but unavailable: {detail}")
        return
    markdown = response.get("markdown") or response.get("receipt_markdown") or response.get("receipt")
    if not isinstance(markdown, str) or not markdown.strip():
        raise E2EFailure(f"receipt markdown response did not include markdown: {response}")
    artifacts.record_feature("receipt_markdown", True, None)
    (artifacts.root / "receipt.md").write_text(markdown, encoding="utf-8")


def start_mission(client: RpcClient, title: str, message: str, scenario: str) -> str:
    key = f"director-e2e:{scenario}:{int(time.time())}:{uuid.uuid4().hex[:8]}"
    response = client.coordinator({
        "op": "start_mission",
        "mission_key": key,
        "title": title,
        "message": message,
        "compact": True,
    }, timeout=180)
    session_id = response.get("selected_coordinator_session_id")
    if not session_id:
        status = response.get("mission_status") or {}
        session_id = status.get("coordinator_session_id")
    if not session_id:
        raise E2EFailure(f"start_mission did not return a coordinator session id: {response}")
    return str(session_id)


def approve_initial_plan(client: RpcClient, artifacts: RunArtifacts, session_id: str, args: argparse.Namespace) -> None:
    obs = wait_until(
        client,
        artifacts,
        session_id,
        lambda item: bool((item.compact.get("checkpoint") or {}).get("actions")),
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("plan-visible")
    deadline = time.monotonic() + args.timeout_seconds
    last_error = ""
    while time.monotonic() < deadline:
        checkpoint = obs.compact.get("checkpoint") or {}
        actions = checkpoint.get("actions") or []
        proceed = next((action for action in actions if action.get("label") == "Proceed"), None)
        if not proceed:
            raise E2EFailure(f"No Proceed action in checkpoint: {checkpoint}")
        message = proceed.get("submit_message")
        if not message:
            raise E2EFailure(f"Proceed checkpoint action is missing submit_message: {proceed}")
        response = client.coordinator({
            "op": "submit",
            "coordinator_session_id": session_id,
            "message": message,
            "compact": True,
        }, timeout=180)
        if response.get("accepted") is not False:
            artifacts.add_checkpoint("plan-approved")
            return
        last_error = str(response.get("error") or "submit was rejected")
        if "mid-run" not in last_error:
            raise E2EFailure(f"Proceed submit rejected: {last_error}")
        if str(obs.compact.get("run_state") or "") == "waitingForQuestion":
            raise E2EFailure(
                "Proceed submit rejected as mid-run even though mission_status reports run_state=waitingForQuestion"
            )
        remaining = int(deadline - time.monotonic())
        if remaining <= 0:
            break
        wait_for_update(client, session_id, obs.fingerprint, remaining)
        obs = observe(client, artifacts, session_id)
        capture_mission_events(client, artifacts, session_id, args.events_mode)
    raise E2EFailure(f"Proceed submit never reached an ordinary turn boundary: {last_error}")


def nodes_by_id(obs: Observation) -> dict[str, dict[str, Any]]:
    return {str(node.get("id")): node for node in obs.nodes if node.get("id")}


def node_counts(obs: Observation) -> dict[str, int]:
    return obs.compact.get("node_counts") or {}


def running_count(obs: Observation) -> int:
    counts = node_counts(obs)
    if "running" in counts:
        return int(counts.get("running") or 0)
    return sum(1 for node in obs.nodes if node.get("status") == "running")


def has_running_work_that_could_still_complete(obs: Observation) -> bool:
    if running_count(obs) <= 0:
        return False
    active_nodes = list(obs.compact.get("active_nodes") or [])
    if not active_nodes:
        return True
    running_active = [node for node in active_nodes if str(node.get("status") or "") == "running"]
    if not running_active:
        return True
    for node in running_active:
        if node.get("bound_session_id") or node.get("bound_row_run_state") or node.get("bound_row_status_group"):
            return True
        if str(node.get("execution_policy") or "") != "coordinator_only":
            return True
    return False


def completed_node_evidence_missing(obs: Observation) -> list[str]:
    structured_node_ids = {
        str(evidence.get("node_id") or evidence.get("nodeID"))
        for evidence in ((obs.full.get("plan") or {}).get("evidence") or obs.full.get("evidence") or [])
        if evidence.get("node_id") or evidence.get("nodeID")
    }
    missing: list[str] = []
    for node in obs.nodes:
        if node.get("status") != "completed":
            continue
        node_id = str(node.get("id") or "")
        completion_evidence = str(node.get("completion_evidence") or "").strip()
        if not completion_evidence and node_id not in structured_node_ids:
            missing.append(node_id or str(node.get("title") or "<untitled node>"))
    return missing


def user_decision_count(status: dict[str, Any]) -> int:
    counts = status.get("decision_counts_by_actor") or {}
    return int(counts.get("user") or 0)


def routing_decision_count(full: dict[str, Any]) -> int:
    return len(full.get("routing_decisions_recent") or ((full.get("plan") or {}).get("routing_decisions") or []))


def terminal_completed(obs: Observation) -> bool:
    return obs.status == "completed"


def assert_common_status_integrity(observations: Iterable[Observation]) -> None:
    last_by_node: dict[str, str] = {}
    for obs in observations:
        for node in obs.nodes:
            node_id = str(node.get("id"))
            status = str(node.get("status") or "")
            previous = last_by_node.get(node_id)
            if previous in TERMINAL_STATUSES and status != previous:
                raise E2EFailure(f"Terminal node {node_id} moved from {previous} to {status}")
            if previous and STATUS_RANK.get(status, 0) < STATUS_RANK.get(previous, 0):
                raise E2EFailure(f"Node {node_id} status regressed from {previous} to {status}")
            last_by_node[node_id] = status


def assert_s1(observations: list[Observation], approved_by_runner: bool) -> None:
    final = observations[-1]
    if final.status != "completed":
        raise E2EFailure(f"S1 expected completed mission, got {final.status}")
    receipt = final.compact.get("receipt_ready_summary") or {}
    if receipt.get("ready") is not True:
        raise E2EFailure(f"S1 expected ready receipt summary, got {receipt}")
    if routing_decision_count(final.full) < 1:
        raise E2EFailure("S1 expected at least one routing decision")
    if missing := completed_node_evidence_missing(final):
        raise E2EFailure(f"S1 expected completed node evidence for {', '.join(missing)}")
    adjusted_user_count = max(user_decision_count(final.compact) - (1 if approved_by_runner else 0), 0)
    if adjusted_user_count != 0:
        raise E2EFailure(f"S1 expected zero post-approval user decisions, got {adjusted_user_count}")
    if int((final.compact.get("counts") or {}).get("needs_you") or 0) != 0:
        raise E2EFailure("S1 expected no pending Needs you count at completion")
    assert_common_status_integrity(observations)


def convergence_node(obs: Observation) -> dict[str, Any] | None:
    candidates = [node for node in obs.nodes if len(node.get("depends_on") or []) >= 2]
    if candidates:
        return candidates[0]
    for node in obs.nodes:
        if "summary" in str(node.get("title") or "").lower():
            return node
    return None


def dependencies_completed(obs: Observation, node: dict[str, Any]) -> bool:
    by_id = nodes_by_id(obs)
    return all((by_id.get(dep) or {}).get("status") == "completed" for dep in (node.get("depends_on") or []))


def s2_convergence_mode(obs: Observation) -> str | None:
    node = convergence_node(obs)
    if not node or not dependencies_completed(obs, node):
        return None
    node_id = str(node.get("id") or "")
    if node.get("status") == "pending" and node_id in (obs.compact.get("ready_node_ids") or []):
        return "ready"
    if node.get("status") == "running":
        return "running"
    if node.get("status") == "completed":
        return "completed"
    return None


def first_s2_convergence_mode(observations: Iterable[Observation]) -> str | None:
    for obs in observations:
        mode = s2_convergence_mode(obs)
        if mode:
            return mode
    return None


def assert_s2(observations: list[Observation], approved_by_runner: bool) -> None:
    final = observations[-1]
    if final.status != "completed":
        raise E2EFailure(f"S2 expected completed mission, got {final.status}")
    max_concurrent = int((((final.compact.get("plan") or {}).get("policy_snapshot") or {}).get("max_concurrent")) or 3)
    for obs in observations:
        if running_count(obs) > max_concurrent:
            raise E2EFailure(f"S2 observed running count {running_count(obs)} above cap {max_concurrent}")
    if max(running_count(obs) for obs in observations) < 2:
        raise E2EFailure("S2 never observed two running nodes simultaneously")
    conv_seen = [convergence_node(obs) for obs in observations]
    if not any(conv_seen):
        raise E2EFailure("S2 did not find a convergence/summary node")
    saw_waiting = False
    saw_ready_or_launched = False
    convergence_id = None
    for obs in observations:
        node = convergence_node(obs)
        if not node:
            continue
        convergence_id = str(node.get("id"))
        deps_done = dependencies_completed(obs, node)
        dep_satisfied = bool(node.get("dependencies_satisfied"))
        if not deps_done and not dep_satisfied:
            saw_waiting = True
        if deps_done and s2_convergence_mode(obs):
            saw_ready_or_launched = True
    if not saw_waiting:
        raise E2EFailure("S2 did not observe convergence node waiting on dependencies")
    if not saw_ready_or_launched:
        raise E2EFailure("S2 did not observe convergence node become ready, running, or completed after parent completion")
    adjusted_user_count = max(user_decision_count(final.compact) - (1 if approved_by_runner else 0), 0)
    if adjusted_user_count != 0:
        raise E2EFailure(f"S2 expected no user submits after plan approval, got {adjusted_user_count}")
    assert_common_status_integrity(observations)


def s2_event_convergence_node(event: dict[str, Any]) -> dict[str, Any] | None:
    nodes = [node for node in (event.get("nodes") or []) if isinstance(node, dict)]
    candidates = [node for node in nodes if len(node.get("depends_on") or []) >= 2]
    if candidates:
        return candidates[0]
    for node in nodes:
        if "summary" in str(node.get("title") or "").lower():
            return node
    return None


def s2_event_dependencies_completed(event: dict[str, Any], node: dict[str, Any]) -> bool:
    nodes = [candidate for candidate in (event.get("nodes") or []) if isinstance(candidate, dict)]
    by_id = {str(candidate.get("id")): candidate for candidate in nodes}
    return all((by_id.get(str(dep)) or {}).get("status") == "completed" for dep in (node.get("depends_on") or []))


def s2_event_convergence_mode(event: dict[str, Any]) -> str | None:
    node = s2_event_convergence_node(event)
    if not node or not s2_event_dependencies_completed(event, node):
        return None
    node_id = str(node.get("id") or "")
    ready_ids = [str(item) for item in (event.get("ready_node_ids") or [])]
    status = str(node.get("status") or "")
    if status == "pending" and node_id in ready_ids:
        return "ready"
    if status == "running":
        return "running"
    if status == "completed":
        return "completed"
    return None


def assert_s2_mission_event_sequence(events: list[dict[str, Any]]) -> None:
    ordered = sorted(
        [event for event in events if isinstance(event.get("seq"), int)],
        key=lambda event: int(event["seq"]),
    )
    if not ordered:
        raise E2EFailure("S2 mission_events were available but no sequenced events were recorded")
    if not any(
        (node := s2_event_convergence_node(event)) is not None
        and not s2_event_dependencies_completed(event, node)
        for event in ordered
    ):
        raise E2EFailure("S2 mission_events did not show convergence node waiting on dependencies")

    modes: list[str] = []
    for event in ordered:
        mode = s2_event_convergence_mode(event)
        if mode and (not modes or modes[-1] != mode):
            modes.append(mode)
    cursor = 0
    for expected in ["ready", "running", "completed"]:
        try:
            cursor = modes.index(expected, cursor) + 1
        except ValueError as exc:
            raise E2EFailure(
                "S2 mission_events did not show exact convergence order "
                f"ready -> running -> completed; observed {modes}"
            ) from exc


def s1_message() -> str:
    return (
        "Run this as a scoped Director mission. Record a visible Mission Plan with "
        'approval_state:"awaiting_approval" before child sessions. After approval, run a '
        "read-only investigation only: inspect the selected workspace docs/config and report "
        "exactly one small candidate for future improvement. Do not edit files, run mutating "
        "validation, commit, push, open PRs, merge, or start a follow-up Mission. Record "
        "evidence and close with a receipt."
    )


def s2_message(sandbox_root: Path) -> str:
    return (
        "Run this as a scoped Director mission. Record a visible Mission Plan with "
        'approval_state:"awaiting_approval" before child sessions. After approval, use Auto '
        "pace and decompose into exactly three deliverable nodes: two independent steps that "
        f"create `{sandbox_root}/A.md` and `{sandbox_root}/B.md` in parallel-capable isolated "
        f"work, then a third step that depends on both, verifies both files exist, and writes "
        f"`{sandbox_root}/SUMMARY.md`. Keep the mission tight: do not create other files, do "
        "not commit, push, open PRs, merge, or run cluster-mutating validation. Record evidence "
        "for every completed node and close with a receipt."
    )


def run_s1(client: RpcClient, artifacts: RunArtifacts, args: argparse.Namespace) -> None:
    sandbox_root = Path(args.sandbox_root).expanduser().resolve() if args.sandbox_root else None
    artifacts.record_timing("started")
    if sandbox_root and sandbox_root.exists() and (sandbox_root / ".git").exists():
        if args.clean_sandbox:
            clean_sandbox(sandbox_root, client.repo_root, args.allow_clean_outside_tmp)
        assert_clean_git(sandbox_root)
    session_id = start_mission(client, "Director E2E S1 read-only", s1_message(), "s1")
    approve_initial_plan(client, artifacts, session_id, args)
    final = wait_until(
        client,
        artifacts,
        session_id,
        terminal_completed,
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("completed")
    assert_s1(artifacts.observations, approved_by_runner=True)
    if sandbox_root and sandbox_root.exists() and (sandbox_root / ".git").exists():
        assert_clean_git(sandbox_root)
    capture_receipt(client, artifacts, session_id, args.receipt_mode)
    artifacts.finalize(True, "s1", {"coordinator_session_id": session_id, "final_status": final.status})


def run_s2(client: RpcClient, artifacts: RunArtifacts, args: argparse.Namespace) -> None:
    if not args.sandbox_root:
        raise E2EFailure("S2 requires --sandbox-root so writable marker files are scoped to a throwaway repo")
    sandbox_root = Path(args.sandbox_root).expanduser().resolve()
    if not sandbox_root.exists() or not (sandbox_root / ".git").exists():
        raise E2EFailure(f"S2 sandbox must be an existing git repo: {sandbox_root}")
    artifacts.record_timing("started")
    if args.clean_sandbox:
        clean_sandbox(sandbox_root, client.repo_root, args.allow_clean_outside_tmp)
    assert_clean_git(sandbox_root)
    if not sandbox_is_visible(client, sandbox_root):
        raise E2EFailure(f"S2 sandbox root is not visible in the selected app workspace: {sandbox_root}")
    session_id = start_mission(client, "Director E2E S2 convergence", s2_message(sandbox_root), "s2")
    approve_initial_plan(client, artifacts, session_id, args)
    saw_fanout = False
    convergence_mode = None

    def marker_probe() -> dict[str, list[str]]:
        return marker_paths(sandbox_root, {"A.md", "B.md", "SUMMARY.md"})

    def done_or_interesting(obs: Observation) -> bool:
        nonlocal saw_fanout, convergence_mode
        if running_count(obs) >= 2 and not saw_fanout:
            saw_fanout = True
            artifacts.add_checkpoint("running-fanout")
        mode = s2_convergence_mode(obs)
        if mode and convergence_mode is None:
            convergence_mode = mode
            artifacts.add_checkpoint(f"convergence-{mode}")
        return terminal_completed(obs)

    final = wait_until(
        client,
        artifacts,
        session_id,
        done_or_interesting,
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        max_updates=90,
        progress_probe=marker_probe,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("completed")
    assert_s2(artifacts.observations, approved_by_runner=True)
    if artifacts.feature_available("mission_events") is True:
        assert_s2_mission_event_sequence(artifacts.mission_events)
    assert_exact_marker_files(sandbox_root)
    capture_receipt(client, artifacts, session_id, args.receipt_mode)
    artifacts.finalize(True, "s2", {
        "coordinator_session_id": session_id,
        "final_status": final.status,
        "saw_running_fanout": saw_fanout,
        "convergence_observed_as": convergence_mode or first_s2_convergence_mode(artifacts.observations),
        "sandbox_root": str(sandbox_root),
    })


def run_scenario(client: RpcClient, artifacts: RunArtifacts, args: argparse.Namespace) -> None:
    if args.scenario == "s1":
        run_s1(client, artifacts, args)
    elif args.scenario == "s2":
        run_s2(client, artifacts, args)
    elif args.scenario == "smoke":
        s1_artifacts = RunArtifacts(artifacts.root / "s1")
        s1_client = RpcClient(client.cli, client.window, client.repo_root, s1_artifacts)
        run_s1(s1_client, s1_artifacts, args)
        smoke_s2_dir = artifacts.root / "s2"
        s2_artifacts = RunArtifacts(smoke_s2_dir)
        s2_client = RpcClient(client.cli, client.window, client.repo_root, s2_artifacts)
        run_s2(s2_client, s2_artifacts, args)
        artifacts.finalize(True, "smoke", {
            "s1_artifact_dir": str(s1_artifacts.root),
            "s2_artifact_dir": str(smoke_s2_dir),
        })
    else:
        raise E2EFailure(f"Unknown scenario: {args.scenario}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run live Director mission E2E scenarios.")
    parser.add_argument("--scenario", choices=["s1", "s2", "smoke"], default="s1")
    parser.add_argument("--workspace", default="homelab-garden")
    parser.add_argument("--window", type=int, default=1)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--idle-timeout-seconds", type=int, default=120)
    parser.add_argument("--output-dir", default="tmp/director-e2e-runs")
    parser.add_argument("--sandbox-root", default=os.environ.get("RPCE_DIRECTOR_E2E_SANDBOX"))
    parser.add_argument("--clean-sandbox", action="store_true", help="Clean the throwaway sandbox before each writable scenario.")
    parser.add_argument(
        "--allow-clean-outside-tmp",
        action="store_true",
        help="Allow --clean-sandbox outside known tmp/director-e2e paths.",
    )
    parser.add_argument("--events-mode", choices=["auto", "snapshot", "required"], default="auto")
    parser.add_argument("--receipt-mode", choices=["auto", "summary", "required"], default="auto")
    parser.add_argument("--repeat", type=int, default=1, help="Run the scenario multiple times and aggregate reports.")
    parser.add_argument("--launch", action="store_true", help="Explicitly launch/relaunch the debug app before running.")
    return parser


def run_once(args: argparse.Namespace, repo_root: Path, artifacts: RunArtifacts, cli: str) -> None:
    client = RpcClient(cli, args.window, repo_root, artifacts)
    ensure_workspace(client, args.workspace)
    run_scenario(client, artifacts, args)


def repeat_report_for(scenario: str, repeat: int, results: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "scenario": scenario,
        "repeat": repeat,
        "passed": all(result["passed"] for result in results),
        "pass_count": sum(1 for result in results if result["passed"]),
        "fail_count": sum(1 for result in results if not result["passed"]),
        "attempts": results,
    }


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.repeat < 1:
        parser.error("--repeat must be >= 1")
    repo_root = Path(__file__).resolve().parents[4]
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{args.scenario}-{uuid.uuid4().hex[:6]}"
    root = (repo_root / args.output_dir / run_id).resolve()
    artifacts = RunArtifacts(root)
    try:
        if args.launch:
            subprocess.run(["make", "dev-run"], cwd=repo_root, check=True)
        cli = resolve_debug_cli()
        if args.repeat == 1:
            run_once(args, repo_root, artifacts, cli)
        else:
            results: list[dict[str, Any]] = []
            for attempt in range(1, args.repeat + 1):
                attempt_artifacts = RunArtifacts(root / f"attempt-{attempt:03d}")
                try:
                    run_once(args, repo_root, attempt_artifacts, cli)
                    results.append({
                        "attempt": attempt,
                        "passed": True,
                        "artifact_dir": str(attempt_artifacts.root),
                        "report": attempt_artifacts.report,
                    })
                except Exception as attempt_exc:
                    attempt_artifacts.finalize(False, args.scenario, {"error": str(attempt_exc), "attempt": attempt})
                    results.append({
                        "attempt": attempt,
                        "passed": False,
                        "artifact_dir": str(attempt_artifacts.root),
                        "error": str(attempt_exc),
                    })
            repeat_report = repeat_report_for(args.scenario, args.repeat, results)
            write_json(root / "repeat_report.json", repeat_report)
            artifacts.report = repeat_report
            if not repeat_report["passed"]:
                raise E2EFailure(f"{repeat_report['fail_count']} of {args.repeat} attempts failed")
        print(f"PASS {args.scenario}: artifacts at {artifacts.root}")
        return 0
    except Exception as exc:
        if not artifacts.report:
            artifacts.finalize(False, args.scenario, {"error": str(exc)})
        print(f"FAIL {args.scenario}: {exc}", file=sys.stderr)
        print(f"Artifacts: {artifacts.root}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
