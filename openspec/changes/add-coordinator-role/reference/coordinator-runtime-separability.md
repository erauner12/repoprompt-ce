# Coordinator runtime separability spike

## Question

Can a provider runtime (Claude/Codex controller + transcript + terminal-commit barrier + loopback MCP client) be driven through one Coordinator-representative turn without being enrolled in `sessionIndex` / the workspace compose-tab model?

## Verdict

**Not separable through the current public run paths.**

Mapping was decisive enough that no disposable harness was added. `AgentModeRunService.startRun` is close to a `TabSession`-driven runtime seam, but every Coordinator-representative entry point that can start a turn or create loopback MCP control first resolves or creates a real compose tab, binds a persistent Agent session ID to it, and uses workspace/tab state for context, persistence, routing, and MCP request binding. A synthetic `tabID` that is absent from workspace compose tabs and absent from the session index can be made into an in-memory `TabSession`, but it cannot represent the current `agent_run.start` path and would bypass the coupling being tested.

## Decisive path mapping

### User-turn path

- `AgentModeViewModel.submitUserTurnCreatingSessionIfNeeded(text:)` starts from `currentTabID`, builds a composer target, and delegates to `executeComposerSubmitAttempt` (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:10770`).
- `executeComposerSubmitAttempt` validates the claimed source session in `sessions[target.tabID]`, may create/activate a session tab, prepares execution location, and finally calls `submitUserTurn(text:tabID:)` (`AgentModeViewModel.swift:10820`).
- `submitUserTurn(text:tabID:)` calls `session(for:)`, appends a user item, updates bindings, schedules save, and starts the run asynchronously (`AgentModeViewModel.swift:11366`, `AgentModeViewModel.swift:11630`, `AgentModeViewModel.swift:11795`).
- `startAgentRun(tabID:initialMessage:)` requires `ensureSessionBoundToTab(session)` before provider start; that binding mutates workspace metadata (`AgentModeViewModel.swift:13029`, `AgentModeViewModel.swift:13053`).

### Runtime start seam

- `AgentModeRunService.startRun` asserts the supplied `TabSession.tabID` matches the supplied `tabID`, resolves workspace path via a dependency hook, and then dispatches to Codex, Claude-native, ACP, or headless runner (`Sources/RepoPrompt/Features/AgentMode/Runtime/AgentModeRunService.swift:160`).
- Its dependencies and hooks are closures back into `AgentModeViewModel`: workspace path, MCP server enabling, persistence, binding updates, UI refresh, terminal publication, attachment cleanup, prompt augmentation, MCP delivery signaling, etc. (`AgentModeViewModel.swift:1953`).
- This means the lower runtime is more separable than the top-level product flow, but the existing seam is not a self-contained Coordinator runtime API; it still assumes a `TabSession` owned by the Agent Mode view model.

### Loopback MCP / `agent_run.start` path

- `AgentRunMCPToolService.executeStart` requires a target window and active non-system workspace before doing anything else (`Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPToolService.swift:256`).
- `agent_run.start` always creates a new session unless an explicit existing tab is requested; explicit `session_id` is rejected (`AgentRunMCPToolService.swift:260`).
- It calls `agentModeVM.mcpResolveOrCreateSessionTarget(... createIfNeeded: true ...)` (`AgentRunMCPToolService.swift:339`).
- `mcpResolveOrCreateSessionTarget` either:
  - rejects an explicit `tabID` if `workspaceManager.composeTab(with:)` does not exist,
  - creates a background compose tab via `promptManager.createBackgroundComposeTab`, or
  - resolves an existing persistent binding using live sessions/workspace claims/session index (`AgentModeViewModel.swift:5761`).
- `mcpCreateBackgroundSessionTab` requires `promptManager` and creates a compose tab with `.mcpBackgroundAgent` capacity policy (`AgentModeViewModel.swift:5870`).
- `AgentExternalMCPRunStarter.start` then activates MCP control, configures the session, binds the current request to the target tab, and dispatches the instruction (`Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentExternalMCPRunStarter.swift:29`).
- `bindCurrentRequestToTabIfPossible` binds the connection to `tabID` + active workspace ID (`Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift:2877`).

## Exact couplings found

### Hard workspace/tab-context coupling

- `mcpResolveOrCreateSessionTarget(tabID:)` rejects non-workspace tabs: `workspaceManager?.composeTab(with: tabID) != nil` is required (`AgentModeViewModel.swift:5799`).
- New MCP starts create a background compose tab, not a runtime-only session (`AgentModeViewModel.swift:5828`, `AgentModeViewModel.swift:5870`).
- Initial thread context reads compose-tab prompt and selection from `workspaceManager.composeTab(with:)`; active tabs additionally publish `promptManager` state before reading (`AgentModeViewModel.swift:14777`).
- Tagged-file auto-selection mutates stored compose-tab selection via `workspaceManager.updateComposeTabStoredOnly` (`AgentModeViewModel.swift:12650`).

Classification: **file/worktree/tab-context coupling**, not cosmetic.

### Hard persistent-session/session-index coupling

- `ensureSessionBoundToTab` creates a persistent Agent session ID and calls `installPersistentSessionBinding(updateWorkspaceMetadata: true)` (`AgentModeViewModel.swift:3331`).
- `installPersistentSessionBinding` compare-and-sets `workspaceManager` active agent session metadata for the tab and refreshes sidebar/session-index derived state (`AgentModeViewModel.swift:3254`).
- `persistentBindingResolution(for:)` resolves session ownership across live `sessions`, workspace compose/stashed tabs, and `ownerValidatedSessionIndex` (`AgentModeViewModel.swift:3366`).
- `mcpActivateControlContext` requires the `TabSession.activeAgentSessionID` to match the requested `sessionID`, registers in `AgentRunSessionStore`, marks the session MCP-originated, and updates MCP/UI state (`AgentModeViewModel.swift:5980`).
- `mcpControlledSession(sessionID:)` finds controlled sessions by scanning `sessions.values`; there is no non-tab runtime registry (`AgentModeViewModel.swift:4516`).

Classification: **persistence/session-index coupling** and **runtime identity coupling**.

### Loopback MCP connection coupling

- `agent_run.start` requires an active project workspace and window (`AgentRunMCPToolService.swift:268`).
- After activation, `AgentExternalMCPRunStarter.start` binds the request/connection to the target tab (`AgentExternalMCPRunStarter.swift:81`).
- That binding uses `connectionID`, active workspace ID, `tabID`, and `windowID` (`MCPServerViewModel.swift:2877`).

Classification: **loopback MCP connection coupling** to tab-scoped routing.

### Runtime-core seam that is partly separable

- `AgentModeRunService.startRun` itself consumes a `TabSession` and callbacks rather than directly reading `promptManager.currentComposeTabs` or `workspaceManager.composeTab` in the body (`AgentModeRunService.swift:160`).
- However its `workspacePathProvider`, `scheduleSave`, `updateBindings`, `publishTerminalCommit`, `augmentUserMessageForProviderSend`, and MCP signaling hooks are view-model closures (`AgentModeViewModel.swift:1953`).
- The Codex path calls `codexRunner.startRun(...)` directly for `.codexExec`, and non-Codex paths build leases that include `tabID`, `runID`, `windowID`, and task-label/control-context state (`AgentModeRunService.swift:185`, `AgentModeRunService.swift:218`).

Classification: **potential extraction seam**, but not enough to prove a Coordinator-representative turn without tab/session enrollment.

## Why no harness was added

The requested synthetic case was:

- synthetic `tabID` not registered in workspace compose tabs,
- not in `sessionIndex`,
- enough `TabSession`-equivalent/provider state to attempt one turn,
- include loopback MCP control context if reachable.

The mapping already falsifies this for the current official path:

1. `agent_run.start` cannot target a non-compose tab; it rejects missing explicit tabs or creates a background compose tab.
2. `startAgentRun` calls `ensureSessionBoundToTab`, which enrolls a persistent session identity and workspace metadata before provider start.
3. MCP control activation requires `activeAgentSessionID == sessionID` and registers that session in the run store.
4. Initial context and tagged-file handling read/mutate compose-tab prompt/selection.

A harness that directly instantiates a `TabSession` and calls `AgentModeRunService.startRun` would test a lower-level seam, not the Coordinator-representative loopback path. It would either avoid `agent_run.start` entirely or reproduce enough `AgentModeViewModel` state to become a marked/background `TabSession` in practice.

## OpenSpec implication

The current implementation supports a **marked `TabSession` / background compose-tab-backed Coordinator runtime**, not a non-enrolled provider runtime.

Design sentence if a marked `TabSession` is necessary:

> Coordinator runtimes are represented as marked Agent `TabSession`s because provider start, transcript persistence, file/worktree context assembly, terminal commit publication, and loopback `agent_run` routing all currently key off the compose-tab-to-Agent-session binding.

## Recommended next action

For the OpenSpec, choose one of two explicit designs:

1. **Near-term / low risk:** model Coordinator as a marked/background Agent `TabSession` with Coordinator metadata and filtering in the UI/session list.
2. **Longer-term extraction:** introduce a runtime-owned session registry and context provider abstraction that replaces compose-tab prompt/selection lookup, workspace active-session binding, session-index ownership, and MCP connection-to-tab binding for Coordinator-owned runtimes.

Do not pursue a “non-enrolled but uses existing `agent_run.start`” design without first extracting those seams.

## Validation

No Swift harness or production code was added, so no build/test validation was required. Mapping was done by static reads of the run, submit, MCP start, target-resolution, and context-building paths.
