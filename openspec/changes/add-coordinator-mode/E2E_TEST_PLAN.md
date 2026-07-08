# Director Mode — Live E2E Test Plan

Runner: an agent (Codex) driving three probes — (1) the app's `coordinator_chat` MCP
(**[verify]** exact op names: start mission / mission_status compact / wait_for_update),
(2) shell in a **sandbox repo** for git/filesystem truth, (3) computer-use screenshots at
named beats for presentation. **Principles:** assert invariants, never transcripts;
deterministic substrate (mechanical marker-file tasks; directives pin the decomposition
shape — we test the machinery, not the model's coding); `wait_for_update` is the sync
primitive (a hang = fingerprint regression, itself a finding); every scenario ends with
teardown assertions (repo state exact, sessions cleaned, mission terminal).

First automated slice: ship the reusable runner and automate **S1 + S2**. Current live
plateau targets S1, S2, S4, S5, S6 (pace, ask→auto, auto→ask), and S7. S3's cap promise
is an always-on invariant watcher unless a future cap-specific bug justifies a standalone
scenario; S8 restart durability is documented and deferred.

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

**S3 — Cap discipline (global invariant, not a default live scenario).**
The standing watcher asserts observed running never exceeds cap at every poll. If a
cap-specific regression appears, add a focused four-independent-node scenario; otherwise
fold "the fourth launches only after a completion" into S2 or the watcher instead of
minting another live run.

**S4 — Step pace + checkpoint loop.** S2's directive at Step.
Invariants: after plan approval, a boundary checkpoint exists; **Decisions badge = 1**
and the queue item's identity derives from `(missionID, kind, planRevision)`; nothing
launches while pending; Proceed launches exactly the ready set and records a
**user-actor** decision (deterministic ID); a plan revision at approval yields a **new**
queue-item identity. UI: queue card anatomy; click-through lands at the checkpoint.

**S5 — childAsk both ways.** Directive instructs the Coordinator to give a normal explore
child Agent Mode session an exact, deliberately simple tool-level prompt: call its
structured user-input MCP tool now (`ask_user` in RepoPrompt CE; `request_user_input` only
if `ask_user` is not advertised in another environment), ask which of two marker names to
use, wait for the pending interaction to be answered, report the selected marker, and stop.
The child prompt must not explain Mission Policy or Me/Director routing; the
parent/Director owns answer routing and attribution. Run twice:
**Me** → pending
interaction appears, queue = 1, answer flows, child proceeds, no ⚙ for the answer;
**Director** → runtime answers, ⚙ decision with question+answer evidence, queue stays 0.
If the child reports `S5_USER_INPUT_TOOL_UNAVAILABLE`, classify the run as a child-backend
capability gap: the selected backend cannot create structured pending user input, so S5/S6
must use a backend or scripted child that advertises `ask_user`/`request_user_input`.
For deterministic correctness runs, pass `--child-model-id scripted`. The Coordinator must
copy the exact scripted contract line into the child prompt; the hidden scripted child then
creates a real `AgentAskUserInteraction` and completes with
`SCRIPTED_CHILD_V1 answer=Alpha token=<TOKEN>`. The harness asserts that completion form,
not just the directive echo. Default live-child S5 remains a model/backend negotiation
sample and should only be treated as a Coordinator failure when the selected backend
actually advertises structured input.
Drive Me/Director headlessly through
`coordinator_chat set_autonomy` with `autonomy_class:"childAsk"` and `mode:"ask|auto"`;
the op itself is a user-channel parity action and must record only the dial-change
decision, not an answer to an already-raised child question.
Current executable `s5` runs both variants in sibling run bundles and flips pace to Auto
before approval so the child can launch without a Step boundary. The Ask branch asserts the
pending child question is observed and external submit routes to `child_interaction`; the
Auto branch asserts no user-facing pending child question is observed and requires a director
childAsk decision plus Alpha evidence at completion. Each variant carries a unique marker
token, must show a fresh `agent_run.start` route and completed-node child binding, and the
Ask/Auto child session and interaction IDs must be disjoint so copied evidence cannot pass.

**S6 — Dial flip semantics.** Three slices. Pace is non-consuming: start Step; flip pace →
Auto through `coordinator_chat set_pace` while approval is pending.
Invariants: snapshot pace mutated, revision bumped, fingerprint advanced; user-actor
"set pace to Auto" decision recorded; **the pending approval checkpoint remains**. ChildAsk
is immediate-reroute: start with `childAsk:ask`, wait for a real pending child question,
flip `childAsk:auto` through `coordinator_chat set_autonomy`, then assert the same
interaction is answered by Director. Invariants: same interaction id; flip user decision
precedes Director childAsk decision; no Director answer predates the flip; exactly one
childAsk answer/evidence pair lands; receipt actor chain reads user flip → Director answer.
The third slice covers the asymmetric reverse: `auto→ask` escalates immediately and beats
any in-flight Director answer; the pending interaction remains stable and user-visible.
The executable scripted slice starts with a hidden auto-routed pending question, flips to
Me, asserts the same interaction reappears in Decisions, answers through the external
child-interaction path, and requires no Director childAsk decision for that interaction.
Runtime callers must be rejected from `set_pace`/`set_autonomy`; runtime child-interaction
submits are rejected while resolved `childAsk` is `ask`. UI: `Policy · … · edited` marker
appears. Backlog edge: ask→auto→ask→auto should re-fire only when a fresh pending child
question still exists; do not let event dedup suppress a legitimate second auto reroute.

**S7 — Stop semantics.** Stop mid-run.
Invariants: user-actor stop decision; cancel routing decision(s) for active children;
status **Stopped**, never Failure styling; terminal UI shows the single follow-up action
and no live composer/dials.

**S8 (deferred) — Restart durability.** Relaunch the app mid-mission with a pending
checkpoint or pending child question. Invariants: mission reconstructs from durable state;
pending ask remains pending; ledger/fingerprint history stays coherent; no duplicate
follow-through event fires; queue does not consume or re-mint identity because of restart.

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

## Scenario Governor

Scenario count tracks doctrine count, not bug count. A new live scenario is added only
when a new doctrine entry is pinned in `DIRECTOR_DECISIONS.md`; ordinary regressions found
by live runs get deterministic flow-layer coverage at the lowest faithful layer. The
remaining live breadth is bounded: S4 (revision/remint identity), S7 (stop honesty), and
S6's auto→ask escalation slice. Tooling friction (`doctor`, `list_missions`,
`archive_mission`) and the scripted child backend improve reliability but do not expand
the doctrine surface.

## Shared Contract Fixture

Pure Python harness tests load `Scripts/Fixtures/director_e2e_compact_status.json` as the
base compact-status shape, and Swift checks the fixture's core keys. The fixture is a
contract skeleton, not a replacement projector: live runs still read `mission_status`
directly from `coordinator_chat`, while unit tests stop hand-mirroring the response
surface from scratch.

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
   never silently stalls. Restart durability is tracked as deferred S8 above.

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
