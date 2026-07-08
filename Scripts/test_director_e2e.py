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
    approval_state: str | None = None,
    default_pace: str = "step",
    revision: int = 1,
    running: int = 0,
    ready: list[str] | None = None,
    user_decisions: int = 1,
    evidence: int = 1,
    structured_evidence_node_ids: list[str] | None = None,
    evidence_summaries: list[str] | None = None,
    decisions: list[dict] | None = None,
    director_decisions: int = 0,
    routing: int = 1,
    routing_decisions: list[dict] | None = None,
    needs_you: int = 0,
    active_nodes: list[dict] | None = None,
    childask_mode: str | None = None,
    warnings: list[str] | None = None,
):
    auto_classes = ["childAsk"] if childask_mode == "auto" else []
    ask_classes = ["childAsk"] if childask_mode == "ask" or childask_mode is None else []
    compact = {
        "fingerprint": fingerprint,
        "plan": {
            "status": status,
            "revision": revision,
            "approval_state": approval_state,
            "policy_snapshot": {"max_concurrent": 3, "default_pace": default_pace},
            "autonomy_summary": {
                "ask": ask_classes,
                "auto": auto_classes,
            },
        },
        "node_counts": {
            "running": running,
        },
        "ready_node_ids": ready or [],
        "decision_counts_by_actor": {
            "user": user_decisions,
            "director": director_decisions,
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
        "liveness_warnings": warnings or [],
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
            ] + [
                {
                    "node_id": None,
                    "summary": summary,
                }
                for summary in (evidence_summaries or [])
            ],
            "decisions": decisions or [],
            "routing_decisions": routing_decisions if routing_decisions is not None else [{} for _ in range(routing)],
        },
        "routing_decisions_recent": routing_decisions if routing_decisions is not None else [{} for _ in range(routing)],
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

    def test_sandbox_context_binding_uses_matching_repo_tab(self) -> None:
        class FakeClient:
            window = 1
            cli = "rpce-cli-debug"
            bound_context_id = None

            def run(self, label, argv, timeout=120):
                return """
## Tab Context Binding ✅
- Window `1` [current] • workspace: homelab-garden
  • Scratch — context_id: `11111111-1111-4111-8111-111111111111`
    repo: `/repo/other`
  • T1 — context_id: `22222222-2222-4222-8222-222222222222`
    repo: `/repo/main`
"""

            def bind_context(self, context_id):
                self.bound_context_id = context_id

        client = FakeClient()
        director_e2e.bind_visible_context_for_sandbox(client, Path("/repo/main/tmp/director-e2e-sandbox"))

        self.assertEqual(client.bound_context_id, "22222222-2222-4222-8222-222222222222")

    def test_compact_status_preserves_response_surface_counts(self) -> None:
        class FakeClient:
            def coordinator(self, payload, timeout=120):
                return {
                    "mission_status": {
                        "fingerprint": "f1",
                        "plan": {"status": "running"},
                    },
                    "counts": {
                        "needs_you": 1,
                        "working": 0,
                    },
                    "selected_coordinator_session_id": "session-1",
                }

        status = director_e2e.compact_status(FakeClient(), "session-1")

        self.assertEqual(status["counts"]["needs_you"], 1)
        self.assertEqual(status["coordinator_session_id"], "session-1")

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
        self.assertTrue(director_e2e.s2_event_convergence_sequence_is_complete(events))

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
        self.assertFalse(director_e2e.s2_event_convergence_sequence_is_complete(events))

    def test_s2_terminal_grace_warranted_by_observed_convergence(self) -> None:
        a = "a"
        b = "b"
        c = "c"
        with tempfile.TemporaryDirectory() as tmp:
            artifacts = director_e2e.RunArtifacts(Path(tmp) / "artifacts")
            artifacts.observations.append(
                observation(
                    "f1",
                    "running",
                    [
                        {"id": a, "status": "completed", "depends_on": []},
                        {"id": b, "status": "completed", "depends_on": []},
                        {"id": c, "title": "Write SUMMARY.md", "status": "running", "depends_on": [a, b]},
                    ],
                    running=1,
                )
            )

            self.assertTrue(director_e2e.s2_terminal_grace_is_warranted(artifacts, Path(tmp) / "sandbox"))

    def test_s2_terminal_grace_warranted_by_marker_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            sandbox = Path(tmp) / "sandbox"
            sandbox.mkdir()
            for name in ["A.md", "B.md", "SUMMARY.md"]:
                (sandbox / name).write_text(name, encoding="utf-8")
            artifacts = director_e2e.RunArtifacts(Path(tmp) / "artifacts")

            self.assertTrue(director_e2e.s2_terminal_grace_is_warranted(artifacts, sandbox))

    def test_s2_terminal_grace_rejects_uninteresting_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            artifacts = director_e2e.RunArtifacts(Path(tmp) / "artifacts")

            self.assertFalse(director_e2e.s2_terminal_grace_is_warranted(artifacts, Path(tmp) / "sandbox"))

    def test_timeout_failure_classification_for_terminal_grace(self) -> None:
        self.assertTrue(director_e2e.timeout_failure_may_be_terminal_graced(Exception("Condition was not reached within 900s")))
        self.assertTrue(director_e2e.timeout_failure_may_be_terminal_graced(Exception("Condition made no observable progress for 120s.")))
        self.assertFalse(director_e2e.timeout_failure_may_be_terminal_graced(Exception("S2 expected completed mission, got running")))

    def test_s2_message_guides_canonical_marker_shell_ops(self) -> None:
        message = director_e2e.s2_message(Path("/tmp/director-e2e-sandbox"))

        self.assertIn("direct shell checks/writes", message)
        self.assertIn("exact absolute paths", message)
        self.assertIn("After writing the assigned marker file, report the result and stop", message)

    def test_s5_message_requires_real_child_input_tool_call(self) -> None:
        message = director_e2e.s5_message("ask", "S5-ask-test")

        self.assertIn("Use this exact child prompt", message)
        self.assertIn("Call the RepoPrompt MCP tool named `ask_user` now", message)
        self.assertIn("If `ask_user` is not advertised, use `request_user_input`", message)
        self.assertIn("`request_user_input`", message)
        self.assertIn("`ask_user`", message)
        self.assertIn("without adding Mission Policy", message)
        self.assertIn("Do not answer in plain text or finish until the tool has created a pending user question", message)
        self.assertIn("Parent/Director handling owns the route", message)
        self.assertIn("using `agent_run.start`", message)
        self.assertIn("with `model_id:\"explore\"`", message)
        self.assertIn("no workflow_name or worktree", message)
        self.assertIn("S5_USER_INPUT_TOOL_UNAVAILABLE", message)
        self.assertIn("S5-ask-test", message)
        self.assertIn("Do not reuse any session_id", message)

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

    def test_s6_accepts_pace_flip_without_consuming_approval_checkpoint(self) -> None:
        before = observation(
            "f1",
            "draft",
            [{"id": "n1", "status": "pending"}],
            approval_state="awaiting_approval",
            default_pace="step",
            revision=4,
            user_decisions=0,
        )
        before.compact["checkpoint"] = {"actions": [{"label": "Proceed"}]}
        after = observation(
            "f2",
            "draft",
            [{"id": "n1", "status": "pending"}],
            approval_state="awaiting_approval",
            default_pace="auto",
            revision=5,
            user_decisions=1,
        )
        after.compact["checkpoint"] = {"actions": [{"label": "Proceed"}]}

        director_e2e.assert_s6_pace_flip(before, after)

    def test_s6_rejects_consumed_approval_checkpoint(self) -> None:
        before = observation(
            "f1",
            "draft",
            [{"id": "n1", "status": "pending"}],
            approval_state="awaiting_approval",
            default_pace="step",
            revision=4,
            user_decisions=0,
        )
        before.compact["checkpoint"] = {"actions": [{"label": "Proceed"}]}
        after = observation(
            "f2",
            "running",
            [{"id": "n1", "status": "running"}],
            approval_state="approved",
            default_pace="auto",
            revision=5,
            user_decisions=1,
        )
        after.compact["checkpoint"] = {"actions": []}

        with self.assertRaises(director_e2e.E2EFailure):
            director_e2e.assert_s6_pace_flip(before, after)

    def test_s6_rejects_missing_user_decision(self) -> None:
        before = observation(
            "f1",
            "draft",
            [{"id": "n1", "status": "pending"}],
            approval_state="awaiting_approval",
            default_pace="step",
            revision=4,
            user_decisions=0,
        )
        before.compact["checkpoint"] = {"actions": [{"label": "Proceed"}]}
        after = observation(
            "f2",
            "draft",
            [{"id": "n1", "status": "pending"}],
            approval_state="awaiting_approval",
            default_pace="auto",
            revision=5,
            user_decisions=0,
        )
        after.compact["checkpoint"] = {"actions": [{"label": "Proceed"}]}

        with self.assertRaises(director_e2e.E2EFailure):
            director_e2e.assert_s6_pace_flip(before, after)

    def test_s6_childask_flip_accepts_director_reroute_after_user_dial_decision(self) -> None:
        pending = observation(
            "f1",
            "running",
            [
                {
                    "id": "n1",
                    "status": "running",
                    "bound_session_id": "child-session",
                    "bound_interaction_id": "interaction-1",
                }
            ],
            running=1,
            needs_you=1,
            childask_mode="ask",
        )
        final = observation(
            "f2",
            "completed",
            [
                {
                    "id": "n1",
                    "status": "completed",
                    "bound_session_id": "child-session",
                    "bound_interaction_id": "interaction-1",
                    "completion_evidence": "Selected Alpha for s6case.",
                }
            ],
            childask_mode="auto",
            user_decisions=4,
            director_decisions=1,
            decisions=[
                {
                    "id": "flip-decision",
                    "label": "routed child questions to the Director",
                    "actor": "user",
                    "decision_class": "childAsk",
                    "timestamp": "2026-07-08T01:00:00Z",
                },
                {
                    "id": "director-decision",
                    "label": "answered a child question",
                    "actor": "director",
                    "decision_class": "childAsk",
                    "interaction_id": "interaction-1",
                    "timestamp": "2026-07-08T01:00:01Z",
                },
            ],
            evidence_summaries=["Director answered Alpha for s6case."],
            routing_decisions=[{"operation": "agent_run.start", "route_kind": "fresh_child"}],
        )
        events = [
            {
                "seq": 8,
                "decision_ids": ["flip-decision"],
                "nodes": [{"id": "n1", "status": "running", "bound_interaction_id": "interaction-1"}],
            },
            {
                "seq": 9,
                "decision_ids": ["flip-decision", "director-decision"],
                "nodes": [{"id": "n1", "status": "completed", "bound_interaction_id": "interaction-1"}],
            },
        ]

        self.assertEqual(
            director_e2e.assert_s6_childask_flip(
                [pending, final],
                events,
                interaction_id="interaction-1",
                seq_before_flip=7,
                token="s6case",
            ),
            {"sessions": ["child-session"], "interactions": ["interaction-1"]},
        )

    def test_s6_childask_flip_rejects_director_answer_before_dial_decision(self) -> None:
        final = observation(
            "f1",
            "completed",
            [
                {
                    "id": "n1",
                    "status": "completed",
                    "bound_session_id": "child-session",
                    "bound_interaction_id": "interaction-1",
                    "completion_evidence": "Selected Alpha for s6case.",
                }
            ],
            childask_mode="auto",
            director_decisions=1,
            decisions=[
                {
                    "id": "director-decision",
                    "label": "answered a child question",
                    "actor": "director",
                    "decision_class": "childAsk",
                    "interaction_id": "interaction-1",
                    "timestamp": "2026-07-08T01:00:00Z",
                },
                {
                    "id": "flip-decision",
                    "label": "routed child questions to the Director",
                    "actor": "user",
                    "decision_class": "childAsk",
                    "timestamp": "2026-07-08T01:00:01Z",
                },
            ],
            evidence_summaries=["Director answered Alpha for s6case."],
            routing_decisions=[{"operation": "agent_run.start", "route_kind": "fresh_child"}],
        )
        events = [
            {
                "seq": 8,
                "decision_ids": ["director-decision"],
                "nodes": [{"id": "n1", "status": "completed", "bound_interaction_id": "interaction-1"}],
            },
            {
                "seq": 9,
                "decision_ids": ["director-decision", "flip-decision"],
                "nodes": [{"id": "n1", "status": "completed", "bound_interaction_id": "interaction-1"}],
            },
        ]

        with self.assertRaises(director_e2e.E2EFailure):
            director_e2e.assert_s6_childask_flip(
                [final],
                events,
                interaction_id="interaction-1",
                seq_before_flip=7,
                token="s6case",
            )

    def test_s6_missing_childask_ledger_warning_fails_loudly(self) -> None:
        obs = observation(
            "f1",
            "running",
            [{"id": "n1", "status": "running", "bound_interaction_id": "interaction-1"}],
            running=1,
            warnings=["completed_child_missing_childask_ledger"],
        )
        with tempfile.TemporaryDirectory() as tmp:
            artifacts = director_e2e.RunArtifacts(Path(tmp))
            with self.assertRaisesRegex(director_e2e.E2EFailure, "S6_MISSING_DIRECTOR_LEDGER_AFTER_CHILD_DONE"):
                director_e2e.fail_missing_childask_ledger_warning(obs, artifacts)

    def test_childask_mode_reads_compact_autonomy_summary(self) -> None:
        ask = observation("f1", "draft", [], childask_mode="ask")
        auto = observation("f2", "draft", [], childask_mode="auto")

        self.assertEqual(director_e2e.plan_childask_mode(ask.compact), "ask")
        self.assertEqual(director_e2e.plan_childask_mode(auto.compact), "auto")

    def test_initial_approval_helper_requires_approved_state(self) -> None:
        waiting = observation("f1", "draft", [], approval_state="awaiting_approval")
        approved = observation("f2", "draft", [], approval_state="approved")
        completed = observation("f3", "completed", [], approval_state="awaiting_approval")

        self.assertFalse(director_e2e.plan_advanced_past_initial_approval(waiting.compact))
        self.assertTrue(director_e2e.plan_advanced_past_initial_approval(approved.compact))
        self.assertFalse(director_e2e.plan_advanced_past_initial_approval(completed.compact))

    def test_s5_ask_accepts_pending_question_and_user_answer_decision(self) -> None:
        pending = observation(
            "f1",
            "running",
            [
                {
                    "id": "n1",
                    "status": "running",
                    "bound_row": {"run_state": "waitingForQuestion", "status_group": "needsYou"},
                }
            ],
            running=1,
            needs_you=1,
            childask_mode="ask",
        )
        final = observation(
            "f2",
            "completed",
            [
                {
                    "id": "n1",
                    "status": "completed",
                    "bound_session_id": "ask-session",
                    "bound_interaction_id": "ask-interaction",
                    "completion_evidence": "S5_CHILD_ANSWER=Alpha S5-ask-test",
                }
            ],
            childask_mode="ask",
            decisions=[
                {
                    "label": "answered a child question",
                    "actor": "user",
                    "decision_class": "childAsk",
                }
            ],
            evidence_summaries=["Child reported S5_CHILD_ANSWER=Alpha S5-ask-test"],
            routing_decisions=[{"operation": "agent_run.start", "route_kind": "fresh_child"}],
        )

        self.assertEqual(
            director_e2e.assert_s5_ask([pending, final], "S5-ask-test"),
            {"sessions": ["ask-session"], "interactions": ["ask-interaction"]},
        )

    def test_s5_ask_rejects_missing_pending_question(self) -> None:
        final = observation(
            "f1",
            "completed",
            [
                {
                    "id": "n1",
                    "status": "completed",
                    "bound_session_id": "ask-session",
                    "bound_interaction_id": "ask-interaction",
                    "completion_evidence": "S5_CHILD_ANSWER=Alpha",
                }
            ],
            decisions=[
                {
                    "label": "answered a child question",
                    "actor": "user",
                    "decision_class": "childAsk",
                }
            ],
            evidence_summaries=["Alpha"],
            routing_decisions=[{"operation": "agent_run.start", "route_kind": "fresh_child"}],
        )

        with self.assertRaises(director_e2e.E2EFailure):
            director_e2e.assert_s5_ask([final])

    def test_pending_child_question_failure_reports_child_input_tool_capability_gap(self) -> None:
        obs = observation(
            "f1",
            "running",
            [
                {
                    "id": "n1",
                    "status": "blocked",
                    "completion_evidence": (
                        "Blocked: child final output was "
                        "`S5_USER_INPUT_TOOL_UNAVAILABLE S5-ask-test`; no pending marker_choice interaction was created."
                    ),
                }
            ],
            childask_mode="ask",
        )

        with self.assertRaisesRegex(director_e2e.E2EFailure, "structured pending question"):
            director_e2e.pending_child_question_or_failed(obs, "S5 ask")
        with self.assertRaisesRegex(director_e2e.E2EFailure, "S5_USER_INPUT_TOOL_UNAVAILABLE S5-ask-test"):
            director_e2e.pending_child_question_with_interaction_or_failed(obs, "S6 childAsk")

    def test_s5_auto_accepts_director_decision_without_user_queue(self) -> None:
        final = observation(
            "f1",
            "completed",
            [
                {
                    "id": "n1",
                    "status": "completed",
                    "bound_session_id": "auto-session",
                    "bound_interaction_id": "auto-interaction",
                    "completion_evidence": "S5_CHILD_ANSWER=Alpha S5-auto-test",
                }
            ],
            childask_mode="auto",
            user_decisions=2,
            director_decisions=1,
            decisions=[
                {
                    "label": "answered child question as Director",
                    "actor": "director",
                    "decision_class": "childAsk",
                    "reason": "Director selected Alpha.",
                }
            ],
            evidence_summaries=["Director answered Alpha for the child question S5-auto-test"],
            routing_decisions=[{"operation": "agent_run.start", "route_kind": "fresh_child"}],
        )

        self.assertEqual(
            director_e2e.assert_s5_auto([final], "S5-auto-test"),
            {"sessions": ["auto-session"], "interactions": ["auto-interaction"]},
        )

    def test_s5_auto_rejects_missing_fresh_child_launch(self) -> None:
        final = observation(
            "f1",
            "completed",
            [
                {
                    "id": "n1",
                    "status": "completed",
                    "bound_session_id": "auto-session",
                    "bound_interaction_id": "auto-interaction",
                    "completion_evidence": "S5_CHILD_ANSWER=Alpha S5-auto-test",
                }
            ],
            childask_mode="auto",
            director_decisions=1,
            decisions=[
                {
                    "label": "answered child question as Director",
                    "actor": "director",
                    "decision_class": "childAsk",
                }
            ],
            evidence_summaries=["Director answered Alpha S5-auto-test"],
            routing_decisions=[],
        )

        with self.assertRaises(director_e2e.E2EFailure):
            director_e2e.assert_s5_auto([final], "S5-auto-test")

    def test_s5_rejects_cross_variant_child_binding_reuse(self) -> None:
        refs = {"sessions": ["shared-session"], "interactions": ["shared-interaction"]}

        with self.assertRaises(director_e2e.E2EFailure):
            director_e2e.assert_s5_variant_refs_disjoint(refs, refs)

    def test_s5_auto_running_bound_interaction_without_pending_row_is_not_user_queue(self) -> None:
        obs = observation(
            "f1",
            "running",
            [
                {
                    "id": "n1",
                    "status": "running",
                    "bound_interaction_id": "interaction-1",
                    "bound_row": {"run_state": "waitingForQuestion", "status_group": "working"},
                }
            ],
            childask_mode="auto",
            needs_you=0,
        )

        self.assertFalse(director_e2e.has_pending_child_question(obs))

    def test_s5_auto_needs_you_count_without_question_shape_is_not_user_queue(self) -> None:
        obs = observation(
            "f1",
            "running",
            [{"id": "n1", "status": "running"}],
            childask_mode="auto",
            needs_you=1,
            active_nodes=[
                {
                    "id": "n1",
                    "status": "running",
                    "bound_row_run_state": "running",
                    "bound_row_status_group": "working",
                }
            ],
        )

        self.assertFalse(director_e2e.has_pending_child_question(obs))

    def test_pending_child_question_wait_rejects_blocked_child_before_idle_timeout(self) -> None:
        obs = observation(
            "f1",
            "blocked",
            [{"id": "n1", "status": "blocked"}],
            running=0,
            needs_you=0,
        )

        with self.assertRaisesRegex(director_e2e.E2EFailure, "S6 childAsk reached blocked"):
            director_e2e.pending_child_question_or_failed(obs, "S6 childAsk")

    def test_s6_child_question_wait_requires_interaction_id(self) -> None:
        obs = observation(
            "f1",
            "running",
            [{"id": "n1", "status": "running"}],
            needs_you=1,
        )

        self.assertFalse(director_e2e.pending_child_question_with_interaction_or_failed(obs, "S6 childAsk"))

    def test_s6_child_question_wait_accepts_bound_row_interaction_id(self) -> None:
        obs = observation(
            "f1",
            "running",
            [
                {
                    "id": "n1",
                    "status": "running",
                    "bound_row": {
                        "run_state": "waitingForQuestion",
                        "status_group": "needsYou",
                        "interaction_id": "interaction-1",
                    },
                }
            ],
            needs_you=1,
        )

        self.assertTrue(director_e2e.pending_child_question_with_interaction_or_failed(obs, "S6 childAsk"))
        self.assertEqual(director_e2e.node_bound_interaction_ids(obs.full), ["interaction-1"])

    def test_s5_auto_rejects_observed_user_queue(self) -> None:
        pending = observation(
            "f1",
            "running",
            [{"id": "n1", "status": "running"}],
            needs_you=1,
            childask_mode="auto",
        )
        final = observation(
            "f2",
            "completed",
            [
                {
                    "id": "n1",
                    "status": "completed",
                    "bound_session_id": "auto-session",
                    "bound_interaction_id": "auto-interaction",
                    "completion_evidence": "S5_CHILD_ANSWER=Alpha",
                }
            ],
            childask_mode="auto",
            director_decisions=1,
            decisions=[
                {
                    "label": "answered child question as Director",
                    "actor": "director",
                    "decision_class": "childAsk",
                }
            ],
            evidence_summaries=["Alpha"],
            routing_decisions=[{"operation": "agent_run.start", "route_kind": "fresh_child"}],
        )

        with self.assertRaises(director_e2e.E2EFailure):
            director_e2e.assert_s5_auto([pending, final])

    def test_routing_decisions_dedupe_compact_and_plan_sources(self) -> None:
        route = {"id": "route-1", "operation": "agent_run.start"}
        obs = observation(
            "f1",
            "running",
            [{"id": "n1", "status": "running"}],
            routing_decisions=[route],
        )

        self.assertEqual(director_e2e.plan_routing_decisions(obs.full), [route])

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

    def test_running_work_still_completable_with_mixed_liveness_warnings_and_bound_node(self) -> None:
        obs = observation(
            "f1",
            "running",
            [{"id": "n1", "status": "running"}],
            running=1,
            warnings=[
                "coordinator_run_state_is_not_active_but_plan_has_active_nodes",
                "running_delegated_nodes_without_bound_sessions",
            ],
            active_nodes=[
                {
                    "id": "n1",
                    "status": "running",
                    "bound_session_id": "session-1",
                }
            ],
        )

        self.assertTrue(director_e2e.has_running_work_that_could_still_complete(obs))

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

    def test_progress_tracker_idle_fails_unbound_delegated_liveness_warning(self) -> None:
        obs = observation(
            "f1",
            "running",
            [{"id": "n1", "status": "running"}],
            running=1,
            active_nodes=[
                {
                    "id": "n1",
                    "status": "running",
                    "execution_policy": "fresh_readonly_child",
                    "bound_session_id": None,
                }
            ],
            warnings=["running_delegated_nodes_without_bound_sessions"],
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

    def test_progress_tracker_idle_fails_nonactive_unbound_delegated_node(self) -> None:
        obs = observation(
            "f1",
            "running",
            [{"id": "n1", "status": "running"}],
            running=1,
            active_nodes=[
                {
                    "id": "n1",
                    "status": "running",
                    "execution_policy": "fresh_readonly_child",
                    "bound_session_id": None,
                }
            ],
            warnings=[
                "coordinator_run_state_is_not_active_but_plan_has_active_nodes",
                "running_delegated_nodes_without_bound_sessions",
            ],
        )
        tracker = director_e2e.ProgressTracker(idle_timeout_seconds=10, start_time=0)

        tracker.update(director_e2e.observation_signature(obs), now=0)

        self.assertTrue(tracker.should_fail_idle(obs, now=120))

    def test_progress_tracker_idle_fails_when_bound_row_already_done(self) -> None:
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
                    "bound_row_run_state": "completed",
                    "bound_row_status_group": "done",
                }
            ],
        )
        tracker = director_e2e.ProgressTracker(idle_timeout_seconds=10, start_time=0)

        tracker.update(director_e2e.observation_signature(obs), now=0)

        self.assertTrue(tracker.should_fail_idle(obs, now=120))

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

    def test_receipt_markdown_success_writes_artifact(self) -> None:
        class FakeClient:
            def try_coordinator(self, payload, timeout=120):
                self.payload = payload
                return True, {"markdown": "# Mission Receipt\n\n## Spend"}

        client = FakeClient()
        with tempfile.TemporaryDirectory() as tmp:
            artifacts = director_e2e.RunArtifacts(Path(tmp))
            director_e2e.capture_receipt(client, artifacts, "session", "required")

            self.assertEqual(client.payload["op"], "receipt")
            self.assertEqual(client.payload["format"], "markdown")
            self.assertTrue(artifacts.features["receipt_markdown"]["available"])
            self.assertEqual((Path(tmp) / "receipt.md").read_text(encoding="utf-8"), "# Mission Receipt\n\n## Spend")

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
