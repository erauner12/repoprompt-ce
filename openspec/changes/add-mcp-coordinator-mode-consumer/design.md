## Context

`MCPServerViewModel` owns a shared MCP update subscription used by existing MCP UI surfaces:

- `DashboardConsumer` currently includes `.toolbarPopover` and `.statusView`.
- `setDashboardUpdatesVisible(_:consumer:)` mutates a `dashboardConsumers` set and calls `updateDashboardSubscriptionIfNeeded()`.
- `shouldObserveDashboardUpdates` stays true when window tools are enabled or any consumer is visible.
- `dashboardTask` / `dashboardTaskID` / `dashboardSubscriptionID` manage one shared subscription to `MCPService.subscribeToDashboardUpdates()`.
- `MCPServerToggleView` already uses `.toolbarPopover`; `startDashboardUpdates()` / `stopDashboardUpdates()` wrap `.statusView`.

Coordinator mode should become another named consumer of this existing lifecycle. That shared contract should be validated before the Coordinator mode UI depends on it.

## Goals / Non-Goals

**Goals:**

- Add a Coordinator mode consumer identity to `MCPServerViewModel.DashboardConsumer`.
- Preserve one shared MCP update subscription while one or more consumers are visible.
- Stop and clear MCP update state only after the last visible consumer hides, unless window tools keep observation enabled.
- Preserve existing toolbar popover and status view behavior.

**Non-Goals:**

- Building the Coordinator mode UI.
- Creating `CoordinatorModeSnapshot`.
- Changing MCP snapshot contents.
- Adding external MCP error triage or active-scope visualization.
- Changing `MCPService.dashboardSnapshot()` or tool-call attribution semantics.

## Decisions

### 1. Add a named consumer, not a special API

Add a new `DashboardConsumer` case for Coordinator mode, e.g. `.coordinatorMode`. The future Coordinator mode should call the existing `setDashboardUpdatesVisible(_:consumer:)` lifecycle rather than introducing a parallel subscription path.

### 2. Preserve shared subscription semantics

The consumer set remains the source of truth. Adding the Coordinator mode consumer must not create multiple MCP update tasks for multiple visible surfaces. The subscription starts when observation becomes necessary and stops only when no consumer remains and window tools do not force observation.

### 3. Existing surfaces remain unchanged

`.toolbarPopover`, `.statusView`, `startDashboardUpdates()`, and `stopDashboardUpdates()` keep their current behavior. Tests should cover mixed visibility so regressions in existing surfaces are visible independent of the Coordinator mode UI.

## Risks / Trade-offs

- **Shared lifecycle regression** → Test consumer combinations, not just the new case.
- **Over-coupling to future UI** → This change only adds the consumer identity and lifecycle guarantees; Coordinator view rendering belongs to `add-coordinator-mode`.
- **Task ref-count confusion** → Keep one task/subscription per view model, controlled by the consumer set and existing `shouldObserveDashboardUpdates` logic.

## Migration Plan

1. Add the new Coordinator mode consumer case.
2. Add focused tests around consumer set / shared subscription behavior.
3. Confirm existing toolbar and status view consumers still keep the stream alive and stop it at the correct time.
4. Let `add-coordinator-mode` consume this case later.

Rollback is straightforward: remove the unused consumer case and tests before any Coordinator mode UI consumes it.
