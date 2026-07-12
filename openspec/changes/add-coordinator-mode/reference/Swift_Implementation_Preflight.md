# Swift Implementation Pre-Flight — Director Mode v2.5.1 → RepoPrompt CE

**Purpose:** the decisions to make and the tightenings to apply *before* writing Swift, plus a deliberate v1 cutline. Companion to `Mock_Iteration_Spec_v2.md` (contracts), `Director_Design_v2.3/v2.4.md` (normative rules), and `Director_Prompt_Design.md` (model calls). It separates what should become real runtime architecture from what is mock-only demo scaffolding.

---

## 1. Decide before day one

**1.1 The naming collision (blocking).** The mock says **Director Mode**; the existing OpenSpec stack in the repo says **Coordinator** (`add-coordinator-mode`, `add-coordinator-role`, `add-coordinator-list-sessions-visibility`, `AgentModeMCPPolicyContext`). Pick one now — either is mechanical, both at once is drift in every symbol, spec, and prompt from commit one. Keep **Mission** as the work unit; the supervisor's name is the open choice. Whichever wins, do the rename as its own no-behavior commit before feature work.

**1.2 The v1 cutline (recommended).** Ship **three shapes**: Scoped Change, Root-Cause Report, Spec-First Build. Defer **Alternatives Bake-off** and **Measured Improvement**. This is not arbitrary — those two carry the runner's two most complex behaviors (fork resolution + compare nodes; loop iterations + stop rules), and deferring them cleanly defers:
- the `fork` autonomy class (arrives with bake-off),
- the loop/iteration machinery and per-iteration ledger trail (arrives with measured),
- the **budget** policy field (nothing enforces it until loops exist — cut from the v1 editor, keep reserved in the schema).

Also defer **Director-proposed mid-flight reshaping** (the split-proposal → parallel-worktrees rewrite) to v1.1; it's the hardest runtime operation (live plan-graph surgery) and the `reshape` class arrives with it. **Keep** user-initiated ✎ plan revision (simpler: user authors the change, re-approval flow already specced).

**Resulting v1 autonomy menu:** pace (Step/Auto) + `plan` + `writes` + `childAsk` + the two locked rows. The class table is additive by design — v1.1 adds `reshape`, v1.2 adds `fork`, no migration.

**1.3 Forward-compat rule (one line, important).** An autonomy class the runtime doesn't recognize resolves to **ask**. This makes adding classes later safe for old missions and old saved policies — new decision kinds never silently auto-run under a policy written before they existed.

## 2. Unify the data model (the mock accreted; Swift should not)

**2.1 One decision event type.** The mock has three parallel structures: `userDecisions[]` strings, `autoDecisions[]` strings, and the `_autoAdvances` counter. In Swift, collapse to a single record:

```swift
struct MissionDecision {
  let cls: AutonomyClass        // plan / advance / writes / childAsk / recover / irreversible / …
  let actor: Actor              // .user | .director
  let label: String             // the fixed vocabulary (design doc v2.3 §4 + v2.4 §2)
  let reason: String?           // required when actor == .director (the ⚙ card text)
  let at: Date
  let refs: Refs                // node ID / session ID / checkpoint kind — IDs, never titles
}
```

Everything projects from this one ledger: the ⚙ cards, the two-sided stat, the strip pills, the Decisions view — and the **receipt** (§5.2). This is the reviewable, attributable decision record.

**2.2 Checkpoints are state; markers are events.** In the mock, a checkpoint is both `mission.checkpoint` *and* marker messages — a duplication that worked for HTML rendering. In Swift: `checkpoint` is a state machine value (`approval / step / writesGate / childAsk / merge / …`), and the thread renders it *live* from state; only resolved checkpoints leave an event behind. Don't port the double representation.

**2.3 A closed MissionEvent enum.** The mock grew ~15 message roles. Collapse the beat roles (`loopiter`, `psteer`, `parallel`, probe beats) into one `progress` event with a subtype — they differ only in rendering. Keep as first-class: `user`, `director`, `grounding`, `evidence` (with verdict), `childQuestion`, `decision` (renders ⚙ or plain by actor), `stat`, `sessionRef`, `terminalOutput`.

**2.4 IDs everywhere.** The Coordinator-era invariants apply unchanged to the mission runtime: owner attribution by lineage walk, never title parsing; agent/model *text* is output, run/session *state* is the control plane; the Coordinator/worker wall lives in display projections, not the relationship index. The decision ledger and evidence ledger reference nodes/sessions by ID.

**2.5 What does not port.** `demoBeats`, the scripted `barMiss`/`childAsk` payloads (real runs produce real misses and real questions), the boot-time seeded examples (in the real app, Examples = actual completed missions), and the narrative-accounting overwrite. All are labeled demo scaffolding in the spec; listing them here so nobody ports theater.

## 3. Contract tightenings (small, each will bite mid-implementation otherwise)

**3.1 Named-close detection moves into the inference call.** The mock detects "…and file an issue" with a regex. In Swift, extend Prompt Design §1's output to `{ shapeId, reason, namedClose: "issue"|"report"|"pr"|null }` — one model call, no brittle regex. The close-conflict *sentence* stays deterministically composed (v2.3 §3.3); only the detection moves.

**3.2 Guidance injection by construction.** Implement standing guidance as one function — `guidanceBlock(for: PromptSite) -> String?` with `PromptSite ∈ {inference, drafting, delegation, interception}` — and make it the *only* way guidance reaches a prompt. The four-channels-and-nowhere-else rule (v2.4 §7) becomes structurally enforced instead of a discipline.

**3.3 childAsk ask-path latency.** "Never escalate a bare question" requires a model call *on the ask path too* (to draft the suggested answer). Specify: the checkpoint appears **immediately** with the raw question; the suggestion streams into the primary action when ready; if the suggestion call fails, the checkpoint degrades to composer-only. Don't block the checkpoint on the suggestion.

**3.4 Autonomy is read at decision time, not captured at spawn.** Live toggling mid-mission is a specced behavior (menu contract); every decision point calls `askOn(mission, cls)` against current state. The one spawn-time snapshot that stays is the *policy* snapshot (name/done/guidance/pins) — trust settings are live, contract text is frozen.

## 4. UI mapping (the split → the existing shell)

The three-column `NavigationSplitView` shell from the Coordinator work maps directly: **rail = sidebar column, thread = content column, plan pane = detail column.** The session inspector is a ZStack overlay *within* the detail column (matching the mock's overlay, min(384, 86%)), not a fourth column. `planCollapsed` = detail-column visibility with the slim strip as the collapsed accessory; the auto-expand-on-first-draft rule ports as-is (it's one line at the drafting call site, guarded by selected-mission). The ✎ revise input is the detail column's footer. Node detail = expanding card in the plan (no node inspector — deleted in v2.5, don't reintroduce).

## 5. Architecture cross-check

**5.1 Where the design is already aligned (no action).** The mission contract is policy (autonomy + done + guidance + pins) × directive × announced shape. Curated state, not transcript accumulation, maps to the evidence ledger + scoped delegation charters (Prompt §3 sends ledger excerpts and bars, never transcripts; Prompt §6 keeps reviewer context sparse and independent). The attention queue maps to the Decisions view. Decomposition changes the job, which is why shapes exist. Reviewable and attributable decisions map to the unified decision ledger (§2.1). The framing to keep: *the user is the reviewer, not the integration layer* — that's our two-sided stat argued as an org-design claim.

**5.2 The Mission Receipt (pulled into v1 — implemented in the mock as of v2.6).** Once §2.1 lands, a receipt is a projection, not a feature: contract snapshot (directive, shape + reason, policy incl. guidance/done, autonomy at start) + the decision ledger (both actors, with reasons) + the evidence ledger + steer/re-pass record + the closing artifact link → one exportable markdown. Prompt §10 already writes PR bodies *from the ledger*; the receipt is the same projection aimed at the operator. Logs are for debugging; receipts are for deciding whether the work was worth doing. For us, this is nearly free.

**5.3 Roadmap, explicitly not now.** (a) **Tool governance** — our pins are *context* pins, not a tool policy (required/allowed/risky/fallback/per-worker); real per-mission MCP/tool policy should ride on `AgentModeMCPPolicyContext` when it comes, not be invented in v1. (b) **Model routing per node** — the blueprint field exists; keep it scripted/static in v1. (c) **Mission survives the worker** — the deeper architectural claim (durable state above the session/model); our ID-based lineage + mission-owned ledgers are the precondition, and nothing in v1 should hang mission state off a live session object.

## 6. v1 acceptance summary

Ships: mission CRUD + contract snapshot · inference call (3 shapes, namedClose) · plan drafting with per-node bars · delegation charters + steer-over-spawn · evidence adjudication with rejection · checkpoints: approval / step / writes gate / childAsk / merge · autonomy: pace + plan + writes + childAsk + locked rows, live-toggled · unified decision ledger + ⚙ cards + two-sided stat · policies (4 built-ins, guidance, no budget UI) · grounding card + close-conflict note · split UI with collapse + auto-expand.

Ships additionally: **Mission Receipt** (projection of contract + two-sided decisions + evidence + close; panel + Markdown export — reference implementation in the mock, v2.6) and **follow-up missions** (completed missions immutable; a message into one starts a linked follow-up inheriting the receipt as grounding + the predecessor's trust settings — mock v2.7; the receipt projection is the enabler, which is why these two ship together).

Deferred with their machinery: bake-off/`fork` · measured/loops/budget · Director-proposed reshape/`reshape` · tool policy · model routing · the model-composed "learnings" receipt line.

**Workspace note (v3.1):** RepoPrompt's existing workspace folder list is the grounding source for repo scope — the drafting call takes it as input, and land nodes carry `repo`. The mock hardcodes the demo's two-repo scope in the blueprint; do NOT port that — resolve scope from grounding + the explore step's evidence, announce it at drafting, keep it steerable.

**Multi-land note (v3.0):** the runtime contract is per-action irreversibility + Done-bar completion — build the land machinery **parameterized by land node from day one** (`node.pr` / `node.branch` / per-node opened-state; no mission-level PR singletons), even though v1 ships only single-land shapes. The stacked Spec-First variant itself can ride v1.1 with zero migration if the runner is node-parameterized from the start — retrofitting singletons later is the expensive path (this is exactly the refactor the mock just underwent).
