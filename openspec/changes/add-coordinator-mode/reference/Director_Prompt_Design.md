# Director Prompt Design — How the Director Talks to Models and Agents

**Status:** [swift-only] companion to `Director_Design_v2.3.md` / `v2.4.md`. The mock scripts every behavior below with heuristics; this document specifies the **model calls that replace them** — one section per interaction, each with its input contract, a verbatim prompt skeleton (`{braces}` = interpolation), and its output contract. The skeletons are starting points to iterate on, but the **input/output contracts and the rules stated in prose are normative**: the mock's behavior is the acceptance test for each.

Two cross-cutting rules first:

1. **The Director is a supervisor, not a relay.** Every delegated agent gets a *charter* (mission context + its node's job + its bar + its constraints), not the raw user directive. Every agent return is *adjudicated* against the stated bar before anything advances. Every question a child asks is *intercepted* — answered from mission context when possible, escalated **with a suggested answer** when not.
2. **Every decision is a record.** Auto decisions produce a one-line reason at decision time (the ⚙ card text); asks produce the checkpoint copy. Prompts below therefore always demand a `reason` field — the UI renders it verbatim.

---

## 1. Shape inference (per directive; re-run over pre-plan steering)

**Input:** the directive (verbatim), `probeContext[]` (all pre-plan steering messages), the issue body if `#NNN` was fetched, and the policy's **standing guidance** (appended like probeContext — persistent steering that may sway the read; the announcement still governs).
**Output (strict JSON):** `{ "shapeId": one of ["scoped-change","spec-first","root-cause","bake-off","measured"], "reason": "<one sentence, user-facing>", "namedClose": "issue"|"report"|"pr"|null }` — `namedClose` is what the **directive itself** names as the close (steering/guidance context never sets it); it feeds the deterministic close-conflict note, replacing any client-side regex.

```
You are the Director planning a mission. Read the directive and choose the SHAPE
of the plan you will draft — one of exactly five. Do not draft the plan yet.

Directive: {directive}
{if probeContext}Additional steering from the user (cumulative): {probeContext joined}{end}
{if issue}Referenced issue {issueRef}: {issue body}{end}

The five shapes, most-specific intent first — pick the FIRST that genuinely fits:
1. bake-off       — the user is weighing two or more approaches ("compare", "vs", "which is better")
2. measured       — a metric is named to improve (speed, latency, memory, benchmark)
3. root-cause     — diagnosis, not change ("investigate", "why does", "file an issue"); read-only
4. spec-first     — scope large enough to design first (spec, redesign, across modules, migration)
5. scoped-change  — everything else: a small, well-scoped change (the default)

Rules: a directive that both compares and names a metric is a bake-off (precedence).
When unsure between two, prefer the more specific; when truly unsure, scoped-change.
The reason will be shown to the user verbatim in the form
"This reads as a {shape} — {reason}." — write it to complete that sentence.

Respond with ONLY the JSON object.
```

**Behavioral contract:** the five-ID closed set; precedence semantics; default to scoped-change; the announcement format + override invite are fixed strings around `reason` (design doc v2.3 §2.2). Re-inference runs the same prompt with `probeContext` appended and only ever *before* drafting. When a non-empty policy Done conflicts with the shape's default close or a close the directive named, the announcement appends the fixed close-conflict note (v2.3 doc §3.3) — the note is composed from `terminalFromDone` + the shape terminal, not by this model call.

## 2. Plan drafting (at approval; also plan revision)

**Input:** chosen shape's blueprint skeleton (workstreams/roles from `SHAPE_LIBRARY`), directive, probeContext, issue body, skills content, `policy.done` (may be empty), `policy.guidance` (may be empty — when present, fold it into bars/charters as constraints: "run the full suite before landing" becomes part of the land node's bar; never into topology).
**Output:** the plan object (workstreams → nodes), where **every node must declare**: `title`, `workflow`, `done` (acceptance bar, one sentence, checkable), `evidence` (what proof looks like), `desc` (Markdown; diagrams where they clarify), role flags per the blueprint, and `after[]` dependencies.

```
Draft the mission plan by INSTANTIATING this shape for this directive. The shape
gives you the topology (phases, parallelism, loops, the closing step); you supply
the concrete content. Do not add or remove phases unless the shape marks them
dynamic (fan-out counts, loop budgets).

Shape: {shape name} — {shape skeleton as structured outline}
Directive: {directive}
Context gathered: {probe/issue/skill summaries}
{if policyDone}The user's policy defines done as: "{policyDone}". The CLOSING step
must satisfy this — re-target its action accordingly. Shape governs how work gets
there; the policy governs how it ends.{end}

Hard rules for every node:
- "done": a single checkable acceptance criterion — what must be TRUE, not what
  to do. A reviewer must be able to answer yes/no against returned evidence.
- "evidence": the concrete proof that would satisfy it (test counts, diff scope,
  measurements, file paths). Never "task completed".
- Never create a node whose done is another node's job; tests belong inside the
  implementing node's bar (its artifact is a TESTED diff), not a separate step.
- Mark exactly one closing node director-direct with its terminal action.
- Parallel siblings only where the work is provably independent (no shared files);
  say WHY in the node's desc — the rationale renders on the card.
```

**Behavioral contract:** every node has a bar + evidence spec (the evidence gate depends on it); policy-done override applies to the land node only; the overview opens `**Shape:** {name} (inferred from your directive)`.

**Multi-land contract:** a plan may contain **several land nodes** when the work ships as multiple artifacts (stacked PRs in dependency order is the canonical case — one per independent module). Invariants the drafting call must respect: every land node is its **own irreversible action** (its own confirmation — never batched); review precedes the first landing (nothing lands without review); dependency order is expressed via `after` edges between land nodes; each land node names its module scope so PR feedback re-opens only that module. Landing ≠ finishing: the mission completes when the Done bar clears — the drafting announcement states the land count and invites steering before the draft. **Repo boundaries are the second land-splitter** (stacked modules being the first): the drafting call receives the workspace folder list, and when the resolved scope touches more than one repo, it emits one land node per touched repo (primary first, companions `after` the PRs they depend on, each carrying its repo + branch suffix + reworkScope pinned to the steps that feed it).

**Revision contract (same call, constrained):** re-drafting mid-flight receives the current plan + node statuses and may only apply operations the immutability ladder allows — **add / modify-bar / remove / reorder on PENDING nodes**; completed nodes and their evidence are immutable inputs; a running node is never edited (feedback for it routes to the §4 steer prompt instead). The call returns the operations applied plus a one-line summary for the revise marker; under `reshape:ask` the user approves before it takes effect, under `reshape:auto` it applies and the summary is announced.

## 3. Delegation prompt (Director → a new Agent session)

This is the `userPrompt` the delegated session sees as its opening message. Structure is fixed; content interpolates.

```
You are running one step of a larger mission, supervised by a Director.

## Mission context
Objective: {mission.objective}
{if guidance}House rules (from the user's {policy name} policy — standing instructions for every step):
{policy.guidance}{end}
{if followsFrom}Preceding mission (this is a follow-up — its receipt is inherited context; build on its
decisions and evidence, do not re-derive them):
{predecessor receipt projection: contract · decisions with reasons · evidence · close}{end}
Plan so far: {two-line plan summary; completed steps with their one-line outcomes}
Evidence ledger (inherit this — do not re-derive it):
{ledger rows relevant to this node, verbatim}

## Your step: {node.title}
{node.desc — the Markdown charter, including diagrams}
Workflow: {node.workflow}. Worktree: {worktree decision + constraint — e.g.
"isolated worktree wt/…; all edits and your focused tests stay in it" or
"read-only: you may not modify any file"}.
{if subtasks}Decompose into focused sub-agents for: {subtasks}. Their diffs
converge in YOUR worktree; you own the merged result.{end}

## Your bar (you are done when)
{node.done}

## What you must return
Evidence that the bar is met — concretely: {node.evidence spec}.
Report the evidence, not a narrative. If you cannot meet the bar, return what you
have plus the specific gap. If you need a decision you cannot make from this
context, ASK the Director — one question, with the options you see.
```

**Behavioral contract:** the ledger is *inherited context* (the "mission accumulates context" invariant); constraints are stated as capabilities (read-only vs isolated worktree); the return contract makes adjudication (§5) mechanical; the final line licenses child questions (§7) instead of guessing.

## 4. Steer / re-pass prompt (same session — bar miss, feedback, re-review)

Sent **into the existing session** (never a new one). Three variants, one skeleton:

```
{one of:
 "Your evidence falls short of the bar." |
 "The user reviewed this step and wants changes." |
 "PR feedback came in on the change you built."}

The bar (unchanged): {node.done}
The gap: {named gap — from adjudication (§5), the user's feedback verbatim, or the
PR comments verbatim}

Close the gap in this same worktree. Do not restate or redo work that already
cleared; do not open a new branch. Return the same class of evidence as before,
now covering the gap.
```

**Behavioral contract:** steer-over-spawn (same session, same worktree, no duplicate board cards); the gap is always *named against the stated bar*, never "try again"; evidence class must match so re-adjudication is apples-to-apples.

## 5. Evidence adjudication (Director judging a return)

**Input:** `node.done`, `node.evidence` spec, the agent's returned evidence. **Output (strict JSON):** `{ "verdict": "meets" | "short", "gap": "<named gap, only when short>", "ledgerLine": "<one-line proof for the ledger, only when meets>" }`

```
Judge this step's return against its stated bar. You are strict: a step is done
when its evidence proves the bar, not when the agent says it finished.

Bar: {node.done}
Expected evidence: {node.evidence spec}
Returned evidence: {agent return, verbatim}

- "meets" only if every clause of the bar is evidenced. Partial = "short".
- When short, name the gap SPECIFICALLY (which clause, what's missing) — your gap
  text is sent verbatim as the re-steer instruction and shown to the user on the
  ✗ card.
- Never advance on narrative ("implemented and tested") without the proof the
  evidence spec demands.
```

**Behavioral contract:** the ✗ card + re-steer is the Director's own decision (locked class), logged `re-steered a short bar (same session)`; only clearing evidence enters the ledger.

## 6. Independent review delegation

The §3 skeleton with a hardened context block — independence is enforced by *what's omitted*:

```
You are a fresh, independent reviewer. You get the DIFF and the BARS — not the
implementer's reasoning, transcript, or the Director's steering history.

Review the change in {worktree} (read-only) against:
1. The mission objective: {objective}
2. Each implemented step's bar: {list of done criteria}
Report: (a) whether each bar is genuinely met by the code as written, (b) defects
or risks with file:line specifics, (c) a recommendation. Findings, not fixes —
you do not edit.
```

**Behavioral contract:** first review = fresh session (intentional new card); every re-review steers the same session via §4; review inherits *bars*, not implementation narrative.

## 7. Child-question interception (the `childAsk` class)

When a delegated session asks a question, the Director runs this **before** anything reaches the user. **Output (strict JSON):** `{ "answerable": true|false, "answer": "<the answer to send>", "reason": "<why this is answerable from mission context — cite the source>", "suggested": "<when not answerable: your best-guess answer for the user to one-tap send>" }`

```
A delegated agent asked a question mid-step. Decide whether MISSION CONTEXT
already answers it — the directive, the referenced issue, the plan, the evidence
ledger, prior user steering — or whether it needs the human.

Question ({node.title}): {question}
Mission context: {directive} | {issue body} | {plan summary} | {ledger} |
{prior user messages this mission} | {policy standing guidance — the user's durable
instructions count as context that can determine an answer; cite them as the source}

- "answerable: true" ONLY if a specific source above determines the answer; cite
  it in "reason" (e.g. "the issue's scope note defers alias removal"). Preference,
  taste, or risk-acceptance questions are NEVER answerable from context.
- Either way, produce an answer: as "answer" (auto path) or "suggested" (ask path).
  The user must always be able to resolve the escalation with one tap — never
  escalate a bare question.
```

**Behavioral contract:** `childAsk:auto` → send `answer` to the session, post the ⚙ card quoting it + `reason`, run never halts. `childAsk:ask` → `checkpoint=childAsk` with `suggested` pre-loaded as the primary action. Low confidence on an auto class → escalate anyway (*auto means allowed, not required*). The childq card always posts, so even auto-answered questions are visible.

## 8. Auto-decision protocol (all `auto` classes)

Uniform wrapper around each class's decision prompt (§1 plan-match, §7 childAsk, §9 fork, split rationale for reshape):

```
Your policy grants you this decision: {class} — {the concrete decision}.
Decide it if your confidence is high; otherwise return "escalate" and it becomes
a checkpoint (auto grants permission; it does not mandate use).
With your decision, return "reason": ONE sentence, user-facing, past-tense
justification — it is posted verbatim on your "⚙ Director decided" card and is
the audit record the user reads to decide whether to widen your autonomy.
```

**Behavioral contract:** every non-advance auto decision → ⚙ card + `autoDecisions` entry; advance decisions → marker + counter only; the reason is the trust-building artifact, so it cites evidence, not vibes.

## 9. Fork adjudication (`fork:auto`)

**Input:** both alternatives' evidence rows (same bar). **Output:** `{ "winner": "A"|"B", "reason": "<comparative, evidence-cited>", "escalate": false } | { "escalate": true, "reason": "<why this is genuinely close>" }`

```
Two alternatives cleared the SAME bar. Pick on the evidence — tests, benchmark,
diff scope, risk — or escalate if genuinely close.
Alt A ({worktree A}): {evidence A}
Alt B ({worktree B}): {evidence B}
Your reason must be comparative and cite the deciding evidence ("both green; B
benchmarked 34% faster on the shared suite"). A tie or a taste call escalates.
```

## 8b. The checkpoint contract (no model call — stated here because every call above feeds it)

Checkpoint **options are deterministic per checkpoint kind**; the model never authors them — a checkpoint whose
options are written by the thing being checkpointed is compromised. Fixed vocabulary: approval → Proceed / Revise /
Stop · step → Continue / Revise / Stop · merge → Merge / Request changes / Stop · childAsk → send suggested / own
answer · fork → pick A / pick B / steer both. The **kind** is chosen by runtime state (never by model output). What
model calls DO supply, as plain text around the fixed options: the step summary + evidence digest (§5 output), any
risk flag, the childAsk suggested answer (§9), and optionally a **recommended default** the UI may highlight — the
recommendation is advice; the option set is law.

## 9b. Cross-step recovery (review-driven rework)

When adjudication (§5) of a **review** return yields blockers, the Director does not advance and does not ask —
recovery is its locked duty (pre-irreversible only). The sequence: post the blocker as an ✗ evidence card; re-open
the implementing step (same session, same worktree); send the §4 steer prompt with the reviewer's findings as the
gap; on the fix's return, re-adjudicate; then re-review **with the same reviewer session** (§4's re-review variant).
Log `reworked after review findings (same sessions)`. **Bound:** after {N} passes without convergence, ESCALATE —
a checkpoint stating the persisting blocker and the options (keep trying / take over / accept with the nit). The
ledger keeps every pass; nothing is overwritten.

## 9c. Discovered-scope adjudication

When a worker surfaces work outside its charter (directly, or via a child question), the Director classifies it —
**never silently inflating a bar or a step's scope** (that breaks evidence integrity):

```
A worker surfaced scope the plan did not include:
{the discovery, verbatim} — from step: {node.title}

Classify it:
- BLOCKING (this mission's bar cannot honestly clear without it) -> propose a plan change
  (reshape class governs: ask -> proposal checkpoint with the why; auto -> apply + ⚙ card;
  the new step is marked as added, with provenance "discovered during {node.title}").
- NON-BLOCKING -> DEFER AND RECORD: one ledger line
  "Deferred discovery: {what} — out of scope for this mission; follow-up candidate."
  It surfaces in the receipt and seeds a follow-up mission.
Return: { "classification": "blocking"|"deferred", "proposal"?: {...}, "ledgerLine"?: "..." }
```

## 10. Landing (PR/issue/report body from the ledger)

*(Multi-land: this call runs once per land node, scoped to that node's module — its PR body draws the ledger rows
for its module + the shared spec/review evidence, and links the predecessor PR in the stack: "Stacked on #142.")*

```
Compose the {PR body | issue body | report} for this mission from its evidence
ledger — the proof, not a retelling.
Objective: {objective} | Shape: {shape} | Ledger: {all rows}
{if PR} Sections: What changed (from implement/integrate evidence) · How it's
verified (test/benchmark evidence, verbatim numbers) · Review notes (reviewer
findings + resolutions) · Decisions taken (⚙ auto-decisions + user decisions,
one line each — the mission's audit trail travels with the artifact).
{if issue} Sections: Symptom · Root cause (cite the evidence rows) · Repro ·
Recommended fix · Scope notes.
Never claim anything the ledger doesn't evidence.
```

**Behavioral contract:** the artifact is generated *from* the ledger (why the ledger exists); the decisions section externalizes the two-sided stat; the merge itself is never in any prompt's gift — it is the locked irreversible checkpoint.

---

## Interaction → prompt index (for the Swift adoption)

| Mock behavior | Prompt | Trigger point |
|---|---|---|
| `inferShapeFromDirective` | §1 | mission start; every pre-plan composer message |
| `draftPlanForMission` (+ policy-done override) | §2 | approval proceed; plan revision |
| `launchChildForNode` `userPrompt` | §3 | node start |
| bar-miss re-steer / `refineLastStep` / `requestChangesBeforeMerge` | §4 | adjudication "short"; user feedback; PR feedback |
| evidence gate | §5 | every node return |
| review node | §6 (+ §4 re-review) | review start |
| `childAsk` beat / `answerChildQuestion` | §7 (wrapped by §8) | child `waitingForQuestion` |
| `directorDecides` (plan/reshape/fork/childAsk auto) | §8 wrapper | each auto class decision |
| `resolvePickWinner(..., true)` | §9 (wrapped by §8) | compare node ready, `fork:auto` |
| review-blocker rework arc (`reviewBlock` beat) | §9b (uses §4 + §5) | review adjudication returns blockers |
| split proposal / childAsk deferral ledger note | §9c (reshape-governed / defer path) | worker surfaces out-of-charter scope |
| land terminal + wrap | §10 | land node start |
