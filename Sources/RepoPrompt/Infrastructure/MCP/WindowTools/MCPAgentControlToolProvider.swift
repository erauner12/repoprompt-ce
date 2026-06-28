import Foundation
import JSONSchema
import MCP
import Ontology
import RepoPromptShared

@MainActor
final class MCPAgentControlToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .agentControl

    private let runtime: MCPWindowToolRuntime
    private let dependencies: MCPWindowToolDependencies

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        self.dependencies = dependencies
    }

    func buildTools() -> [Tool] {
        [
            agentExploreTool(),
            agentRunTool(),
            agentManageTool(),
            coordinatorChatTool()
        ]
    }

    private func agentExploreTool() -> Tool {
        let defaultWaitSeconds = Int(MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds)
        return runtime.tool(
            name: MCPWindowToolName.agentExplore,
            freshnessPolicy: .none,
            description: """
            Short-lived, read-only explore child agents for narrow codebase probes. Each child runs in a fresh session with its own context window. Always uses the `explore` role; no custom `model_id`, workflows, session reuse, `steer`, or `respond`.

            Explore children inherit the caller's worktree bindings by default; pass `inherit_worktree=false` to opt out. Start-only worktree controls can bind an existing worktree or create one before provider startup, overriding an inherited primary-root binding. Multi-message creates produce one worktree per child when branch/path are implicit and reject a shared explicit branch or path.

            Valid for workflow-less Coordinator Mission Plan probe nodes when the work is narrow, read-only, and disposable. For Coordinator pre-approval lightweight discovery, pass the planned node's `mission_node_id`. Do not use `agent_explore` for workflow-bearing nodes: it cannot attach `workflow_name`/`workflow_id`; planned Investigate/Deep Plan/Orchestrate/Review nodes must use `agent_run.start` or `agent_run.steer` with the same workflow metadata recorded in the Mission Plan.

            **Operations**: start | poll | wait | cancel

            - `start`: Launch one or more fresh explore sessions. Provide `message` for one probe or `messages` for multiple probes. Batch starts wait for the first referenced session to finish or need input unless `detach=true`.
            - `poll`: Return current snapshot immediately for `session_id` or `session_ids`.
            - `wait`: Block until the first referenced explore run finishes or needs input. `timeout=0` behaves like poll.
            - `cancel`: Cancel a live explore child session.

            Explore children are read-only — no edits, oracle calls, or further sub-agent spawning.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                description: """
                Provide `op` plus operation-specific fields.

                **start**: message or messages (required, mutually exclusive), mission_node_id?, detach?, timeout?, inherit_worktree?, worktree|worktree_id|worktree_create? and worktree_* args
                **poll / wait**: session_id or session_ids (mutually exclusive), timeout? (wait only)
                **cancel**: session_id (required)
                """,
                properties: [
                    "op": .string(description: "Operation.", enum: ["start", "poll", "wait", "cancel"]),
                    "message": .string(description: "[start] Exploration instruction text for one fresh explore child. Mutually exclusive with messages."),
                    "messages": .array(description: "[start] Array of exploration instruction strings. Mutually exclusive with message. Starts one fresh explore child per entry.", items: .string()),
                    "mission_node_id": .string(description: "[start] Optional Coordinator Mission Plan node UUID for policy checks. Required for the pre-approval lightweight discovery exception."),
                    "detach": .boolean(description: "[start] Return immediately instead of waiting. Default false."),
                    "timeout": .number(description: "[start, wait] Max wait seconds. 0 = poll. Default \(defaultWaitSeconds)."),
                    "worktree": .string(description: "[start] Existing worktree selector to bind before provider startup: @current, @main, @branch:<name>, name, branch, path, or @id:<worktree_id>. Mutually exclusive with worktree_id and worktree_create."),
                    "worktree_id": .string(description: "[start] Durable worktree ID to bind before provider startup. Mutually exclusive with worktree and worktree_create."),
                    "worktree_create": .boolean(description: "[start] Create an app-managed Git worktree, bind it to the new session, materialize its hidden root, then start the provider. Mutually exclusive with worktree/worktree_id."),
                    "inherit_worktree": .boolean(description: "[start] When started from an Agent Mode run, inherit the source session's worktree bindings before provider startup. Default true. Set false to keep parent session threading but skip worktree inheritance; explicit worktree/worktree_id/worktree_create args still bind the requested worktree."),
                    "worktree_repo_root": .string(description: "[start] Repo/logical root selector for worktree resolution or creation. Defaults to the first loaded Git repo."),
                    "worktree_branch": .string(description: "[start + worktree_create] Optional branch name for the new worktree. Defaults to an rp/agent/<session>-... branch."),
                    "worktree_base_ref": .string(description: "[start + worktree_create] Optional base ref/commit for the new worktree."),
                    "worktree_path": .string(description: "[start + worktree_create] Optional explicit absolute path (or ~/...). External paths require allow_external_worktree_path=true."),
                    "worktree_label": .string(description: "[start] Optional visual label to persist for the bound worktree."),
                    "worktree_color": .string(description: "[start] Optional visual color to persist for the bound worktree as #RRGGBB."),
                    "allow_external_worktree_path": .boolean(description: "[start + worktree_create] Allow explicit worktree_path outside RepoPrompt's app-managed worktree container."),
                    "session_id": .string(description: "[poll, wait, cancel] Explore child session UUID returned by start."),
                    "session_ids": .array(description: "[wait, poll] Array of explore child session UUIDs. Mutually exclusive with session_id.", items: .string())
                ],
                required: ["op"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executeAgentExplore(args)
        }
    }

    private func agentRunTool() -> Tool {
        let defaultWaitSeconds = Int(MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds)
        let messageDescription = "[start, steer] Instruction text. Required for start and steer. If sharing an exported plan, include the path/instruction directly in this text."
        return runtime.tool(
            name: MCPWindowToolName.agentRun,
            freshnessPolicy: .none,
            description: """
            Spawn and control Agent Mode sessions. `start` always creates a new session/tab; use `steer` to continue an existing session.

            **Role labels** — pass as `model_id` to select via the global role-default mapping:
            - `explore` — Fast exploration and codebase mapping
            - `engineer` — Balanced engineering work
            - `pair` — Interactive pair programming with highest-tier models
            - `design` — Architecture, design discussions, creative problem solving; writes a markdown review document (saved under `docs/reviews/`, `docs/designs/`, or `docs/analysis/`) as its primary deliverable for review/analysis tasks

            Role labels resolve through the effective global role-default mapping; see the top-level `task_labels` array from `agent_manage.list_agents` for the authoritative label→model mapping. If `model_id` is omitted on `start`, RepoPrompt uses the `pair` role. To pin an exact agent+model+effort target, pass a specific compound `model_id` from `agents[].models[].model_id` in the same response.

            **Operations**: start | poll | wait | cancel | steer | respond

            - `start`: Launch an agent run in a **new** session/tab. Do NOT pass `session_id` — use `steer` to continue an existing session. Omit `model_id` to use the `pair` role, or pass `model_id` with a role label (resolved via the global role-default mapping in `agent_manage.list_agents` `task_labels`) or an explicit compound `model_id` from `agents[].models[].model_id`. When started from an Agent Mode run, the new child session inherits the source session's worktree bindings by default; pass `inherit_worktree=false` to keep parent session threading but skip worktree inheritance. Optional start-only worktree args can bind the new session to an existing worktree (`worktree`/`worktree_id`) or create an app-managed worktree (`worktree_create=true`) before provider startup; explicit worktree args still bind the requested worktree. Returns a `session_id` — save it for all follow-up calls. Waits up to `timeout` seconds (default \(defaultWaitSeconds)). Pass `detach: true` to return immediately. Required for workflow-bearing Coordinator Mission Plan nodes, including read-only Investigate nodes; pass the node's `workflow_name`/`workflow_id`. For narrow workflow-less read-only probe nodes, prefer `agent_explore.start`.
            - `poll`: Return current snapshot immediately. Accepts `session_id` (single) or `session_ids` (array — returns all current snapshots).
            - `wait`: Block until the run finishes or needs input. Default \(defaultWaitSeconds)s. `timeout: 0` = poll. Accepts `session_id` (single) or `session_ids` (array — returns when first session reaches interesting state). Returns `interaction_id` when input is pending.
            - `cancel`: Stop an active agent run. Only valid when the run is `running` or `waiting_for_input`. Requires `session_id`.
            - `steer`: Continue an existing agent session by sending a follow-up instruction to the `session_id` returned by `start`. If the run is still active, the instruction is steered into that run; if the last run already finished, RepoPrompt starts the next run in the same session. Pass `wait: true` (or `timeout_seconds`) to block until the steered run finishes or needs input. Do NOT use `steer` when status is `waiting_for_input` — use `respond` instead. For workflow-bearing Coordinator Mission Plan nodes, pass the same `workflow_name`/`workflow_id` recorded on the node.
            - `respond`: Resolve a pending interaction (question, approval, MCP elicitation, etc). Requires `session_id` and `interaction_id` from the snapshot. The `interaction_id` is returned as a top-level field in poll/wait responses when input is pending. For MCP elicitation, use `response` (`accept`, `decline`, or `cancel`) plus optional object `content` and `meta`.

            **session_id lifecycle**: `start` creates a new session and returns `session_id` in the response. All subsequent operations on that run require passing the same `session_id` back. Do NOT invent session IDs — always use the value returned by `start`.

            **Sub-agent spawning**: MCP-started `orchestrate` runs can dispatch sub-agents. Sub-agents cannot recursively start additional agent runs.

            **Parallel agents**: When launching multiple agents in parallel, always use `detach: true` so each `start` returns immediately without blocking. You can then `wait` or `poll` each `session_id` independently.

            **IMPORTANT — never end your turn with active agents**: Sub-agents may need approval for tool calls or ask questions via `waiting_for_input`. Always `wait`/`poll` on every started session and `respond` to any pending interactions before finishing your turn. An unattended agent will stall indefinitely.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                description: """
                Provide `op` plus operation-specific fields.

                **start**: message (required), model_id? (defaults to pair), session_name?, mission_node_id?, workflow_id|workflow_name?, detach?, timeout?, inherit_worktree?, coordinator_internal?, worktree|worktree_id|worktree_create? and worktree_* args. Use workflow_name="orchestrate" to plan, decompose, and dispatch sub-agents.
                **poll / wait**: session_id or session_ids (mutually exclusive), timeout? (wait only)
                **cancel**: session_id (required)
                **steer**: session_id (required, from a prior `start`/`steer` response), message (required), wait?, timeout_seconds?, workflow_id|workflow_name?
                **respond**: session_id (required), interaction_id (required), response?, answers?, amendment?, content?, meta?
                """,
                properties: [
                    "op": .string(description: "Operation.", enum: ["start", "poll", "wait", "cancel", "steer", "respond"]),
                    "message": .string(description: messageDescription),
                    "model_id": .string(description: "[start] Role label from agent_manage.list_agents task_labels (explore, engineer, pair, design — resolved via global role defaults), or an explicit compound model_id from agents[].models[].model_id to pin an exact target. Defaults to pair when omitted."),
                    "session_id": .string(description: "[poll, wait, cancel, steer, respond] Session UUID returned by a prior start/steer response. Do not fabricate it. Not accepted by start — use steer to continue an existing session."),
                    "session_ids": .array(description: "[wait, poll] Array of session UUIDs. For wait: returns when first session reaches interesting state. For poll: returns all current snapshots. Mutually exclusive with session_id.", items: .string()),
                    "session_name": .string(description: "[start] Display name for a new session."),
                    "mission_node_id": .string(description: "[start] Optional Coordinator Mission Plan node UUID for policy checks and later Coordinator-side binding. Required for pre-approval Investigate, Deep Plan, and plan_critique exceptions."),
                    "workflow_id": .string(description: "[start, steer, respond] Workflow ID. Mutually exclusive with workflow_name."),
                    "workflow_name": .string(description: "[start, steer, respond] Workflow name. Mutually exclusive with workflow_id."),
                    "coordinator_internal": .boolean(description: "[start] Coordinator-internal housekeeping session. Hides the child from Coordinator board/action-chip surfaces while preserving parentage and Agent Mode state. Default false."),
                    "detach": .boolean(description: "[start] Return immediately instead of waiting. Default false."),
                    "timeout": .number(description: "[start, wait] Max wait seconds. 0 = poll. Default \(defaultWaitSeconds)."),
                    "worktree": .string(description: "[start] Existing worktree selector to bind before provider startup: @current, @main, @branch:<name>, name, branch, path, or @id:<worktree_id>. Mutually exclusive with worktree_id and worktree_create."),
                    "worktree_id": .string(description: "[start] Durable worktree ID to bind before provider startup. Mutually exclusive with worktree and worktree_create."),
                    "worktree_create": .boolean(description: "[start] Create an app-managed Git worktree, bind it to the new session, materialize its hidden root, then start the provider. Mutually exclusive with worktree/worktree_id."),
                    "inherit_worktree": .boolean(description: "[start] When started from an Agent Mode run, inherit the source session's worktree bindings before provider startup. Default true. Set false to keep parent session threading but skip worktree inheritance; explicit worktree/worktree_id/worktree_create args still bind the requested worktree."),
                    "worktree_repo_root": .string(description: "[start] Repo/logical root selector for worktree resolution or creation. Defaults to the first loaded Git repo."),
                    "worktree_branch": .string(description: "[start + worktree_create] Optional branch name for the new worktree. Defaults to an rp/agent/<session>-... branch."),
                    "worktree_base_ref": .string(description: "[start + worktree_create] Optional base ref/commit for the new worktree."),
                    "worktree_path": .string(description: "[start + worktree_create] Optional explicit absolute path (or ~/...). External paths require allow_external_worktree_path=true."),
                    "worktree_label": .string(description: "[start] Optional visual label to persist for the bound worktree."),
                    "worktree_color": .string(description: "[start] Optional visual color to persist for the bound worktree as #RRGGBB."),
                    "allow_external_worktree_path": .boolean(description: "[start + worktree_create] Allow explicit worktree_path outside RepoPrompt's app-managed worktree container."),
                    "wait": .boolean(description: "[steer] Wait for an interesting/terminal state after steering. Implied when timeout_seconds is provided."),
                    "timeout_seconds": .number(description: "[steer] Max wait seconds when wait=true. 0 = immediate post-steer snapshot. Default \(defaultWaitSeconds)."),
                    "interaction_id": .string(description: "[respond] Pending interaction UUID from the snapshot. Returned as a top-level field in poll/wait responses when the run is waiting_for_input."),
                    "response": .string(description: "[respond] Text answer or decision token (accept, decline, cancel, skip, etc). For MCP elicitation use accept, decline, or cancel; a non-action string is sent as content.response."),
                    "answers": .object(description: "[respond] Structured answers keyed by question ID."),
                    "content": .object(description: "[respond] MCP elicitation content object to send with action=accept."),
                    "meta": .object(description: "[respond] Optional MCP elicitation _meta object."),
                    "amendment": .string(description: "[respond] Amendment text for accept_with_amendment decisions.")
                ],
                required: ["op"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executeAgentRun(args)
        }
    }

    private func agentManageTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.agentManage,
            freshnessPolicy: .providerManaged,
            description: """
            List agents, manage sessions, and browse workflows.

            **Operations**: list_agents | list_sessions | get_log | extract_handoff | handoff | create_session | resume_session | stop_session | cleanup_sessions | list_workflows

            - `list_agents`: Returns top-level `task_labels` as the authoritative role-label→model mapping (explore, engineer, pair, design), plus `agents[].models[]` with explicit compound `model_id` targets for callers that want to pin a specific agent/model/effort. Use `task_labels` entries for role-based routing; use `agents[].models[].model_id` for exact selections. Pass `roles_only=true` to return only `task_labels` and omit the explicit per-agent target catalog.
            - `list_sessions`: Browse sessions. Returns `session_id` for each session. Filter by MCP-facing `state` (e.g. `running`, `waiting_for_input`, `completed`, `failed`). When called from agent mode, automatically scopes to sessions spawned by the current agent session.
            - `get_log`: Read faithful transcript XML for a session, preserving visible assistant/tool order without handoff compaction or narration pruning. Use `offset`/`limit` to page by turns.
            - `extract_handoff` (`handoff` alias): Export the full `<forked_session ...>` handoff XML for a live or persisted session. Persisted sessions export transcript-only payloads; `include_file_contents` is accepted only for a live source tab that is currently active so file selection can be snapshotted reliably. Use `output_path` to write to a file; inline XML is returned by default only when no output path is provided.
            - `create_session` / `resume_session`: Create or resume a session with a specific `model_id`.
            - `stop_session`: Stop a live session.
            - `cleanup_sessions`: Delete specific MCP-originated sessions by ID. Only sessions started via MCP are eligible; user-created sessions are never deleted. Skips active sessions. Use `list_sessions` first to find session IDs, then pass them here.
            - `list_workflows`: Discover workflows usable with `agent_run` operations, including `orchestrate` for planning, decomposition, and sub-agent dispatch.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                description: """
                Provide `op` plus operation-specific fields.

                **list_agents**: roles_only?
                **list_workflows**: no additional fields
                **list_sessions**: agent?, state?, limit?
                **get_log**: session_id (required), offset?, limit?
                **extract_handoff / handoff**: session_id (required), up_to_item_id?, include_file_contents?, output_path?, overwrite?, inline?, max_transcript_items?, max_tool_args_characters?
                **create_session**: model_id?, session_name?
                **resume_session**: session_id (required), model_id?
                **stop_session**: session_id (required)
                **cleanup_sessions**: session_ids (required, array of session UUIDs)

                Default extraction behavior: `extract_handoff` (or alias `handoff`) returns `handoff_xml` inline when `output_path` is omitted. When `output_path` is provided, XML is written to disk and omitted from the response unless `inline=true`. `output_path` must be absolute (or `~/...`); CLI shorthand resolves relative paths before calling MCP.
                """,
                properties: [
                    "op": .string(description: "Operation.", enum: ["list_agents", "list_sessions", "get_log", "extract_handoff", "handoff", "create_session", "resume_session", "stop_session", "cleanup_sessions", "list_workflows"]),
                    "model_id": .string(description: "[create_session, resume_session] Role label from list_agents task_labels (explore, engineer, pair, design — resolved via global role defaults), or an explicit compound model_id from list_agents agents[].models[].model_id."),
                    "session_id": .string(description: "[get_log, extract_handoff, resume_session, stop_session] Session UUID."),
                    "session_name": .string(description: "[create_session] Display name for a new session."),
                    "limit": .integer(description: "[list_sessions, get_log] Max results."),
                    "up_to_item_id": .string(description: "[extract_handoff] Optional transcript row UUID cutoff."),
                    "include_file_contents": .boolean(description: "[extract_handoff] Include file contents only when the source session is live and its tab is active. Default false."),
                    "output_path": .string(description: "[extract_handoff] Absolute output path (or ~/...) for the handoff XML. When set, inline XML is omitted unless inline=true."),
                    "overwrite": .boolean(description: "[extract_handoff] Whether output_path may replace an existing file. Default true."),
                    "inline": .boolean(description: "[extract_handoff] Include handoff_xml in the response. Default true without output_path, false with output_path."),
                    "max_transcript_items": .integer(description: "[extract_handoff] Transcript item budget; clamped to 1...1000. Default 200."),
                    "max_tool_args_characters": .integer(description: "[extract_handoff] Tool argument character budget; clamped to 0...20000. Default 2000."),
                    "state": .string(description: "[list_sessions] Session state filter. Use MCP-facing values such as running, waiting_for_input, completed, failed."),
                    "offset": .integer(description: "[get_log] Turn offset."),
                    "session_ids": .array(description: "[cleanup_sessions] Array of session UUIDs to delete.", items: .string()),
                    "roles_only": .boolean(description: "[list_agents] When true, return only the authoritative role-label mapping (task_labels) and omit the explicit per-agent target catalog. Default false.")
                ],
                required: ["op"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executeAgentManage(args)
        }
    }

    private func coordinatorChatTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.coordinatorChat,
            freshnessPolicy: .providerManaged,
            description: """
            External test/control surface for Coordinator Mode. This mirrors the visible Coordinator UI: list parent threads, select a parent thread, start a fresh parent thread, atomically start a fresh Mission with an initial directive, stop the selected Mission, submit a directive to the selected parent, or record/read the selected Mission Plan.

            **Operations**: list | select | new | start_mission | stop_mission | submit | mission_plan | mission_status

            - `list`: Return current Coordinator parent selection, available parents, and board counts.
            - `select`: Select an existing Coordinator parent by `coordinator_session_id`.
            - `new`: Mirror New Coordinator. The rail switches to a blank parent context; the next submit creates the parent runtime.
            - `start_mission`: Start a fresh Coordinator Mission and submit the initial directive in one operation. Prefer this for external automation starting a new mission.
            - `stop_mission`: Stop the selected or requested Coordinator Mission and cancel live linked sessions without archiving or deleting them.
            - `submit`: Send a directive to the selected parent, to `coordinator_session_id`, or to a fresh parent when `new_parent=true`.
            - `mission_plan`: Create or update the selected Coordinator Mission's DAG-lite plan. Use this before delegated child starts. Workstream and node arrays are upserts by default: include only changed entries for existing IDs/titles; omitted entries are preserved. Use `replace_workstreams=true` or `replace_nodes=true` when rewriting that part of the plan of record. Routing decisions append/upsert by id.
            - `mission_status`: Read back the selected Coordinator Mission's current plan, node status, and newest 20 routing decisions. Use `compact=true` for polling from external automation.

            Coordinator-role agents should use `mission_plan` to record concrete user-specific deliverables before delegating child Agent Mode sessions. Workflows such as Investigate, Deep Plan, Orchestrate, and Review belong in node workflow metadata only when the node is intended to run that real workflow. Workflow-less read-only probe nodes may be launched with `agent_explore.start`; workflow-bearing nodes should be launched or steered through `agent_run` with the same workflow, and `mission_status` reports planned/actual workflow matches for bound nodes.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                description: """
                Provide `op` plus operation-specific fields.

                **list**: no additional fields
                **select**: coordinator_session_id (required)
                **new**: no additional fields
                **start_mission**: message (required)
                **stop_mission**: coordinator_session_id?
                **submit**: message (required), coordinator_session_id? or new_parent?
                **mission_plan**: coordinator_session_id? plus one or more of objective, status, approval_state, workstreams, nodes, routing_decisions, events. replace_workstreams/replace_nodes may be true for deliberate plan rewrites.
                **mission_status**: coordinator_session_id?, compact?; returns current plan state and routing_decisions_recent newest-first, max 20. compact=true returns a smaller polling summary with liveness warnings, checkpoint submit hints, and short recent history.
                """,
                properties: [
                    "op": .string(description: "Operation.", enum: ["list", "select", "new", "start_mission", "stop_mission", "submit", "mission_plan", "mission_status"]),
                    "coordinator_session_id": .string(description: "[select, stop_mission, submit, mission_plan, mission_status] Existing Coordinator parent session UUID. Defaults to the selected Coordinator for mission_plan/mission_status."),
                    "message": .string(description: "[start_mission, submit] Directive text to send to the fresh, selected, or requested Coordinator parent."),
                    "new_parent": .boolean(description: "[submit] Start from a blank Coordinator parent before sending this directive. Default false."),
                    "compact": .boolean(description: "[mission_status] Return a small polling summary instead of the full Coordinator snapshot. Includes plan-approval checkpoint actions when available. Default false."),
                    "objective": .string(description: "[mission_plan] User-specific Mission objective."),
                    "status": .string(description: "[mission_plan] Mission status.", enum: ["draft", "approved", "running", "blocked", "completed", "stopped"]),
                    "approval_state": .string(description: "[mission_plan] Human approval state for the plan.", enum: ["not_required", "awaiting_approval", "approved", "revision_requested"]),
                    "replace_workstreams": .boolean(description: "[mission_plan] Replace all existing workstreams with the provided workstreams instead of upserting/preserving omitted workstreams. Default false."),
                    "replace_nodes": .boolean(description: "[mission_plan] Replace all existing nodes with the provided nodes instead of upserting/preserving omitted nodes. Default false."),
                    "workstreams": .array(
                        description: "[mission_plan] Workstream upsert objects. Existing workstreams may be patched by id or title. New workstreams require title, purpose, default_policy, and worktree_strategy { mode, worktree_id?, reason? }.",
                        items: .object(
                            description: "Mission workstream.",
                            properties: [
                                "id": .string(description: "Optional stable UUID."),
                                "title": .string(description: "User-level workstream title."),
                                "purpose": .string(description: "Why this workstream exists."),
                                "role": .string(description: "Optional role label."),
                                "default_policy": .string(description: "Default execution policy.", enum: ["coordinator_only", "fresh_readonly_child", "steer_primary", "fresh_sibling_on_same_worktree", "fresh_worktree", "ask_user"]),
                                "worktree_strategy": .object(
                                    description: "Worktree strategy.",
                                    properties: [
                                        "mode": .string(description: "Worktree mode.", enum: ["noneReadOnly", "createIsolated", "reuseExisting", "reuseWorkstream", "askUser"]),
                                        "worktree_id": .string(description: "Optional worktree identifier."),
                                        "reason": .string(description: "Reason for this strategy.")
                                    ],
                                    required: ["mode"]
                                ),
                                "primary_session_id": .string(description: "Optional primary child session UUID."),
                                "related_session_ids": .array(description: "Optional related child session UUIDs.", items: .string())
                            ],
                            required: ["title"]
                        )
                    ),
                    "nodes": .array(
                        description: "[mission_plan] DAG-lite node upserts. Titles should be concrete deliverables, not generic phase names. Existing nodes may be patched by id or title. New nodes require title, workstream_id or workstream_title, and execution_policy; status defaults to pending.",
                        items: .object(
                            description: "Mission Plan node.",
                            properties: [
                                "id": .string(description: "Optional stable UUID."),
                                "title": .string(description: "Concrete deliverable title."),
                                "detail": .string(description: "Node detail."),
                                "workflow_name": .string(description: "Optional workflow hint such as Deep Plan, Orchestrate, or Review."),
                                "completion_evidence": .string(description: "Evidence that marks this node complete."),
                                "workstream_id": .string(description: "Workstream UUID."),
                                "workstream_title": .string(description: "Workstream title alternative."),
                                "depends_on": .array(description: "Dependency node UUIDs.", items: .string()),
                                "role": .string(description: "Optional role label."),
                                "execution_policy": .string(description: "How this node should execute.", enum: ["coordinator_only", "fresh_readonly_child", "steer_primary", "fresh_sibling_on_same_worktree", "fresh_worktree", "plan_critique", "ask_user"]),
                                "status": .string(description: "Node status.", enum: ["pending", "running", "completed", "blocked", "skipped", "cancelled"]),
                                "bound_session_id": .string(description: "Optional delegated session UUID."),
                                "bound_interaction_id": .string(description: "Optional interaction UUID.")
                            ],
                            required: ["title"]
                        )
                    ),
                    "events": .array(
                        description: "[mission_plan] Optional plan events.",
                        items: .object(
                            description: "Mission Plan event.",
                            properties: [
                                "id": .string(description: "Optional event UUID."),
                                "kind": .string(description: "Event kind.", enum: ["created", "revised", "approved", "node_started", "node_completed", "node_blocked", "session_bound", "gate_cleared"]),
                                "node_id": .string(description: "Optional node UUID."),
                                "node_title": .string(description: "Optional node title alternative."),
                                "session_id": .string(description: "Optional session UUID."),
                                "interaction_id": .string(description: "Optional interaction UUID."),
                                "timestamp": .string(description: "Optional ISO 8601 timestamp."),
                                "summary": .string(description: "Event summary.")
                            ],
                            required: ["kind"]
                        )
                    ),
                    "routing_decisions": .array(
                        description: "[mission_plan] Optional Coordinator routing decision log entries. Entries append/upsert by id; omitted decisions are preserved. Record these before/with start, steer, respond, cancel, or hold choices.",
                        items: .object(
                            description: "Coordinator routing decision.",
                            properties: [
                                "id": .string(description: "Optional stable decision UUID. Reuse id to replace a previous decision."),
                                "timestamp": .string(description: "Optional ISO 8601 timestamp."),
                                "node_id": .string(description: "Optional Mission Plan node UUID."),
                                "node_title": .string(description: "Optional node title alternative."),
                                "workstream_id": .string(description: "Optional workstream UUID."),
                                "workstream_title": .string(description: "Optional workstream title alternative."),
                                "decision": .string(description: "Routing decision kind.", enum: ["start_fresh_readonly_child", "start_fresh_worktree", "steer_primary", "start_fresh_sibling_on_same_worktree", "respond_to_interaction", "hold_for_user", "cancel_or_replace"]),
                                "operation": .string(description: "Concrete operation chosen.", enum: ["agent_explore.start", "agent_run.start", "agent_run.steer", "agent_run.respond", "agent_run.cancel", "coordinator_hold"]),
                                "session_id": .string(description: "Optional target/new child session UUID."),
                                "prior_session_id": .string(description: "Optional previous/replaced session UUID."),
                                "worktree_id": .string(description: "Optional worktree identifier."),
                                "workflow_name": .string(description: "Optional workflow label such as Investigate, Orchestrate, or Review."),
                                "model_id": .string(description: "Optional model_id target used for this route."),
                                "role": .string(description: "Optional role label used for this route."),
                                "reason": .string(description: "Why this route was chosen."),
                                "context_summary": .string(description: "Compact handoff context used to make the routing decision.")
                            ],
                            required: ["decision", "operation", "reason"]
                        )
                    )
                ],
                required: ["op"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executeCoordinatorChat(args)
        }
    }
}
