## 1. Consumer identity

- [x] 1.1 Add a Coordinator mode case to `MCPServerViewModel.DashboardConsumer`.
- [x] 1.2 Keep existing `.toolbarPopover` and `.statusView` cases unchanged.
- [x] 1.3 Keep Coordinator mode on the existing `setDashboardUpdatesVisible(_:consumer:)` API.

## 2. Shared lifecycle behavior

- [x] 2.1 Verify a first visible consumer starts MCP update observation.
- [x] 2.2 Verify a second visible consumer does not start a duplicate MCP update task.
- [x] 2.3 Verify hiding one of multiple visible consumers keeps observation active.
- [x] 2.4 Verify hiding the last visible consumer stops observation and clears MCP snapshot state when window tools do not force observation.
- [x] 2.5 Verify window-tools-enabled behavior still keeps observation active independent of visible consumers.

## 3. Existing consumer regression coverage

- [x] 3.1 Cover toolbar popover visibility behavior.
- [x] 3.2 Cover status view `startDashboardUpdates()` / `stopDashboardUpdates()` behavior.
- [x] 3.3 Cover mixed visibility among toolbar popover, status view, and Coordinator mode consumers.

## 4. Validation

- [x] 4.1 Run focused MCP Coordinator mode consumer lifecycle tests.
- [x] 4.2 Run the smallest relevant coordinated Swift validation lane for touched MCP view-model files.
- [x] 4.3 Run `openspec validate add-mcp-coordinator-mode-consumer`.
