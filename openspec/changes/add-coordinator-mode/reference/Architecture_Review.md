# Architecture Review — Director Mode mock v3.22, pre-implementation

*Audit of the mock + specs against all community feedback (wren, naj, aAtila, camsoft, pvncher, Ryan, Moonray) and against a Swift implementer's first month. Verdict up front: the **control-plane doctrine is sound and validated** — the gaps are all in what happens when things go wrong, cost money, or restart.*

## What's confirmed solid (don't touch)

- **The two-dial trust model** — wren asked for it, the strip converged on it independently, and the mid-run-flip demo makes it teachable. Ship as designed.
- **Shape inference from directive language** — aAtila's flow fit with zero machinery changes (PRD Slices = fixture + one regex), which is the strongest evidence the node/workstream/after model is the right substrate. Multi-parent `after` composing with per-slice chains (v3.22) proves ordering + parallelism coexist.
- **The queue-never-lies doctrine + one-question-two-surfaces** — this is the product thesis and it's coherent end to end (standalone asks, childAsks, held sessions, ambient badge).
- **Evidence bars with reworkScope re-opening** — matches Moonray's independently-evolved Backlog culture ("a report is a claim"); the community already believes this.
- **Sessions-as-working-memory / mission-as-durable-record / archive-as-view-flag** — clean, and it pre-answers half of the persistence question.

## The gaps

### Severity 1 — change the mock now (they change doctrine, and doctrine changes are cheap now, expensive later)

**G1. The Director's judgment is itself a claim — and currently unfalsifiable.**
Every ⚙ auto-decision (answered a worker, accepted evidence, re-steered a bar miss) is final. There is no overrule. But the Director is an LLM: its evidence judgments and drafted answers will sometimes be wrong, and the human watching the thread has no recourse except Stop. This breaks the mock's own principle ("auto is never silent") one level short — *auto must also never be final*. **Change: every ⚙ card gets an Overrule action** → converts the decision to yours, steers the affected session with your correction, and the receipt records both (the Director's decision *and* your overrule). Receipt schema impact is why this must land before Swift.

**G2. No concurrency bound — now load-bearing after PRD Slices.**
Parallel chains schedule freely; nothing limits simultaneous sessions. Moonray's Backlog caps its flight set at 3 for good reasons (rate limits, machine load, reviewability), and pvncher's root-caching concern is the same constraint from the maintainer's side. **Change: `maxConcurrent` on the policy (default 3), scheduler respects it, strip shows `running 2/3`.** Trivial in the mock; structural in Swift.

**G3. Failure is unmodeled — the Blocked lane has never had an occupant.**
Real sessions crash, hang, hit limits, and return garbage. The mock's every session succeeds or waits. This is the first thing a Swift implementer hits and the first thing camsoft's fear list is actually about. **Design (mock beat, arm-gated so it can't pollute the committed video):** a delegated session fails mid-step → the Director retries once, ⚙-carded ("restarted the worker — attempt 2 of 2") → second failure → session enters **Blocked**, mission raises a decision (kind **Unblock**: *Re-delegate fresh session / Skip this step — recorded / Stop the mission*). Doctrine line: *the Director absorbs the first failure; the second one is yours.* Implement after the Trust-Mid-Run recording; the schema (retry count, failure reason, Unblock decision kind) goes in the spec now.

### Severity 2 — spec commitments required before Swift (no mock UI needed)

**G4. Budget is declared but dead.** `budget: null` on every policy, while the flagship Hands-off demo is an *overnight run* — exactly where runaway burn happens. Commit: per-mission budget (tokens and/or wall-clock) as a policy field; **breach is a checkpoint, not a silent stop** (options: raise the budget / wind down cleanly / stop). This is also the single highest-credibility feature for the maintainer's perf-and-cost lens.

**G5. The Director's context contract is unspecified — and it's THE implementation decision.** What does the Director see when judging evidence or drafting an answer? Full transcripts recreate camsoft's context-pollution objection; summaries are lossy. Commit the contract: the Director sees, per node, `{done bar, returned evidence, last N transcript lines, diff stats, question text}` — never full transcripts by default; it may *escalate* ("open the session") and every escalation is logged in the receipt. This bounds Director context growth to O(nodes), not O(tokens spent).

**G6. Restart/resume.** Overnight missions guarantee the app restarts mid-mission. Commit: mission state (plan, decisions, evidence, receipt) is durably persisted on every transition; on relaunch, sessions are re-attached where the backing process survives, else declared **failed** and routed through G3's failure path. No third state.

**G7. Attribution completeness.** Decisions answerable from two surfaces (and soon overrulable) need the receipt to record *channel*: `{decision, actor: you|director, surface: mission|session, overruled?: by-you}`. One line in the schema now saves an audit-trail migration later.

### Behavioral tightenings (small, spec-level)

- **Hub freeze:** once any slice chain starts, the hub's outputs (the slicing) are frozen; reshaping the decomposition is a splitProposal-class checkpoint, not a Revise.
- **Inference generalization:** ordering language ("after", "depends on", "only when X is done") should produce dependent chains even without the literal word "PRD" — currently keyed too narrowly. Post-video.
- **Fresh-eyes knob:** re-review steers the same session (pinned); consider a policy option for a *fresh* reviewer on the final combined review only. Note, don't build.
- **Queue aging:** urgency ints exist; no starvation story. Note only.

## Recommended sequence

1. **Now (mock v3.23):** G1 Overrule + G2 concurrency cap — both small, both doctrine, both harness-pinned.
2. **Now (docs):** this review + spec sections for G3–G7 → these become the Swift preflight's contract pages.
3. **After recording Trust-Mid-Run:** G3 failure beat in the mock (arm-gated), because demoing *"watch it fail and watch what the Director does"* is the single best answer to camsoft's fears — likely Video 4.
4. **Swift phase gate:** no implementation starts on a subsystem whose G-item lacks a spec section.


---

# Round 2 — post-source-read gaps (v3.24 era)

*Status of round 1: **G1 (overrule)** and **G2 (flight cap)** implemented in mock v3.23. **G5 (context contract)** closed — Director_Context_Contract.md is buildable-from-source, and mock v3.24 demos it (bundle disclosure, {label, description} options, the read-only probe). **G3 (failure path)** designed, staged post-video. **G4 (budget), G6 (restart), G7 (attribution)** remain spec commitments. Reading the upstream source surfaced four new items:*

**G8. Permission approvals under delegation — a third input class we never modeled.**
Real sessions raise *permission approvals* (run this command, edit outside the worktree — the "Permissions · Auto Review" surface visible in the shipping app), and upstream's `Interaction.Kind` includes `approval` natively. The mock's trust model has two dials (pace, questions) but no story for a delegated worker's permission prompt. Commit: the mission **policy sets each delegated session's permission mode at spawn**; anything that still escalates lands in the Decisions queue as its own kind (**Approve**), and — like merges — **approvals never auto-resolve by default** at any trust level. This is a safety surface, not a convenience surface.

**G9. The questions dial has a concrete mechanism: `ask_user` rerouting.**
Upstream sessions ask the human via the `ask_user` tool (`MCPWindowToolNames.askUser`). Under mission delegation, the childAsk interception isn't magic — it's **caller-identity-based tool behavior**, the exact pattern `AgentExploreMCPToolService` already uses for depth: when the caller is a mission-delegated session, `ask_user` routes to the Director channel and resolves per the Me/Director dial. Spec this as the implementation of the dial; it also guarantees workers can't accidentally bypass the queue.

**G10. Interactions are richer than one question.**
Upstream `Interaction` carries `user_input` with **multi-field forms** (`Field[]` with options, `allowsMultiple`, `allowsCustom`, `isSecret`) and responseTypes `structured`/`decision`. The mock and queue model single-question asks. Commit a mapping table — Interaction.Kind → Decision kind (question→Answer, approval→Approve, user_input→Fill, elicitation→Answer) — and require the queue to render multi-field forms. `isSecret` fields must never transit the Director's ledger (route to the human only).

**G11. Handoff extraction runs tool-side, never in Director context.**
Evidence rides `extract_handoff` — but the *extractor* consumes transcript text. If the Director calls it and reads raw output, transcripts re-enter by the back door. Commit: extraction is a **tool-side operation** (or probe-class call) whose only Director-visible output is the structured `MissionEvidence` DTO. Sharpens Contract §5.

**G12. Role→model routing and judge tier.**
`MCPAgentRoleDefaultsService` gives per-role model defaults upstream. Missions multiply sessions × flight cap × models; the policy should either inherit role defaults or carry overrides, the **judge's model tier** must be chosen deliberately (judgments are small — a cheap tier is defensible), and all of it feeds G4's budget accounting (including workers' own oracle spend).

*Behavioral tightenings carried forward unchanged: hub freeze after chains start; ordering-language inference beyond the literal "PRD"; optional fresh-eyes final review; queue aging. None block the video or the Swift preflight.*
