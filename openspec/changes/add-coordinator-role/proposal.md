## Why

The current Coordinator view can demo supervision by manually targeting an ordinary live Agent Mode session, but that makes the supervisor part of the supervised workspace fleet. RepoPrompt needs a real Coordinator role: a layer-above meta-agent that can observe and direct workspace Agent Mode sessions without itself becoming a workspace session/card.

The key boundary is that agent/model text is output, while Agent run/session state is the control plane. External callers and the Coordinator should not infer completion, failure, or pending input from model prose when RepoPrompt can expose deterministic lifecycle state.

This change captures the architecture needed before implementation so the role identity, ownership model, scope model, instruction delivery path, and tool boundary are agreed before the demo shim hardens into product behavior.

## What Changes

- Add a new `coordinator-role` capability describing the first real Coordinator runtime identity.
- Define the Coordinator as a layer-above meta-agent, separate from Coordinator mode row/card projection.
- Record the runtime separability verdict: Coordinator v1 uses a marked/background Agent `TabSession`, while a non-enrolled provider runtime is deferred because existing run paths key off compose-tab-to-Agent-session binding.
- Reuse existing `agent_run` / `agent_manage` lifecycle/control surfaces for v1 delegation instead of requiring a new native lifecycle subsystem.
- Use a delegate-only first Coordinator capability boundary: list/supervise sessions, spawn/message/steer agents through explicit APIs, poll/wait for deterministic lifecycle state, and report status/failure from existing snapshot fields; do not directly focus tabs, read files, mutate selections, control worktrees, approve/decline, cancel/stop, or inspect full logs in v1.
- Let Coordinator v1 supervise its own launched delegated fleet through lifecycle handles returned by `agent_run.start`; broader active-workspace `list_sessions` visibility is deferred to a separate capability change.
- Define Coordinator runtime ownership, launch/restore behavior, and the human-to-Coordinator instruction delivery path, with per-window lazy creation as the leading first implementation and existing MCP background-tab creation as the likely seam to confirm.
- Require the Coordinator's identity marker to keep its context/history out of all workspace-session enumeration surfaces at the enumeration boundary, and to protect the runtime from inappropriate background-agent eviction or destructive cleanup/stop targeting, even if storage reuses existing Agent session persistence.
- Define v1 instruction/action audit semantics before adding higher-level directive, autonomy, or broader mutation powers.
- Preserve the existing manual selected-session composer as Layer 1/demo behavior until the real role replaces or supersedes it.

## Capabilities

### New Capabilities
- `coordinator-role`: Defines the real Coordinator meta-agent role, including runtime identity/ownership, launch and instruction delivery, existing lifecycle/control surface reuse, scope model, enumeration visibility rules, delegate-only execution-enforced tool contract, v1 instruction/action audit semantics, deferred directive/autonomy boundaries, and relationship to the existing Coordinator view/demo composer.

### Modified Capabilities

None as a formal OpenSpec capability in this change. The existing in-flight `coordinator-mode` change remains the human-facing observation/control-plane surface. This change defines the runtime role that may later integrate with that surface.

## Impact

- Agent Mode role/catalog model: defines a Coordinator runtime identity distinct from `pair`, `engineer`, `explore`, and `design`, while avoiding the trap where a plain task-label addition creates an ordinary tab-backed Coordinator session; the Coordinator still resolves to a concrete provider/model through a separate launch path.
- Existing Agent run/session lifecycle surfaces: Coordinator v1 should reuse `agent_run` / `agent_manage` start/poll/wait/steer/list behavior; typed native facade extraction is deferred unless implementation proves it necessary.
- Run-lease / connection-policy plumbing: should be refactored to a named policy context before threading the Coordinator privilege marker through the privilege boundary.
- MCP binding/tool policy: Coordinator scope requires lifecycle-handle tracking for launched delegated runs, execution-enforced whole-tool restrictions, whole-tool advertisement filtering, and op/arg-level guards for disallowed operations on otherwise-allowed tools; broader `list_sessions` visibility is a separate visibility-boundary change.
- Coordinator mode: must distinguish the temporary selected-session composer target from the real Coordinator runtime and define the real instruction delivery path.
- Session enumeration and lifecycle targeting: must exclude Coordinator-marked runtime state at the shared workspace-session / `sessionIndex` enumeration boundary so it is never shown as a supervised session in current or future UI, service, or MCP session lists; incidental destructive cleanup/stop flows must also skip Coordinator-marked runtimes unless explicitly authorized, while an intentional user reset/teardown/recreate path remains defined.
- Instruction/action control APIs: requires explicit list/spawn/poll/wait/steer/status-reporting behavior and auditable action records before implementation; v1 may project action records from existing transcript tool-call items before adding a separate store; higher-level directives remain deferred.
