# Coordinator Runtime Demo Stubs

This branch implements only Item 1 of `prompt-exports/coordinator-runtime-demo-orchestration-plan.md`.

Deliberate shortcuts / non-goals for the demo spine:

- Coordinator runtime identity is an in-memory `TabSession.isCoordinatorRuntimeDemo` marker only. It is for addressability and board self-exclusion during the demo, not durable restore.
- No full containment model is implemented for Coordinator-owned fleets.
- No `list_sessions` broadening or visibility-policy change is implemented.
- No coordinator-runtime restore flow is implemented.
- No eviction/stash exemption is implemented for the Coordinator runtime.
- `New Coordinator Run` is a reproducibility shortcut, not production lifecycle architecture: it sets a one-shot force-new flag so the next left-rail directive creates a fresh Codex Coordinator runtime, while board/history noise remains out of scope.
- No production policy-context refactor is implemented beyond reusing the existing root MCP-control prompt/tool advertisement behavior.
- The Coordinator runtime is hard-coded for the demo to Codex with the GPT-5.5 High model.
- The Coordinator runtime prompt includes a hardcoded loopback proof step before fan-out: start one explore child with `coordinator_internal=true` and require a returned `session_id` before continuing.
- Fan-out behavior is prompt-guided only in this item; center-board fleet projection and right-inspector UX are left to Item 2 and Item 3.
- Board eligibility is narrowed to descendants of the current in-memory demo Coordinator runtime marker. Until a durable fleet handle model exists, previous demo runtime tabs are excluded by the demo runtime marker and demo reset flow.
- Coordinator-internal children such as the loopback proof are hidden from the board and Coordinator action-chip rail so housekeeping does not masquerade as supervised delegated work.
- Coordinator action chips are currently derived from newly visible delegated rows/results, not from a first-class tool-call event stream. They support delegate/resolved display only; pending, collect, cancel, and multi-action event semantics remain future work.
- Workflow display is read-only metadata derived from the latest user-turn workflow on the live Agent session. It can appear, change, or clear between turns, and it does not yet affect board filtering, sorting, or action creation.
- The left Coordinator rail remains the composer surface; the right inspector is not used as a composer.
