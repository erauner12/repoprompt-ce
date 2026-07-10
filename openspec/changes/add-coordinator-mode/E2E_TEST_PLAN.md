# Director / Coordinator Mission Runtime — Live E2E Test Plan

This plan validates the current core Coordinator Mission runtime at the external first-consumer boundary. Scenarios assert Mission state, ledgers, events, side effects, receipts, and lifecycle cleanup; they do not assert model prose except for explicit deterministic scripted-child markers.

## Principles

- Test invariants, not transcripts.
- Use `coordinator_chat` as the primary driver and observation surface.
- Use compact `mission_status` and `wait_for_update` as the synchronization contract.
- Prefer deterministic substrate: trivial marker-file tasks, explicit Mission shape, scripted child where childAsk mechanics are under test.
- Every scenario ends with terminal/lifecycle assertions and a receipt-ready summary when terminal.
- Every run records doctor capabilities, status/event history, invariant failures, timings, Coordinator model/tier, child backend, and artifact paths.

## Required capabilities

Before scenario execution, run `coordinator_chat op="doctor"` and record:

- supported `coordinator_chat` ops;
- `mission_events` support;
- receipt Markdown support;
- `set_pace` / `set_autonomy` support;
- structured child input availability;
- scripted child availability;
- lifecycle ops (`list_missions`, `archive_mission`);
- runtime gates for external-only user actions and archive.

When `--doctor-mode required` is enabled, missing required capabilities fail before scenario work starts.

## Sandbox substrate

Use a throwaway workspace root/repository for side-effect assertions. Scenario tasks should create or inspect trivial marker files so correctness can be verified mechanically. Reset the sandbox before each attempt and assert expected cleanliness based on policy:

- Read-only scenarios must leave all roots clean.
- Fresh-worktree mutable scenarios must keep the canonical root clean until an explicit landing step is in scope.
- No scenario pushes, opens a PR, or mutates remote state.

## Scenario plateau

### S1 — Read-only investigation

**Purpose:** Prove read-only Mission execution can delegate investigation and close with evidence without repository changes.

**Setup:** Read-only policy or equivalent Mission Plan, Auto pace acceptable.

**Expected invariants:**

- Mission Plan records concrete read-only work.
- At least one read-only child/probe route is recorded when the Mission delegates.
- Done nodes carry evidence.
- Decision/evidence counts are reflected in `mission_status`.
- Receipt is terminal and retrievable.
- Sandbox has zero diffs.
- Queue/Needs-you count remains zero unless the model explicitly asks a user question.

### S2 — Parallel fan-out and convergence

**Purpose:** Prove DAG-lite dependencies, parallel running nodes, cap discipline, and auto-pickup of newly ready work.

**Directive shape:** Two independent child tasks create `A.md` and `B.md` in their own worktrees. A third dependent task verifies both and writes or reports `SUMMARY.md` according to the scenario variant.

**Expected invariants:**

- A poll/event shows two independent nodes running simultaneously when cap permits.
- Running node count never exceeds policy `maxConcurrent`.
- Dependent node has `deps_satisfied:false` until both parents complete.
- Dependent node enters `ready_node_ids` exactly after dependencies complete.
- Auto follow-through picks up eligible work without user input when policy permits.
- `mission_events` or compact status history records ready → running → completed transition order.
- Artifacts are found in the expected worktree/canonical locations for the variant.
- Terminal receipt summarizes decisions/evidence.

### S3 — Cap discipline watcher

**Purpose:** Continuous invariant rather than a default standalone scenario.

**Expected invariant:** Every status wake in every scenario asserts running Mission node count is less than or equal to policy `maxConcurrent`. Add a standalone S3 only if a cap-specific regression needs focused reproduction.

### S4 — Step pace and checkpoint revision identity

**Purpose:** Prove approval checkpoint instance IDs are revision-bound, approval is atomic before runtime resume, and non-user approval doors are rejected.

**Expected invariants:**

- Awaiting-approval compact status exposes `checkpoint_instance_id`.
- Approval-granting Proceed without `expected_checkpoint_instance_id` rejects and records no user decision.
- A plan revision while still awaiting approval changes the instance ID.
- Stale approval-granting Proceed using the old expected ID rejects and records no user decision.
- A SwiftUI/rendered-button equivalent using a stale rendered ID rejects the same way as the external MCP path.
- A Coordinator runtime caller attempting checkpoint action/Proceed as user rejects as impersonation.
- Generic `mission_plan` self-approval (`approval_state:"approved"`) rejects or preserves the prior non-approved state.
- Generic runtime creation or transition to `approval_state:"not_required"` rejects; legacy decoded `not_required` is non-authorizing and cannot delegate.
- Current Proceed accepts only when its expected ID matches the current checkpoint, records one user plan-approval decision for that instance, transitions the plan to `approved`, and only then allows runtime resume/delegation.
- Live harness target: when Proceed is accepted while the Director revision turn is still active, `mission_status` exposes a durable `post_approval_continuation` with stable continuation/checkpoint/plan identity as deferred, then delivered with `attempts=1`, `last_error:null`, no duplicate delivered transition, and no second external `submit` once the next ordinary turn boundary arrives.
- Stale Stop remains accepted because it withdraws approval.

### S5 — childAsk Me and Director parity

**Purpose:** Prove Mission-bound child questions route through user or Director according to `childAsk` autonomy and record honest actors.

**Child prompt:** The Coordinator must tell the child to ask a structured user-input question with two marker options and then report the selected marker. For deterministic runs, use `--child-model-id scripted` and the exact line:

```text
SCRIPTED_CHILD_V1 ask_marker token=<TOKEN> options=Alpha,Beta
```

**Ask / Me branch invariants:**

- `set_autonomy childAsk ask` or equivalent policy routes child question to user.
- Pending child question becomes visible and queue/Needs-you reflects it.
- External `coordinator_chat submit` answers the child through the `child_interaction` path.
- A user childAsk decision/evidence chain is recorded.
- No Director answer is recorded for that interaction.
- Scripted child completes with `SCRIPTED_CHILD_V1 answer=Alpha token=<TOKEN>` when Alpha is submitted.

**Auto / Director branch invariants:**

- `set_autonomy childAsk auto` or equivalent policy routes child question to Director.
- User-facing pending child question does not remain visible.
- Runtime answer records a Director `childAsk` decision and evidence for the same interaction.
- Exactly one answer lands for the interaction.
- Receipt reads the actor chain honestly.

**Capability classification:** If a live child backend reports structured input unavailable, classify as model/backend capability gap unless doctor indicated structured input was advertised and the runtime still failed.

### S6 — Dial flip semantics

**Purpose:** Prove pace and childAsk dials mutate Mission-owned policy/autonomy through user-action parity without consuming unrelated checkpoints.

**Pace slice invariants:**

- Start at Step with approval pending.
- `coordinator_chat set_pace pace=auto` mutates policy/default pace, bumps revision/fingerprint, and records a user `set pace to Auto` decision.
- The pending plan approval checkpoint remains pending; the dial does not consume it.

**Ask → Auto childAsk slice invariants:**

- Start with a real pending child question under Ask.
- `set_autonomy childAsk auto` records a user route-to-Director decision.
- The same interaction is answered by Director.
- The route decision precedes the Director childAsk decision.
- Exactly one childAsk answer/evidence pair lands.

**Auto → Ask childAsk slice invariants:**

- Start with hidden/auto-routed pending child question.
- Flip to Ask.
- The same interaction becomes user-visible.
- User answer completes the child through `coordinator_chat submit`.
- No Director childAsk decision is recorded for that interaction after the flip.
- Runtime child-interaction submits are rejected while resolved `childAsk` is Ask.

### S7 — Stop honesty

**Purpose:** Prove stop is a terminal user action that cancels active work without treating the Mission as failed or deleting audit state.

**Expected invariants:**

- Stop records a user irreversible/stop decision.
- Active linked child sessions receive cancel routing decisions.
- Active/blocked/bound nodes become cancelled as appropriate.
- Mission status is `stopped`, not failed.
- No running/ready work and no pending Decisions row remain.
- Terminal receipt is available through `receipt format=markdown`.
- Archive remains separate from stop.

### S8 — Restart durability (deferred)

**Purpose:** Future scenario for relaunch with pending plan approval, pending child question, or pending/deferred/dispatching post-approval continuation.

**Required future invariants:** Mission reconstructs from durable state; pending asks and deferred continuation records remain pending/deferred without being consumed; queue item identity does not duplicate or disappear; completed/stopped receipts remain available.

### Future bounded preauthorization — unattended Mission starts (deferred)

**Purpose:** Future scenario family, not part of the current demo plateau. Revisit unattended starts only after a bounded, user-approved Mission charter is expressible and enforceable.

**Future shape:** A start contract such as `initialPlanReview: required | preauthorized(policyGrantID)` with a versioned user grant. The app must validate the generated concrete Mission Plan against that grant before delegation.

**Required future invariants:** scoped tools, budgets, write authority, evidence duties, stop conditions, receipt provenance, and generated-plan validation are enforced by the app; irreversible approvals still resolve to Ask.

### S9 — Recovery / chaos (deferred)

**Purpose:** Future scenario for missing artifacts, stuck children, or cancelled/killed child runs.

**Required future invariants:** Coordinator detects the gap from evidence/status, prefers steer-not-respawn when appropriate, records recovery routing/evidence, and closes or asks without silently stalling.

## Shared invariant watcher

On every compact-status wake or mission event batch, validate:

- running node count ≤ `maxConcurrent`;
- node status monotonicity for terminal states;
- dependency satisfaction matches completed dependencies;
- `ready_node_ids` equals pending nodes whose dependencies are completed;
- childAsk:auto completed interaction nodes have decision and evidence for the interaction;
- running delegated nodes have bound sessions;
- `eligible_nodes_idle` is recorded as telemetry when approved ready work exists and the Coordinator is idle;
- terminal completed Missions have only terminal nodes;
- decision actor integrity: user decisions only from app/external paths, Director decisions only from runtime ledger writes;
- compact fingerprint advances after decision/evidence/policy/autonomy/node/status changes.

## Tooling and lifecycle cleanup

- Use `mission_events since_seq` when available; otherwise derive status history from `mission_status` fingerprints.
- Use `receipt format=markdown` when terminal receipt is required.
- Use `list_missions` before and after runs to inventory live/archived Missions.
- With `--archive-on-success`, archive only after a successful terminal run, then re-check status, events, receipt, decisions, evidence, and lineage by Mission ID.
- Failed attempts remain unarchived unless a cleanup run explicitly stops/archives them.
- `archive_mission` must reject runtime callers and non-terminal Missions.

## Run bundles

Each attempt writes a bundle containing at least:

- doctor/features JSON;
- scenario config, Coordinator model/tier, child model/backend, random tokens, and sandbox root;
- compact status history JSONL;
- mission events JSONL when available;
- invariant violation report;
- receipt Markdown or receipt-ready summary;
- mission inventory before/after cleanup;
- sandbox git/filesystem snapshots;
- timing metrics: time to plan, approval, first child start, fan-out, convergence, completion, receipt, archive;
- screenshots only for optional UI/presentation tiers.

## Pass-rate batches

- Repeated batches are diagnostics, not demos.
- Pre-register repeat count, scenario, Coordinator model/tier, child backend, doctor/events/receipt/archive modes, and timeout policy.
- Every counted attempt stays in the denominator.
- If a plumbing or harness defect requires a code fix, invalidate and restart the affected batch after the fix.
- Model-negotiation, environment, and soak failures remain counted because they measure the selected tier/environment.
- Cheap regression-tier pass rates are not comparable to default Coordinator-tier pass rates.
- Prompt/directive changes require default-tier validation before being treated as presentable.

## Scenario governance

Add a new live scenario only when `DIRECTOR_DECISIONS.md` pins new doctrine. Ordinary regressions should receive the lowest faithful deterministic coverage first, then join a live scenario only if they define a new runtime contract boundary.
