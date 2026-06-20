## Why

The current Coordinator view can demo supervision by manually targeting an ordinary live Agent Mode session, but that makes the supervisor part of the supervised workspace fleet. RepoPrompt needs a real Coordinator role: a layer-above meta-agent that can observe and direct workspace Agent Mode sessions without itself becoming a workspace session/card.

This change captures the architecture needed before implementation so the role, scope model, and tool boundary are agreed before the demo shim hardens into product behavior.

## What Changes

- Add a new `coordinator-role` capability describing the first real Coordinator runtime identity.
- Define the Coordinator as a layer-above meta-agent, separate from Coordinator mode row/card projection.
- Use a delegate-only first capability boundary: list/supervise sessions, spawn/message/steer agents through explicit APIs, and summarize status; do not directly focus tabs, read files, mutate selections, or control worktrees in v1.
- Treat MCP-bound top-level/global scope as the leading runtime hypothesis, while explicitly resolving whether “new agent role in code” means an MCP-bound role entry or a true in-app non-tab-scoped Agent Mode role.
- Require the Coordinator’s own context/history to live outside the workspace fleet projection so it never appears as a normal Coordinator board/list row.
- Define directive/audit semantics before adding autonomy or broader mutation powers.
- Preserve the existing manual selected-session composer as Layer 1/demo behavior until the real role replaces or supersedes it.

## Capabilities

### New Capabilities
- `coordinator-role`: Defines the real Coordinator meta-agent role, including runtime identity, scope model, visibility rules, delegate-only tool contract, directive audit semantics, and relationship to the existing Coordinator view/demo composer.

### Modified Capabilities

None. The existing in-flight `coordinator-mode` change remains the human-facing observation/control-plane surface. This change defines the runtime role that may later integrate with that surface.

## Impact

- Agent Mode role/catalog model: adds or reserves a Coordinator role distinct from `pair`, `engineer`, `explore`, and `design`.
- MCP binding/tool policy: likely requires a top-level/global Coordinator scope distinct from current tab-scoped Agent Mode MCP policy.
- Coordinator mode: must distinguish the temporary selected-session composer target from the real Coordinator runtime.
- Session projection: must ensure Coordinator runtime state is not projected into workspace board/list groups as a supervised session.
- Directive/control APIs: requires explicit message/spawn/steer/summarize contracts and auditable directive records before implementation.
