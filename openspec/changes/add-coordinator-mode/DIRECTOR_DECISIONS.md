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
  _recommended_ policy pointer that pre-selects the grid but never locks it. `▸ Try:`
  chips are inline templates and the reference pattern:
  `MissionTemplate = { directive text, optional recommended-policy ref, optional shape hint }`.
- **Vocabulary:** "Permissions" is reserved for run-level permissions (the Agent Mode
  concept). Director says "Mission Policy" exclusively. A per-mission run-permission
  preset for delegated children is a recorded deferral, not a feature.
- **Policy library roadmap (LOCKED 2026-07-06 — custom policies: yes, staged).**
  _Why:_ a policy is a named, reusable trust envelope — the encoding of earned trust for a
  recurring kind of mission (mission-is-the-unit: recurring kinds → recurring envelopes;
  the name survives into ledger and receipt as the one-word trust story).
  _Stage 0 (done):_ four built-ins + snapshot-at-draft + single picker.
  _Stage 1 (scheduled):_ the two dials (pace; `Me|Director` via `missionPlanUpdater`) —
  per-mission adjustment without library writes.
  _Stage 2 (custom policies):_ primary affordance is **"Save as policy"** from a mission's
  captured snapshot (policies are born from lived missions, not blank forms); secondary is
  "Edit a copy" from a built-in. Both open one minimal editor: name · pace · per-class
  ask/auto in human display names (F3 vocabulary rule applies) · cap · guidance. Storage
  mirrors `CoordinatorMissionTemplateStore`; customs join the grid; built-ins immutable;
  snapshot doctrine already guarantees library edits never touch running missions.
  _Never build:_ policy-per-node (the envelope is mission-scoped), per-repo auto-selection
  rules, sharing/marketplace. Templates compose via the recommended-policy pointer only.
  _Timing:_ behind the screenshot parity pass + demo; ~two focused runs (store/model,
  then editor UI).
- **Autonomy control model — three layers (LOCKED 2026-07-06).** The levers differ in
  scope and must look like it:
  _Layer 1 — Policy (noun, picked once):_ the named stance chosen on the draft grid;
  rendered everywhere as the name.
  _Layer 2 — Dials (standing adjustments, exactly two):_ pace (`Step|Auto`) and
  `Me|Director` (childAsk). Dials write **mission-level overrides onto the snapshot** via
  `missionPlanUpdater` — never mutate the library policy, never re-send metadata. When a
  dial diverges from the named policy, the name must say so: echo becomes
  **"Policy · Default · edited (pace → Auto)"** — a preset name may never lie. ("Save as
  policy" attaches here in Stage 2.) Application semantics: pace changes configure the
  next step boundary and never consume a pending checkpoint; `Me|Director` childAsk changes
  are route changes with the asymmetric pending-question semantics in §3c. Every mid-run
  dial change posts a ledger line ("You set pace → Auto for this mission") so scope is
  self-evident and audited.
  Current-code gap (recon 2026-07-06): pace exists _only_ inside the policy snapshot — no
  composer pace variable, no mission-level override channel; the dial must gain the
  override path rather than binding to the preset's field.
  _Layer 3 — Moment buttons (one-time acts):_ checkpoint triad, gate approval, overrule —
  always act once, never configure. Visual grammar: dials are segmented toggles, moment
  acts are buttons; the two never share styling.
  _Legibility rule:_ the contract shows where it bites — at boundaries/strip, derive a
  dynamic preview from the autonomy map × the ready set ("Auto continues: launch 2 ready
  steps · Stops for: merge (irreversible)"). _Trust loop:_ the wrap-up stat card may
  suggest encoding ("Decided itself 7×, no overrules — save these settings as a policy /
  try Hands-off for missions like this").

## 3a. CHARTER — Dial override channel (dispatch-ready; explicit; supersedes nothing)

**Intent: the `Step|Auto` dial is KEPT, exactly as prominent and dynamic as today. This
charter gives it (and `Me|Director`) a real data path. Do not remove, relocate, or
de-emphasize either dial. Any instruction that reads otherwise is a misreading.**

1. **Composer state.** Add `missionPaceSelection` (and `childAskSelection`) to the
   composer VM. Initialize: draft → from the selected grid policy
   (`defaultPace` / `autonomy[childAsk-key]`); mission selected → from
   `plan.policySnapshot`. **[verify]** the exact childAsk autonomy-class key string used
   by the runtime; use it verbatim.
2. **Draft capture honesty.** `policyProviderLines` (VM ~406) must read the **effective**
   values — `Default pace:` from the dial selection, `Autonomy:` childAsk from the dial —
   not the raw policy fields. What the runtime records as `policy_snapshot` therefore
   equals what the user configured at send.
3. **Mid-run write path.** Dial change on a mission with a recorded plan →
   `missionPlanUpdater` mutation setting `policySnapshot.defaultPace`
   (resp. `autonomy[childAsk-key]`), with revision bump — **and a user-actor decision
   record** with fixed labels: "set pace to Auto" / "set pace to Step" /
   "routed child questions to Me" / "routed child questions to the Director". Wave 2.5's
   ledger→transcript projection then renders the audit echo automatically; build nothing
   extra for display.
4. **Semantics guardrails.** A pace dial change never consumes a pending checkpoint
   (held-checkpoint invariant — add the test if absent). It sends no steer and no
   metadata; the runtime picks it up at the next boundary via `mission_status`
   (fingerprint moves on mutation). `Me|Director` childAsk changes follow §3c because child
   questions are their own standing route, not the generic step checkpoint. **[verify]**
   `defaultPace` participates in the compact policy fingerprint part; if absent, add it
   (one line + one test).
5. **`edited` honesty marker.** Pure computed comparison of the snapshot's
   {pace, childAsk} against the library policy bearing `policySnapshot.id`. When they
   differ: composer echo and plan-pane policy chip render
   **"Policy · {name} · edited"** (tooltip lists the diffs, e.g. "pace → Auto"). No stored
   flag; built-ins are the comparison base today, custom policies by the same id lookup
   later. This is Stage 2's future "Save as policy" attachment point — do not build that
   button now.
6. **Prompt check.** Confirm `AgentModePrompts` states the policy snapshot may change
   mid-mission and is re-read at each boundary; add one sentence if absent. No MCP
   protocol changes in this charter.
7. **Tests.** (a) draft: dial flip → provider metadata carries effective pace/childAsk;
   (b) mid-run: dial flip → snapshot mutated, revision + compact fingerprint advance,
   user-actor decision recorded with the exact fixed label; (c) a pending checkpoint
   survives a dial flip; (d) `edited` true/false matrix incl. flip-back-to-preset →
   marker clears; (e) childAsk key round-trips through mission_status.
8. **Out of scope.** Per-class autonomy menu, custom policy CRUD, a cap dial, any
   checkpoint-anatomy changes, the boundary contract-preview, the wrap-up suggestion
   (those are separate items in §3).

## 3b. Autonomy extensibility (LOCKED 2026-07-06): the map is the mechanism

The autonomy map (`class → ask|auto`, unknown resolves to Ask) **is** the extensible
mechanism — new classes are one key + one prompt sentence + policy updates, with zero
schema risk. No generalized per-class control surface is built. **Graduation rule:** a
new class enters ask-by-default with a human display name and joins the policy
definitions; it earns a dial only if real usage shows it is flexed mid-mission (dial
count discipline: two today, three ever, absent strong evidence). **One structural
investment (opportunistic, cheap):** an `AutonomyClass` registry — key, display name,
one-line human description, default — centralizing vocabulary now scattered across
prompts, policies, and ask-summary strings; it feeds grid copy, echo lines, the Stage 2
editor, and the future boundary contract-preview. The general editing surface remains
Stage 2's minimal editor, reached via "Save as policy" — from lived experience, never
speculation.

## 3c. Pending childAsk flip semantics (LOCKED 2026-07-07)

`Me|Director` is a standing route for child questions, including one already pending.
**Ask → Auto is immediate reroute:** the external dial flip is the consent record; after
the user-actor "routed child questions to the Director" decision is written, the runtime
may suppress that pending child question from the user queue, answer it as Director, and
record a Director `childAsk` decision plus evidence for the same interaction id.
**Auto → Ask is asymmetric escalation:** if the user flips back to Me while a Director
answer is not yet committed, the pending question must become visible and a later runtime
answer is rejected. Escalation to the human wins races.

S6 invariants: interaction id is stable across the flip; the dial-change user decision
precedes any Director childAsk decision; exactly one answer lands; losing user/Director
race attempts reject loudly; receipts must read the actor chain honestly ("user flipped,
then X answered"). `set_pace` / `set_autonomy` are external-user parity ops only:
coordinator-runtime callers are blocked at execution, not merely hidden by advertisement.
The `auto→ask` race is guarded at submit time, not by prompt wording: the child-interaction
submit path re-resolves current `childAsk`, so a stale Director/runtime answer after the
Me flip is rejected instead of being ledgered. The scripted S6 slice exercises the
observable half of that contract by proving the hidden auto-routed interaction reappears
for the user and completes with a user childAsk decision and no Director answer.

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

- top-level `ready_node_ids`; the compact fingerprint carries both **explicitly**
  (edge-only revisions advance `wait_for_update`); `eligible_nodes_idle` documents its
  transient-fire window as telemetry. The `running N/cap` chip reads
  `MissionPlanReadinessProjection.runningNodeCount` — UI and scheduler agree on the node as
  the unit. Follow-up (non-blocking): the ready-set rule exists twice (view projection +
  MCP helper); extract a shared `CoordinatorMissionPlanScheduling` helper when either is
  next touched.

## 6. Calm Law + K-pass charter (LOCKED 2026-07-06) — attention hierarchy as layout

**The law (the queue doctrine applied to pixels): show what needs you; summarize what is
running; collapse what is done.** The screen is an attention queue — one loud thing
maximum, ambient state quiet, history folded. Diagnosis from live screenshots: identical
facts render 3–5× per screen; every entry is a bordered card; plan events spam the
transcript; raw session IDs wear chips; two composers coexist on completed missions.

**Principles:**

1. **One home per fact.** If a fact renders twice on one screen, one instance is wrong.
   Canonical homes: plan structure/objective → right pane only (the in-conversation plan
   card becomes a one-line reference: "Mission Plan · r7 → view"); policy/pace/cap →
   strip only; counts → strip rollup only. The receipt keeps its archival copy but
   renders collapsed (stat line + expand).
2. **Attention tiers.** Tier 1 (loud, max ONE): the active checkpoint/question — siblings
   dim while one exists. Tier 2 (ambient): strip rollup + running node lines. Tier 3
   (collapsed by default): completed parts fold to one line ("Part 1 · done · 1 ✓",
   expandable); done nodes drop their chips; the receipt folds to its stat line.
3. **Prose over cards.** Director prose renders unboxed (Agent Mode's grammar). Cards are
   reserved for: checkpoints, one per delegated session (updating **in place** — its
   status line absorbs bound/completed events), evidence verdicts, the receipt.
   **Event coalescing:** Plan Session-bound / Node-completed / Revised rows collapse into
   the session card's status or a single "Plan updated · r6→r7" line.
4. **Chip budget: ≤2 per row, semantic-state only, never raw IDs** (session identity is a
   link, not a chip; fix the duplicated "Read-only child ×2" rendering). Done-state rows
   carry zero chips.
5. **One composer at a time.** The plan-revision composer exists only when the pane is
   open AND the mission is active; completed missions show a single "Start a follow-up
   Mission…" composer and nothing else. **Completed is the calmest state**: wrap-up card
   - collapsed receipt + a "transcript" disclosure — a finished mission must look
     _quieter_ than a running one.

**K-pass (staged, each its own small run):** K1 deduplicate (plan reference card, strip
ownership, delete the mission-context card — its facts live in strip + grounding,
collapse receipt); K2 coalesce events + in-place session cards; K3 chip budget + ID
removal; K4 tiering/collapse + unboxed prose + checkpoint dimming; K5 composer
exclusivity + completed-state calm. **Acceptance:** the count test — the current
completed-mission screenshot's facts in ≤⅓ the visual elements — plus the squint rule
above. **K6 (runtime UX note):** the generic fallback approval plan that precedes the
first real decomposition should render as a "Drafting the plan…" state, not a full plan
card that gets replaced — suppress the plan card until the first substantive revision.

**K1 — ACCEPTED (2026-07-06, live-verified).** Completed-mission center = summary +
folded transcript; terminal status wins over stale approval; mission-context card gone.
Residual carried into K3: the plan pane duplicates itself (pane header vs. inner card
both render "Mission Plan"/status; policy renders twice within one block) — fold so the
pane header row IS the strip and the inner card loses its duplicate header/chips.

**K3 — EXPANDED: the Signal Shape System (supersedes "chip budget"; user-derived).**
Uniform shape flattens the signal hierarchy: when every fact is a capsule, no capsule
can claim attention. Encode information class in form —
_State_ (mission/node status, needs-you): the ONLY filled capsules; max one per row.
_Counts_ (`2/2 done`, `running 0/3`): plain text — numbers self-signal.
_Metadata_ (policy · edited · pace · cap · workflow · role): one muted interpunct text
line, no borders (e.g. `Default · edited · auto · cap 3`).
_Identity_ (sessions, nodes): text links, never chips; no raw ID fragments anywhere;
fix the duplicated "Read-only child ×2" rendering.
Rule: **a capsule is a claim on attention** — scarcity is the feature; the amber
`needs you` pill must be visually alone in its class. Applies to strip, part headers,
node rows, transcript cards, and receipt alike.

**K7 — Inspector eviction (NEW, per user review).** The inspector never renders inside
the Mission Plan pane. A plan node's bound session is a **link** (one tap → Open Agent);
the inspector exists only alongside the Board (its H4 home), and receives the calm
anatomy (no key-value debug rows) in a later polish pass.

**Focus order:** K3(expanded) → K7 → K2 → K4 → K5.

**K3/K7 — ACCEPTED (2026-07-06, live-verified).** Signal Shape System formalized as a
typed mapping in `CoordinatorMissionPresentationPolicy` (`SignalFactClass → SignalShape`);
mission-pane inspector evicted; Board inspector collapses to a side rail. Carried flag →
**K7b:** the Board inspector's _inner_ anatomy is still key-value debug rows; give it the
calm treatment in a later pass.

**K8 — State-conditional calm (from the 2026-07-06 computer-use audit): controls and
emphasis must respond to mission state.** Extend `CoordinatorMissionPresentationPolicy`
with pure, tested functions (`composerMode(for:)`, `paneEmphasis(for:)`,
`boardColumnEmphasis(for:)`, `railRowSignal(for:)`):

- **K8a — Terminal composer.** Completed/stopped missions never show the full composer
  (dials, policy echo, stop are live-mission controls and contradict finality). Replace
  with ONE quiet action — "Start a follow-up Mission →" — which reveals the full composer
  only on explicit intent. **Absorbs K5.**
- **K8b — Right-pane emphasis.** Exactly one status capsule, in the pane header. Plan
  body neutral; evidence on Done nodes collapses to an expandable "Evidence ✓" line;
  green exists only as the state capsule, never as tinted text blocks.
- **K8c — Board de-rainbow.** Columns become neutral containers; color lives only in the
  header dot + count. Empty columns dim (reduced opacity, header retained) but keep their
  positions — no layout jumping.
- **K8d — Rail signal.** Terminal mission rows use muted-text status, no filled capsule;
  rail capsules are reserved for live / needs-you rows so current work is visually
  distinct from history by form, not just position.

**Audit finding #4 (policy grid before intent) — DEFERRED.** It would reverse the
accepted, mock-locked C3 draft surface, whose grid is the demo's teaching surface ("your
words choose the shape; policy chooses stops"). Captured kernel for later: _progressive
familiarity_ — after the user's first few missions, the grid may default-collapse to the
summary row with the four-card chooser on demand. Revisit post-demo.

**Focus order (updated):** K8 → K2 (event coalescing — matters for _running_ missions,
which K1's completed-state folding doesn't touch) → K4 remainder (unboxed Director prose,
checkpoint dimming) → K7b (calm inspector anatomy).

**K8 — ACCEPTED (2026-07-06, live-verified).** Terminal follow-up action, single pane
capsule, folded evidence, neutral board columns, muted rail history — all landed with
presentation-policy tests.

**K9 — Demo-polish run (bang-for-buck ranking toward the demo video):**

1. **K2 executes now** — the running transcript is where demo eyes live; four stacked
   Plan event rows per worker completion fold into the in-place session card + one
   "Plan updated · rN→rM" line.
2. **Narration vocabulary (bundle with K2):** the runtime's own prose is the last
   internals leak ("Policy snapshot is Auto with childAsk auto…"). One `AgentModePrompts`
   sentence: narrate in human terms, never autonomy class keys. Also tuck `r7` revision
   jargon into metadata form.
3. **K4-lite:** unbox Director prose (Agent Mode's grammar).
4. **Stage the demo mission:** the parallel fan-out story (two independent chains →
   converging review; `running 2/3`; `Waiting on A ✓ · B …` ticking; auto-pickup on the
   second parent; evidence; receipt) — W1's on-camera moment. One dry run doubles as the
   outstanding seven-state screenshot pass; record after.

## 7. Open deferrals (recorded, not holes)

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

## 13. Task-queuing article audit — CLOSED (2026-07-07, code-verified)

The founding gap analysis is resolved: DAG scheduling/auto-pickup (W1, S2 live-proof),
attention queue (Decisions, H3.1), idle telemetry (`eligible_nodes_idle`, adopted as the
harness's failure oracle), conflict safety (worktree isolation + proven steer-not-respawn
recovery, beyond the article), contract + receipts. Deferrals stand: priority (FIFO
doctrine), backlog tiers (`mission_key` hook; Light Missions absorb quick capture),
soft edges. **Remaining gap: Spend.** Receipt reserve exists
(`CoordinatorMissionReceiptProjection.spendReserveCopy`, test-asserted, shape frozen);
`Runtime/Usage` holds context estimators only. **Spend v1 wave:** [verify] whether
per-session cumulative usage is captured today → if yes, pure projection summing
mission-owned sessions into the reserved slot (+ optional strip figure); if no, capture
then project. Budget enforcement stays behind visibility and arrives later as a `spend`
autonomy class via §3b's graduation rule. E2E: extend a scenario to assert receipt
spend present once v1 lands.

## 14. feature scan (2026-07-07) — adopt / have / skip

**Validation:** converged on the doctrine —
"everything not in the queue is already moving" (= queue never lies), "earned autonomy"
(= trust model), "missions, not sessions" (= survives-the-worker). We have it shipped.
**ADOPT:**

- **A. Mission Pins** (their Context Pins): user-attached files/notes per mission,
  riding every delegation charter + judge bundle via the existing bounded-exhibit
  machinery (`forkFileContentsBlock`) — additive plan field + composer/pane affordance.
  Kills the re-explaining tax; the Context Contract already designed the transport.
- **B. Receipt-grounded follow-ups** (their "reopen with full context" / pragmatic
  Cross-Mission Memory v1): a follow-up mission auto-pins its predecessor's receipt.
  Composes three existing pieces — predecessor links + receipt projection + pins (A).
  Full cross-mission memory (receipts corpus grounding `director ask`) stays the §12
  post-v1 bet.
- **C. Attempt budgets** (their "Max 3 attempts"): a runaway-loop guard the bar-recovery
  path lacks — after N consecutive short-evidence verdicts on a node, escalate to a
  checkpoint instead of re-steering forever. Implementable NOW (pre-Spend); additive
  policy/node field + prompt sentence + one e2e assertion. Dollar budgets remain gated
  behind Spend v1 (§13) and the future `spend` autonomy class.
- **D. Cost-per-completed-step framing** (their "$2.14 · 23 tasks"): presentation
  decision recorded now so Spend v1 builds per-mission/per-step rollups, never
  token-counter UI.
  **SKIP (with reasons):** Mission Notes (ledger + guidance + a note-type pin cover it;
  §11 one-concept discipline), Handoffs (the receipt IS the handoff; single-user CE),
  grouping/initiatives (backlog-tier adjacent, deferred), quick-switcher (post-v1 polish),
  cost/speed/second-opinion routing (seams exist — routing decisions record model;
  fork/pick-winner deferred; cost-aware waits on Spend — noted, not built).

## 8. coordinator_chat extension roadmap (2026-07-07, harness-driven)

Rule: extend for **observation** and **user-channel parity** only; never new runtime
powers. Additions stay additive ops.

1. **`mission_events since=<seq>`** — sequenced in-memory transition journal per mission
   (Swift-side, published from Coordinator snapshot changes). This removes the polling-race
   class that forced S2 to accept ready/running/completed convergence snapshots; the harness
   now asserts exact ready → running → completed transition order whenever this op is
   available.
2. **User-action parity: `set_pace` / `set_autonomy`** — implemented for the two visible
   dials. Both route through the same `missionPlanUpdater` path as the UI controls: same
   revision bump and same user-actor decision labels. `set_pace` controls Step/Auto;
   `set_autonomy` currently exposes `autonomy_class:"childAsk"` for the Me/Director dial.
   **Actor-integrity gate required:** these per-op user actions must be blocked at
   execution for coordinator/runtime-owned MCP callers even though `coordinator_chat`
   remains advertised for runtime `mission_plan` writes; the runtime must not be able to
   forge user-actor records. Harness `s6` exercises both `set_pace` at a pending approval
   checkpoint (revision/fingerprint advance, user decision recorded, checkpoint unconsumed)
   and `set_autonomy` at a pending child question (the §3c immediate-reroute path).
3. **`receipt format=markdown`** — implemented as the existing pure receipt projection;
   the harness can write `receipt.md` without UI copying.
4. **Lifecycle: `list_missions` / `archive_mission`** — support harness setup/teardown
   and scenario isolation. `archive_mission` is a user-channel lifecycle action, not a
   runtime power: coordinator/runtime-owned MCP callers must be execution-gated from
   archiving, because archive can hide a Mission from the rail after the fact. Archival is
   retention-only: receipts, decisions, evidence, events, and lineage remain durable and
   retrievable; archive only removes the Mission from ordinary live rail surfaces.
5. **`doctor`** — read-only capability pulse: app/build facts where available, supported
   `coordinator_chat` ops, native events/receipt, dials, scripted child, lifecycle ops, and
   child structured-input availability.

Not doing: `mission_status` field selectors, which fragment the contract; any
plan-structure mutation outside the existing mission-plan path.

## 15. E2E suite boundary and live evidence (2026-07-08)

The live suite is bounded by doctrine, not by every bug found while running it. New live
scenarios require a new pinned doctrine entry; ordinary regressions get deterministic
flow-layer coverage at the lowest faithful layer. Current plateau: S1 read-only, S2
fan-out/convergence with exact `mission_events` ordering, S4 checkpoint revision identity,
S5 childAsk Me/Director parity, S6 dial semantics (pace, ask→auto, auto→ask), and S7 stop
honesty. S3 cap discipline is a global invariant watcher, not a default live scenario.
S8 restart durability is the declared deferred boundary: relaunch with a pending ask must
reconstruct without consuming, duplicating, or re-minting the queue item.

Live evidence from the July 8 S5 run: when the selected Codex CLI child backend lacked a
structured user-input tool and returned `S5_USER_INPUT_TOOL_UNAVAILABLE`, the Coordinator
blocked the node with explicit evidence instead of fabricating the requested `Alpha`
result. That is the anti-fabrication validator net working as intended. The remaining
S5/S6 live blocker is environment/tooling, so the next reliability investment is
capability `doctor` plus a scripted child backend; it is not more scenario breadth.

Scripted-child reliability layer (2026-07-08): RepoPrompt's child tool policy treats
structured user input as a product contract for Agent Mode children (`ask_user` is granted
and advertised for explore/pair children). The scripted child exists only as hidden
debug/E2E infrastructure for deterministic childAsk mechanics: `model_id:"scripted"`
maps to a hidden Codex-exec test runner, is not exposed in normal model lists, requires the
exact line `SCRIPTED_CHILD_V1 ask_marker token=<TOKEN> options=Alpha,Beta`, creates a real
`AgentAskUserInteraction`, and must complete with `SCRIPTED_CHILD_V1 answer=Alpha
token=<TOKEN>`. Scripted runs are the cheap correctness gate; live child runs remain
model/backend negotiation samples. Tripwires: scripted must not become the only gate,
must reuse the real session lifecycle, must not grow into a general interpreter, must not
weaken harness assertions for scripted quirks, and must never leak into user-facing model
selection.

Mission-bound child response gate (2026-07-08): prompt guidance alone is insufficient for
actor-integrity rules. Scripted S5 proved that the follow-through directive can say
`coordinator_chat op=submit` while the live Coordinator still tries `agent_run.respond`.
Generic Agent Mode response is therefore blocked for active Mission-bound child questions
in both `childAsk:ask` and `childAsk:auto`; every Mission child answer must enter through
`coordinator_chat op=submit`, the one path that records actor decision and evidence before
resolving the child. Non-Mission child interactions keep normal `agent_run.respond`
behavior. `coordinator_chat submit` also treats `checkpoint_action` as an explicit
Coordinator continuation command; even if a child question is pending, a checkpoint
action must not be consumed as a child answer.

Runtime Mission routing guard (2026-07-08): the selected Coordinator Mission is a
presentation/external-driver default, not a runtime write target. Coordinator-runtime
`coordinator_chat` calls without an explicit `coordinator_session_id` resolve to the
caller Mission via run-scoped tab context; if that cannot be resolved, the call fails
closed instead of falling back to the selected Mission. This prevents stale child or
Coordinator turns from writing ask/auto variant ledger state into whichever Mission the
user currently has selected.

Checkpoint approval identity (2026-07-09): plan approval is a revision-bound consent
grant. Compact `mission_status` exposes a `checkpoint_instance_id`, and
`coordinator_chat submit` accepts `expected_checkpoint_instance_id` for checkpoint
actions. Consent-granting stale submits (`proceed`, evidence/deepen/critique/start
smaller lanes) reject and name the current checkpoint; stale `stop` still succeeds,
because withdrawing consent is harm-reducing and must not be denied by a fast plan
revision. Rejected stale grants record no user decision. The SwiftUI click path still
binds implicitly to the rendered checkpoint and does not yet echo the instance id; that
narrow render-to-click race is deliberately deferred for a UI follow-up.

Terminal-state honesty (2026-07-08): a Mission cannot publish `status:"completed"` while
any planned node remains pending, running, or blocked. Runtime `mission_plan` writes must
leave the Mission running until every node reaches a terminal state, or explicitly mark
unfinished nodes skipped/cancelled with evidence. Receipts, terminal UI, and archived row
status all depend on this invariant. The guard lives at the MCP parse boundary and in the
shared follow-through state merger, because non-MCP state updates can otherwise merge a
stale pending node into a terminal plan.

Stop honesty live proof (2026-07-09): S7 now exercises `coordinator_chat stop_mission`
after a scripted child has created a real pending child question. The accepted contract is
terminal `status:"stopped"`, no running/ready work, no pending Decisions row, a user
`stopped the Mission` irreversible decision, `agent_run.cancel` routing for active
sessions, cancelled node state rather than completed/failure styling, and a terminal
receipt available through `coordinator_chat receipt format=markdown`.

E2E plateau closure (2026-07-09): the declared first-consumer suite is live-proven at the
contract boundary: S1 read-only, S2 fan-out/convergence with exact `mission_events`
ordering, S4 checkpoint revision identity, S5 childAsk Me/Director parity, S6 pace plus
ask→auto plus auto→ask dial semantics, and S7 stop honesty with receipt. S3 remains a
global cap invariant watcher rather than a separate live scenario; S8 restart durability
and S9 recovery remain declared deferred boundaries.

Validation rig note (2026-07-09): a previous push-time red gate across MCP
lifecycle/watchdog/concurrency filters was observed once and not reproduced at the same
HEAD. The app-up baseline run on July 9 was green for
`MCPToolExecutionWatchdogIntegrationTests`, `PersistentMCPDistinctConnectionConcurrencyTests`,
`AgentModeRunServiceLifecycleTests`, and `MCPToolExecutionContractTests`. The mechanism is
unknown; the contention hypothesis is not confirmed. Treat future repeats as a fresh
diagnostic with this baseline, not as a known product regression.

Test-suite ledger status (2026-07-09): exact new E2E/checkpoint rows were added, but the
global `verify-ledger` command remains a known-red repository maintenance item with
pre-existing missing rows. The tooling phase must either repair that ledger so it can gate
again, or explicitly descope it from Coordinator reliability preflight; it must not remain
an ambient red footnote.

Coordinator tooling phase (2026-07-09): `coordinator_chat doctor`, `list_missions`, and
`archive_mission` are additive tooling ops for setup, teardown, and diagnosis. `doctor` is
side-effect free and safe for any caller. `list_missions` is a compact inventory that
includes live and archived Missions by default for external callers; Coordinator runtime
callers are scoped to their own Mission and fail closed if that Mission cannot be resolved,
preserving fleet-visibility gating. `archive_mission` is external-only,
terminal-only, and retention-only: running Missions must be stopped first; Coordinator
runtime callers are rejected; already archived Missions return idempotent success; pinned
Missions are unpinned as part of archive; selected archived Missions clear selection so
they leave the ordinary live rail. Archive never deletes or invalidates receipt, events,
decisions, evidence, status, or lineage.

Baseline sampling rules (2026-07-09): pass-rate batches are pre-registered diagnostics,
not curated demos. Every attempt counts, and failed attempts are not quietly rerun.
Failure classes are `plumbing`, `harness`, `model-negotiation`, `environment`, and `soak`.
If a plumbing or harness defect requires a code fix, restart the affected batch after the
fix; model-negotiation, environment, and soak failures stay in the denominator because
they are part of what the batch measures. Report raw pass counts only: 10/10 is useful
evidence but not a broad statistical guarantee. Run S5/S6 scripted batches in one
continuous app session so `--archive-on-success` also soaks mission cleanup and retention.

Baseline sampling results (2026-07-09): first raw scripted batches ran against one visible
debug app session with `--repeat 10 --doctor-mode required --events-mode required
--receipt-mode required --archive-on-success --child-model-id scripted`. The S6 batch was
restarted after two harness/plumbing fixes (stop the non-terminal pace slice before
receipt/archive, then retry terminal readiness races for receipt/archive); those invalid
batches are not counted. Counted results:

- S5 artifact root:
  `tmp/director-e2e-runs/20260709T145114Z-s5-b06f6d` — 9/10 passed. Attempt 1 failed as
  `model-negotiation`: the Mission reached approved/running with no active work and one
  ready child node, then made no observable progress for 208 seconds. Successful attempt
  durations ranged ~293-341s, median ~312s.
- S6 artifact root:
  `tmp/director-e2e-runs/20260709T183323Z-s6-a3f473` — 9/10 passed. Attempt 6 failed as
  `soak/product status-regression`: a node moved from completed back to running, with the
  warning `node_should_steer_primary_but_started_fresh`. Successful attempt durations
  ranged ~436-516s, median ~476s.
- Archive soak: S5 archived 18 successful-attempt Missions; S6 archived 27. Archive
  cleanup preserved status/events/receipt retrieval for successful attempts. Failed
  attempts were left unarchived by design.
- Demo-leading receipt artifact:
  `tmp/director-e2e-runs/20260709T145114Z-s5-b06f6d/attempt-002/auto/receipt.md` records a
  childAsk:auto run with Director-routed answer evidence. Completed and stopped receipts
  remain separate packaging artifacts.

Coordinator runtime attribution (2026-07-08): `actor:user` on a Director-answered child
question is fabricated user consent. `coordinator_chat` therefore stays conservative:
ambiguous request metadata is user-authored, never Director-authored. The fix is durable
role propagation, not permissive attribution: Coordinator runtime sessions must carry the
runtime marker through reused/steered runs, run-policy re-seeding, and prompt/lease
construction so Director answers arrive with explicit `isCoordinatorRuntime` metadata.
