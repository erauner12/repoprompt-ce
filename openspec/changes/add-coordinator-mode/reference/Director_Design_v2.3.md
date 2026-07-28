# Director Design v2.3 — Directive-First Missions, Policies, and the Decision Metric

**Status:** Normative for the v2.3 mock (`RepoPrompt_Command_Center_v2.html`) and for the Swift translation of these mechanics. Where this document and the Mock Iteration Spec overlap, this document governs the four v2.3 changes; the spec governs everything else. Every rule below is implemented and harness-verified in the mock unless explicitly marked **[swift-only]**.

**The value thesis this design serves:** the Director's value over Agent Mode is not parallelism or plan pretty-printing — it is converting *turns* into *decisions*. In Agent Mode a multi-step job costs the user every turn; under a Director it costs the user only the decisions that genuinely need a human: approve the plan, resolve real forks, confirm the irreversible. Everything in v2.3 either removes an element that didn't serve that thesis (shape pickers, the per-mission board, glyph taxonomy) or makes the thesis measurable (the decision stat).

---

## 1. Concept model

| Concept | Definition | Chosen by | Lives on |
|---|---|---|---|
| **Directive** | The user's free-text description of the work (may reference `#NNN`) | User | `mission.objective` (verbatim, immutable) |
| **Shape** | Which of the five plan blueprints the plan is drafted from | **Director, inferred from the directive** (user can steer pre-draft, revise post-draft) | `mission.shape` (name) + the announcement message |
| **Policy** | How much the user trusts the run: pace, checkpoints, optional Definition of Done, budget, pinned skills | User (picked or authored; "Default" if untouched) | `MISSION_POLICIES` registry; snapshot on `mission.policyName/policyDone/policyPins` |
| **Plan** | The drafted DAG (workstreams/nodes/bars/routing) | Director drafts; user approves/revises | `mission.workstreams/nodes` |
| **Decision** | A user interaction that resolved a checkpoint or steered the mission | User | `mission.userDecisions` (append-only label list) |

**The invariant that replaces "templates":** *shape is never picked; policy never shapes.* There is no user-facing artifact that encodes topology. The five blueprints (`SHAPE_LIBRARY`: Scoped Change, Spec-First Build, Root-Cause Report, Alternatives Bake-off, Measured Improvement) are the Director's internal library, referenced by inference and mentioned in UI copy only as examples of what it can draft.

## 2. Shape inference — exact contract

### 2.1 Decision procedure

`inferShapeFromDirective(text)` evaluates the classes below **in order** and returns the first match; order is part of the contract (most-specific intent wins). Input is lowercased. Output is `{ name, reason }` where `reason` is a fixed per-shape explanation sentence.

| Precedence | Shape | Intent class | Mock trigger (regex, stand-in) | Reason copy (fixed) |
|---|---|---|---|---|
| 1 | Alternatives Bake-off | Weighing approaches | `\bcompare\b`, `\bvs\.?\b`, `versus`, `bake?off`, `alternativ`, `two approaches`, `which is (better\|faster)` | "you're weighing two approaches — I'll build both against the same bar and you pick on the evidence" |
| 2 | Measured Improvement | Named metric to improve | `optimi[sz]e`, `speed?up`, `\bperf\b`, `performance`, `latency`, `\bfaster\b`, `too slow`, `reduce (the )?(time\|latency\|memory)`, `benchmark` | "it names a metric to improve — I'll baseline it first, then run a measured try/keep-or-revert loop" |
| 3 | Root-Cause Report | Diagnosis, not change | `investigat`, `root?cause`, `diagnos`, `why (is\|does\|did)`, `file (an? )?(issue\|bug)`, `crash(es\|ing\|ed)?\b`, `no code change`, `read?only` | "this reads as diagnosis, not a change — read-only evidence gathering, ending in a filed issue" |
| 4 | Spec-First Build | Design-first / large scope | `\bspec\b`, `design (first\|doc)`, `architect`, `\brework\b`, `overhaul`, `\bredesign\b`, `across modules`, `multiple (modules\|services)`, `migrat` | "the scope is big enough to design first — spec, sign-off, then parallel module builds and integrate" |
| 5 (default) | Scoped Change | Everything else | — | "a small, well-scoped change — explore, implement with focused tests, independent review, then a PR" |

**[swift-only] Model contract.** The regex table is an honest stand-in. In Swift, the same decision is one model call: input = directive + probeContext (+ issue body if fetched); output = `{shapeId ∈ the five, reason: one sentence}`. The five-shape closed set, the precedence *semantics* (a directive that both compares and names a metric is a bake-off), the fixed announcement format, and the default-to-Scoped-Change behavior are the contract; the mechanism is not. A "draft a custom shape outside the library" path is explicitly out of scope for now (§7, deferred).

### 2.2 Announcement (the routing record)

Every mission's grounding ends with the Director's shape announcement, exact format:

> `{grounding sentence}. This reads as a {shape, lowercase} — {reason}. No plan exists yet — approve the mission checkpoint and I'll draft it. (Not the shape you meant? Say so below before I draft.)`

This message **is** the shape routing record: shape + reason + override invitation, logged in the thread before any plan exists. The plan overview repeats it as `**Shape:** {name} (inferred from your directive)`.

### 2.3 Re-inference (pre-draft override)

Any composer message sent while `checkpoint === approval && no plan exists` (the probe-steering path) re-runs inference over **`objective + " " + probeContext.join(" ")`** (the directive plus *all* pre-plan steering, cumulative). If the result differs from `mission.shape`:
- `mission.shape` is updated;
- the Director announces: `Added to context — and that changes the shape: this now reads as a {shape, lowercase} ({reason}). Approve to draft, or keep steering.`
- If unchanged, the standard probe acknowledgment is posted.

**Boundary rule:** re-inference exists **only before the plan is drafted**. After drafting, shape changes go through plan revision (✎ Plan → re-approval) or the mid-flight split proposal — the shape name is then descriptive history, not a control.

## 3. Mission Policies — exact contract

### 3.1 Schema

```yaml
policy:
  id:            # "pol-…" builtin | "user-{slug}-{n}"
  name:          # unique among user policies (save = upsert by name)
  user:          # true for authored policies (renders the "yours" badge)
  pace:          # "Step" | "Auto"
  planApproval:  # bool, default true
  mutableGate:   # bool, default false
  done:          # free text, DEFAULT EMPTY — see 3.3
  budget:        # string|null (max iterations; display-only in mock)
  pins:          # [skill] always loaded for missions under this policy
```

Built-ins: **Default** (Step, approve plan, no gate, done empty) and **Hands-off** (Auto, approve plan, no gate, done empty). The editor's "＋ New Policy" prefill example is **Careful writes** (Step, approve plan, **gate first write on**, done empty).

### 3.2 Application at mission start (who wins what)

| Field | Source & precedence |
|---|---|
| pace, planApproval, mutableGate | Policy pre-loads them into the composer on pick (`applyPolicyDefaults`); **the composer's current values win** (user toggles after picking override the policy for that mission). Snapshot onto the mission at start. |
| skills | `inferSkillsFromBrief(directive) ∪ policy.pins`. Shapes carry no skills. Empty union renders as "the repo's conventions". |
| shape | **Never from policy.** Inference only (§2). |
| done | Snapshot to `mission.policyDone` at start; governs the close (§3.3). |
| budget, pins | Snapshot to mission fields; budget is display-only (unenforced, documented). |

### 3.3 Definition of Done — the close-override rule

**Rule:** *shape governs how work gets there; policy Done governs how it ends.*

- `policy.done` **empty** (the default) → the drafted shape's own terminal stands (Scoped Change → PR, Root-Cause → issue, …).
- `policy.done` **non-empty** → after `draftPlanForMission` builds the nodes, the land node (`directorDirect`) is re-targeted: `terminal = terminalFromDone(done)`; title/desc replaced with the fixed per-terminal strings, suffixed "(Close set by your policy's Definition of Done.)". The reversibility gate then follows the *new* terminal (PR → merge always confirms; issue/report → no merge-style gate).
- The override applies regardless of shape (forcing a Root-Cause shape to close with a PR is permitted and predictable — user's policy, user's consequence). No other node is modified.
- **(v2.5) The override is announced, never silent:** when a non-empty policy Done re-targets the close against the shape's default terminal — or against a close the directive itself named ("…and file an issue" under a report-closing policy) — the grounding shape announcement carries an explicit note: *"your {policy} policy's definition of done closes this by {X} — your directive mentions {Y}; the policy wins unless you say otherwise before I draft."* Same pre-draft override window as the shape itself.

### 3.4 What the policy editor is NOT

No brief. No plan preview. No phase/workflow authoring. No shape field. The editor is: name, autonomy, checkpoint toggles, budget, optional Done (with the drafted-close + reversibility hint when non-empty, and an explicit "empty = each shape decides" hint), pinned skills. Deleted machinery (must not be resurrected in Swift): `scaffoldFromDescription`, `compileEditorTemplate`, `editorProduces`, `resolveTemplateBlueprint`, brief-based skill suggestion, phase preview (`templatePhases`/`collapseFanout`/`stepMark`/`nodeProduces`).

## 4. Decision accounting — exact counting rule

`mission.userDecisions` is an append-only list of **fixed labels**. A decision = a user interaction that resolved a checkpoint or steered the mission. The full table (anything not listed is NOT counted):

| User interaction | Label | Recorded in |
|---|---|---|
| Confirm at plan-approval checkpoint (incl. auto-proceed when the user toggles plan-approval off while waiting) | `plan approval` | `advanceMissionCheckpoint` (wasApproval) |
| Confirm at a step checkpoint that starts the next step | `step check-in` | step-continue fallthrough |
| The Continue that *arms* the before-edits gate (Step pace) | `step check-in` | gate-arming branch |
| Confirm that crosses the before-edits gate (armed on Step, or direct on Auto) | `before-edits gate` | step-continue fallthrough (`crossedGate`) |
| Confirm Merge | `confirmed the merge` | merge branch |
| Request changes (merge option **or** generic option) | `sent it back (changes)` | `requestChangesBeforeMerge` (no feedback) / generic request branch |
| Paste PR feedback into the composer at merge | `PR feedback pass` | `requestChangesBeforeMerge` (with feedback) |
| Composer feedback that re-steers the last completed step | `step feedback` | `refineLastStep` |
| ✎ Plan revision sent | `plan revision` | `revisePlan` (the subsequent re-approval also counts as `plan approval` — two interactions, two decisions, intentional) |
| Pre-plan probe/steering message | `context steer` | pre-plan composer branch |
| Pick the winner (bake-off) | `picked the winner` | pickwinner branch |
| Approve the split | `approved the split` | splitProposal branch |
| Keep as one worktree | `kept one worktree` | splitProposal branch |
| Revise option on any checkpoint | `held for a plan change` | revise branch |
| Stop (any checkpoint) | `stopped the mission` | stop branches |

**Never counted:** auto-approved step markers (Auto pace), the Director's autonomous bar-miss re-steer, probe/loop/psteer beats, selecting checkpoint radio options without confirming, opening/closing inspectors/sessions/plan, policy-menu toggling outside the waiting-approval auto-proceed case, the final "all steps complete" confirm when nothing started.

**Display contract:**
- On completion, `finishMission` posts a `role:"stat"` message: **"Needed you N×"** + parts grouped in first-occurrence order with `×k` for repeats (e.g. `plan approval · step check-in ×4 · step feedback · confirmed the merge`). Suppressed when the list is empty (seeded examples).
- After completion, the mission status strip shows a green `needed you N×` pill.
- **[swift-only]:** persist decisions as typed events (label + checkpoint id + timestamp), not strings; the label set above is the display vocabulary. This is the same event log the routing/audit work feeds.

**Why this exact rule:** the stat must be *honest under Step* — a Step run showing `7×` against Auto's `2×` is the pace comparison working as intended, not a bug. Do not exclude step check-ins to make numbers smaller.

## 5. The Plan is the board (per-mission Board tab removed)

- `renderMissionBoard` is deleted; the mission Work surface renders the Plan (header "Mission Plan · Live — nodes carry their session, status, and evidence") unconditionally, plus Turn Float and Inspector. The fleet's **All Agents Board** is unchanged and remains the only kanban.
- `state.rightTab` is replaced by **`state.inspectorFocus: "node" | "session"`** — it no longer selects a stage, only which inspector flavor renders and whether the selected node card highlights/expands.

Focus transition table (deterministic):

| Action | inspectorFocus | Also |
|---|---|---|
| Select plan node / open-plan-node / inspector "Plan node →" | `node` | selectedNode set; bound session follows into selectedSession; card expands |
| Select session (delegated card in thread, fleet card, inspector "Bound session →") | `session` | selectedSession set; in mission view → Work + inspector open |
| Delegated card `›` (open-session-plan) | `node` if the session binds to a plan node, else `session` | |
| Decision card with sessionId | `node` if bound, else `session` | routes to the mission first |
| Select mission (rail) | `node` (reset) | Talk view, inspector closed |
| All Agents Board nav | `session` | fleet inspector ignores focus (always session-flavored) |

## 6. Execution glyphs — variance only

Supervision-to-a-bar is now the **stated universal rule** (and demonstrated by the ✗ bar-miss beat), so the per-row `↻` marker is retired along with the shape previews that carried it. The only glyphs that render are the ones marking where a plan's *shape varies*: **⇉** parallel band tag, **↳** convergence tag (both from `renderNodeGroups`), **⟳** loop strip on loop nodes. `· steer` chips remain on steer-reuse nodes (none in current shapes; tests are folded). No glyph taxonomy legend is needed anywhere.

## 7. Deferred / out of scope (do not implement speculatively)

Custom shapes drafted outside the five-shape library; budget enforcement; policy-level shape *hints*; per-decision timestamps in the mock; a "confidence" field on inference; Decisions-queue changes. Each is a conscious deferral, not an oversight.

## 8. Rename map (for translating any earlier notes/specs)

| Old (≤ v2.2) | New (v2.3) |
|---|---|
| `MISSION_TEMPLATES` (user-facing templates) | `SHAPE_LIBRARY` (Director-internal blueprints) |
| `templateByName` | `shapeByName` |
| `mission.template` | `mission.shape` |
| Template picker cards / "Use template" | Policy cards (`renderPolicyCards`) / "Use policy" |
| Template editor (brief + preview) | Policy editor (`renderPolicyEditor`, no brief/preview) |
| `state.draftTemplate` | `state.draftPolicy` (a policy name) |
| `state.templateEditorOpen` / `editorDraft` | `state.policyEditorOpen` / `policyDraft` |
| `state.rightTab` ("plan"/"board") | `state.inspectorFocus` ("node"/"session") |
| `blankTemplate`/`editorFromTemplate`/`applyTemplateDefaults` | `blankPolicy`/`editorFromPolicy`/`applyPolicyDefaults` |
| actions `pick/clone/open/close-template-*` | `pick/clone/open/close-policy-*` |
| Deleted with no replacement | `renderMissionBoard`, `templatePhases`, `collapseFanout`, `stepMark`, `nodeProduces`, `scaffoldFromDescription`, `compileEditorTemplate`, `editorProduces`, `resolveTemplateBlueprint`, `effectiveSkills` (→ `missionSkills(directive, policy)`), `tplVars`, `EDITOR_WORKFLOWS`, `templatePickerOpen` |

## 9. Swift translation summary

| Change | Data model | Behavior | Projection |
|---|---|---|---|
| Shape inference + announcement | `mission.shape` + routing event | model call per §2.1 contract; re-inference pre-draft | announcement copy, overview "Shape:" line |
| Policies | policy registry + mission snapshot fields | close-override in plan drafting (§3.3); skills union | cards, editor, composer `Policy ·` chip |
| Decision accounting | typed decision events | record at the fifteen trigger points (§4 table) | stat card, strip pill, ×N grouping |
| Board removal / inspectorFocus | drop board-tab state; `inspectorFocus` enum | focus transition table (§5) | "Mission Plan" work header |
| Glyph rule | — | — | ⇉/↳/⟳ only |

Demo-narration deltas live in `Mission_Demo_Scripts.md` (v2.3 sections: cold open, V0 §3, V1 §1, V2 closing stat, V3 §4, V5 rewrite, V6 inference framing, mechanics rewrites, question bank).
