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
- The Coordinator runtime prompt includes a hardcoded loopback proof step before fan-out: start one explore child and require a returned `session_id` before continuing.
- Fan-out behavior is prompt-guided only in this item; center-board fleet projection and right-inspector UX are left to Item 2 and Item 3.
- The left Coordinator rail remains the composer surface; the right inspector is not used as a composer.
