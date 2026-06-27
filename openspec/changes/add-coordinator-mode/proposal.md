## Why

Users can already run multiple isolated Agent Mode sessions, often across worktrees, but supervising them requires jumping between session rows, transcripts, MCP status, and notifications. RepoPrompt needs a calm mission-control surface that helps users see what needs attention, inspect progress, and jump into the existing Agent UI without replacing it.

## What Changes

- Add a new non-default Coordinator mode peer surface inside the existing `.main` app experience.
- Render Coordinator mode from a single `CoordinatorModeSnapshot` projection composed from the active window's Agent Mode state and `MCPServerViewModel.dashboard`, consuming the MCP Coordinator mode consumer added by `add-mcp-coordinator-mode-consumer`.
- Scope v1 to active-workspace rows with current-window live-state enrichment and keep Agent Mode as the default surface.
- Show a Coordinator rail when a Coordinator can be selected or detected, plus a board-first grouped agent workspace with read-only within-group sorting, List view fallback/alternate, optional inspector / trailing detail column, compact MCP footer/popover, and deep links back to Agent Mode.
- Keep the board/list as the only v1 human-facing fleet view; do not add a separate Coordinator-rail agent roster or "agents in Coordinator context" surface in v1.
- Include one scoped Layer 1 demo/manual write path: a Coordinator composer that is enabled only for a current-window live Coordinator and sends ordinary user turns to that selected session. This is not the future real Coordinator runtime instruction delivery path. Board/list cards, pending prompts, and inspector content remain read-only/deep-link-first.
- Surface structured waiting/user-attention states read-only, enrich live MCP-controlled sessions with normalized interaction details when available, and deep-link users to Agent Mode for response.
- Avoid heuristic labels and runtime rewrites: workflow is optional, objective is deferred, and workstream chips render only from structured data such as worktree binding metadata.

## Capabilities

### New Capabilities
- `coordinator-mode`: Provides Coordinator mode for supervising active-workspace agent sessions through a single Coordinator view projection, board-first grouped status view, List fallback/alternate, optional Coordinator rail with demo/manual current-window Coordinator composer, MCP awareness, and Agent UI deep links. Board/list cards and pending prompts remain read-only/deep-link-first, and v1 does not add a separate by-agent roster in the Coordinator rail.

### Modified Capabilities

None.

## Impact

- App shell: introduces in-`.main` surface selection while preserving existing `.main` / `.workspaceEntry` root gating and Agent Mode default behavior.
- Agent Mode: reads existing session metadata, live window state, pending interaction projection, worktree binding summaries, and deep-link routing without replacing Agent UI.
- MCP: depends on `add-mcp-coordinator-mode-consumer` for the Coordinator mode consumer identity, then projects existing MCP state rather than embedding the full MCP status surface.
- Tests: requires snapshot, grouping, Coordinator selection, MCP projection, deep-link, and surface-selection coverage.
