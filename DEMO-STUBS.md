# Coordinator Runtime Demo Stubs

This branch implements only Item 1 of `prompt-exports/coordinator-runtime-demo-orchestration-plan.md`.

Deliberate shortcuts / non-goals for the demo spine:

- Coordinator runtime identity is an in-memory `TabSession.isCoordinatorRuntimeDemo` marker only. It is for addressability and board self-exclusion during the demo, not durable restore.
- No durable containment model is implemented for Coordinator-owned fleets.
- No `list_sessions` broadening or visibility-policy change is implemented.
- No coordinator-runtime restore flow is implemented.
- No eviction/stash exemption is implemented for the Coordinator runtime.
- `New Coordinator Run` is still a demo bridge operation, but the intended next behavior is additive: create another Coordinator backing runtime and select it for the rail without clearing previously supervised fleet rows. The earlier destroy/replace reset semantics are a known demo constraint to retire.
- Rail `Clear Chat` should remain display-only. Any operation that retires one Coordinator runtime or resets the whole demo fleet should be explicit rather than hidden behind `New Coordinator Run` or ordinary chat clearing.
- No production policy-context refactor is implemented beyond reusing the existing root MCP-control prompt/tool advertisement behavior.
- The Coordinator runtime is hard-coded for the demo to Codex with the GPT-5.5 High model.
- The automatic loopback proof step has been retired from the default demo prompt. Real delegated sessions now exercise the same `agent_run.start` path directly, so asking for one delegate should create exactly one visible delegated session.
- Fan-out behavior is prompt-guided only in this item; center-board fleet projection and right-inspector UX are left to Item 2 and Item 3.
- Board eligibility is currently narrowed to descendants of the current in-memory demo Coordinator runtime marker. The next production-demo refinement should aggregate descendants from all active workspace demo Coordinator roots so multiple parent tasks remain visible across fresh Coordinator chats.
- Aggregate board projection is not complete until parent ownership is visible on cards/rows with a reserved neutral treatment distinct from lifecycle status and workflow labels.
- Coordinator-internal children remain supported and hidden from the board and Coordinator action-chip rail so future housekeeping sessions do not masquerade as supervised delegated work.
- Coordinator action chips are currently derived from newly visible delegated rows/results, not from a first-class tool-call event stream. They support delegate/resolved display only; pending, collect, cancel, and multi-action event semantics remain future work.
- Workflow display is read-only metadata derived from the latest user-turn workflow on the live Agent session. It can appear, change, or clear between turns, and it does not yet affect board filtering, sorting, or action creation.
- The left Coordinator rail remains the composer surface; the right inspector is not used as a composer.
