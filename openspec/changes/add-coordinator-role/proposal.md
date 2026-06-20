## Why

The current Coordinator view can demo supervision by manually targeting an ordinary live Agent Mode session, but that makes the supervisor part of the supervised workspace fleet. RepoPrompt needs a real Coordinator role: a layer-above meta-agent that can observe and direct workspace Agent Mode sessions without itself becoming a workspace session/card.

The key boundary is that agent/model text is output, while Agent run/session state is the control plane. External callers and the Coordinator should not infer completion, failure, or pending input from model prose when RepoPrompt can expose deterministic lifecycle state.

This change captures the architecture needed before implementation so the role, scope model, run/session lifecycle contract, and tool boundary are agreed before the demo shim hardens into product behavior.

## What Changes

- Add a new `coordinator-role` capability describing the first real Coordinator runtime identity.
- Define the Coordinator as a layer-above meta-agent, separate from Coordinator mode row/card projection.
- Define a native RepoPrompt Agent run/session lifecycle contract underneath MCP tool schemas, including stable handles, deterministic status, pending interaction shape, response/cancel semantics, and durable artifact references.
- Treat MCP `agent_run` and `agent_manage` as adapters/consumers of that lifecycle contract, not as the only durable boundary.
- Use a delegate-only first Coordinator capability boundary: list/supervise sessions, spawn/message/steer agents through explicit APIs, poll/wait for deterministic lifecycle state, and summarize/export through artifact references; do not directly focus tabs, read files, mutate selections, control worktrees, approve/decline, cancel/stop, or inspect full logs in v1.
- Give the Coordinator top-level active-workspace session visibility, or a stricter explicitly recorded scope, without applying the ordinary child-only agent filter.
- Require the Coordinator's own context/history to live outside the workspace fleet projection so it never appears as a normal Coordinator board/list row.
- Define v1 instruction/action audit semantics before adding higher-level directive, autonomy, or broader mutation powers.
- Preserve the existing manual selected-session composer as Layer 1/demo behavior until the real role replaces or supersedes it.

## Capabilities

### New Capabilities
- `coordinator-role`: Defines the real Coordinator meta-agent role, including runtime identity, lifecycle contract, scope model, visibility rules, delegate-only tool contract, v1 instruction/action audit semantics, deferred directive/autonomy boundaries, and relationship to the existing Coordinator view/demo composer.

### Modified Capabilities

None as a formal OpenSpec capability in this change. The existing in-flight `coordinator-mode` change remains the human-facing observation/control-plane surface. This change defines the runtime role and native lifecycle contract that may later integrate with that surface.

## Impact

- Agent Mode role/catalog model: adds or reserves a Coordinator role distinct from `pair`, `engineer`, `explore`, and `design`, while avoiding the trap where a plain role-label addition creates an ordinary tab-backed Coordinator session.
- Native Agent run/session lifecycle: requires a durable RepoPrompt control-plane contract for handles, status, interactions, responses, cancellation, and artifact references.
- MCP binding/tool policy: `agent_run` and `agent_manage` should adapt the native lifecycle contract; Coordinator scope likely requires a top-level/global or active-workspace-top-level control surface distinct from current tab-scoped Agent Mode MCP policy.
- Coordinator mode: must distinguish the temporary selected-session composer target from the real Coordinator runtime.
- Session projection: must ensure Coordinator runtime state is not projected into workspace board/list groups as a supervised session.
- Instruction/action control APIs: requires explicit list/spawn/poll/wait/steer/summarize contracts and auditable action records before implementation; higher-level directives remain deferred.
