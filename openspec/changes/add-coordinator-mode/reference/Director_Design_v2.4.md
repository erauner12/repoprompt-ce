# Director Design v2.4 — Autonomy as Decision-Class Policy (Earned, Auditable Trust)

**Status:** Normative for the v2.4 mock and its Swift translation, alongside `Director_Design_v2.3.md` (which still governs shape inference, policies-as-trust, decision accounting basics, and the board removal). Where the two overlap on autonomy/checkpoints, **this document supersedes v2.3**. Everything below is implemented and harness-verified in the mock unless marked **[swift-only]**.

**The problem this redesign solves.** The prior model conflated two different things: Step/Auto was a *pause frequency* knob, and the "Checkpoints" menu was two special-case toggles (plan approval, before-first-write). Neither expressed the actual intent: *let the Director make automatic decisions between meaningful checkpoints — earned, visible trust — but hard-stop for the human at certain points.* Frequency is not trust. The redesign makes **decision classes** the unit of policy.

---

## 1. The model in one paragraph

During a run the Director encounters *decisions*, each belonging to a **class**. Policy sets each class to **ask** (stop for the human — a checkpoint) or **auto** (the Director decides itself). **Auto is never silent:** every non-advance auto decision posts a **"⚙ Director decided"** card in the thread — what it chose and the one-line reason — and is appended to `mission.autoDecisions`. Two rows are **locked**: *bar recovery* is always the Director's (within-step supervision is its job at any trust level — logged, never a knob), and *irreversible actions* always ask. Step/Auto survives as the shortcut for exactly one class — **step advance** — so the composer seg stays, but it is now *defined by* the class table rather than being a separate mechanism. Trust is earned by reading the ⚙ cards and widening the auto set; it is audited by the two-sided completion stat: **"Needed you N× · Decided itself M×."**

## 2. The decision classes (exact table)

`AUTONOMY_CLASSES` — each `"ask" | "auto"`, stored per-mission on `mission.autonomy` and per-policy on `policy.autonomy`:

| Class | The decision | `ask` behavior | `auto` behavior | Default |
|---|---|---|---|---|
| `plan` | Accept the drafted plan and start | Plan-approval checkpoint | Director drafts, verifies the plan matches the announced shape, starts; ⚙ card "waived plan approval" | ask |
| *advance* (= pace) | Proceed past a step whose evidence met its bar | Step checkpoint at every boundary (**Step**) | Advances on evidence (**Auto**); "» auto-approved" markers; counted via `_autoAdvances`, **not carded** (a ⚙ per advance would be noise) | Auto in Hands-off; Step in Default |
| `writes` | Cross into the first mutable write | The amber before-edits gate (mirrors onto `mutableBoundary` nodes' `gate`, live) | No stop at the write boundary | auto |
| `reshape` | Apply a mid-flight plan change the Director proposes (split, added step) | `splitProposal` checkpoint | Applies immediately; ⚙ card "applied a split" + revise marker; plan overview notes the revision | ask |
| `fork` | Pick between alternatives (bake-off winner) | `pickwinner` checkpoint with side-by-side evidence | Director picks on the evidence; ⚙ card "picked the winner" with the comparative reason | ask |
| `childAsk` | Answer a delegated agent's mid-step question | `childAsk` checkpoint (question + the Director's *suggested answer*, one-tap send or type your own) | Director answers **from mission context** (issue scope, plan, ledger); ⚙ card "answered the implementer" quoting the answer + why it was answerable | ask |
| **Bar recovery** *(locked)* | Evidence short of the bar → re-steer the same session | — | Always the Director's; logged as `re-steered a short bar (same session)` in `autoDecisions`; the ✗ card + re-steer narration IS its card | Director's, always |
| **Irreversible** *(locked)* | Merge / deploy / send | Always the merge-style checkpoint | never | ask, always |

**The two lines that make the model coherent:** *within-step supervision is always the Director's; between-step and cross-step decisions are governed by class policy.* And *auto means allowed, not required* — **[swift-only]** a low-confidence Director should ask even on an auto class (the class grants permission; it doesn't mandate use).

## 3. Exact mechanics (as implemented)

- **`defaultAutonomy()`** = `{plan:"ask", writes:"auto", reshape:"ask", fork:"ask", childAsk:"ask"}`. `askOn(m, cls)` is the single read path; the old `cpPlanApproval`/`cpMutableGate` booleans are **deleted** (mapping: `cpPlanApproval:true ⇔ plan:"ask"`, `cpMutableGate:true ⇔ writes:"ask"` — the schema is a strict generalization).
- **Gate mirroring:** at draft time and on live toggle, `node.gate = askOn(m,"writes")` for every `mutableBoundary` node.
- **Fork auto:** in `startNextNode`, a `compareChoice` node with `fork:auto` resolves via `resolvePickWinner(m,"B",true)` instead of setting `checkpoint=pickwinner`. The scripted "B" (better benchmark) is the stand-in for the adjudication model call.
- **Reshape auto:** `proposeWorktreeSplit` applies the split immediately (⚙ card + revise marker), never sets `splitProposal`.
- **Child questions:** scripted once per mission on the Scoped Change implement node (`node.childAsk = {question, suggested, reason}`), played in `runnerTick` **before** the bar-miss beat. Always posts a `role:"childq"` card (amber "? child question"). On `ask`: `checkpoint="childAsk"`, session `runState=waitingForQuestion`, run halts; the checkpoint shows the question + the Director's **suggested answer**; primary button sends it, or the composer sends a custom answer (`answerChildQuestion(m, text)`), recorded as user decision `answered a child question`. On `auto`: ⚙ card with the answer + "answered from mission context — {reason}", run continues untouched. Beat order in the canonical run: question → (answer) → ✗ bar miss → re-steer → ✓ — a deliberately rich supervision sequence.
- **Plan auto at start:** the skip-approval path posts the ⚙ "waived plan approval" card (reason cites the shape match) instead of silently proceeding.
- **Live toggling:** the Autonomy menu works mid-mission; flipping `plan` to auto while waiting at approval = delegating that decision → the Director takes it immediately (counts as `plan approval`, consistent with v2.3's waiver rule); flipping `writes` re-mirrors gates.
- **Two-sided stat:** `decisionStat` returns `{total, parts, autoTotal, autoParts}` where autoParts = grouped `autoDecisions` + `advanced past N steps on evidence` (from `_autoAdvances`). Stat card renders both lines; the status strip adds a grey `decided itself M×` pill next to the green `needed you N×` pill. Turn-float peek shows both totals.
- **Composer pill:** `Autonomy · asks N` where N = ask-classes + (Step ? 1 : 0) + 1 (irreversible).

## 4. UI surfaces

**Autonomy menu** (replaces the Checkpoints popover; same `cpill` anchor): one row per class with ✋ Ask / ⚙ Auto state + per-state explanatory note; a **Step advance** row wired to pace (the seg is its shortcut); two locked rows (Bar recovery — "Director's"; Irreversible — "Always asks"). Header copy states the contract: *auto is never silent — the Director posts a ⚙ card with its reason.*

**Policy editor:** the Checkpoints row becomes a **Decisions** row of five class chips (toggle Ask/Auto) + the locked note. No other editor changes from v2.3.

**Policy cards:** each shows an `asks: plan · forks · …` chip derived from the autonomy map (`only the irreversible` when everything is auto) plus a per-policy description line.

## 5. The built-in policy set (and why these four)

| Policy | Pace | Autonomy (ask classes) | Done | Teaches |
|---|---|---|---|---|
| **Default** | Step | plan, reshape, fork, childAsk (writes auto) | — | The training-wheels posture: every boundary visible while trust is earned |
| **Hands-off** | Auto | plan, fork | — | The target posture: approve once; Director handles reshaping + child questions itself, logged; real forks and the merge still come to you |
| **Careful writes** | Step | plan, **writes**, reshape, fork, childAsk | — | The `writes` class: nothing mutates without an explicit gate |
| **Read-only** | Auto | plan, fork | "A written report of the findings. No code changes." | The Done-override lever + the safest full-autonomy posture: *it can't write, so it can run* |

Editor prefill (**"Overnight perf hunter"**: Auto; plan auto, **writes ask**, reshape auto, childAsk auto; budget 6; pins `profiling`) exercises every field including `plan:auto` and pins — the one configuration no built-in shows.

## 6. Seeded completed shape examples

Four **Completed** example missions (rail → Examples) preserve the old template scenarios as living references — one per non-baseline shape, with objectives that deliberately carry the inference keywords so each example also teaches *why* it got its shape:

| Example | Objective (verbatim) | Shape (inferred) | Close | Stat |
|---|---|---|---|---|
| Redesign the sync engine (spec first) | "redesign the sync engine across modules, spec first" | Spec-First Build | PR #128 merged | Needed 2× · decided itself 6× |
| Investigate the session teardown crash | "investigate the crash on session teardown and file an issue" | Root-Cause Report | Issue #312 | Needed 1× · decided itself 3× |
| Rate limiter: cache vs index | "rate limiter — compare cache vs index" | Alternatives Bake-off | PR #131 (user picked B) | Needed 3× · decided itself 4× |
| Speed up the dashboard query | "speed up the dashboard query" | Measured Improvement | PR #136 | Needed 3× · decided itself 4× |

**Mechanism (contract):** `seedCompletedExample` runs at boot **through the real machinery** — `inferShapeFromDirective` → `draftPlanForMission` → a synchronous `runnerTick` drive — so example plans, beats, evidence ledgers, and threads can never drift from what the Director actually drafts. The one labeled fiction: after the drive, the accounting is **overwritten with the narrative** user/auto decisions above and the stat re-posted (a drive under all-auto autonomy wouldn't produce the story each example tells). The bake-off drive sets `fork:"ask"` and resolves the pickwinner as a user message so no ⚙ pick card contradicts "the user picked." Example missions and all their sessions carry `example:true` and stay out of Decisions and the fleet Board (existing gating).

## 7. Standing guidance (the policy's third leg)

**What it is.** `policy.guidance` — optional free text: the user's *standing* voice for missions under this policy (conventions, bars, cautions, emphasis). A policy now says three things: how much you trust a run (autonomy), how it ends (Done), and **how it should operate** (guidance). Directive = per-mission intent; guidance = durable intent.

**The authority rule (normative).** Guidance is **standing steering, never a bypass**. It enters exactly the channels the user's *live* steering already enters, and nothing else:

| Channel | How guidance enters | Mock implementation |
|---|---|---|
| Shape inference | Appended to the inference input (like probeContext) — it can *sway* the read; the announce-with-reason → approve pipeline is unchanged, so it can never silently *pick* a shape | `inferShapeFromDirective(directive + " " + guidance)`; re-inference includes it too |
| Plan drafting | Folded into bars/charters; overview records it: `**Standing guidance ({policy}):** …` | overview line (mock); real drafting per Prompt Design §2 |
| Delegation | A "House rules (from the {policy} policy): …" block every delegated agent sees | appended to `userPrompt` (visible in Agent Mode) |
| Child-question interception | Guidance **is mission context** for answerability — it widens what `childAsk:auto` can answer, citing the guidance as the source | Prompt Design §7 input |

**Applied visibly (contract):** when guidance is non-empty, grounding posts a `role:"guidance"` card (`▤ standing guidance · {policy}` + the text verbatim) and the grounding line acknowledges it ("Your {policy} policy's standing guidance applies — I'll fold it into the plan's bars and every delegation."). You always see what standing instructions entered the room — same visibility principle as the shape announcement and the ⚙ cards.

**Boundary examples.** Good guidance: "Run the full suite before any landing step" (bar constraint) · "Prefer minimal diffs" (supervision emphasis) · "Flag public-API changes as a question instead of proceeding" (childAsk escalation rule) · "Anything touching the sync engine should be designed first" (shape-relevant standing steering — sways inference, announced). **Not honored as written:** a phase list ("1. explore 2. build 3. PR") — topology dictation is treated as steering input to the same decisions; the Director still drafts the plan and the invariants (evidence gates, locked irreversible ask, announce → approve) always win. This is the boundary that keeps guidance from resurrecting the deleted "brief."

**Where it shows in UI:** policy editor gains a *Standing guidance* textarea (with the boundary stated in its hint); policy cards show a `▤ standing guidance` chip (full text on hover); built-in **Read-only** ships guidance ("cite file paths and line numbers…; findings only") and the editor prefill ("Overnight perf hunter") demonstrates a guidance + childAsk-escalation combo.

## 8. Swift translation summary

| Piece | Data model | Behavior | Projection |
|---|---|---|---|
| Autonomy map | `mission.autonomy` + `policy.autonomy` (5-class enum map); delete the two booleans | class checks at the seven decision points (§2/§3) | Autonomy menu, editor Decisions row, policy card `asks:` chip, pill |
| Auto-decision log | typed events alongside user decisions | `directorDecides` at every non-advance auto decision; advance counted | ⚙ cards, two-sided stat, grey strip pill |
| Child questions | `childAsk` payload on the runtime question event | interception decision (answer-from-context vs escalate **with a suggested answer** — never a bare question); see `Director_Prompt_Design.md` §7 | childq card, childAsk checkpoint, composer answer path |
| Seeded examples | demo scaffolding only | boot-time generation via real drafting (keep the never-drift property) | Examples rail |
| Standing guidance | `policy.guidance` + `mission.policyGuidance` snapshot | injected at the four channels in §7 (inference, drafting, delegation, interception) — never elsewhere | guidance card in grounding, editor textarea, `▤` card chip, overview line |

Prompt contracts for every behavior above live in **`Director_Prompt_Design.md`**. Demo-narration deltas live in `Mission_Demo_Scripts.md` (v2.4 sections).
