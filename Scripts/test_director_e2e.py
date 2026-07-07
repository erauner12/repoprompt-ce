#!/usr/bin/env python3
"""Unit tests for the Director E2E runner's pure invariants."""

from __future__ import annotations

import importlib.util
import sys
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


if __name__ == "__main__":
    unittest.main()
