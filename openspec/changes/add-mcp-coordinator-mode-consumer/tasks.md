## 1. Consumer identity

- [ ] 1.1 Add a Coordinator mode case to `MCPServerViewModel.DashboardConsumer`.
- [ ] 1.2 Keep existing `.toolbarPopover` and `.statusView` cases unchanged.
- [ ] 1.3 Keep Coordinator mode on the existing `setDashboardUpdatesVisible(_:consumer:)` API.

## 2. Shared lifecycle behavior

- [ ] 2.1 Verify a first visible consumer starts MCP update observation.
- [ ] 2.2 Verify a second visible consumer does not start a duplicate MCP update task.
- [ ] 2.3 Verify hiding one of multiple visible consumers keeps observation active.
- [ ] 2.4 Verify hiding the last visible consumer stops observation and clears MCP snapshot state when window tools do not force observation.
- [ ] 2.5 Verify window-tools-enabled behavior still keeps observation active independent of visible consumers.

## 3. Existing consumer regression coverage

- [ ] 3.1 Cover toolbar popover visibility behavior.
- [ ] 3.2 Cover status view `startDashboardUpdates()` / `stopDashboardUpdates()` behavior.
- [ ] 3.3 Cover mixed visibility among toolbar popover, status view, and Coordinator mode consumers.

## 4. Validation

- [ ] 4.1 Run focused MCP Coordinator mode consumer lifecycle tests.
- [ ] 4.2 Run the smallest relevant coordinated Swift validation lane for touched MCP view-model files.
- [ ] 4.3 Run `openspec validate add-mcp-coordinator-mode-consumer`.
