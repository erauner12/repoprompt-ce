# Director Mode — Standing Decision Record

Recreated 2026-07-06 after the untracked `docs/plans/mock-parity-2026-07-05.md` and
`docs/plans/coordinator-mock-overhaul-2026-07-06.md` were lost to a worktree recreation
(they were gitignored). **This file is tracked on purpose.** Durable decisions live here;
ephemeral run charters may stay in `docs/plans/` but must cite this record.

## 1. Fidelity principles (LOCKED)
- **Mock for structure, Agent Mode for temperature.** The HTML mock
  (`reference/RepoPrompt_Command_Center.html`) is authoritative for layout, anatomy, copy,
  and interaction. Agent Mode is authoritative for palette, chip severity, and accent
  economy. `CoordinatorTheme` anchors to system materials; color is reserved for semantic
  state (amber = needs-you, red = genuine failure, green = done, blue = running/live);
  metadata chips are neutral; card kickers are neutral label + status dot.
- **Layout contract (four states).** Draft = rail + full-width center draft surface +
  composer, no right pane. Mission-without-plan = rail + conversation, no right pane
  (no-plan strip lives inside the conversation). Mission-with-plan = rail + conversation +
  Mission Plan pane (header: title + status + collapse; no segmented pickers). Board =
  rail + full-width center board, no composer, no right pane. Any deviation is a spec
  change, not an implementation choice.
- Plan-node clicks never open the inspector (highlight only; info lives on the card).
  The inspector remains exclusively for Agent Board rows.

## 2. Deliberate divergences from the mock (each needs a future mock-sync pass)
- Header `Stop / Clear` removed — composer stop is canonical; Clear conflicts with
  ledger-is-history doctrine.
- Neutral palette / chip discipline (see §1) supersedes the mock's colorful chips, which
  were legibility scaffolding in an HTML artifact.
- Composer `Permissions` chip removed from the Director surface (see §3) — in the mock it
  was ported theater from Agent Mode with no defined Director behavior.

## 3. Policy ownership model (LOCKED 2026-07-06)
- **One picker: the draft-surface policy grid.** The composer policy popover
  (`CoordinatorMissionPolicyPopoverView` behind the "Permissions" chip) duplicated the
  picker with internal ask-class vocabulary and a colliding name; it is removed from the
  Director composer.
- **Lifecycle:** policy library (named definitions; built-ins now, "Edit a copy" CRUD
  deferred) → draft-time selection on the grid → captured at send as provider-only
  metadata → runtime records `policy_snapshot` on the Mission Plan → **the mission owns
  its snapshot**, decoupled from the library thereafter → mid-mission adjustments are the
  dials only (pace; `Me|Director` childAsk when it lands) through the app-owned
  `missionPlanUpdater` seam — never a re-pick, never a re-send.
- **Mission Templates are orthogonal.** Policy = "how much stops for you" (never shape);
  Template = "what kind of work" (never trust). The one coupling: a template MAY carry a
  *recommended* policy pointer that pre-selects the grid but never locks it. `▸ Try:`
  chips are inline templates and the reference pattern:
  `MissionTemplate = { directive text, optional recommended-policy ref, optional shape hint }`.
- **Vocabulary:** "Permissions" is reserved for run-level permissions (the Agent Mode
  concept). Director says "Mission Policy" exclusively. A per-mission run-permission
  preset for delegated children is a recorded deferral, not a feature.
- **Policy library roadmap (LOCKED 2026-07-06 — custom policies: yes, staged).**
  *Why:* a policy is a named, reusable trust envelope — the encoding of earned trust for a
  recurring kind of mission (mission-is-the-unit: recurring kinds → recurring envelopes;
  the name survives into ledger and receipt as the one-word trust story).
  *Stage 0 (done):* four built-ins + snapshot-at-draft + single picker.
  *Stage 1 (scheduled):* the two dials (pace; `Me|Director` via `missionPlanUpdater`) —
  per-mission adjustment without library writes.
  *Stage 2 (custom policies):* primary affordance is **"Save as policy"** from a mission's
  captured snapshot (policies are born from lived missions, not blank forms); secondary is
  "Edit a copy" from a built-in. Both open one minimal editor: name · pace · per-class
  ask/auto in human display names (F3 vocabulary rule applies) · cap · guidance. Storage
  mirrors `CoordinatorMissionTemplateStore`; customs join the grid; built-ins immutable;
  snapshot doctrine already guarantees library edits never touch running missions.
  *Never build:* policy-per-node (the envelope is mission-scoped), per-repo auto-selection
  rules, sharing/marketplace. Templates compose via the recommended-policy pointer only.
  *Timing:* behind the screenshot parity pass + demo; ~two focused runs (store/model,
  then editor UI).
- **Autonomy control model — three layers (LOCKED 2026-07-06).** The levers differ in
  scope and must look like it:
  *Layer 1 — Policy (noun, picked once):* the named stance chosen on the draft grid;
  rendered everywhere as the name.
  *Layer 2 — Dials (standing adjustments, exactly two):* pace (`Step|Auto`) and
  `Me|Director` (childAsk). Dials write **mission-level overrides onto the snapshot** via
  `missionPlanUpdater` — never mutate the library policy, never re-send metadata. When a
  dial diverges from the named policy, the name must say so: echo becomes
  **"Policy · Default · edited (pace → Auto)"** — a preset name may never lie. ("Save as
  policy" attaches here in Stage 2.) Application semantics, one rule stated in UI help and
  here: **dial changes apply from the next boundary; a pending checkpoint is never
  consumed** (toggles configure, buttons act). Every mid-run dial change posts a ledger
  line ("You set pace → Auto for this mission") so scope is self-evident and audited.
  Current-code gap (recon 2026-07-06): pace exists *only* inside the policy snapshot — no
  composer pace variable, no mission-level override channel; the dial must gain the
  override path rather than binding to the preset's field.
  *Layer 3 — Moment buttons (one-time acts):* checkpoint triad, gate approval, overrule —
  always act once, never configure. Visual grammar: dials are segmented toggles, moment
  acts are buttons; the two never share styling.
  *Legibility rule:* the contract shows where it bites — at boundaries/strip, derive a
  dynamic preview from the autonomy map × the ready set ("Auto continues: launch 2 ready
  steps · Stops for: merge (irreversible)"). *Trust loop:* the wrap-up stat card may
  suggest encoding ("Decided itself 7×, no overrules — save these settings as a policy /
  try Hands-off for missions like this").

## 4. Decisions queue doctrine + identity (LOCKED)
- The queue contains **asks — things waiting on the user — only**: pending child
  interactions, pending checkpoints, held boundaries. Blocked nodes/sessions are never
  queue items unless they carry a pending interaction; scheduler stalls are
  `liveness_warnings` telemetry, never queue entries.
- Identity: child interaction → its own UUID; checkpoint → deterministic UUID from
  `(missionID, checkpointKind, planRevision)` via `CoordinatorMissionStableIdentity`
  (a re-approval after revision is a NEW item by construction); held boundary →
  `(missionID, "held-checkpoint", planRevision)`.
- Ordering: **oldest-first FIFO, no urgency tiers** (attention ranking is the user's
  judgment; the queue is honest, not clever). Badge = pending count, never ledger size,
  never telemetry.

## 5. W1/W2 content-review gate — PASSED (2026-07-06 @ a131f2dc)
Resume-directive eligibility instruction present and test-asserted; flight cap counts
**running nodes** (`denyFlightCapReached`, default 3) uniformly across run/explore starts
including pre-approval probes; compact `mission_status` carries per-node `deps_satisfied`
+ top-level `ready_node_ids`; the compact fingerprint carries both **explicitly**
(edge-only revisions advance `wait_for_update`); `eligible_nodes_idle` documents its
transient-fire window as telemetry. The `running N/cap` chip reads
`MissionPlanReadinessProjection.runningNodeCount` — UI and scheduler agree on the node as
the unit. Follow-up (non-blocking): the ready-set rule exists twice (view projection +
MCP helper); extract a shared `CoordinatorMissionPlanScheduling` helper when either is
next touched.

## 6. Open deferrals (recorded, not holes)
- Custom policy CRUD — designed and staged; see §3 "Policy library roadmap" ("Save as
  policy" primary, "Edit a copy" secondary, minimal editor, post-parity timing).
- Per-class autonomy menu; `Me|Director` dial ships via the `missionPlanUpdater` seam.
- Policy snapshot **drift guard** (compare sent policy vs runtime-recorded snapshot on
  first publish; pure projection).
- Probe loop-iteration transcript beats (runtime contract addition).
- Child-question suggested-answer contract.
- Per-mission run-permission preset for delegated children.
- Soft dependency edges, node priority, mission backlog tiers, `failed` node status
  (decode-compat), `CoordinatorMissionRoutingOperation` closed-enum forward-compat
  strategy before any new operation is added.
