# Director Mode — Problem Statement

*One-pager for discussion / GH Projects ticket. Companion to the two demo videos.*

## The problem

RPCE's workflows (Deep Plan, Orchestrate, Review) are good at **one unit of work in one session**. The moment a task is big enough to decompose, the human becomes the orchestration layer:

> "I start with a PRD that acts as a hub, then break it into smaller slices. For each slice my workflow is deep plan → orchestrate → review. Right now I run those slices manually, one at a time, babysitting each one through that loop before moving to the next. It means 3 separate sessions per slice." — aAtila

That babysitting role has concrete costs: you sequence what runs next, you carry the state of every slice in your head, you discover a stuck fix→review loop only when you next look at its tab, and a worker's question stalls its session until you find it. The role doesn't scale past 2–3 threads, and it's exactly the kind of bookkeeping software is for.

## Why an orchestrator session can't be the answer

1. **Depth limits.** A parent agent can spawn a pair agent, which can only spawn explore probes. An orchestrator therefore cannot run a full plan→build→review→fix chain *per slice* — there's no depth left for the fix loop. The Director sits one level up and can spawn orchestrators. (Credit: Eric.)
2. **Context pollution.** Driving N slices from one thread stuffs every slice's detail into one context window. The coordinating role needs summaries and evidence, not diffs.
3. **A transcript is not a control surface.** Approvals, worker questions, and failures inside a long transcript have no queue, no audit trail, and no guarantees. "Anything irreversible always asks" cannot be enforced by prompt discipline alone.

## What Director Mode is

An **observability and control layer for meta-orchestration** (wren's framing). A second surface (⌘2) over existing Agent Mode (⌘1):

- **Missions** — a directive whose *words choose the plan's shape* (a PRD with slices → per-slice plan→build→review chains; a metric → a measured loop; "investigate" → read-only root-cause). You approve the plan before anything runs.
- **Evidence gates** — every step has a "done when" bar and must return evidence that clears it. A delegate's report is a claim, not evidence. A review can re-open an earlier step; a non-converging fix loop comes to you as a decision instead of burning tokens overnight.
- **One Decisions queue** — every input request lands there, whether the mission surfaced it or a session raised it. Nothing waits inside a tab you have to find.
- **Two dials** — pace (step/auto) and who answers worker questions (me/director), changeable mid-run. Plan approval and anything irreversible (merges) always ask in the current design — default-safe, not dogma.
- **A receipt** — every decision, yours or the Director's, in one audit trail per mission.

The skills/prompts still produce all the actual work. The Director is another prompted role deciding what runs next; **the app owns the checkpoints and the paper trail.**

## Who it's for (and who it isn't)

- The moment a single task is big enough to decompose — most non-trivial work (aAtila's PRD flow is the canonical story).
- Parallel investigations / bug fixes / PR reviews-with-fixes, typically 2–3 threads (Eric's use), each in its own worktree.
- Prior art inside this community: Moonray's **Backlog** workflow already implements this shape as prompt discipline — triage → readiness gates → ≤3 concurrent worktree'd Loop subagents → independent verification → close via a ledger. Director Mode is that pattern with app-owned guarantees and a UI (board, queue, receipts) instead of hooks and reminders.
- It is **not** for people who prefer strictly serial work — Agent Mode is unchanged, and Director is a separate mode (like the old IDE/Agent toggle) precisely so it never complicates the default experience.

## Non-goals (v1)

- Cross-workspace views (root-caching overhead; workspace stays the central instance).
- Auto-merge at any trust level.
- Replacing existing workflows — it composes them.

## Current state

Interactive HTML mock (single file, open in a browser) + demo videos 1–2; design docs and a test harness (378 assertions) alongside. Swift implementation phase follows community validation of the concept.
