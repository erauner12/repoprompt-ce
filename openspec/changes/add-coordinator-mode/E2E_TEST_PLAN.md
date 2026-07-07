# Director Mode — Live E2E Test Plan

Runner: an agent (Codex) driving three probes — (1) the app's `coordinator_chat` MCP
(**[verify]** exact op names: start mission / mission_status compact / wait_for_update),
(2) shell in a **sandbox repo** for git/filesystem truth, (3) computer-use screenshots at
named beats for presentation. **Principles:** assert invariants, never transcripts;
deterministic substrate (mechanical marker-file tasks; directives pin the decomposition
shape — we test the machinery, not the model's coding); `wait_for_update` is the sync
primitive (a hang = fingerprint regression, itself a finding); every scenario ends with
teardown assertions (repo state exact, sessions cleaned, mission terminal).

First automated slice: ship the reusable runner and automate **S1 + S2**. S3-S8 remain
planned follow-ups until the harness/reporting shape is proven against live missions.

## Sandbox substrate
A throwaway repo (`e2e-sandbox`) added as a workspace root. Tasks are trivial and
verifiable: create/read marker files. Reset between scenarios (`git clean -fdx && git
checkout .`), assert clean before each run.

## Scenarios

**S1 — Read-only investigation (Auto · Director-answers).**
Directive: inspect docs, report one candidate; Read-only policy.
Ledger: ≥1 explore child launched (routing decision recorded); every Done node carries
evidence; receipt `Needed you 0`; mission Completed. Git: zero diffs in all roots; no
commits/pushes. UI beats: strip shows running≥1 then Completed; ⚙ cards present; queue
badge stays 0.

**S2 — Parallel fan-out + convergence (the W1 flagship; Careful writes · Auto).**
Directive: "Two independent steps: create `A.md` and `B.md` (own worktrees). Then a third
step, after both, verifies both exist and writes `SUMMARY.md`."
Ledger invariants: some poll shows **running = 2 simultaneously**; converging node
`deps_satisfied=false` until BOTH parents Completed; it enters `ready_node_ids` exactly
then; **it launches with no user input** (auto-pickup); fingerprint advanced across the
transition; running ≤ cap at every poll. Git: exactly A.md, B.md, SUMMARY.md in expected
worktrees/branches. UI beats: `running 2/3`; the waiting-on line ticking `A ✓ · B …`;
converged launch entry.

**S3 — Cap discipline (Auto).** Four independent marker tasks, cap 3.
Invariants: observed running never exceeds 3 at any poll; the fourth node launches only
after a completion; total completions = 4.

**S4 — Step pace + checkpoint loop.** S2's directive at Step.
Invariants: after plan approval, a boundary checkpoint exists; **Decisions badge = 1**
and the queue item's identity derives from `(missionID, kind, planRevision)`; nothing
launches while pending; Proceed launches exactly the ready set and records a
**user-actor** decision (deterministic ID); a plan revision at approval yields a **new**
queue-item identity. UI: queue card anatomy; click-through lands at the checkpoint.

**S5 — childAsk both ways.** Directive instructs the worker to ask which of two marker
names to use. Run twice: **Me** → pending interaction appears, queue = 1, answer flows,
child proceeds, no ⚙ for the answer; **Director** → runtime answers, ⚙ decision with
question+answer evidence, queue stays 0.

**S6 — Mid-run dial flip.** Start Step; flip pace → Auto mid-mission.
Invariants: snapshot pace mutated, revision bumped, fingerprint advanced; user-actor
"set pace to Auto" decision recorded; **a pending checkpoint is not consumed** by the
flip; later boundaries auto-continue. UI: `Policy · … · edited` marker appears.

**S7 — Stop semantics.** Stop mid-run.
Invariants: user-actor stop decision; cancel routing decision(s) for active children;
status **Stopped**, never Failure styling; terminal UI shows the single follow-up action
and no live composer/dials.

**S8 (manual/optional) — Stall telemetry.** If reproducible, confirm
`eligible_nodes_idle` appears in warnings and never in the Decisions queue.

## The watch-for list (what "working" means)
Ledger layer: plan recorded with policy snapshot **equal to what was sent**; node
statuses monotone (Pending→Running→Completed, or Blocked/Cancelled with reasons); every
Done node has evidence; decisions carry correct **actors** (user only from app paths);
`ready_node_ids`/`deps_satisfied` always consistent with statuses+edges; fingerprint
advances on every observed change; receipt totals match the decision log.
Side-effect layer: only the artifacts the directive names; clean trees under Read-only;
no pushes/PRs ever (sandbox has no remote by design).
UI layer: strip rollup matches ledger counts; queue badge = pending asks only; capsules
only on state; terminal calm (single action, muted history).

## Packaging
Ship as a skill (`.agents/skills/rpce-director-e2e/`): one runner with scenario switches
emitting a pass/fail report **plus the mission's own receipt-ready summary** as the
artifact — the receipt is half the evidence by design. The runner uses progress-aware
deadlines: a generous hard ceiling plus a shorter no-progress window. Slow-but-alive
work can continue; idle missions with no running work fail with the last compact/full
status, warnings, and artifact path.

## Expansions (from the first live S2 runs, 2026-07-06)

**Findings that drove these:** a writer child created `A.md` in its isolated worktree
while canonical saw only `B.md`; the Coordinator autonomously detected the gap,
materialized the missing in-scope file, **steered the existing verifier instead of
respawning**, and closed cleanly — but the fixed 90s boundary timeout called it a
failure mid-recovery.

1. **Progress-aware deadlines (replace fixed timeouts).** Fail on a *no-progress window*
   (N seconds with no fingerprint advance AND no Running children AND ready nodes
   pending — the harness adopts `eligible_nodes_idle` semantics as its own failure
   oracle), plus one overall hard ceiling. Slow-but-alive (recovery, long children) must
   never fail; genuinely stalled must fail fast.
2. **Worktree-aware artifact assertions + discipline invariant.** Every artifact
   assertion states WHERE: child worktree, canonical root, or post-land. New standing
   invariant: under fresh-worktree strategy, the canonical root stays clean until an
   explicit land — a child writing canonical directly is a violation. Split S2:
   **S2a** asserts artifacts in worktrees + convergence verifying across them;
   **S2b** (when landing is in scope) asserts canonical only after land.
3. **S9 — Recovery as a deliberate scenario.** Engineer a gap (verifier expects a file
   that won't exist at its location); assert: detection via evidence, **steer-not-respawn**
   (routing decision targets the existing session), recovery evidence recorded, clean
   close. Recovery duration becomes a measured metric, not a timeout guess.
4. **Run bundles on every run.** JSONL of every compact status at each fingerprint wake
   + receipt Markdown + git snapshots + screenshots + timings (time-to-plan,
   time-to-fanout, time-to-convergence, recovery duration). Enables replay debugging,
   cross-version regression diffs, and latency baselines.
5. **Continuous invariant watcher.** On every wake, validate: running ≤ cap; status
   monotonicity (needs the JSONL history); `deps_satisfied` consistency; decision actor
   integrity; terminal nodes gain evidence within one revision. Violations are recorded
   with the offending snapshot attached.
6. **Statistical pass rates.** `--repeat N` (3–5): report pass rate per scenario and
   which invariant flakes; tag runs with the runtime model so regressions attribute to
   model vs app.
7. **Tier split.** Ledger + filesystem tiers run headless and often; computer-use UI
   beats become an optional `--ui` tier for release checks.
8. **Chaos tier (later): S10** kill a child mid-run → coordinator observes the terminal
   event, marks the node blocked/cancelled with reason, re-steers or asks per policy,
   never silently stalls. **S11** app restart mid-mission → follow-through state and
   mission_status reconstruct ("the mission survives the worker" gets its test).

## Harness slice accepted (2026-07-07)

The first extension-ready runner pass keeps today's snapshot contract but adds adapters
for future `coordinator_chat` ops:

- `--events-mode auto|snapshot|required`: builds without `mission_events` derive
  `status_history.jsonl` from `mission_status`; builds with `mission_events since_seq`
  write `events.jsonl` and make S2 assert exact ready → running → completed ordering.
- `--receipt-mode auto|summary|required`: current Swift builds can write `receipt.md`
  through `receipt format=markdown`; `summary` preserves the lightweight
  `receipt_ready_summary.json` fallback.
- `--idle-timeout-seconds`, `--repeat`, and `--clean-sandbox` make S1/S2 usable as
  repeatable diagnostics without hiding stalls as model slowness.
- Each run emits capability, timing, status-history, and invariant-violation artifacts.
