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
MISSING_CHILDASK_LEDGER_WARNING = "completed_child_missing_childask_ledger"
CHILD_INPUT_TOOL_UNAVAILABLE = "S5_USER_INPUT_TOOL_UNAVAILABLE"
SCRIPTED_CHILD_SELECTOR = "scripted"
SCRIPTED_CHILD_COMPLETION_PREFIX = "SCRIPTED_CHILD_V1 answer="
TERMINAL_READINESS_MESSAGE = "not ready until the Mission is completed or stopped"
ARCHIVE_TERMINAL_READINESS_MESSAGE = "archive_mission is only available after a Mission is completed or stopped"
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
    run_config: dict[str, Any] = field(default_factory=dict)
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

    def set_run_config(self, config: dict[str, Any]) -> None:
        self.run_config = dict(config)
        write_json(self.root / "run_config.json", self.run_config)

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
            "run_config": self.run_config,
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

    def bind_context(self, context_id: str) -> None:
        self.run(
            "bind_context:bind",
            [self.cli, "-w", str(self.window), "-c", "bind_context", "-j", json.dumps({"op": "bind", "context_id": context_id})],
        )

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


def bind_visible_context_for_sandbox(client: RpcClient, sandbox_root: Path) -> None:
    windows = client.run("windows for context bind", [client.cli, "-w", str(client.window), "-c", "bind_context", "-j", json.dumps({"op": "list"})])
    resolved = sandbox_root.expanduser().resolve()
    pending_context_id: str | None = None
    for line in windows.splitlines():
        context_match = re.search(r"context_id:\s*`([0-9A-Fa-f-]+)`", line)
        if context_match:
            pending_context_id = context_match.group(1)
            continue
        repo_match = re.search(r"repo:\s*`([^`]+)`", line)
        if not repo_match or pending_context_id is None:
            continue
        repo = Path(repo_match.group(1)).expanduser().resolve()
        if resolved == repo or repo in resolved.parents:
            client.bind_context(pending_context_id)
            return


def tree_roots_text(client: RpcClient) -> str:
    return client.exec_text("tree roots", "tree --type roots")


def visible_workspace_roots(tree_roots_output: str) -> list[Path]:
    roots: list[Path] = []
    seen: set[Path] = set()
    for line in tree_roots_output.splitlines():
        candidates = [match.group(1).rstrip(";,") for match in re.finditer(r"(/[^\s`;]+)", line)]
        if not candidates:
            candidate = line.strip()
            if "→" in candidate:
                candidate = candidate.rsplit("→", 1)[1].strip()
            candidates = [candidate] if candidate.startswith("/") else []
        for candidate in candidates:
            root = Path(candidate).expanduser().resolve()
            if root in seen:
                continue
            seen.add(root)
            roots.append(root)
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
    status = dict(status)
    if isinstance(response.get("counts"), dict):
        status.setdefault("counts", response["counts"])
    if response.get("selected_coordinator_session_id"):
        status.setdefault("coordinator_session_id", response["selected_coordinator_session_id"])
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
        "surface_counts": obs.compact.get("counts") or {},
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
    fail_missing_childask_ledger_warning(obs, artifacts)
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
        fail_missing_childask_ledger_warning(obs, artifacts)
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


def fail_missing_childask_ledger_warning(obs: Observation, artifacts: RunArtifacts) -> None:
    warnings = {str(item) for item in (obs.compact.get("liveness_warnings") or obs.compact.get("warnings") or [])}
    if MISSING_CHILDASK_LEDGER_WARNING not in warnings:
        return
    raise E2EFailure(
        "S6_MISSING_DIRECTOR_LEDGER_AFTER_CHILD_DONE: child completed while the Mission node "
        f"remained running without childAsk decision/evidence. artifacts={artifacts.root}"
    )


def timeout_failure_may_be_terminal_graced(error: Exception) -> bool:
    message = str(error)
    return message.startswith("Condition was not reached within ") or message.startswith(
        "Condition made no observable progress for "
    )


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
    response: dict[str, Any] = {}
    ok = False
    deadline = time.monotonic() + 45
    while True:
        ok, response = client.try_coordinator({
            "op": "receipt",
            "coordinator_session_id": session_id,
            "format": "markdown",
        }, timeout=60)
        markdown = response.get("markdown") or response.get("receipt_markdown") or response.get("receipt")
        if not ok or (isinstance(markdown, str) and markdown.strip()):
            break
        if TERMINAL_READINESS_MESSAGE not in str(response.get("error") or "") or time.monotonic() >= deadline:
            break
        time.sleep(2)
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


def capture_doctor(client: RpcClient, artifacts: RunArtifacts, mode: str) -> dict[str, Any] | None:
    if mode == "off":
        artifacts.record_feature("doctor", False, "doctor mode off")
        return None
    ok, response = client.try_coordinator({"op": "doctor"}, timeout=60)
    if not ok:
        detail = str(response.get("error") or "doctor unsupported")
        artifacts.record_feature("doctor", False, detail)
        if mode == "required":
            raise E2EFailure(f"doctor required but unavailable: {detail}")
        return None
    doctor = response.get("doctor")
    if not isinstance(doctor, dict):
        raise E2EFailure(f"doctor response did not include doctor object: {response}")
    write_json(artifacts.root / "doctor.json", doctor)
    artifacts.record_feature("doctor", True, None)
    features = ((doctor.get("coordinator_chat") or {}).get("features") or {})
    if isinstance(features, dict):
        for name, available in features.items():
            if isinstance(available, bool):
                artifacts.record_feature(str(name), available, "doctor")
    return doctor


def list_missions(client: RpcClient, artifacts: RunArtifacts, include_archived: bool = True) -> list[dict[str, Any]]:
    ok, response = client.try_coordinator({
        "op": "list_missions",
        "include_archived": include_archived,
    }, timeout=60)
    if not ok:
        detail = str(response.get("error") or "list_missions unsupported")
        artifacts.record_feature("list_missions", False, detail)
        raise E2EFailure(f"list_missions unavailable: {detail}")
    artifacts.record_feature("list_missions", True, None)
    missions = response.get("missions")
    if not isinstance(missions, list):
        raise E2EFailure(f"list_missions response did not include missions array: {response}")
    normalized = [mission for mission in missions if isinstance(mission, dict)]
    write_json(artifacts.root / "missions.json", normalized)
    return normalized


def archive_mission(client: RpcClient, artifacts: RunArtifacts, session_id: str) -> dict[str, Any]:
    response: dict[str, Any] = {}
    deadline = time.monotonic() + 45
    while True:
        try:
            response = client.coordinator({
                "op": "archive_mission",
                "coordinator_session_id": session_id,
            }, timeout=120)
            break
        except E2EFailure as exc:
            message = str(exc)
            if coordinator_op_unsupported(message):
                artifacts.record_feature("archive_mission", False, message)
                raise E2EFailure(f"archive_mission unavailable: {message}")
            if (
                TERMINAL_READINESS_MESSAGE not in message
                and ARCHIVE_TERMINAL_READINESS_MESSAGE not in message
            ) or time.monotonic() >= deadline:
                raise
            time.sleep(2)
    artifacts.record_feature("archive_mission", True, None)
    write_json(artifacts.root / "archive_mission.json", response)
    if response.get("accepted") is not True:
        raise E2EFailure(f"archive_mission rejected: {response.get('error') or response}")
    return response


def coordinator_session_ids_from_report(report: dict[str, Any]) -> list[str]:
    seen: set[str] = set()
    session_ids: list[str] = []

    def append(value: Any) -> None:
        if not isinstance(value, str) or not value.strip() or value in seen:
            return
        seen.add(value)
        session_ids.append(value)

    append(report.get("coordinator_session_id"))
    for variant in report.get("variants") or []:
        if not isinstance(variant, dict):
            continue
        variant_report = variant.get("report")
        if isinstance(variant_report, dict):
            append(variant_report.get("coordinator_session_id"))
    return session_ids


def archive_final_mission_if_requested(client: RpcClient, artifacts: RunArtifacts, args: argparse.Namespace) -> None:
    if not getattr(args, "archive_on_success", False):
        return
    session_ids = coordinator_session_ids_from_report(artifacts.report)
    if not session_ids:
        raise E2EFailure("--archive-on-success requires a scenario report with coordinator_session_id or variant reports")
    archive_results = [archive_mission(client, artifacts, session_id) for session_id in session_ids]
    write_json(artifacts.root / "archive_missions.json", archive_results)
    missions = list_missions(client, artifacts, include_archived=True)
    for session_id in session_ids:
        archived = next((mission for mission in missions if mission.get("coordinator_session_id") == session_id), None)
        if archived is None or archived.get("archived") is not True:
            raise E2EFailure(f"archive_mission did not leave mission archived in list_missions: {archived}")
        # Retention check: archived Missions must remain readable by id.
        compact_status(client, session_id)
        capture_mission_events(client, artifacts, session_id, args.events_mode)
        capture_receipt(client, artifacts, session_id, args.receipt_mode)


def start_mission(
    client: RpcClient,
    title: str,
    message: str,
    scenario: str,
    coordinator_model_id: str | None = None,
) -> str:
    key = f"director-e2e:{scenario}:{int(time.time())}:{uuid.uuid4().hex[:8]}"
    payload: dict[str, Any] = {
        "op": "start_mission",
        "mission_key": key,
        "title": title,
        "message": message,
        "compact": True,
    }
    if coordinator_model_id:
        payload["coordinator_model_id"] = coordinator_model_id
    response = client.coordinator(payload, timeout=180)
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
        if plan_advanced_past_initial_approval(obs.compact):
            artifacts.add_checkpoint("plan-approved")
            return
        checkpoint = obs.compact.get("checkpoint") or {}
        actions = checkpoint.get("actions") or []
        proceed = next((action for action in actions if action.get("label") == "Proceed"), None)
        if not proceed:
            raise E2EFailure(f"No Proceed action in checkpoint: {checkpoint}")
        message = proceed.get("submit_message")
        if not message:
            raise E2EFailure(f"Proceed checkpoint action is missing submit_message: {proceed}")
        submit_payload = {
            "op": "submit",
            "coordinator_session_id": session_id,
            "message": message,
            "compact": True,
        }
        checkpoint_action = proceed.get("checkpoint_action")
        if isinstance(checkpoint_action, str) and checkpoint_action.strip():
            submit_payload["checkpoint_action"] = checkpoint_action.strip()
        expected_checkpoint_instance_id = checkpoint_instance_id(obs.compact)
        if expected_checkpoint_instance_id:
            submit_payload["expected_checkpoint_instance_id"] = expected_checkpoint_instance_id
        response = client.coordinator(submit_payload, timeout=180)
        if response.get("accepted") is not False:
            artifacts.add_checkpoint("plan-approved")
            return
        last_error = str(response.get("error") or "submit was rejected")
        if stale_checkpoint_submit_rejected(last_error):
            obs = observe(client, artifacts, session_id)
            capture_mission_events(client, artifacts, session_id, args.events_mode)
            continue
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


def stale_checkpoint_submit_rejected(message: str) -> bool:
    return "Stale checkpoint submit rejected" in message and "current checkpoint_instance_id" in message


def submit_with_midrun_retry(
    client: RpcClient,
    artifacts: RunArtifacts,
    session_id: str,
    payload: dict[str, Any],
    args: argparse.Namespace,
    action_label: str,
    wire_attempts: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    deadline = time.monotonic() + args.timeout_seconds
    last_error = ""
    obs = observe(client, artifacts, session_id)
    while time.monotonic() < deadline:
        response = client.coordinator(payload, timeout=180)
        if wire_attempts is not None:
            wire_attempts.append(response)
        if response.get("accepted") is not False:
            return response
        last_error = str(response.get("error") or "submit was rejected")
        if "mid-run" not in last_error:
            return response
        if str(obs.compact.get("run_state") or "") == "waitingForQuestion":
            raise E2EFailure(
                f"{action_label} rejected as mid-run even though mission_status reports run_state=waitingForQuestion"
            )
        remaining = int(deadline - time.monotonic())
        if remaining <= 0:
            break
        wait_for_update(client, session_id, obs.fingerprint, remaining)
        obs = observe(client, artifacts, session_id)
        capture_mission_events(client, artifacts, session_id, args.events_mode)
    raise E2EFailure(f"{action_label} never reached an ordinary turn boundary: {last_error}")


def submit_current_proceed_with_checkpoint_refresh(
    client: RpcClient,
    artifacts: RunArtifacts,
    session_id: str,
    obs: Observation,
    args: argparse.Namespace,
) -> tuple[dict[str, Any], str, Observation]:
    deadline = time.monotonic() + args.timeout_seconds
    attempts: list[dict[str, Any]] = []
    wire_attempts: list[dict[str, Any]] = []
    current_obs = obs
    while time.monotonic() < deadline:
        current_checkpoint_id = checkpoint_instance_id(current_obs.compact)
        if not current_checkpoint_id:
            raise E2EFailure("S4 current checkpoint refresh did not expose checkpoint_instance_id")
        proceed = checkpoint_action(current_obs.compact, "Proceed")
        if not proceed:
            raise E2EFailure("S4 current checkpoint refresh did not expose a Proceed action")
        proceed_message = str(proceed.get("submit_message") or "Approved to proceed.")
        checkpoint_action_id = str(proceed.get("checkpoint_action") or "proceed")
        response = submit_with_midrun_retry(client, artifacts, session_id, {
            "op": "submit",
            "coordinator_session_id": session_id,
            "message": proceed_message,
            "checkpoint_action": checkpoint_action_id,
            "expected_checkpoint_instance_id": current_checkpoint_id,
            "compact": True,
        }, args, "S4 current Proceed", wire_attempts)
        attempts.append({
            "checkpoint_instance_id": current_checkpoint_id,
            "response": response,
        })
        write_json(artifacts.root / "current_checkpoint_submit_attempts.json", attempts)
        write_json(artifacts.root / "current_checkpoint_wire_submits.json", wire_attempts)
        if response.get("accepted") is not False:
            return response, current_checkpoint_id, current_obs
        error = str(response.get("error") or "")
        if "Stale checkpoint submit rejected" not in error:
            raise E2EFailure(f"S4 current Proceed submit rejected: {error or response}")
        current_obs = observe(client, artifacts, session_id)
        capture_mission_events(client, artifacts, session_id, args.events_mode)
        artifacts.add_checkpoint("current-checkpoint-refreshed")
    raise E2EFailure("S4 current Proceed never accepted a refreshed checkpoint instance")


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
    warnings = {str(item) for item in (obs.compact.get("liveness_warnings") or obs.compact.get("warnings") or [])}
    active_nodes = list(obs.compact.get("active_nodes") or [])

    def has_bound_running_node() -> bool:
        return any(
            str(node.get("status") or "") == "running"
            and (
                node.get("bound_session_id")
                or node.get("bound_row_run_state")
                or node.get("bound_row_status_group")
            )
            for node in active_nodes
            if isinstance(node, dict)
        )

    if (
        "coordinator_run_state_is_not_active_but_plan_has_active_nodes" in warnings
        and "running_delegated_nodes_without_bound_sessions" in warnings
    ):
        return has_bound_running_node()
    if "running_delegated_nodes_without_bound_sessions" in warnings:
        return has_bound_running_node()
    if not active_nodes:
        return True
    running_active = [node for node in active_nodes if str(node.get("status") or "") == "running"]
    if not running_active:
        return True
    for node in running_active:
        bound_row_run_state = str(node.get("bound_row_run_state") or "")
        bound_row_status_group = str(node.get("bound_row_status_group") or "")
        if bound_row_run_state in TERMINAL_STATUSES or bound_row_status_group == "done":
            continue
        if node.get("bound_session_id") or bound_row_run_state or bound_row_status_group:
            return True
        if str(node.get("execution_policy") or "") != "coordinator_only":
            return True
    return False


def checkpoint_instance_id(status: dict[str, Any]) -> str | None:
    checkpoint = status.get("checkpoint")
    if not isinstance(checkpoint, dict):
        nested = status.get("mission_status")
        if isinstance(nested, dict):
            checkpoint = nested.get("checkpoint")
    if not isinstance(checkpoint, dict):
        return None
    raw = checkpoint.get("checkpoint_instance_id") or checkpoint.get("checkpointInstanceID")
    if raw is None:
        return None
    value = str(raw).strip()
    return value or None


def checkpoint_action(status: dict[str, Any], label: str) -> dict[str, Any] | None:
    checkpoint = status.get("checkpoint")
    if not isinstance(checkpoint, dict):
        return None
    for action in checkpoint.get("actions") or []:
        if isinstance(action, dict) and str(action.get("label") or "") == label:
            return action
    return None


def decision_id(decision: dict[str, Any]) -> str:
    return str(decision.get("id") or decision.get("decision_id") or "").strip()


def decision_checkpoint_instance_id(decision: dict[str, Any]) -> str:
    return str(decision.get("checkpoint_instance_id") or decision.get("checkpointInstanceID") or "").strip()


def decision_ids(status: dict[str, Any]) -> set[str]:
    return {decision_id(decision) for decision in plan_decisions(status) if decision_id(decision)}


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


def plan_revision(status: dict[str, Any]) -> int:
    plan = status.get("plan") or {}
    value = plan.get("revision") or plan.get("plan_revision") or 0
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def plan_default_pace(status: dict[str, Any]) -> str:
    plan = status.get("plan") or {}
    policy = plan.get("policy_snapshot") or plan.get("policySnapshot") or {}
    return str(policy.get("default_pace") or policy.get("defaultPace") or "").lower()


def plan_approval_state(status: dict[str, Any]) -> str:
    plan = status.get("plan") or {}
    return str(plan.get("approval_state") or plan.get("approvalState") or "").lower()


def has_checkpoint_action(status: dict[str, Any], label: str) -> bool:
    checkpoint = status.get("checkpoint") or {}
    actions = checkpoint.get("actions") or []
    return any(str(action.get("label") or "") == label for action in actions if isinstance(action, dict))


def plan_or_nodes_mention_token(status: dict[str, Any], token: str) -> bool:
    token = token.strip().lower()
    if not token:
        return True
    plan = mission_plan_payload(status)
    fields: list[str] = []
    for key in ["mission_key", "objective", "shape_summary", "predecessor_summary"]:
        fields.append(str(plan.get(key) or ""))
    for node in status.get("nodes") or plan.get("nodes") or []:
        if not isinstance(node, dict):
            continue
        fields.extend(
            str(node.get(key) or "")
            for key in ["title", "detail", "completion_evidence", "done_criteria", "role"]
        )
    return token in "\n".join(fields).lower()


def plan_advanced_past_initial_approval(status: dict[str, Any]) -> bool:
    approval_state = plan_approval_state(status)
    return approval_state == "approved"


def revision_proposal_status(status: dict[str, Any]) -> dict[str, Any]:
    value = status.get("revision_proposal") or {}
    return value if isinstance(value, dict) else {}


def pending_revision_proposal(status: dict[str, Any]) -> dict[str, Any] | None:
    value = revision_proposal_status(status).get("pending")
    return value if isinstance(value, dict) else None


def recent_revision_proposal_resolution(status: dict[str, Any]) -> dict[str, Any] | None:
    value = revision_proposal_status(status).get("recent_resolution")
    return value if isinstance(value, dict) else None


def assert_summary_only_revision_checkpoint(status: dict[str, Any]) -> None:
    checkpoint = status.get("checkpoint") or {}
    pending = pending_revision_proposal(status)
    if checkpoint.get("kind") != "revision_proposal" or pending is None:
        raise E2EFailure("S8 expected a pending revision_proposal checkpoint")
    labels = [
        str(action.get("label") or "")
        for action in checkpoint.get("actions") or []
        if isinstance(action, dict)
    ]
    if labels != ["Revise plan", "Keep current plan", "Stop Mission"]:
        raise E2EFailure(f"S8 expected exact proposal actions, got {labels}")
    forbidden_keys = {"replacement_plan", "replacement_diff", "requested_change", "exact_replacement"}
    serialized = _stable_json({"checkpoint": checkpoint, "pending": pending})
    if forbidden_keys.intersection(checkpoint) or forbidden_keys.intersection(pending):
        raise E2EFailure("S8 proposal checkpoint exposed an exact replacement payload")
    if "Approve revised plan" in serialized:
        raise E2EFailure("S8 proposal checkpoint exposed an exact replacement approval action")
    for action in checkpoint.get("actions") or []:
        if not isinstance(action, dict) or action.get("label") == "Stop Mission":
            continue
        allowed = {
            "label",
            "submit_op",
            "checkpoint_action",
            "proposal_id",
            "expected_contract_fingerprint",
            "expected_checkpoint_instance_id",
        }
        extras = set(action).difference(allowed)
        if extras:
            raise E2EFailure(f"S8 proposal action duplicated non-identity payload fields: {sorted(extras)}")


def plan_childask_mode(status: dict[str, Any]) -> str:
    plan = status.get("plan") or {}
    autonomy_summary = plan.get("autonomy_summary") or {}
    auto = {str(item) for item in (autonomy_summary.get("auto") or [])}
    ask = {str(item) for item in (autonomy_summary.get("ask") or [])}
    if "childAsk" in auto:
        return "auto"
    if "childAsk" in ask:
        return "ask"
    autonomy = plan.get("autonomy") or {}
    value = str(autonomy.get("childAsk") or "").lower()
    if value in {"ask", "auto"}:
        return value
    return "unknown"


def needs_you_count(obs: Observation) -> int:
    try:
        return int((obs.compact.get("counts") or {}).get("needs_you") or 0)
    except (TypeError, ValueError):
        return 0


def has_pending_child_question(obs: Observation) -> bool:
    saw_node_shape = False
    for node in obs.compact.get("active_nodes") or []:
        if not isinstance(node, dict):
            continue
        saw_node_shape = True
        status_group = str(node.get("bound_row_status_group") or "")
        if status_group == "needsYou":
            return True
        if str(node.get("bound_row_run_state") or "") == "waitingForQuestion" and status_group != "working":
            return True
    for node in obs.nodes:
        bound_row = node.get("bound_row")
        if isinstance(bound_row, dict) and bound_row:
            saw_node_shape = True
            status_group = str(bound_row.get("status_group") or "")
            if status_group == "needsYou":
                return True
            if str(bound_row.get("run_state") or "") == "waitingForQuestion" and status_group != "working":
                return True
    if needs_you_count(obs) > 0 and not saw_node_shape:
        return True
    return False


def iter_status_strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
        return
    if isinstance(value, dict):
        for nested in value.values():
            yield from iter_status_strings(nested)
        return
    if isinstance(value, list):
        for nested in value:
            yield from iter_status_strings(nested)


def child_input_tool_unavailable_token(obs: Observation) -> str | None:
    for source in [obs.compact.get("active_nodes") or [], obs.nodes]:
        for text in iter_status_strings(source):
            if CHILD_INPUT_TOOL_UNAVAILABLE not in text:
                continue
            match = re.search(rf"{CHILD_INPUT_TOOL_UNAVAILABLE}\s+`?([A-Za-z0-9_.:-]+)", text)
            return match.group(1) if match else "unknown"
    return None


def raise_child_input_tool_unavailable_if_present(obs: Observation, scenario: str) -> None:
    token = child_input_tool_unavailable_token(obs)
    if not token:
        return
    raise E2EFailure(
        f"{scenario} child backend could not create a structured pending question: "
        f"{CHILD_INPUT_TOOL_UNAVAILABLE} {token}. The selected child role did not advertise "
        "`ask_user` or `request_user_input`; use a backend with structured user-input support "
        "or a scripted child before running this live scenario."
    )


def pending_child_question_or_failed(obs: Observation, scenario: str) -> bool:
    if has_pending_child_question(obs):
        return True
    raise_child_input_tool_unavailable_if_present(obs, scenario)
    if obs.status in {"blocked", "completed", "stopped", "cancelled"}:
        raise E2EFailure(
            f"{scenario} reached {obs.status} before a visible pending child question appeared"
        )
    if obs.nodes and all(str(node.get("status") or "") not in {"pending", "running"} for node in obs.nodes):
        raise E2EFailure(
            f"{scenario} has no runnable child node left before a pending child question appeared"
        )
    return False


def pending_child_question_with_interaction_or_failed(obs: Observation, scenario: str) -> bool:
    if has_pending_child_question(obs):
        if node_bound_interaction_ids(obs.full) or node_bound_interaction_ids(obs.compact):
            return True
        return False
    raise_child_input_tool_unavailable_if_present(obs, scenario)
    if obs.status in {"blocked", "completed", "stopped", "cancelled"}:
        raise E2EFailure(
            f"{scenario} reached {obs.status} before a pending child interaction id appeared"
        )
    if obs.nodes and all(str(node.get("status") or "") not in {"pending", "running"} for node in obs.nodes):
        raise E2EFailure(
            f"{scenario} has no runnable child node left before a pending child interaction id appeared"
        )
    return False


def has_hidden_auto_child_question(obs: Observation) -> bool:
    if plan_childask_mode(obs.compact) != "auto":
        return False
    if has_pending_child_question(obs):
        raise E2EFailure("S6 childAsk escalation observed a user-facing question while childAsk was still Auto")
    if not (node_bound_interaction_ids(obs.full) or node_bound_interaction_ids(obs.compact)):
        return False
    for node in obs.nodes:
        if not isinstance(node, dict):
            continue
        bound_row = node.get("bound_row")
        if isinstance(bound_row, dict):
            if str(bound_row.get("run_state") or "") == "waitingForQuestion":
                return str(bound_row.get("status_group") or "") == "working"
    for node in obs.compact.get("active_nodes") or []:
        if not isinstance(node, dict):
            continue
        if str(node.get("bound_row_run_state") or "") == "waitingForQuestion":
            return str(node.get("bound_row_status_group") or "") == "working"
    return False


def hidden_auto_child_question_with_interaction_or_failed(obs: Observation, scenario: str) -> bool:
    if has_hidden_auto_child_question(obs):
        return True
    raise_child_input_tool_unavailable_if_present(obs, scenario)
    if obs.status in {"blocked", "completed", "stopped", "cancelled"}:
        raise E2EFailure(
            f"{scenario} reached {obs.status} before a hidden auto-routed child question appeared"
        )
    if obs.nodes and all(str(node.get("status") or "") not in {"pending", "running"} for node in obs.nodes):
        raise E2EFailure(
            f"{scenario} has no runnable child node left before a hidden auto-routed child question appeared"
        )
    return False


def mission_plan_payload(status: dict[str, Any]) -> dict[str, Any]:
    plan = status.get("plan")
    if isinstance(plan, dict):
        return plan
    nested = status.get("mission_status")
    if isinstance(nested, dict) and isinstance(nested.get("plan"), dict):
        return nested["plan"]
    return {}


def plan_decisions(status: dict[str, Any]) -> list[dict[str, Any]]:
    plan = mission_plan_payload(status)
    decisions = plan.get("decisions") or status.get("decisions") or []
    return [decision for decision in decisions if isinstance(decision, dict)]


def plan_evidence(status: dict[str, Any]) -> list[dict[str, Any]]:
    plan = mission_plan_payload(status)
    evidence = plan.get("evidence") or status.get("evidence") or []
    return [item for item in evidence if isinstance(item, dict)]


def plan_routing_decisions(status: dict[str, Any]) -> list[dict[str, Any]]:
    plan = mission_plan_payload(status)
    decisions: list[dict[str, Any]] = []
    seen: set[str] = set()
    for candidate in [
        status.get("routing_decisions_recent"),
        status.get("routing_decisions"),
        plan.get("routing_decisions"),
    ]:
        if isinstance(candidate, list):
            for item in candidate:
                if not isinstance(item, dict):
                    continue
                key = str(
                    item.get("id")
                    or item.get("routing_decision_id")
                    or item.get("decision_id")
                    or _stable_json(item)
                )
                if key in seen:
                    continue
                seen.add(key)
                decisions.append(item)
    return decisions


def decision_matches(
    decision: dict[str, Any],
    *,
    label: str | None = None,
    actor: str | None = None,
    decision_class: str | None = None,
) -> bool:
    if label is not None and str(decision.get("label") or "") != label:
        return False
    if actor is not None and str(decision.get("actor") or "") != actor:
        return False
    if decision_class is not None:
        classes = {
            str(decision.get("decision_class") or ""),
            str(decision.get("resolved_autonomy_class") or ""),
        }
        if decision_class not in classes:
            return False
    return True


def has_decision(
    status: dict[str, Any],
    *,
    label: str | None = None,
    actor: str | None = None,
    decision_class: str | None = None,
) -> bool:
    return bool(matching_decisions(status, label=label, actor=actor, decision_class=decision_class))


def matching_decisions(
    status: dict[str, Any],
    *,
    label: str | None = None,
    actor: str | None = None,
    decision_class: str | None = None,
    interaction_id: str | None = None,
) -> list[dict[str, Any]]:
    decisions = [
        decision
        for decision in plan_decisions(status)
        if decision_matches(decision, label=label, actor=actor, decision_class=decision_class)
    ]
    if interaction_id is not None:
        decisions = [decision for decision in decisions if str(decision.get("interaction_id") or "") == interaction_id]
    return decisions


def decision_timestamp(decision: dict[str, Any]) -> str:
    return str(decision.get("timestamp") or "")


def node_bound_interaction_ids(status: dict[str, Any]) -> list[str]:
    seen: set[str] = set()
    ids: list[str] = []
    for source in [status.get("nodes"), status.get("active_nodes")]:
        if not isinstance(source, list):
            continue
        for node in source:
            if not isinstance(node, dict):
                continue
            for key in ["bound_interaction_id", "interaction_id", "pending_interaction_id"]:
                value = str(node.get(key) or "")
                if value and value not in seen:
                    seen.add(value)
                    ids.append(value)
            bound_row = node.get("bound_row")
            if isinstance(bound_row, dict):
                for key in ["bound_interaction_id", "interaction_id", "pending_interaction_id"]:
                    value = str(bound_row.get(key) or "")
                    if value and value not in seen:
                        seen.add(value)
                        ids.append(value)
    return ids


def max_event_seq(events: list[dict[str, Any]]) -> int:
    seqs = [int(event.get("seq") or 0) for event in events if isinstance(event, dict)]
    return max(seqs, default=0)


def event_journal_has_bound_interaction_after(
    events: list[dict[str, Any]],
    interaction_id: str,
    since_seq: int,
) -> bool:
    for event in events:
        if int(event.get("seq") or 0) <= since_seq:
            continue
        for node in event.get("nodes") or []:
            if isinstance(node, dict) and str(node.get("bound_interaction_id") or "") == interaction_id:
                return True
    return False


def event_seq_for_decision_id(events: list[dict[str, Any]], decision_id: str) -> int | None:
    for event in events:
        if not isinstance(event, dict):
            continue
        decision_ids = {str(item) for item in (event.get("decision_ids") or [])}
        if decision_id in decision_ids:
            return int(event.get("seq") or 0)
    return None


def assert_childask_flip_order(
    events: list[dict[str, Any]],
    flip_decision: dict[str, Any],
    director_decision: dict[str, Any],
) -> None:
    flip_id = str(flip_decision.get("id") or "")
    director_id = str(director_decision.get("id") or "")
    if events and flip_id and director_id:
        flip_seq = event_seq_for_decision_id(events, flip_id)
        director_seq = event_seq_for_decision_id(events, director_id)
        if flip_seq is None or director_seq is None:
            raise E2EFailure(
                "S6 childAsk mission_events did not expose decision_ids for flip/director answer; "
                f"flip_id={flip_id!r} director_id={director_id!r}"
            )
        if director_seq <= flip_seq:
            raise E2EFailure(
                "S6 childAsk expected the user dial-change journal event to precede the Director answer; "
                f"flip_seq={flip_seq} director_seq={director_seq}"
            )
        return

    flip_ts = decision_timestamp(flip_decision)
    director_ts = decision_timestamp(director_decision)
    if not flip_ts or not director_ts or director_ts <= flip_ts:
        raise E2EFailure(
            "S6 childAsk expected the user dial-change decision to precede the Director childAsk answer; "
            f"flip={flip_ts!r} director={director_ts!r}"
        )


def assert_childask_escalation_order(
    events: list[dict[str, Any]],
    flip_decision: dict[str, Any],
    user_answer_decision: dict[str, Any],
) -> None:
    flip_id = str(flip_decision.get("id") or "")
    answer_id = str(user_answer_decision.get("id") or "")
    if events and flip_id and answer_id:
        flip_seq = event_seq_for_decision_id(events, flip_id)
        answer_seq = event_seq_for_decision_id(events, answer_id)
        if flip_seq is None or answer_seq is None:
            raise E2EFailure(
                "S6 childAsk escalation mission_events did not expose decision_ids for flip/user answer; "
                f"flip_id={flip_id!r} answer_id={answer_id!r}"
            )
        if answer_seq <= flip_seq:
            raise E2EFailure(
                "S6 childAsk escalation expected the Me dial-change journal event to precede the user answer; "
                f"flip_seq={flip_seq} answer_seq={answer_seq}"
            )
        return

    flip_ts = decision_timestamp(flip_decision)
    answer_ts = decision_timestamp(user_answer_decision)
    if not flip_ts or not answer_ts or answer_ts <= flip_ts:
        raise E2EFailure(
            "S6 childAsk escalation expected the Me dial-change decision to precede the user childAsk answer; "
            f"flip={flip_ts!r} answer={answer_ts!r}"
        )


def evidence_text(status: dict[str, Any]) -> str:
    parts: list[str] = []
    for item in plan_evidence(status):
        parts.extend(str(item.get(key) or "") for key in ["summary", "source", "details", "quote"])
    for node in status.get("nodes") or []:
        if isinstance(node, dict):
            parts.append(str(node.get("completion_evidence") or ""))
    return "\n".join(part for part in parts if part).lower()


def routing_decision_count(full: dict[str, Any]) -> int:
    return len(plan_routing_decisions(full))


def routing_is_agent_run_start(decision: dict[str, Any]) -> bool:
    values = " ".join(
        str(decision.get(key) or "")
        for key in [
            "operation",
            "operation_display_name",
            "tool",
            "label",
            "decision",
            "route",
            "routed_to",
            "command",
        ]
    ).lower()
    return "agent_run.start" in values or "start_fresh_readonly_child" in values


def observed_agent_run_start(observations: Iterable[Observation]) -> bool:
    for obs in observations:
        for status in [obs.compact, obs.full]:
            if any(routing_is_agent_run_start(item) for item in plan_routing_decisions(status)):
                return True
    return False


def bound_child_refs(status: dict[str, Any]) -> dict[str, list[str]]:
    sessions: set[str] = set()
    interactions: set[str] = set()
    for node in status.get("nodes") or []:
        if not isinstance(node, dict):
            continue
        for key in ["bound_session_id", "session_id", "agent_session_id"]:
            value = str(node.get(key) or "")
            if value:
                sessions.add(value)
        for key in ["bound_interaction_id", "interaction_id", "pending_interaction_id"]:
            value = str(node.get(key) or "")
            if value:
                interactions.add(value)
        bound_row = node.get("bound_row")
        if isinstance(bound_row, dict):
            for key in ["bound_session_id", "session_id", "agent_session_id"]:
                value = str(bound_row.get(key) or "")
                if value:
                    sessions.add(value)
            for key in ["bound_interaction_id", "interaction_id", "pending_interaction_id"]:
                value = str(bound_row.get(key) or "")
                if value:
                    interactions.add(value)
    return {"sessions": sorted(sessions), "interactions": sorted(interactions)}


def assert_s5_fresh_child_launch(observations: list[Observation], mode: str) -> dict[str, list[str]]:
    if not observed_agent_run_start(observations):
        raise E2EFailure(f"S5 {mode} expected a fresh agent_run.start routing decision")
    refs = bound_child_refs(observations[-1].full)
    if not refs["sessions"]:
        raise E2EFailure(f"S5 {mode} expected the completed node to retain a bound child session id")
    if not refs["interactions"]:
        raise E2EFailure(f"S5 {mode} expected the completed node to retain a bound child interaction id")
    return refs


def assert_s5_variant_token(status: dict[str, Any], token: str | None, mode: str) -> None:
    if token and token.lower() not in evidence_text(status):
        raise E2EFailure(f"S5 {mode} expected evidence/completion text to include variant token {token}")


def assert_scripted_child_completion_marker(
    status: dict[str, Any],
    token: str | None,
    mode: str,
    child_model_id: str,
) -> None:
    if child_model_id != SCRIPTED_CHILD_SELECTOR or not token:
        return
    expected = f"{SCRIPTED_CHILD_COMPLETION_PREFIX}Alpha token={token}"
    if expected.lower() not in evidence_text(status):
        raise E2EFailure(f"S5/S6 {mode} expected scripted completion marker {expected!r}")


def assert_s5_variant_refs_disjoint(ask_refs: dict[str, list[str]], auto_refs: dict[str, list[str]]) -> None:
    shared_sessions = sorted(set(ask_refs.get("sessions") or []) & set(auto_refs.get("sessions") or []))
    shared_interactions = sorted(set(ask_refs.get("interactions") or []) & set(auto_refs.get("interactions") or []))
    if shared_sessions or shared_interactions:
        raise E2EFailure(
            "S5 ask and auto variants reused child bindings: "
            f"sessions={shared_sessions or 'none'} interactions={shared_interactions or 'none'}"
        )


def assert_s7_stop(
    observations: list[Observation],
    *,
    interaction_id: str | None = None,
) -> dict[str, list[str]]:
    if not observations:
        raise E2EFailure("S7 stop did not record any observations")
    final = observations[-1]
    if final.status != "stopped":
        raise E2EFailure(f"S7 expected stopped mission, got {final.status}")
    assert_common_status_integrity(observations)
    if any(str(node.get("status") or "") == "running" for node in final.nodes):
        raise E2EFailure("S7 stopped mission still has a running plan node")
    if running_count(final) != 0:
        raise E2EFailure(f"S7 stopped mission still reports running count {running_count(final)}")
    if final.compact.get("ready_node_ids"):
        raise E2EFailure(f"S7 stopped mission still reports ready nodes: {final.compact.get('ready_node_ids')}")
    if has_pending_child_question(final) or needs_you_count(final) != 0:
        raise E2EFailure("S7 stopped mission still has a pending user decision/question")
    stop_decisions = matching_decisions(
        final.full,
        label="stopped the Mission",
        actor="user",
        decision_class="irreversible",
    )
    if not stop_decisions:
        raise E2EFailure("S7 expected a user actor irreversible stop decision")
    cancel_routes = [
        route
        for route in plan_routing_decisions(final.full)
        if str(route.get("operation") or "") == "agent_run.cancel"
    ]
    if not cancel_routes:
        raise E2EFailure("S7 expected an agent_run.cancel routing decision for active child work")
    if not observed_agent_run_start(observations):
        raise E2EFailure("S7 expected a fresh agent_run.start routing decision before stop")
    refs = {"sessions": [], "interactions": []}
    for obs in observations:
        obs_refs = bound_child_refs(obs.full)
        refs["sessions"].extend(ref for ref in obs_refs["sessions"] if ref not in refs["sessions"])
        refs["interactions"].extend(ref for ref in obs_refs["interactions"] if ref not in refs["interactions"])
    refs["sessions"].sort()
    refs["interactions"].sort()
    if not refs["sessions"]:
        raise E2EFailure("S7 expected to observe a bound child session before stop")
    if not refs["interactions"]:
        raise E2EFailure("S7 expected to observe a bound child interaction before stop")
    if interaction_id and interaction_id not in refs["interactions"]:
        raise E2EFailure(f"S7 expected stopped child refs to include interaction {interaction_id}")
    if not any(str(node.get("status") or "") == "cancelled" for node in final.nodes):
        raise E2EFailure("S7 expected at least one cancelled node after stop")
    return refs


def terminal_completed(obs: Observation) -> bool:
    return obs.status == "completed"


def terminal_stopped(obs: Observation) -> bool:
    return obs.status == "stopped"


def nonterminal_nodes_in_completed_mission(obs: Observation) -> list[dict[str, Any]]:
    if obs.status != "completed":
        return []
    return [
        node
        for node in obs.nodes
        if isinstance(node, dict) and str(node.get("status") or "") not in TERMINAL_STATUSES
    ]


def assert_common_status_integrity(observations: Iterable[Observation]) -> None:
    last_by_node: dict[str, str] = {}
    for obs in observations:
        incomplete = nonterminal_nodes_in_completed_mission(obs)
        if incomplete:
            summary = ", ".join(
                f"{node.get('title') or node.get('id')}: {node.get('status')}"
                for node in incomplete
            )
            raise E2EFailure(f"Mission reported completed with non-terminal nodes: {summary}")
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


def post_approval_continuation(obs: Observation) -> dict[str, Any]:
    compact_plan = obs.compact.get("plan") or {}
    full_plan = obs.full.get("plan") or {}
    value = compact_plan.get("post_approval_continuation") or full_plan.get("post_approval_continuation") or {}
    return value if isinstance(value, dict) else {}


def assert_s4_post_approval_continuation_lifecycle(
    observations: list[Observation],
    *,
    current_checkpoint_id: str,
) -> None:
    records = [
        (obs.index, post_approval_continuation(obs))
        for obs in observations
        if post_approval_continuation(obs)
    ]
    if not records:
        raise E2EFailure("S4 expected mission_status to expose post_approval_continuation after Proceed")
    statuses = [str(record.get("status") or "") for _, record in records]
    continuation_ids = {str(record.get("id") or "") for _, record in records}
    continuation_ids.discard("")
    if len(continuation_ids) != 1:
        raise E2EFailure(f"S4 expected one stable continuation id, got {sorted(continuation_ids)}")
    checkpoint_ids = {str(record.get("checkpoint_instance_id") or "") for _, record in records}
    if checkpoint_ids != {current_checkpoint_id}:
        raise E2EFailure(
            f"S4 expected continuation checkpoint identity {current_checkpoint_id}, got {sorted(checkpoint_ids)}"
        )
    plan_keys = {
        (str(record.get("plan_id") or ""), int(record.get("plan_revision") or 0))
        for _, record in records
    }
    if any(not plan_id or plan_revision <= 0 for plan_id, plan_revision in plan_keys):
        raise E2EFailure(f"S4 expected non-empty continuation plan identity, got {sorted(plan_keys)}")
    if len(plan_keys) != 1:
        raise E2EFailure(f"S4 expected stable continuation plan identity, got {sorted(plan_keys)}")
    collapsed: list[str] = []
    for status in statuses:
        if not collapsed or collapsed[-1] != status:
            collapsed.append(status)
    forbidden = {"failed", "invalidated"}.intersection(statuses)
    if forbidden:
        raise E2EFailure(f"S4 post-approval continuation reached forbidden status(es): {sorted(forbidden)}")
    if not any(status in {"pending", "deferred", "dispatching", "delivered"} for status in statuses):
        raise E2EFailure(f"S4 expected a post-approval continuation lifecycle observation, got {statuses}")
    if collapsed.count("delivered") != 1 or collapsed[-1] != "delivered":
        raise E2EFailure(f"S4 expected exactly one delivered transition at the end, got {collapsed}")
    final_record = records[-1][1]
    final_attempts = int(final_record.get("attempts") or 0)
    if final_attempts != 1:
        raise E2EFailure(f"S4 expected exactly one accepted continuation dispatch attempt, got {final_attempts}")
    if final_record.get("last_error") is not None:
        raise E2EFailure(f"S4 expected delivered continuation last_error == null, got {final_record.get('last_error')!r}")


def assert_s4_checkpoint_revision(
    observations: list[Observation],
    *,
    stale_checkpoint_id: str,
    current_checkpoint_id: str,
    decisions_before_stale_submit: set[str],
    decisions_after_stale_submit: set[str],
    token: str | None = None,
) -> None:
    if not stale_checkpoint_id or not current_checkpoint_id:
        raise E2EFailure("S4 expected non-empty stale and current checkpoint instance ids")
    if stale_checkpoint_id == current_checkpoint_id:
        raise E2EFailure(f"S4 expected checkpoint instance id to change after revision, got {current_checkpoint_id}")
    if decisions_after_stale_submit != decisions_before_stale_submit:
        added = sorted(decisions_after_stale_submit - decisions_before_stale_submit)
        raise E2EFailure(f"S4 stale Proceed submit recorded unexpected decision ids: {added}")
    final = observations[-1]
    if final.status != "completed":
        raise E2EFailure(f"S4 expected completed mission, got {final.status}")
    approvals = matching_decisions(
        final.full,
        label="approved the Mission plan",
        actor="user",
    )
    current_approvals = [
        decision
        for decision in approvals
        if decision_checkpoint_instance_id(decision) == current_checkpoint_id
    ]
    stale_approvals = [
        decision
        for decision in approvals
        if decision_checkpoint_instance_id(decision) == stale_checkpoint_id
    ]
    if len(current_approvals) != 1:
        raise E2EFailure(
            f"S4 expected exactly one approval decision stamped with current checkpoint {current_checkpoint_id}, "
            f"got {len(current_approvals)}"
        )
    if stale_approvals:
        raise E2EFailure(f"S4 found approval decision stamped with stale checkpoint {stale_checkpoint_id}")
    if token and token not in evidence_text(final.full).lower() and token.lower() not in _stable_json(final.full).lower():
        raise E2EFailure(f"S4 expected final evidence/status to include token {token}")
    assert_s4_post_approval_continuation_lifecycle(
        observations,
        current_checkpoint_id=current_checkpoint_id,
    )
    assert_common_status_integrity(observations)


def assert_s6_pace_flip(before: Observation, after: Observation) -> None:
    if plan_default_pace(before.compact) != "step":
        raise E2EFailure(f"S6 expected initial Step pace, got {plan_default_pace(before.compact)!r}")
    if plan_default_pace(after.compact) != "auto":
        raise E2EFailure(f"S6 expected Auto pace after set_pace, got {plan_default_pace(after.compact)!r}")
    if not before.fingerprint or after.fingerprint == before.fingerprint:
        raise E2EFailure("S6 expected compact fingerprint to advance after set_pace")
    if plan_revision(after.compact) <= plan_revision(before.compact):
        raise E2EFailure(
            f"S6 expected revision bump after set_pace, got before={plan_revision(before.compact)} "
            f"after={plan_revision(after.compact)}"
        )
    if user_decision_count(after.compact) != user_decision_count(before.compact) + 1:
        raise E2EFailure(
            "S6 expected exactly one user decision for set_pace; "
            f"before={user_decision_count(before.compact)} after={user_decision_count(after.compact)}"
        )
    if plan_approval_state(after.compact) != "awaiting_approval":
        raise E2EFailure(f"S6 expected approval checkpoint to remain awaiting_approval, got {plan_approval_state(after.compact)!r}")
    if not has_checkpoint_action(after.compact, "Proceed"):
        raise E2EFailure("S6 expected pending approval checkpoint to keep its Proceed action after set_pace")


def assert_s6_childask_flip(
    observations: list[Observation],
    events: list[dict[str, Any]],
    *,
    interaction_id: str,
    seq_before_flip: int,
    token: str | None = None,
) -> dict[str, list[str]]:
    final = observations[-1]
    if final.status != "completed":
        raise E2EFailure(f"S6 childAsk expected completed mission, got {final.status}")
    if needs_you_count(final) != 0:
        raise E2EFailure(f"S6 childAsk expected no pending Decisions at completion, got {needs_you_count(final)}")
    if interaction_id not in node_bound_interaction_ids(final.full):
        raise E2EFailure(f"S6 childAsk expected final node to keep interaction id {interaction_id}")

    flip_decisions = matching_decisions(
        final.full,
        label="routed child questions to the Director",
        actor="user",
        decision_class="childAsk",
    )
    if not flip_decisions:
        raise E2EFailure("S6 childAsk expected a user decision routing child questions to the Director")
    director_decisions = matching_decisions(
        final.full,
        actor="director",
        decision_class="childAsk",
        interaction_id=interaction_id,
    )
    if len(director_decisions) != 1:
        raise E2EFailure(
            f"S6 childAsk expected exactly one Director childAsk answer for {interaction_id}, "
            f"got {len(director_decisions)}"
        )
    user_answer_decisions = matching_decisions(
        final.full,
        label="answered a child question",
        actor="user",
        decision_class="childAsk",
        interaction_id=interaction_id,
    )
    if user_answer_decisions:
        raise E2EFailure("S6 childAsk expected the pending question to be answered by Director, not an extra user answer")

    assert_childask_flip_order(events, flip_decisions[0], director_decisions[0])
    if not event_journal_has_bound_interaction_after(events, interaction_id, seq_before_flip):
        raise E2EFailure("S6 childAsk mission_events did not show the same bound interaction after the flip")
    if "alpha" not in evidence_text(final.full):
        raise E2EFailure("S6 childAsk expected final evidence/completion text to mention Alpha")
    if token:
        assert_s5_variant_token(final.full, token, "childAsk flip")
    refs = assert_s5_fresh_child_launch(observations, "childAsk flip")
    if interaction_id not in refs["interactions"]:
        raise E2EFailure(f"S6 childAsk expected fresh child refs to include interaction {interaction_id}")
    assert_common_status_integrity(observations)
    return refs


def assert_s6_childask_escalation(
    observations: list[Observation],
    events: list[dict[str, Any]],
    *,
    interaction_id: str,
    seq_before_flip: int,
    token: str | None = None,
) -> dict[str, list[str]]:
    final = observations[-1]
    if final.status != "completed":
        raise E2EFailure(f"S6 childAsk escalation expected completed mission, got {final.status}")
    if needs_you_count(final) != 0:
        raise E2EFailure(
            f"S6 childAsk escalation expected no pending Decisions at completion, got {needs_you_count(final)}"
        )
    if interaction_id not in node_bound_interaction_ids(final.full):
        raise E2EFailure(f"S6 childAsk escalation expected final node to keep interaction id {interaction_id}")
    if not any(has_hidden_auto_child_question(obs) for obs in observations):
        raise E2EFailure("S6 childAsk escalation never observed the hidden auto-routed pending question")
    if not any(
        has_pending_child_question(obs)
        and interaction_id in (node_bound_interaction_ids(obs.full) or node_bound_interaction_ids(obs.compact))
        for obs in observations
    ):
        raise E2EFailure("S6 childAsk escalation never observed the same interaction reappear for the user")

    flip_decisions = matching_decisions(
        final.full,
        label="routed child questions to Me",
        actor="user",
        decision_class="childAsk",
    )
    if not flip_decisions:
        raise E2EFailure("S6 childAsk escalation expected a user decision routing child questions to Me")
    user_answer_decisions = matching_decisions(
        final.full,
        label="answered a child question",
        actor="user",
        decision_class="childAsk",
        interaction_id=interaction_id,
    )
    if len(user_answer_decisions) != 1:
        raise E2EFailure(
            f"S6 childAsk escalation expected exactly one user childAsk answer for {interaction_id}, "
            f"got {len(user_answer_decisions)}"
        )
    director_decisions = matching_decisions(
        final.full,
        actor="director",
        decision_class="childAsk",
        interaction_id=interaction_id,
    )
    if director_decisions:
        raise E2EFailure("S6 childAsk escalation expected no Director answer after routing child questions to Me")

    assert_childask_escalation_order(events, flip_decisions[0], user_answer_decisions[0])
    if not event_journal_has_bound_interaction_after(events, interaction_id, seq_before_flip):
        raise E2EFailure("S6 childAsk escalation mission_events did not show the same bound interaction after the flip")
    if "alpha" not in evidence_text(final.full):
        raise E2EFailure("S6 childAsk escalation expected final evidence/completion text to mention Alpha")
    if token:
        assert_s5_variant_token(final.full, token, "childAsk escalation")
    refs = assert_s5_fresh_child_launch(observations, "childAsk escalation")
    if interaction_id not in refs["interactions"]:
        raise E2EFailure(f"S6 childAsk escalation expected fresh child refs to include interaction {interaction_id}")
    assert_common_status_integrity(observations)
    return refs


def assert_s5_ask(observations: list[Observation], token: str | None = None) -> dict[str, list[str]]:
    final = observations[-1]
    if final.status != "completed":
        raise E2EFailure(f"S5 ask expected completed mission, got {final.status}")
    assert_common_status_integrity(observations)
    if not any(has_pending_child_question(obs) for obs in observations):
        raise E2EFailure("S5 ask never observed a pending child question / Decisions queue item")
    if needs_you_count(final) != 0:
        raise E2EFailure(f"S5 ask expected no pending Decisions at completion, got {needs_you_count(final)}")
    if not has_decision(final.full, label="answered a child question", actor="user", decision_class="childAsk"):
        raise E2EFailure("S5 ask expected a user actor childAsk decision for the external answer")
    if "alpha" not in evidence_text(final.full):
        raise E2EFailure("S5 ask expected final evidence/completion text to mention Alpha")
    assert_s5_variant_token(final.full, token, "ask")
    refs = assert_s5_fresh_child_launch(observations, "ask")
    return refs


def assert_s5_auto(observations: list[Observation], token: str | None = None) -> dict[str, list[str]]:
    final = observations[-1]
    if final.status != "completed":
        raise E2EFailure(f"S5 auto expected completed mission, got {final.status}")
    assert_common_status_integrity(observations)
    if any(has_pending_child_question(obs) for obs in observations):
        raise E2EFailure("S5 auto observed a user-facing pending child question")
    if has_decision(final.full, label="answered a child question", actor="user", decision_class="childAsk"):
        raise E2EFailure("S5 auto must not record a user actor child-answer decision")
    director_child_decision = any(
        decision_matches(decision, actor="director", decision_class="childAsk")
        or (
            str(decision.get("actor") or "") == "director"
            and "child question" in " ".join(
                str(decision.get(key) or "").lower()
                for key in ["label", "reason", "checkpoint_id", "checkpoint_instance_id"]
            )
        )
        for decision in plan_decisions(final.full)
    )
    if not director_child_decision:
        raise E2EFailure("S5 auto expected a director child-question decision explaining the answer")
    if "alpha" not in evidence_text(final.full):
        raise E2EFailure("S5 auto expected final evidence/completion text to mention Alpha")
    assert_s5_variant_token(final.full, token, "auto")
    if needs_you_count(final) != 0:
        raise E2EFailure(f"S5 auto expected no pending Decisions at completion, got {needs_you_count(final)}")
    refs = assert_s5_fresh_child_launch(observations, "auto")
    return refs


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
        "not commit, push, open PRs, merge, or run cluster-mutating validation. For these marker "
        "files, use direct shell checks/writes against the exact absolute paths if file tools "
        "remap paths into isolated worktrees. After writing the assigned marker file, report the "
        "result and stop; do not keep polling. Record evidence for every completed node and close "
        "with a receipt."
    )


def s6_message() -> str:
    return (
        "Run this as a scoped Director mission for a Step/Auto dial smoke test. Record a "
        'visible Mission Plan with approval_state:"awaiting_approval" before child sessions. '
        "Keep the plan tiny: one coordinator-only verification node that would inspect status "
        "after approval, but do not start any child sessions until approved. Do not edit files, "
        "run validation, commit, push, open PRs, merge, or start a follow-up Mission."
    )


def s4_message(token: str) -> str:
    return (
        "Run this as a scoped Director mission for checkpoint revision identity. Record a visible "
        'Mission Plan with approval_state:"awaiting_approval" before child sessions. Keep the plan '
        "tiny: one coordinator-only node titled `S4 checkpoint revision verifier` that records "
        f"evidence containing token `{token}` after approval, then completes. Do not start child "
        "sessions, edit files, run validation, commit, push, open PRs, merge, or start a follow-up "
        "Mission. If you receive a directive containing `S4_REVISION_REQUEST`, revise the visible "
        f"Mission Plan exactly once before approval, keep approval_state:\"awaiting_approval\", keep token `{token}`, "
        "increment the plan revision, and wait for approval again."
    )


def s8_message(token: str) -> str:
    return (
        "Run this as a scoped Director mission for the trusted revision-proposal lifecycle. Record a visible "
        'Mission Plan with approval_state:"awaiting_approval" before doing work. Use two coordinator-only nodes: '
        f"first S8 inspect premise {token}, then dependent S8 execute revised contract {token}. After initial "
        "approval, complete only the premise inspection with evidence that the approved assumption is stale. Then "
        "call coordinator_chat propose_revision exactly once against the current approved material-contract identity. "
        "Use representation summary_only, summary 'Replace the stale premise before execution', affected_fields "
        "['objective', 'nodes', 'done_criteria'], remedy 'changed_assumption', and requested_change "
        f"'Use the verified S8 premise {token} before execution.' Do not include a replacement plan or diff. After "
        "filing, do not resolve the proposal, impersonate a user decision, mutate the approved contract, start or "
        "complete the execution node, or call propose_revision again. Wait for the external Revise plan action. "
        "When the trusted app reports revisionRequested, write one concrete revised Mission Plan that retains token "
        f"{token}, changes the objective and execution node to require the verified premise, sets "
        'approval_state:"awaiting_approval", and waits for exact user approval. Do not execute before that approval. '
        f"After the revised plan is approved, complete its coordinator-only execution node with evidence containing {token}, "
        "then complete the Mission. Do not start child sessions, edit files, run validation, commit, push, open PRs, "
        "merge, deploy, or start a follow-up Mission."
    )


def scripted_child_contract_line(token: str) -> str:
    return f"SCRIPTED_CHILD_V1 ask_marker token={token} options=Alpha,Beta"


def s5_message(
    mode: str,
    variant_token: str | None = None,
    child_model_id: str = "explore",
) -> str:
    token = variant_token or "S5-child-marker"
    if child_model_id == SCRIPTED_CHILD_SELECTOR:
        child_prompt = (
            "Use the scripted Director E2E child contract. Copy this exact line on its own line:\n"
            f"{scripted_child_contract_line(token)}\n"
            "After the scripted interaction is answered, report the exact completion marker "
            f"`{SCRIPTED_CHILD_COMPLETION_PREFIX}Alpha token={token}` in normal text."
        )
        completion_requirement = (
            f"the exact scripted completion marker `{SCRIPTED_CHILD_COMPLETION_PREFIX}Alpha token={token}` "
            f"and the exact token `{token}`"
        )
    else:
        child_prompt = (
            f"You are the S5/S6 marker child for token `{token}`. Call the RepoPrompt MCP tool named `ask_user` now. "
            "Ask exactly one single-select question with id `marker_choice`, header `Marker`, question "
            "`Which marker should this child use?`, options `Alpha` and `Beta`, and no auto-resolution. If `ask_user` "
            "is not advertised, use `request_user_input` if that structured user-input tool is advertised. Do not answer "
            "in plain text or finish until the tool has created a pending user question. After the interaction is answered, "
            f"report the selected marker and token `{token}` in normal text. If neither `ask_user` nor `request_user_input` "
            f"is advertised, report `S5_USER_INPUT_TOOL_UNAVAILABLE {token}` and stop."
        )
        completion_requirement = f"the exact selected marker `Alpha` and token `{token}`"
    return (
        "Run this as a scoped Director mission for a Me/Director child-question smoke test. "
        'Record a visible Mission Plan with approval_state:"awaiting_approval" before child sessions. '
        "After approval, launch exactly one narrow read-only child Agent Mode session using `agent_run.start` "
        f"with `model_id:\"{child_model_id}\"`, the planned `mission_node_id`, and no workflow_name or worktree. Use this exact "
        f"child prompt without adding Mission Policy, childAsk, Me/Director routing, Coordinator autonomy, or who will "
        f"answer the question: {child_prompt} "
        "The expected safe answer is `Alpha`. The child final output, plan evidence, and node completion evidence "
        f"must include the exact token `{token}`. Parent/Director handling owns the route: if current Mission Policy routes child questions to Me, "
        "pause for the external answer; if it routes child questions to the Director, wait for the pending child "
        "interaction and answer `Alpha` through the Director path, then record a director child-question decision "
        "and evidence explaining that answer. After the answer, wait for the child final output, then "
        "mark the node completed only after replacing `completion_evidence` with result evidence that includes "
        f"{completion_requirement}. The child should report the selected answer in normal text that "
        "includes `Alpha`, record evidence, and stop. Do not reuse any session_id, interaction_id, routing_decision, "
        "node_id, or evidence from another S5 variant or prior Mission. Do not edit files, run validation, commit, "
        f"push, open PRs, merge, or start a follow-up Mission. This run is the `{mode}` variant."
    )


def s2_event_convergence_sequence_is_complete(events: list[dict[str, Any]]) -> bool:
    try:
        assert_s2_mission_event_sequence(events)
        return True
    except E2EFailure:
        return False


def s2_terminal_grace_is_warranted(artifacts: RunArtifacts, sandbox_root: Path) -> bool:
    if first_s2_convergence_mode(artifacts.observations):
        return True
    if artifacts.feature_available("mission_events") is True and s2_event_convergence_sequence_is_complete(artifacts.mission_events):
        return True
    marker_state = marker_paths(sandbox_root, {"A.md", "B.md", "SUMMARY.md"})
    return all(marker_state.get(name) for name in ["A.md", "B.md", "SUMMARY.md"])


def wait_for_s2_terminal_grace(
    client: RpcClient,
    artifacts: RunArtifacts,
    session_id: str,
    args: argparse.Namespace,
    watcher: InvariantWatcher,
) -> Observation | None:
    grace_seconds = max(int(getattr(args, "terminal_grace_seconds", 0) or 0), 0)
    if grace_seconds <= 0:
        return None
    artifacts.add_checkpoint("terminal-grace")
    deadline = time.monotonic() + grace_seconds
    last_obs = artifacts.observations[-1] if artifacts.observations else observe(client, artifacts, session_id)
    while time.monotonic() < deadline:
        capture_mission_events(client, artifacts, session_id, args.events_mode)
        obs = observe(client, artifacts, session_id)
        watcher.check(obs)
        last_obs = obs
        if terminal_completed(obs):
            artifacts.add_checkpoint("completed-after-grace")
            return obs
        remaining = int(deadline - time.monotonic())
        if remaining <= 0:
            break
        wait_for_update(client, session_id, obs.fingerprint or last_obs.fingerprint, remaining)
    return None


def run_s1(client: RpcClient, artifacts: RunArtifacts, args: argparse.Namespace) -> None:
    sandbox_root = Path(args.sandbox_root).expanduser().resolve() if args.sandbox_root else None
    artifacts.record_timing("started")
    if sandbox_root and sandbox_root.exists() and (sandbox_root / ".git").exists():
        if args.clean_sandbox:
            clean_sandbox(sandbox_root, client.repo_root, args.allow_clean_outside_tmp)
        assert_clean_git(sandbox_root)
    session_id = start_mission(client, "Director E2E S1 read-only", s1_message(), "s1", args.coordinator_model_id)
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
    bind_visible_context_for_sandbox(client, sandbox_root)
    if not sandbox_is_visible(client, sandbox_root):
        raise E2EFailure(f"S2 sandbox root is not visible in the selected app workspace: {sandbox_root}")
    session_id = start_mission(client, "Director E2E S2 convergence", s2_message(sandbox_root), "s2", args.coordinator_model_id)
    approve_initial_plan(client, artifacts, session_id, args)
    watcher = InvariantWatcher(artifacts)
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

    try:
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
            watcher=watcher,
        )
    except E2EFailure as exc:
        if not timeout_failure_may_be_terminal_graced(exc) or not s2_terminal_grace_is_warranted(artifacts, sandbox_root):
            raise
        final = wait_for_s2_terminal_grace(client, artifacts, session_id, args, watcher)
        if final is None:
            raise
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


def run_s4(client: RpcClient, artifacts: RunArtifacts, args: argparse.Namespace) -> None:
    artifacts.record_timing("started")
    variant_token = f"S4-checkpoint-{uuid.uuid4().hex[:8]}"
    session_id = start_mission(
        client,
        f"Director E2E S4 checkpoint revision {variant_token}",
        s4_message(variant_token),
        "s4",
        args.coordinator_model_id,
    )
    initial = wait_until(
        client,
        artifacts,
        session_id,
        lambda item: (
            plan_approval_state(item.compact) == "awaiting_approval"
            and has_checkpoint_action(item.compact, "Proceed")
            and checkpoint_instance_id(item.compact) is not None
            and plan_or_nodes_mention_token(item.full, variant_token)
        ),
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("plan-visible")
    stale_checkpoint_id = checkpoint_instance_id(initial.compact)
    if not stale_checkpoint_id:
        raise E2EFailure("S4 initial checkpoint did not expose checkpoint_instance_id")
    initial_revision = plan_revision(initial.compact)
    revise_action = checkpoint_action(initial.compact, "Revise")
    if not revise_action:
        raise E2EFailure("S4 initial checkpoint did not expose a Revise action")
    revision_marker = f"S4_REVISION_REQUEST {uuid.uuid4().hex[:8]}"
    revise_message = str(revise_action.get("submit_message") or "Revise the plan:")
    revise_response = submit_with_midrun_retry(client, artifacts, session_id, {
        "op": "submit",
        "coordinator_session_id": session_id,
        "message": (
            f"{revise_message}\n\n{revision_marker}: revise the plan now before approval. "
            f"Keep approval_state:\"awaiting_approval\", keep token `{variant_token}`, "
            "and do not approve or start work yet."
        ),
        "compact": True,
    }, args, "S4 Revise")
    write_json(artifacts.root / "revision_request_response.json", revise_response)
    if revise_response.get("accepted") is False:
        raise E2EFailure(f"S4 revision request rejected: {revise_response.get('error') or revise_response}")
    artifacts.add_checkpoint("revision-requested")

    revised = wait_until(
        client,
        artifacts,
        session_id,
        lambda item: (
            plan_approval_state(item.compact) == "awaiting_approval"
            and has_checkpoint_action(item.compact, "Proceed")
            and (checkpoint_instance_id(item.compact) or "") != stale_checkpoint_id
            and plan_revision(item.compact) > initial_revision
            and plan_or_nodes_mention_token(item.full, variant_token)
        ),
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("revision-visible")
    revised_checkpoint_id = checkpoint_instance_id(revised.compact)
    if not revised_checkpoint_id:
        raise E2EFailure("S4 revised checkpoint did not expose checkpoint_instance_id")
    proceed = checkpoint_action(revised.compact, "Proceed")
    if not proceed:
        raise E2EFailure("S4 revised checkpoint did not expose a Proceed action")
    proceed_message = str(proceed.get("submit_message") or "Approved to proceed.")
    checkpoint_action_id = str(proceed.get("checkpoint_action") or "proceed")
    decisions_before_stale = decision_ids(revised.full)

    stale_response = submit_with_midrun_retry(client, artifacts, session_id, {
        "op": "submit",
        "coordinator_session_id": session_id,
        "message": proceed_message,
        "checkpoint_action": checkpoint_action_id,
        "expected_checkpoint_instance_id": stale_checkpoint_id,
        "compact": True,
    }, args, "S4 stale Proceed")
    write_json(artifacts.root / "stale_checkpoint_submit_response.json", stale_response)
    if stale_response.get("accepted") is not False:
        raise E2EFailure(f"S4 stale Proceed submit unexpectedly accepted: {stale_response}")
    stale_error = str(stale_response.get("error") or "")
    if not stale_checkpoint_submit_rejected(stale_error):
        raise E2EFailure(f"S4 stale Proceed rejection did not name the current checkpoint: {stale_error}")
    after_stale = observe(client, artifacts, session_id)
    capture_mission_events(client, artifacts, session_id, args.events_mode)
    decisions_after_stale = decision_ids(after_stale.full)
    artifacts.add_checkpoint("stale-submit-rejected")

    latest_after_stale_checkpoint_id = checkpoint_instance_id(after_stale.compact) or revised_checkpoint_id
    if latest_after_stale_checkpoint_id != revised_checkpoint_id:
        artifacts.add_checkpoint("post-stale-checkpoint-refreshed")
    current_response, current_checkpoint_id, accepted_checkpoint_observation = submit_current_proceed_with_checkpoint_refresh(
        client,
        artifacts,
        session_id,
        after_stale,
        args,
    )
    write_json(artifacts.root / "current_checkpoint_submit_response.json", current_response)
    current_attempts_path = artifacts.root / "current_checkpoint_submit_attempts.json"
    current_attempts = json.loads(current_attempts_path.read_text()) if current_attempts_path.exists() else []
    if len(current_attempts) != 1:
        raise E2EFailure(f"S4 expected one accepted current Proceed submit attempt, got {len(current_attempts)}")
    current_wire_submits_path = artifacts.root / "current_checkpoint_wire_submits.json"
    current_wire_submits = json.loads(current_wire_submits_path.read_text()) if current_wire_submits_path.exists() else []
    if len(current_wire_submits) != 1:
        raise E2EFailure(f"S4 expected exactly one current Proceed wire submit, got {len(current_wire_submits)}")
    artifacts.add_checkpoint("current-submit-accepted")

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
    assert_s4_checkpoint_revision(
        artifacts.observations,
        stale_checkpoint_id=stale_checkpoint_id,
        current_checkpoint_id=current_checkpoint_id,
        decisions_before_stale_submit=decisions_before_stale,
        decisions_after_stale_submit=decisions_after_stale,
        token=variant_token,
    )
    capture_receipt(client, artifacts, session_id, args.receipt_mode)
    artifacts.finalize(True, "s4", {
        "coordinator_session_id": session_id,
        "final_status": final.status,
        "variant_token": variant_token,
        "revision_before": initial_revision,
        "revision_after": plan_revision(accepted_checkpoint_observation.compact),
        "stale_checkpoint_instance_id": stale_checkpoint_id,
        "current_checkpoint_instance_id": current_checkpoint_id,
    })


def run_s8(client: RpcClient, artifacts: RunArtifacts, args: argparse.Namespace) -> None:
    artifacts.record_timing("started")
    token = f"S8-revision-proposal-{uuid.uuid4().hex[:8]}"
    session_id = start_mission(
        client,
        f"Director E2E S8 trusted revision proposal {token}",
        s8_message(token),
        "s8",
        args.coordinator_model_id,
    )
    approve_initial_plan(client, artifacts, session_id, args)

    proposed = wait_until(
        client,
        artifacts,
        session_id,
        lambda item: (
            pending_revision_proposal(item.compact) is not None
            and (item.compact.get("checkpoint") or {}).get("kind") == "revision_proposal"
            and plan_approval_state(item.compact) == "approved"
        ),
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("revision-proposal-visible")
    assert_summary_only_revision_checkpoint(proposed.compact)
    pending = pending_revision_proposal(proposed.compact) or {}
    proposal_id = str(pending.get("proposal_id") or "")
    contract_fingerprint = str(pending.get("base_contract_fingerprint") or "")
    proposal_checkpoint_id = checkpoint_instance_id(proposed.compact) or ""
    if not proposal_id or not contract_fingerprint or not proposal_checkpoint_id:
        raise E2EFailure("S8 proposal status omitted stable proposal/contract/checkpoint identity")
    current_contract = revision_proposal_status(proposed.compact).get("current_contract") or {}
    if str(current_contract.get("fingerprint") or "") != contract_fingerprint:
        raise E2EFailure("S8 pending proposal base does not match the current approved contract")
    decisions_before_pause = decision_ids(proposed.full)
    node_counts_before_pause = dict(node_counts(proposed))
    if int(node_counts_before_pause.get("running") or 0) != 0:
        raise E2EFailure(f"S8 execution was still running at proposal pause: {node_counts_before_pause}")

    time.sleep(1)
    paused = observe(client, artifacts, session_id)
    capture_mission_events(client, artifacts, session_id, args.events_mode)
    assert_summary_only_revision_checkpoint(paused.compact)
    paused_pending = pending_revision_proposal(paused.compact) or {}
    stable_identity = (
        str(paused_pending.get("proposal_id") or ""),
        str(paused_pending.get("base_contract_fingerprint") or ""),
        checkpoint_instance_id(paused.compact) or "",
    )
    if stable_identity != (proposal_id, contract_fingerprint, proposal_checkpoint_id):
        raise E2EFailure(
            "S8 proposal identities changed while awaiting external resolution: "
            f"{(proposal_id, contract_fingerprint, proposal_checkpoint_id)} -> {stable_identity}"
        )
    if recent_revision_proposal_resolution(paused.compact) is not None:
        raise E2EFailure("S8 Director self-resolved the proposal before external action")
    if decision_ids(paused.full) != decisions_before_pause:
        raise E2EFailure("S8 proposal pause recorded a decision before external resolution")
    if int(node_counts(paused).get("running") or 0) != 0:
        raise E2EFailure(f"S8 execution advanced while proposal was pending: {node_counts(paused)}")
    artifacts.add_checkpoint("revision-proposal-paused")

    revise_action = checkpoint_action(paused.compact, "Revise plan")
    if not revise_action:
        raise E2EFailure("S8 pending proposal did not expose Revise plan")
    response = client.coordinator({
        "op": "submit",
        "coordinator_session_id": session_id,
        "checkpoint_action": str(revise_action.get("checkpoint_action") or ""),
        "proposal_id": str(revise_action.get("proposal_id") or ""),
        "expected_contract_fingerprint": str(revise_action.get("expected_contract_fingerprint") or ""),
        "expected_checkpoint_instance_id": str(revise_action.get("expected_checkpoint_instance_id") or ""),
        "compact": True,
    }, timeout=180)
    write_json(artifacts.root / "revise_plan_response.json", response)
    if response.get("accepted") is False:
        raise E2EFailure(f"S8 external Revise plan rejected: {response.get('error') or response}")
    artifacts.add_checkpoint("revision-requested")

    accepted = wait_until(
        client,
        artifacts,
        session_id,
        lambda item: bool(
            (revision_proposal_status(item.compact).get("accepted_drafting") or {}).get(
                "resolution_id"
            )
        ),
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    accepted_drafting = revision_proposal_status(accepted.compact).get("accepted_drafting") or {}
    drafting_hints = accepted_drafting.get("submit_hints") or {}
    resolution_id = str(accepted_drafting.get("resolution_id") or "")
    hinted_resolution_id = str(drafting_hints.get("accepted_revision_resolution_id") or "")
    hinted_session_id = str(drafting_hints.get("coordinator_session_id") or "")
    if not resolution_id or hinted_resolution_id != resolution_id:
        raise E2EFailure("S8 accepted drafting status omitted its resolution-bound submit hint")
    if hinted_session_id != session_id:
        raise E2EFailure("S8 accepted drafting submit hint was not bound to the target Mission")
    if str((recent_revision_proposal_resolution(accepted.compact) or {}).get("resolution_id") or "") != resolution_id:
        raise E2EFailure("S8 accepted drafting hint did not match the recent resolution identity")

    drafting_response = submit_with_midrun_retry(client, artifacts, session_id, {
        "op": "submit",
        "coordinator_session_id": session_id,
        "accepted_revision_resolution_id": resolution_id,
        "message": (
            "Continue the accepted revision flow now. Draft and publish a concrete revised "
            f"Mission Plan for user approval that incorporates {token}. Do not execute it "
            "before the revised-plan approval checkpoint is accepted."
        ),
        "compact": True,
    }, args, "S8 concrete revised-plan drafting")
    write_json(artifacts.root / "revision_drafting_response.json", drafting_response)
    if drafting_response.get("accepted") is False:
        raise E2EFailure(
            "S8 accepted Revise could not resume concrete revised-plan drafting: "
            f"{drafting_response.get('error') or drafting_response}"
        )
    if str(drafting_response.get("accepted_revision_resolution_id") or "") != resolution_id:
        raise E2EFailure("S8 drafting response did not preserve the accepted resolution identity")
    artifacts.add_checkpoint("revision-drafting-submitted")

    revised = wait_until(
        client,
        artifacts,
        session_id,
        lambda item: (
            plan_approval_state(item.compact) == "awaiting_approval"
            and (item.compact.get("checkpoint") or {}).get("kind") == "plan_approval"
            and has_checkpoint_action(item.compact, "Proceed")
            and pending_revision_proposal(item.compact) is None
            and (recent_revision_proposal_resolution(item.compact) or {}).get("outcome")
            == "accepted_for_concrete_revision"
            and plan_or_nodes_mention_token(item.full, token)
        ),
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("revision-visible")
    revised_checkpoint_id = checkpoint_instance_id(revised.compact) or ""
    if not revised_checkpoint_id or revised_checkpoint_id == proposal_checkpoint_id:
        raise E2EFailure("S8 concrete revised plan did not expose a distinct exact-approval checkpoint")
    revised_contract = (
        revision_proposal_status(revised.compact).get("current_contract") or {}
    ).get("fingerprint")
    if not revised_contract or revised_contract == contract_fingerprint:
        raise E2EFailure("S8 concrete revised plan did not change material contract identity")

    proceed = checkpoint_action(revised.compact, "Proceed")
    if not proceed:
        raise E2EFailure("S8 revised plan did not expose Proceed")
    approval_response = submit_with_midrun_retry(client, artifacts, session_id, {
        "op": "submit",
        "coordinator_session_id": session_id,
        "message": str(proceed.get("submit_message") or "Approved to proceed."),
        "checkpoint_action": str(proceed.get("checkpoint_action") or "proceed"),
        "expected_checkpoint_instance_id": revised_checkpoint_id,
        "compact": True,
    }, args, "S8 revised-plan approval")
    write_json(artifacts.root / "revised_plan_approval_response.json", approval_response)
    if approval_response.get("accepted") is False:
        raise E2EFailure(f"S8 revised-plan approval rejected: {approval_response.get('error') or approval_response}")
    artifacts.add_checkpoint("current-submit-accepted")

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
    resolution = recent_revision_proposal_resolution(final.compact) or {}
    if str(resolution.get("proposal_id") or "") != proposal_id:
        raise E2EFailure("S8 final status lost the proposal-to-resolution identity")
    if str(resolution.get("outcome") or "") != "accepted_for_concrete_revision":
        raise E2EFailure(f"S8 final resolution outcome was not accepted: {resolution}")
    final_decisions = decision_ids(final.full)
    if len(final_decisions.difference(decisions_before_pause)) < 2:
        raise E2EFailure("S8 expected separate external Revise and revised-plan approval decisions")
    if not plan_or_nodes_mention_token(final.full, token):
        raise E2EFailure(f"S8 final plan/evidence omitted token {token}")
    capture_receipt(client, artifacts, session_id, args.receipt_mode)
    artifacts.finalize(True, "s8", {
        "coordinator_session_id": session_id,
        "final_status": final.status,
        "variant_token": token,
        "proposal_id": proposal_id,
        "base_contract_fingerprint": contract_fingerprint,
        "proposal_checkpoint_instance_id": proposal_checkpoint_id,
        "revised_contract_fingerprint": revised_contract,
        "revised_plan_checkpoint_instance_id": revised_checkpoint_id,
        "resolution_id": resolution.get("resolution_id"),
    })


def set_childask_mode(
    client: RpcClient,
    artifacts: RunArtifacts,
    session_id: str,
    mode: str,
    args: argparse.Namespace,
) -> Observation:
    response = client.coordinator({
        "op": "set_autonomy",
        "coordinator_session_id": session_id,
        "autonomy_class": "childAsk",
        "mode": mode,
        "compact": True,
    }, timeout=180)
    write_json(artifacts.root / f"set_autonomy_{mode}_response.json", response)
    if response.get("accepted") is False:
        raise E2EFailure(f"S5 set_autonomy {mode} rejected: {response.get('error') or response}")
    if response.get("routed_to") != "set_autonomy":
        raise E2EFailure(f"S5 set_autonomy response did not report routed_to=set_autonomy: {response}")
    obs = observe(client, artifacts, session_id)
    capture_mission_events(client, artifacts, session_id, args.events_mode)
    if plan_childask_mode(obs.compact) != mode:
        raise E2EFailure(f"S5 expected childAsk mode {mode}, got {plan_childask_mode(obs.compact)!r}")
    artifacts.add_checkpoint(f"childask-{mode}")
    return obs


def set_pace_auto_for_s5(
    client: RpcClient,
    artifacts: RunArtifacts,
    session_id: str,
    args: argparse.Namespace,
) -> Observation:
    if artifacts.observations and plan_default_pace(artifacts.observations[-1].compact) == "auto":
        return artifacts.observations[-1]
    response = client.coordinator({
        "op": "set_pace",
        "coordinator_session_id": session_id,
        "pace": "auto",
        "compact": True,
    }, timeout=180)
    write_json(artifacts.root / "set_pace_auto_response.json", response)
    if response.get("accepted") is False:
        raise E2EFailure(f"S5 set_pace auto rejected: {response.get('error') or response}")
    if response.get("routed_to") != "set_pace":
        raise E2EFailure(f"S5 set_pace response did not report routed_to=set_pace: {response}")
    obs = observe(client, artifacts, session_id)
    capture_mission_events(client, artifacts, session_id, args.events_mode)
    if plan_default_pace(obs.compact) != "auto":
        raise E2EFailure(f"S5 expected Auto pace, got {plan_default_pace(obs.compact)!r}")
    artifacts.add_checkpoint("pace-set-auto")
    return obs


def run_s5_variant(
    client: RpcClient,
    artifacts: RunArtifacts,
    args: argparse.Namespace,
    mode: str,
) -> dict[str, list[str]]:
    artifacts.record_timing("started")
    variant_token = f"S5-{mode}-{uuid.uuid4().hex[:8]}"
    session_id = start_mission(
        client,
        f"Director E2E S5 childAsk {mode} {variant_token}",
        s5_message(mode, variant_token, args.child_model_id),
        f"s5-{mode}",
        args.coordinator_model_id,
    )
    wait_until(
        client,
        artifacts,
        session_id,
        lambda item: (
            plan_approval_state(item.compact) == "awaiting_approval"
            and has_checkpoint_action(item.compact, "Proceed")
            and plan_or_nodes_mention_token(item.full, variant_token)
        ),
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("plan-visible")
    set_childask_mode(client, artifacts, session_id, mode, args)
    set_pace_auto_for_s5(client, artifacts, session_id, args)
    approve_initial_plan(client, artifacts, session_id, args)

    if mode == "ask":
        wait_until(
            client,
            artifacts,
            session_id,
            lambda item: pending_child_question_or_failed(item, "S5 ask"),
            args.timeout_seconds,
            idle_timeout_seconds=args.idle_timeout_seconds,
            events_mode=args.events_mode,
        )
        artifacts.add_checkpoint("child-question-visible")
        response = client.coordinator({
            "op": "submit",
            "coordinator_session_id": session_id,
            "answers": {
                "marker_choice": {
                    "answers": ["Alpha"],
                    "selected_options": ["Alpha"],
                },
            },
            "compact": True,
        }, timeout=180)
        write_json(artifacts.root / "child_answer_response.json", response)
        if response.get("accepted") is False:
            raise E2EFailure(f"S5 child answer rejected: {response.get('error') or response}")
        if response.get("routed_to") != "child_interaction":
            raise E2EFailure(f"S5 child answer did not route to child_interaction: {response}")
        artifacts.add_checkpoint("child-question-answered")
        final = wait_until(
            client,
            artifacts,
            session_id,
            terminal_completed,
            args.timeout_seconds,
            idle_timeout_seconds=args.idle_timeout_seconds,
            events_mode=args.events_mode,
        )
        child_refs = assert_s5_ask(artifacts.observations, variant_token)
        assert_scripted_child_completion_marker(final.full, variant_token, mode, args.child_model_id)
    else:
        def done_without_user_queue(obs: Observation) -> bool:
            if has_pending_child_question(obs):
                raise E2EFailure("S5 auto observed a user-facing child question before completion")
            return terminal_completed(obs)

        final = wait_until(
            client,
            artifacts,
            session_id,
            done_without_user_queue,
            args.timeout_seconds,
            idle_timeout_seconds=args.idle_timeout_seconds,
            events_mode=args.events_mode,
        )
        child_refs = assert_s5_auto(artifacts.observations, variant_token)
        assert_scripted_child_completion_marker(final.full, variant_token, mode, args.child_model_id)

    artifacts.add_checkpoint("completed")
    capture_receipt(client, artifacts, session_id, args.receipt_mode)
    artifacts.finalize(True, f"s5-{mode}", {
        "coordinator_session_id": session_id,
        "final_status": final.status,
        "childask_mode": mode,
        "variant_token": variant_token,
        "child_refs": child_refs,
        "observed_pending_child_question": any(has_pending_child_question(obs) for obs in artifacts.observations),
    })
    return child_refs


def run_s5(client: RpcClient, artifacts: RunArtifacts, args: argparse.Namespace) -> None:
    results: list[dict[str, Any]] = []
    refs_by_mode: dict[str, dict[str, list[str]]] = {}
    for mode in ["ask", "auto"]:
        variant_artifacts = RunArtifacts(artifacts.root / mode)
        variant_client = RpcClient(client.cli, client.window, client.repo_root, variant_artifacts)
        refs_by_mode[mode] = run_s5_variant(variant_client, variant_artifacts, args, mode)
        results.append({
            "mode": mode,
            "passed": True,
            "artifact_dir": str(variant_artifacts.root),
            "report": variant_artifacts.report,
        })
    assert_s5_variant_refs_disjoint(refs_by_mode["ask"], refs_by_mode["auto"])
    artifacts.finalize(True, "s5", {"variants": results})


def run_s6_pace(client: RpcClient, artifacts: RunArtifacts, args: argparse.Namespace) -> dict[str, Any]:
    artifacts.record_timing("started")
    session_id = start_mission(client, "Director E2E S6 pace flip", s6_message(), "s6", args.coordinator_model_id)
    before = wait_until(
        client,
        artifacts,
        session_id,
        lambda item: plan_approval_state(item.compact) == "awaiting_approval" and has_checkpoint_action(item.compact, "Proceed"),
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("plan-visible")
    response = client.coordinator({
        "op": "set_pace",
        "coordinator_session_id": session_id,
        "pace": "auto",
        "compact": True,
    }, timeout=180)
    write_json(artifacts.root / "set_pace_response.json", response)
    if response.get("accepted") is False:
        raise E2EFailure(f"S6 set_pace rejected: {response.get('error') or response}")
    if response.get("routed_to") != "set_pace":
        raise E2EFailure(f"S6 set_pace response did not report routed_to=set_pace: {response}")
    after = observe(client, artifacts, session_id)
    capture_mission_events(client, artifacts, session_id, args.events_mode)
    assert_s6_pace_flip(before, after)
    artifacts.add_checkpoint("pace-set-auto")

    stop_response = client.coordinator({
        "op": "stop_mission",
        "coordinator_session_id": session_id,
        "compact": True,
    }, timeout=180)
    write_json(artifacts.root / "stop_mission_response.json", stop_response)
    if stop_response.get("accepted") is False:
        raise E2EFailure(f"S6 pace cleanup stop rejected: {stop_response.get('error') or stop_response}")
    stopped = wait_until(
        client,
        artifacts,
        session_id,
        terminal_stopped,
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("pace-mission-stopped")
    capture_receipt(client, artifacts, session_id, args.receipt_mode)

    artifacts.finalize(True, "s6", {
        "coordinator_session_id": session_id,
        "final_status": stopped.status,
        "pace_asserted_status": after.status,
        "approval_state": plan_approval_state(after.compact),
        "default_pace": plan_default_pace(after.compact),
        "revision_before": plan_revision(before.compact),
        "revision_after": plan_revision(after.compact),
    })
    return {
        "coordinator_session_id": session_id,
        "final_status": stopped.status,
        "pace_asserted_status": after.status,
        "approval_state": plan_approval_state(after.compact),
        "default_pace": plan_default_pace(after.compact),
        "revision_before": plan_revision(before.compact),
        "revision_after": plan_revision(after.compact),
    }


def run_s6_childask_flip(client: RpcClient, artifacts: RunArtifacts, args: argparse.Namespace) -> dict[str, Any]:
    artifacts.record_timing("started")
    variant_token = f"S6-childask-{uuid.uuid4().hex[:8]}"
    session_id = start_mission(
        client,
        f"Director E2E S6 childAsk flip {variant_token}",
        s5_message("ask", variant_token, args.child_model_id),
        "s6-childask",
        args.coordinator_model_id,
    )
    wait_until(
        client,
        artifacts,
        session_id,
        lambda item: (
            plan_approval_state(item.compact) == "awaiting_approval"
            and has_checkpoint_action(item.compact, "Proceed")
            and plan_or_nodes_mention_token(item.full, variant_token)
        ),
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("plan-visible")
    set_childask_mode(client, artifacts, session_id, "ask", args)
    set_pace_auto_for_s5(client, artifacts, session_id, args)
    approve_initial_plan(client, artifacts, session_id, args)

    pending = wait_until(
        client,
        artifacts,
        session_id,
        lambda item: pending_child_question_with_interaction_or_failed(item, "S6 childAsk"),
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("child-question-visible")
    interaction_ids = node_bound_interaction_ids(pending.full) or node_bound_interaction_ids(pending.compact)
    if not interaction_ids:
        raise E2EFailure("S6 childAsk could not identify the pending child interaction id before flip")
    interaction_id = interaction_ids[0]
    capture_mission_events(client, artifacts, session_id, args.events_mode)
    seq_before_flip = max_event_seq(artifacts.mission_events)

    set_childask_mode(client, artifacts, session_id, "auto", args)
    artifacts.add_checkpoint("childask-auto-after-pending")

    def completed_without_user_queue(obs: Observation) -> bool:
        if obs.status in {"blocked", "stopped", "cancelled"}:
            raise E2EFailure(f"S6 childAsk reached terminal/blocking state before completion: {obs.status}")
        return terminal_completed(obs)

    final = wait_until(
        client,
        artifacts,
        session_id,
        completed_without_user_queue,
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("completed")
    refs = assert_s6_childask_flip(
        artifacts.observations,
        artifacts.mission_events,
        interaction_id=interaction_id,
        seq_before_flip=seq_before_flip,
        token=variant_token,
    )
    assert_scripted_child_completion_marker(final.full, variant_token, "childAsk flip", args.child_model_id)
    capture_receipt(client, artifacts, session_id, args.receipt_mode)
    result = {
        "coordinator_session_id": session_id,
        "final_status": final.status,
        "variant_token": variant_token,
        "interaction_id": interaction_id,
        "child_refs": refs,
    }
    artifacts.finalize(True, "s6-childask", result)
    return result


def run_s6_childask_escalation(client: RpcClient, artifacts: RunArtifacts, args: argparse.Namespace) -> dict[str, Any]:
    artifacts.record_timing("started")
    variant_token = f"S6-escalate-{uuid.uuid4().hex[:8]}"
    session_id = start_mission(
        client,
        f"Director E2E S6 childAsk escalation {variant_token}",
        s5_message("auto-to-ask", variant_token, args.child_model_id),
        "s6-childask-escalation",
        args.coordinator_model_id,
    )
    wait_until(
        client,
        artifacts,
        session_id,
        lambda item: (
            plan_approval_state(item.compact) == "awaiting_approval"
            and has_checkpoint_action(item.compact, "Proceed")
            and plan_or_nodes_mention_token(item.full, variant_token)
        ),
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("plan-visible")
    set_childask_mode(client, artifacts, session_id, "auto", args)
    set_pace_auto_for_s5(client, artifacts, session_id, args)
    approve_initial_plan(client, artifacts, session_id, args)

    hidden = wait_until(
        client,
        artifacts,
        session_id,
        lambda item: hidden_auto_child_question_with_interaction_or_failed(item, "S6 childAsk escalation"),
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("child-question-hidden-auto")
    interaction_ids = node_bound_interaction_ids(hidden.full) or node_bound_interaction_ids(hidden.compact)
    if not interaction_ids:
        raise E2EFailure("S6 childAsk escalation could not identify hidden child interaction id before flip")
    interaction_id = interaction_ids[0]
    capture_mission_events(client, artifacts, session_id, args.events_mode)
    seq_before_flip = max_event_seq(artifacts.mission_events)

    set_childask_mode(client, artifacts, session_id, "ask", args)
    wait_until(
        client,
        artifacts,
        session_id,
        lambda item: (
            pending_child_question_with_interaction_or_failed(item, "S6 childAsk escalation")
            and interaction_id in (node_bound_interaction_ids(item.full) or node_bound_interaction_ids(item.compact))
        ),
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("child-question-escalated-to-user")

    response = client.coordinator({
        "op": "submit",
        "coordinator_session_id": session_id,
        "answers": {
            "marker_choice": {
                "answers": ["Alpha"],
                "selected_options": ["Alpha"],
            },
        },
        "compact": True,
    }, timeout=180)
    write_json(artifacts.root / "child_answer_response.json", response)
    if response.get("accepted") is False:
        raise E2EFailure(f"S6 childAsk escalation child answer rejected: {response.get('error') or response}")
    if response.get("routed_to") != "child_interaction":
        raise E2EFailure(f"S6 childAsk escalation child answer did not route to child_interaction: {response}")
    artifacts.add_checkpoint("child-question-answered-by-user")

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
    refs = assert_s6_childask_escalation(
        artifacts.observations,
        artifacts.mission_events,
        interaction_id=interaction_id,
        seq_before_flip=seq_before_flip,
        token=variant_token,
    )
    assert_scripted_child_completion_marker(final.full, variant_token, "childAsk escalation", args.child_model_id)
    capture_receipt(client, artifacts, session_id, args.receipt_mode)
    result = {
        "coordinator_session_id": session_id,
        "final_status": final.status,
        "variant_token": variant_token,
        "interaction_id": interaction_id,
        "child_refs": refs,
    }
    artifacts.finalize(True, "s6-childask-escalation", result)
    return result


def run_s6(client: RpcClient, artifacts: RunArtifacts, args: argparse.Namespace) -> None:
    results: list[dict[str, Any]] = []
    for name, runner in [
        ("pace", run_s6_pace),
        ("childask", run_s6_childask_flip),
        ("childask-escalation", run_s6_childask_escalation),
    ]:
        variant_artifacts = RunArtifacts(artifacts.root / name)
        variant_client = RpcClient(client.cli, client.window, client.repo_root, variant_artifacts)
        result = runner(variant_client, variant_artifacts, args)
        results.append({
            "name": name,
            "passed": True,
            "artifact_dir": str(variant_artifacts.root),
            "result": result,
            "report": variant_artifacts.report,
        })
    artifacts.finalize(True, "s6", {"variants": results})


def run_s7(client: RpcClient, artifacts: RunArtifacts, args: argparse.Namespace) -> None:
    artifacts.record_timing("started")
    variant_token = f"S7-stop-{uuid.uuid4().hex[:8]}"
    session_id = start_mission(
        client,
        f"Director E2E S7 stop semantics {variant_token}",
        s5_message("s7-stop", variant_token, args.child_model_id),
        "s7",
        args.coordinator_model_id,
    )
    wait_until(
        client,
        artifacts,
        session_id,
        lambda item: (
            plan_approval_state(item.compact) == "awaiting_approval"
            and has_checkpoint_action(item.compact, "Proceed")
            and plan_or_nodes_mention_token(item.full, variant_token)
        ),
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("plan-visible")
    set_childask_mode(client, artifacts, session_id, "ask", args)
    set_pace_auto_for_s5(client, artifacts, session_id, args)
    approve_initial_plan(client, artifacts, session_id, args)

    pending = wait_until(
        client,
        artifacts,
        session_id,
        lambda item: pending_child_question_with_interaction_or_failed(item, "S7 stop"),
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("child-question-visible")
    interaction_ids = node_bound_interaction_ids(pending.full) or node_bound_interaction_ids(pending.compact)
    if not interaction_ids:
        raise E2EFailure("S7 could not identify pending child interaction id before stop")
    interaction_id = interaction_ids[0]
    capture_mission_events(client, artifacts, session_id, args.events_mode)

    response = client.coordinator({
        "op": "stop_mission",
        "coordinator_session_id": session_id,
        "compact": True,
    }, timeout=180)
    write_json(artifacts.root / "stop_mission_response.json", response)
    if response.get("accepted") is False:
        raise E2EFailure(f"S7 stop_mission rejected: {response.get('error') or response}")
    if response.get("routed_to") != "coordinator_stop":
        raise E2EFailure(f"S7 stop_mission response did not route to coordinator_stop: {response}")
    artifacts.add_checkpoint("stop-submitted")

    final = wait_until(
        client,
        artifacts,
        session_id,
        terminal_stopped,
        args.timeout_seconds,
        idle_timeout_seconds=args.idle_timeout_seconds,
        events_mode=args.events_mode,
    )
    artifacts.add_checkpoint("stopped")
    refs = assert_s7_stop(artifacts.observations, interaction_id=interaction_id)
    capture_receipt(client, artifacts, session_id, args.receipt_mode)
    artifacts.finalize(True, "s7", {
        "coordinator_session_id": session_id,
        "final_status": final.status,
        "variant_token": variant_token,
        "interaction_id": interaction_id,
        "child_refs": refs,
    })


def run_scenario(client: RpcClient, artifacts: RunArtifacts, args: argparse.Namespace) -> None:
    if args.scenario == "s1":
        run_s1(client, artifacts, args)
    elif args.scenario == "s2":
        run_s2(client, artifacts, args)
    elif args.scenario == "s4":
        run_s4(client, artifacts, args)
    elif args.scenario == "s5":
        run_s5(client, artifacts, args)
    elif args.scenario == "s6":
        run_s6(client, artifacts, args)
    elif args.scenario == "s7":
        run_s7(client, artifacts, args)
    elif args.scenario == "s8":
        run_s8(client, artifacts, args)
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
    parser.add_argument("--scenario", choices=["s1", "s2", "s4", "s5", "s6", "s7", "s8", "smoke"], default="s1")
    parser.add_argument("--workspace", default="homelab-garden")
    parser.add_argument("--window", type=int, default=1)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--idle-timeout-seconds", type=int, default=120)
    parser.add_argument(
        "--terminal-grace-seconds",
        type=int,
        default=240,
        help="Extra S2-only terminal wait after convergence/artifacts are observed but the main deadline expires.",
    )
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
    parser.add_argument("--doctor-mode", choices=["auto", "required", "off"], default="auto")
    parser.add_argument(
        "--archive-on-success",
        action="store_true",
        help="Archive the completed/stopped Coordinator Mission after a successful scenario and verify artifacts remain readable.",
    )
    parser.add_argument(
        "--child-model-id",
        default="explore",
        help="Child model_id used by S5/S6/S7 childAsk scenarios; use 'scripted' for deterministic E2E child support.",
    )
    parser.add_argument(
        "--coordinator-model-id",
        default=os.environ.get("RPCE_DIRECTOR_E2E_COORDINATOR_MODEL_ID"),
        help=(
            "Optional Coordinator runtime model_id/role shortcut for fresh Missions. "
            "Use this for cheap regression-tier batches; omit it for the default headline negotiation tier."
        ),
    )
    parser.add_argument("--repeat", type=int, default=1, help="Run the scenario multiple times and aggregate reports.")
    parser.add_argument("--launch", action="store_true", help="Explicitly launch/relaunch the debug app before running.")
    return parser


def run_config_for_args(args: argparse.Namespace) -> dict[str, Any]:
    coordinator_model_id = args.coordinator_model_id or None
    return {
        "scenario": args.scenario,
        "workspace": args.workspace,
        "window": args.window,
        "coordinator_model_id": coordinator_model_id,
        "coordinator_tier": "cheap_regression" if coordinator_model_id else "default_negotiation",
        "child_model_id": args.child_model_id,
        "doctor_mode": args.doctor_mode,
        "events_mode": args.events_mode,
        "receipt_mode": args.receipt_mode,
        "archive_on_success": bool(args.archive_on_success),
        "repeat": args.repeat,
    }


def run_once(args: argparse.Namespace, repo_root: Path, artifacts: RunArtifacts, cli: str) -> None:
    artifacts.set_run_config(run_config_for_args(args))
    client = RpcClient(cli, args.window, repo_root, artifacts)
    ensure_workspace(client, args.workspace)
    capture_doctor(client, artifacts, args.doctor_mode)
    run_scenario(client, artifacts, args)
    archive_final_mission_if_requested(client, artifacts, args)


def repeat_report_for(
    scenario: str,
    repeat: int,
    results: list[dict[str, Any]],
    run_config: dict[str, Any] | None = None,
) -> dict[str, Any]:
    report = {
        "scenario": scenario,
        "repeat": repeat,
        "passed": all(result["passed"] for result in results),
        "pass_count": sum(1 for result in results if result["passed"]),
        "fail_count": sum(1 for result in results if not result["passed"]),
        "attempts": results,
    }
    if run_config is not None:
        report["run_config"] = run_config
    return report


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.repeat < 1:
        parser.error("--repeat must be >= 1")
    repo_root = Path(__file__).resolve().parents[4]
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{args.scenario}-{uuid.uuid4().hex[:6]}"
    root = (repo_root / args.output_dir / run_id).resolve()
    artifacts = RunArtifacts(root)
    artifacts.set_run_config(run_config_for_args(args))
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
            repeat_report = repeat_report_for(args.scenario, args.repeat, results, run_config_for_args(args))
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
