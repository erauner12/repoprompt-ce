#!/usr/bin/env python3
"""Unit tests for the Director E2E runner's pure invariants."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / ".agents/skills/rpce-director-e2e/scripts/director_e2e.py"
SPEC = importlib.util.spec_from_file_location("director_e2e", RUNNER)
director_e2e = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules["director_e2e"] = director_e2e
SPEC.loader.exec_module(director_e2e)


def observation(
    fingerprint: str,
    status: str,
    nodes: list[dict],
    *,
    running: int = 0,
    ready: list[str] | None = None,
    user_decisions: int = 1,
    evidence: int = 1,
    structured_evidence_node_ids: list[str] | None = None,
    routing: int = 1,
    needs_you: int = 0,
    active_nodes: list[dict] | None = None,
):
    compact = {
        "fingerprint": fingerprint,
        "plan": {
            "status": status,
            "policy_snapshot": {"max_concurrent": 3},
        },
        "node_counts": {
            "running": running,
        },
        "ready_node_ids": ready or [],
        "decision_counts_by_actor": {
            "user": user_decisions,
            "director": 0,
        },
        "evidence_counts": {
            "total": evidence,
        },
        "receipt_ready_summary": {
            "ready": status == "completed",
        } if status == "completed" else None,
        "counts": {
            "needs_you": needs_you,
        },
        "active_nodes": active_nodes or [],
    }
    full = {
        "nodes": nodes,
        "plan": {
            "evidence": [
                {
                    "node_id": node_id,
                    "summary": "structured evidence",
                }
                for node_id in (structured_evidence_node_ids or [])
            ],
        },
        "routing_decisions_recent": [{} for _ in range(routing)],
    }
    return director_e2e.Observation(index=0, compact=compact, full=full)


class DirectorE2ETests(unittest.TestCase):
    def test_parse_cli_json_accepts_prefixed_output(self) -> None:
        parsed = director_e2e.parse_cli_json('noise\n{"ok": true, "value": 3}\n')
        self.assertEqual(parsed["value"], 3)

    def test_coordinator_op_unsupported_accepts_schema_rejection(self) -> None:
        message = "Error: [-32602] Invalid params: coordinator_chat op must be one of: list, mission_status"

        self.assertTrue(director_e2e.coordinator_op_unsupported(message))

    def test_sandbox_visibility_accepts_nested_visible_root(self) -> None:
        output = """
## File Tree ✅
/repo/main
/repo/other
Loaded roots: demo → /repo/fallback
"""
        roots = director_e2e.visible_workspace_roots(output)

        self.assertTrue(director_e2e.sandbox_is_visible_from_roots(Path("/repo/main/tmp/e2e"), roots))
        self.assertTrue(director_e2e.sandbox_is_visible_from_roots(Path("/repo/fallback/tmp/e2e"), roots))
        self.assertFalse(director_e2e.sandbox_is_visible_from_roots(Path("/outside/e2e"), roots))

    def test_s1_accepts_single_runner_approval_with_node_evidence(self) -> None:
        obs = observation(
            "f1",
            "completed",
            [{"id": "n1", "status": "completed", "completion_evidence": "done"}],
            user_decisions=1,
            evidence=0,
            routing=1,
        )
        director_e2e.assert_s1([obs], approved_by_runner=True)

    def test_s1_accepts_structured_node_evidence(self) -> None:
        obs = observation(
            "f1",
            "completed",
            [{"id": "n1", "status": "completed"}],
            user_decisions=1,
            evidence=1,
            structured_evidence_node_ids=["n1"],
            routing=1,
        )
        director_e2e.assert_s1([obs], approved_by_runner=True)

    def test_s1_rejects_missing_completed_node_evidence(self) -> None:
        obs = observation(
            "f1",
            "completed",
            [{"id": "n1", "status": "completed"}],
            user_decisions=1,
            evidence=1,
            routing=1,
        )
        with self.assertRaises(director_e2e.E2EFailure):
            director_e2e.assert_s1([obs], approved_by_runner=True)

    def test_s1_rejects_post_approval_user_decision(self) -> None:
        obs = observation(
            "f1",
            "completed",
            [{"id": "n1", "status": "completed", "completion_evidence": "done"}],
            user_decisions=2,
            evidence=1,
            routing=1,
        )
        with self.assertRaises(director_e2e.E2EFailure):
            director_e2e.assert_s1([obs], approved_by_runner=True)

    def test_common_integrity_allows_repeated_status_poll(self) -> None:
        first = observation(
            "f1",
            "running",
            [{"id": "n1", "status": "running", "depends_on": []}],
            running=1,
        )
        second = observation(
            "f1",
            "running",
            [{"id": "n1", "status": "running", "depends_on": []}],
            running=1,
        )
        director_e2e.assert_common_status_integrity([first, second])

    def test_s2_accepts_convergence_sequence(self) -> None:
        a = "a"
        b = "b"
        c = "c"
        observations = [
            observation(
                "f1",
                "running",
                [
                    {"id": a, "status": "running", "depends_on": []},
                    {"id": b, "status": "running", "depends_on": []},
                    {"id": c, "title": "Write SUMMARY.md", "status": "pending", "depends_on": [a, b], "dependencies_satisfied": False},
                ],
                running=2,
            ),
            observation(
                "f2",
                "running",
                [
                    {"id": a, "status": "completed", "depends_on": []},
                    {"id": b, "status": "completed", "depends_on": []},
                    {"id": c, "title": "Write SUMMARY.md", "status": "pending", "depends_on": [a, b], "dependencies_satisfied": True},
                ],
                ready=[c],
            ),
            observation(
                "f3",
                "completed",
                [
                    {"id": a, "status": "completed", "depends_on": []},
                    {"id": b, "status": "completed", "depends_on": []},
                    {"id": c, "title": "Write SUMMARY.md", "status": "completed", "depends_on": [a, b], "dependencies_satisfied": True},
                ],
            ),
        ]
        director_e2e.assert_s2(observations, approved_by_runner=True)

    def test_s2_accepts_fast_launch_without_ready_snapshot(self) -> None:
        a = "a"
        b = "b"
        c = "c"
        observations = [
            observation(
                "f1",
                "running",
                [
                    {"id": a, "status": "running", "depends_on": []},
                    {"id": b, "status": "running", "depends_on": []},
                    {"id": c, "title": "Write SUMMARY.md", "status": "pending", "depends_on": [a, b], "dependencies_satisfied": False},
                ],
                running=2,
            ),
            observation(
                "f2",
                "running",
                [
                    {"id": a, "status": "completed", "depends_on": []},
                    {"id": b, "status": "completed", "depends_on": []},
                    {"id": c, "title": "Write SUMMARY.md", "status": "running", "depends_on": [a, b], "dependencies_satisfied": True},
                ],
                running=1,
            ),
            observation(
                "f3",
                "completed",
                [
                    {"id": a, "status": "completed", "depends_on": []},
                    {"id": b, "status": "completed", "depends_on": []},
                    {"id": c, "title": "Write SUMMARY.md", "status": "completed", "depends_on": [a, b], "dependencies_satisfied": True},
                ],
            ),
        ]
        director_e2e.assert_s2(observations, approved_by_runner=True)
        self.assertEqual(director_e2e.first_s2_convergence_mode(observations), "running")

    def test_s2_mission_events_require_exact_convergence_order(self) -> None:
        a = "a"
        b = "b"
        c = "c"
        events = [
            {
                "seq": 1,
                "nodes": [
                    {"id": a, "status": "running", "depends_on": []},
                    {"id": b, "status": "running", "depends_on": []},
                    {"id": c, "title": "Write SUMMARY.md", "status": "pending", "depends_on": [a, b]},
                ],
                "ready_node_ids": [],
            },
            {
                "seq": 2,
                "nodes": [
                    {"id": a, "status": "completed", "depends_on": []},
                    {"id": b, "status": "completed", "depends_on": []},
                    {"id": c, "title": "Write SUMMARY.md", "status": "pending", "depends_on": [a, b]},
                ],
                "ready_node_ids": [c],
            },
            {
                "seq": 3,
                "nodes": [
                    {"id": a, "status": "completed", "depends_on": []},
                    {"id": b, "status": "completed", "depends_on": []},
                    {"id": c, "title": "Write SUMMARY.md", "status": "running", "depends_on": [a, b]},
                ],
                "ready_node_ids": [],
            },
            {
                "seq": 4,
                "nodes": [
                    {"id": a, "status": "completed", "depends_on": []},
                    {"id": b, "status": "completed", "depends_on": []},
                    {"id": c, "title": "Write SUMMARY.md", "status": "completed", "depends_on": [a, b]},
                ],
                "ready_node_ids": [],
            },
        ]
        director_e2e.assert_s2_mission_event_sequence(events)

    def test_s2_mission_events_reject_fast_launch_without_ready_event(self) -> None:
        a = "a"
        b = "b"
        c = "c"
        events = [
            {
                "seq": 1,
                "nodes": [
                    {"id": a, "status": "running", "depends_on": []},
                    {"id": b, "status": "running", "depends_on": []},
                    {"id": c, "title": "Write SUMMARY.md", "status": "pending", "depends_on": [a, b]},
                ],
                "ready_node_ids": [],
            },
            {
                "seq": 2,
                "nodes": [
                    {"id": a, "status": "completed", "depends_on": []},
                    {"id": b, "status": "completed", "depends_on": []},
                    {"id": c, "title": "Write SUMMARY.md", "status": "running", "depends_on": [a, b]},
                ],
                "ready_node_ids": [],
            },
            {
                "seq": 3,
                "nodes": [
                    {"id": a, "status": "completed", "depends_on": []},
                    {"id": b, "status": "completed", "depends_on": []},
                    {"id": c, "title": "Write SUMMARY.md", "status": "completed", "depends_on": [a, b]},
                ],
                "ready_node_ids": [],
            },
        ]
        with self.assertRaises(director_e2e.E2EFailure):
            director_e2e.assert_s2_mission_event_sequence(events)

    def test_s2_rejects_missing_convergence_after_parent_completion(self) -> None:
        a = "a"
        b = "b"
        c = "c"
        observations = [
            observation(
                "f1",
                "running",
                [
                    {"id": a, "status": "running", "depends_on": []},
                    {"id": b, "status": "running", "depends_on": []},
                    {"id": c, "title": "Write SUMMARY.md", "status": "pending", "depends_on": [a, b], "dependencies_satisfied": False},
                ],
                running=2,
            ),
            observation(
                "f2",
                "completed",
                [
                    {"id": a, "status": "completed", "depends_on": []},
                    {"id": b, "status": "completed", "depends_on": []},
                    {"id": c, "title": "Write SUMMARY.md", "status": "pending", "depends_on": [a, b], "dependencies_satisfied": True},
                ],
            ),
        ]
        with self.assertRaises(director_e2e.E2EFailure):
            director_e2e.assert_s2(observations, approved_by_runner=True)

    def test_s2_rejects_cap_violation(self) -> None:
        obs = observation(
            "f1",
            "running",
            [
                {"id": "a", "status": "running", "depends_on": []},
                {"id": "b", "status": "running", "depends_on": []},
                {"id": "c", "status": "running", "depends_on": []},
                {"id": "d", "status": "running", "depends_on": []},
            ],
            running=4,
        )
        with self.assertRaises(director_e2e.E2EFailure):
            director_e2e.assert_s2([obs], approved_by_runner=True)

    def test_progress_tracker_resets_on_signature_change(self) -> None:
        first = observation("f1", "running", [], running=0)
        second = observation("f2", "running", [], running=0)
        tracker = director_e2e.ProgressTracker(idle_timeout_seconds=10, start_time=0)

        tracker.update(director_e2e.observation_signature(first), now=0)
        self.assertFalse(tracker.should_fail_idle(first, now=9))
        self.assertTrue(tracker.should_fail_idle(first, now=11))
        tracker.update(director_e2e.observation_signature(second), now=11)
        self.assertFalse(tracker.should_fail_idle(second, now=20))

    def test_progress_tracker_does_not_idle_fail_running_work(self) -> None:
        obs = observation("f1", "running", [{"id": "n1", "status": "running"}], running=1)
        tracker = director_e2e.ProgressTracker(idle_timeout_seconds=10, start_time=0)

        tracker.update(director_e2e.observation_signature(obs), now=0)

        self.assertFalse(tracker.should_fail_idle(obs, now=120))

    def test_progress_tracker_idle_fails_unbound_coordinator_only_running_node(self) -> None:
        obs = observation(
            "f1",
            "running",
            [{"id": "n1", "status": "running"}],
            running=1,
            active_nodes=[
                {
                    "id": "n1",
                    "status": "running",
                    "execution_policy": "coordinator_only",
                    "bound_session_id": None,
                }
            ],
        )
        tracker = director_e2e.ProgressTracker(idle_timeout_seconds=10, start_time=0)

        tracker.update(director_e2e.observation_signature(obs), now=0)

        self.assertTrue(tracker.should_fail_idle(obs, now=120))

    def test_progress_tracker_allows_bound_running_node(self) -> None:
        obs = observation(
            "f1",
            "running",
            [{"id": "n1", "status": "running"}],
            running=1,
            active_nodes=[
                {
                    "id": "n1",
                    "status": "running",
                    "execution_policy": "fresh_worktree",
                    "bound_session_id": "session",
                }
            ],
        )
        tracker = director_e2e.ProgressTracker(idle_timeout_seconds=10, start_time=0)

        tracker.update(director_e2e.observation_signature(obs), now=0)

        self.assertFalse(tracker.should_fail_idle(obs, now=120))

    def test_capability_fallback_records_unsupported_events(self) -> None:
        class FakeClient:
            def try_coordinator(self, payload, timeout=120):
                return False, {"error": "unsupported coordinator_chat op mission_events"}

        with tempfile.TemporaryDirectory() as tmp:
            artifacts = director_e2e.RunArtifacts(Path(tmp))
            director_e2e.capture_mission_events(FakeClient(), artifacts, "session", "auto")

            self.assertFalse(artifacts.features["mission_events"]["available"])
            self.assertFalse((Path(tmp) / "events.jsonl").exists())

    def test_required_events_fail_when_unsupported(self) -> None:
        class FakeClient:
            def try_coordinator(self, payload, timeout=120):
                return False, {"error": "unsupported coordinator_chat op mission_events"}

        with tempfile.TemporaryDirectory() as tmp:
            artifacts = director_e2e.RunArtifacts(Path(tmp))
            with self.assertRaises(director_e2e.E2EFailure):
                director_e2e.capture_mission_events(FakeClient(), artifacts, "session", "required")

    def test_receipt_fallback_and_required_modes(self) -> None:
        class FakeClient:
            def try_coordinator(self, payload, timeout=120):
                return False, {"error": "unsupported coordinator_chat op receipt"}

        with tempfile.TemporaryDirectory() as tmp:
            artifacts = director_e2e.RunArtifacts(Path(tmp))
            director_e2e.capture_receipt(FakeClient(), artifacts, "session", "auto")
            self.assertFalse(artifacts.features["receipt_markdown"]["available"])
            with self.assertRaises(director_e2e.E2EFailure):
                director_e2e.capture_receipt(FakeClient(), artifacts, "session", "required")

    def test_repeat_report_aggregates_attempts(self) -> None:
        report = director_e2e.repeat_report_for(
            "s2",
            3,
            [
                {"attempt": 1, "passed": True},
                {"attempt": 2, "passed": False},
                {"attempt": 3, "passed": True},
            ],
        )

        self.assertFalse(report["passed"])
        self.assertEqual(report["pass_count"], 2)
        self.assertEqual(report["fail_count"], 1)

    def test_sandbox_clean_safety_rejects_suspicious_path(self) -> None:
        repo = Path("/repo")

        self.assertTrue(director_e2e.sandbox_clean_is_safe(Path("/repo/tmp/director-e2e-sandbox"), repo))
        self.assertFalse(director_e2e.sandbox_clean_is_safe(Path("/repo/src"), repo))
        self.assertFalse(director_e2e.sandbox_clean_is_safe(Path("/tmp/not-the-sandbox"), repo))

    def test_clean_sandbox_accepts_empty_git_repo(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            sandbox = repo / "tmp" / "director-e2e-sandbox"
            sandbox.mkdir(parents=True)
            subprocess.run(["git", "init"], cwd=sandbox, check=True, capture_output=True)
            (sandbox / "A.md").write_text("scratch", encoding="utf-8")

            director_e2e.clean_sandbox(sandbox, repo)

            self.assertFalse((sandbox / "A.md").exists())

    def test_invariant_watcher_catches_cap_violation(self) -> None:
        obs = observation(
            "f1",
            "running",
            [
                {"id": "a", "status": "running"},
                {"id": "b", "status": "running"},
                {"id": "c", "status": "running"},
                {"id": "d", "status": "running"},
            ],
            running=4,
        )
        with tempfile.TemporaryDirectory() as tmp:
            watcher = director_e2e.InvariantWatcher(director_e2e.RunArtifacts(Path(tmp)))
            with self.assertRaises(director_e2e.E2EFailure):
                watcher.check(obs)

    def test_invariant_watcher_catches_status_regression(self) -> None:
        first = observation("f1", "running", [{"id": "a", "status": "running"}], running=1)
        second = observation("f2", "running", [{"id": "a", "status": "pending"}])
        with tempfile.TemporaryDirectory() as tmp:
            watcher = director_e2e.InvariantWatcher(director_e2e.RunArtifacts(Path(tmp)))
            watcher.check(first)
            with self.assertRaises(director_e2e.E2EFailure):
                watcher.check(second)

    def test_invariant_watcher_catches_dependency_mismatch(self) -> None:
        obs = observation(
            "f1",
            "running",
            [
                {"id": "a", "status": "running"},
                {"id": "b", "status": "pending", "depends_on": ["a"], "dependencies_satisfied": True},
            ],
        )
        with tempfile.TemporaryDirectory() as tmp:
            watcher = director_e2e.InvariantWatcher(director_e2e.RunArtifacts(Path(tmp)))
            with self.assertRaises(director_e2e.E2EFailure):
                watcher.check(obs)


if __name__ == "__main__":
    unittest.main()
