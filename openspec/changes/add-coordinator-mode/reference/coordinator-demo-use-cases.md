# Coordinator Demo Use Cases

This demo script distinguishes the three axes that can otherwise blur together:

- **Coordinator runtime root**: one top-level Coordinator conversation/control loop, created by the existing Coordinator runtime or by `New Coordinator`.
- **Delegated session**: a normal tab-scoped Agent Mode session launched by a Coordinator runtime root.
- **Owner Coordinator**: the Coordinator runtime root that owns a board row's attribution; this is resolved from structured lineage and is not necessarily the row's immediate `parentSessionID`.
- **Worktree**: the workspace used by a delegated session; multiple worktrees do not imply multiple Coordinator runtime roots.

The rule of thumb: prompt text can ask one Coordinator runtime root to launch many delegated sessions, while `New Coordinator` creates another Coordinator runtime root. Read-only probe descendants under a delegated worker still attribute to the same owner Coordinator; they are not separate parent Coordinators.

## 1. Single Delegation

Facet: basic Coordinator-to-agent loop.

Checkpoint required: current single-runtime demo.

Gesture:

1. Send one directive to the current Coordinator.

Prompt:

```text
Delegate one agent using the Investigate workflow to answer this repo question: does the README mention how to run tests? Keep it to one delegated session and report the finding in one sentence.
```

Expected result:

- One Coordinator parent.
- One delegated child.
- The board shows one child moving through `Working` to `Done`.
- The rail shows a concise Coordinator response.

## 2. One-Parent Fan-Out

Facet: one mission parallelized across multiple workers.

Checkpoint required: current single-runtime demo; selected-runtime checkpoint also supports it.

Gesture:

1. Send one fan-out directive to the current Coordinator.

Prompt:

```text
Coordinate three delegated checks in parallel, each in its own worktree: one agent checks README.md for test instructions, one checks AGENTS.md for validation guidance, and one checks CONTRIBUTING.md for contributor setup notes. Wait for all three and report a three-row status summary.
```

Expected result:

- One Coordinator parent.
- Three delegated children.
- Usually three worktrees, one per child.
- The board shows three child cards owned by the same parent.
- This should not create three parent Coordinators.

## 3. Sequential Multi-Parent Work

Facet: separate missions that should not share one conversation.

Checkpoint required: selected-runtime board checkpoint; the rail-header parent switcher must let the user return to an earlier parent.

Gesture:

1. Send Parent A prompt.
2. Click `New Coordinator`.
3. Send Parent B prompt.

Parent A prompt:

```text
Delegate one Investigate workflow agent to check whether README.md documents how to run tests. Keep it to one child and report one sentence.
```

Parent B prompt:

```text
Delegate one Review workflow agent to inspect openspec/changes/add-coordinator-mode/specs/coordinator-mode/spec.md for whether fan-out versus multi-parent semantics are clear. Report one paragraph and do not edit files.
```

Expected result:

- Two Coordinator parents.
- Each parent has its own conversation and child.
- In selected-runtime mode, switching selected parent swaps the rail and selected board scope.
- In aggregate mode, both children remain visible together with parent attribution.

## 4. Simultaneous Multi-Parent Work

Facet: the headline control-plane demo: multiple missions in flight at once.

Checkpoint required: aggregate fleet board checkpoint.

Gesture:

1. Send a fan-out prompt to Parent A.
2. While Parent A is still running, click `New Coordinator`.
3. Send a second fan-out prompt to Parent B.

Parent A prompt:

```text
Delegate two agents in parallel: one audits the MCP layer for obvious error-handling risks, and one checks nearby tests for coverage gaps. Use separate worktrees, do not edit files, and report back when both are complete.
```

Parent B prompt:

```text
Delegate two agents in parallel: one reviews the README setup instructions for accuracy, and one checks for broken or stale documentation links. Use separate worktrees, do not edit files, and report back when both are complete.
```

Expected result:

- Two Coordinator parents.
- Four delegated children total.
- The aggregate board shows all eligible children at once.
- Each card/row has sourced parent attribution so the user can tell which mission owns it.
- The selected parent receives subtle emphasis without hiding the other parent's children.

## 5. Switch And Supervise

Facet: durable parent conversations that can be revisited.

Checkpoint required: selected-runtime board checkpoint; aggregate board makes it more legible.

Gesture:

1. Send a prompt to Parent A.
2. Click `New Coordinator`.
3. Send a prompt to Parent B.
4. Use the rail-header parent switcher to select Parent A again.
5. Send a follow-up to Parent A.

Parent A prompt:

```text
Delegate one Investigate workflow agent to inspect the Coordinator demo tasks and identify the smallest remaining implementation risk. Report a short finding.
```

Parent B prompt:

```text
Delegate one Review workflow agent to inspect the Coordinator board/list UI notes and identify one polish issue worth fixing next. Report a short finding.
```

Parent A follow-up:

```text
Based on that risk, ask one more delegated agent to verify whether the relevant test coverage exists. Keep it to one child and report the result.
```

Expected result:

- Parent A and Parent B remain separate Coordinator conversations.
- Selecting Parent A restores the rail target for Parent A instead of creating a new parent.
- The follow-up attaches to Parent A and does not affect Parent B's conversation.
- In aggregate mode, children from both parents remain visible with parent attribution.

## 6. DAG-Lite Mission Status Smoke

Facet: external Mission Plan control surface, Plan tab projection, and unified node inspector without delegated child behavior.

Checkpoint required: `coordinator_chat` `mission_plan` write, `mission_status` readback, Plan presentation, and inspector projection.

Gesture:

1. Start or select a fresh Coordinator Mission named `DAG-lite status smoke`.
2. Use `coordinator_chat` `op=mission_plan` to write one read-only Mission Plan revision.
3. Use `coordinator_chat` `op=mission_status` to read the Mission state back.
4. Open the Plan presentation and select `Orchestrate` or `Review`.

Prompt:

```text
DAG-lite mission status smoke. Start a fresh Coordinator Mission. Record a Mission Plan with objective "Validate DAG-lite status surface", one workstream named "Status surface", and three nodes: Plan, Orchestrate, Review. Mark Plan completed, Orchestrate running, Review pending and dependent on Orchestrate. Then summarize the Mission status: debug summary, node counts, and whether Review dependencies are satisfied. Do not edit files or launch child agents.
```

Expected readback:

- `debug_summary` is `DAG-lite status smoke: running, r1, 1/3 terminal nodes, 1 active/blocking.`
- Node counts include `completed: 1`, `running: 1`, and `pending: 1`.
- `Review.dependencies_satisfied == false` because `Orchestrate` is still running.
- The Plan presentation renders revision `r1`, status `Running`, approval `Approved`, workstream `Status surface`, and nodes `Plan`, `Orchestrate`, and `Review`.
- Selecting a node opens the unified inspector with its status, role/workflow metadata, dependency state, and recent node event.
- The scenario does not edit files, launch child agents, or rely on app-side hidden mutation beyond the explicit Mission Plan state written through `mission_plan`.

Coordinator-owned completion checkpoint:

1. Update the same Mission Plan so `Plan` and `Orchestrate` are `completed`, `Review` is `running`, and `Review.dependencies_satisfied == true`.
2. Send a Coordinator chat directive to complete the current state-only Mission Plan.
3. Read `mission_status` again.

Expected completion readback:

- `debug_summary` is completed with `3/3 terminal nodes` and `0 active/blocking`.
- Node counts include `completed: 3`, `running: 0`, and `pending: 0`.
- `Plan`, `Orchestrate`, and `Review` are all `completed`.
- No delegated child rows are created.

## Non-Example: Three Worktrees Is Not Three Parents

Prompt:

```text
Spin up three separate worktrees and delegate one agent to each.
```

Expected result:

- One Coordinator parent, because the user sent one directive to one Coordinator.
- Three delegated children, each possibly backed by a distinct worktree.
- Multiple parents only appear when the user explicitly creates or selects separate Coordinator conversations, such as with `New Coordinator`.
