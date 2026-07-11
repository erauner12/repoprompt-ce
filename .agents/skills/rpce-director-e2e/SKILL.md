---
name: rpce-director-e2e
description: Run live RepoPrompt CE Director/Coordinator mission end-to-end validation through rpce-cli-debug. Use when validating coordinator_chat start_mission, mission_status, wait_for_update, Director Mission plans, read-only completion, parallel fan-out, dependency convergence, receipt summaries, and UI-supporting live Mission behavior.
---

# RepoPrompt Director E2E

Use this skill to run live Director mission scenarios against a visible RepoPrompt CE debug app. The runner dogfoods the app's own MCP surface: `coordinator_chat start_mission`, `mission_status compact`, and `wait_for_update`.

## Quick Start

From the repo root:

```bash
.agents/skills/rpce-director-e2e/scripts/director_e2e.py --scenario s1 --workspace homelab-garden --window 1
```

For the writable convergence scenario, pass a sandbox repo that is already visible to the selected workspace:

```bash
.agents/skills/rpce-director-e2e/scripts/director_e2e.py --scenario s2 --workspace homelab-garden --window 1 --sandbox-root /path/to/director-e2e-sandbox --clean-sandbox --events-mode required --receipt-mode required
```

For the Step/Auto user-action parity check:

```bash
.agents/skills/rpce-director-e2e/scripts/director_e2e.py --scenario s6 --workspace homelab-garden --window 1 --events-mode required
```

For the Me/Director child-question parity check:

```bash
.agents/skills/rpce-director-e2e/scripts/director_e2e.py --scenario s5 --workspace homelab-garden --window 1 --events-mode required --receipt-mode required
```

For deterministic childAsk correctness, use the hidden scripted child:

```bash
.agents/skills/rpce-director-e2e/scripts/director_e2e.py --scenario s5 --workspace homelab-garden --window 1 --events-mode required --receipt-mode required --child-model-id scripted
.agents/skills/rpce-director-e2e/scripts/director_e2e.py --scenario s6 --workspace homelab-garden --window 1 --events-mode required --child-model-id scripted
```

For checkpoint revision identity:

```bash
.agents/skills/rpce-director-e2e/scripts/director_e2e.py --scenario s4 --workspace homelab-garden --window 1 --events-mode required --receipt-mode required
```

For stop semantics against a live child, use the hidden scripted child:

```bash
.agents/skills/rpce-director-e2e/scripts/director_e2e.py --scenario s7 --workspace homelab-garden --window 1 --events-mode required --child-model-id scripted
```

For the trusted post-approval revision-proposal narrative:

```bash
.agents/skills/rpce-director-e2e/scripts/director_e2e.py --scenario s8 --workspace homelab-garden --window 1 --events-mode required --receipt-mode required
```

To capture capabilities and clean up a successful run:

```bash
.agents/skills/rpce-director-e2e/scripts/director_e2e.py --scenario s5 --workspace homelab-garden --window 1 --events-mode required --receipt-mode required --doctor-mode required --archive-on-success --child-model-id scripted
```

Use `--scenario smoke` to run S1 then S2. The smoke command requires `--sandbox-root` because S2 writes marker files.

Useful knobs:

- `--idle-timeout-seconds 120`: fail only after no observable progress and no running work.
- `--repeat N`: produce per-attempt reports plus `repeat_report.json`.
- `--events-mode auto|snapshot|required`: use Swift `mission_events` when available; default falls back to snapshot history.
- `--receipt-mode auto|summary|required`: use Swift `receipt format=markdown` when available; default falls back to receipt-ready summary.
- `--doctor-mode auto|required|off`: capture `coordinator_chat doctor` into `doctor.json`; `required` fails early on unsupported apps.
- `--archive-on-success`: after a passing terminal scenario, call `list_missions`/`archive_mission` and verify mission status, events, and receipt remain readable by id.
- `--child-model-id explore|scripted|...`: choose the child model used by S5/S6 childAsk scenarios. `scripted` is hidden debug/E2E infrastructure and must emit `SCRIPTED_CHILD_V1 answer=Alpha token=<TOKEN>`.
- `--coordinator-model-id engineer|design|...`: choose the fresh Coordinator runtime's underlying model for a cheap regression-tier batch. Omit this for the default headline negotiation tier.
- `--clean-sandbox`: clean a known throwaway Director E2E sandbox before writable scenarios.

Cheap regression-tier batches should record their Coordinator model explicitly, for example:

```bash
.agents/skills/rpce-director-e2e/scripts/director_e2e.py --scenario s5 --workspace homelab-garden --window 1 --repeat 10 --doctor-mode required --events-mode required --receipt-mode required --archive-on-success --child-model-id scripted --coordinator-model-id design
```

Do not compare cheap-tier pass rates directly with default-tier pass rates; prompt/directive changes still need a default Coordinator validation batch.

## Runtime Contract

- Require an already running CE debug app by default. Use `--launch` only when an intentional relaunch is acceptable.
- Use `rpce-cli-debug` or `REPOPROMPT_DEBUG_CLI_INSTALL_PATH`; the script falls back to the user-space debug CLI and bundled debug app helper.
- Treat structured MCP status as the authority. Do not assert transcripts.
- Store artifacts under `tmp/director-e2e-runs/<run-id>/`: command logs, compact/full statuses, status history, capabilities, `doctor.json`, `missions.json`, archive result, timings, report JSON, and receipt summary/markdown when available.
- On timeout or assertion failure, keep the mission state intact for inspection and write the last compact/full status to artifacts.

## Scenarios

- `s1`: read-only investigation. Expects a completed mission, route/evidence records, receipt readiness, no post-approval user decisions, and a clean optional sandbox.
- `s2`: parallel fan-out and convergence. Expects two parents to run concurrently, a dependent summary node to wait until parents complete, then observes convergence as ready/running/completed depending on polling speed, no extra human submit after approval, cap discipline, completion, and exactly `A.md`, `B.md`, `SUMMARY.md` in the sandbox.
- `s4`: Checkpoint revision identity. Starts a coordinator-only awaiting-approval mission, requests one plan revision before approval, asserts a new checkpoint instance, rejects stale Proceed without recording a decision, accepts current Proceed, and verifies the approval decision is stamped with the current instance.
- `s5`: Me/Director child-question parity. Runs the same child Agent Mode mission twice. By default, the Coordinator is instructed to pass an exact, simple prompt to the selected child: call the structured RepoPrompt MCP `ask_user` tool now (`request_user_input` is only an alternate when `ask_user` is not advertised), wait for the pending interaction to be answered, report the selected marker, and stop. With `--child-model-id scripted`, the Coordinator must copy the exact `SCRIPTED_CHILD_V1 ask_marker token=<TOKEN> options=Alpha,Beta` line and the hidden scripted child creates the real pending question deterministically. The parent/Director owns Me-vs-Director routing and answer attribution, and the runner sets pace to Auto before approval so the child can launch. In Ask/Me mode it expects a visible pending child question, `coordinator_chat submit` routing to `child_interaction`, and a user childAsk answer decision. In Auto/Director mode it expects completion without a user-facing pending child question and a director childAsk decision/evidence record. Both variants require a fresh `agent_run.start`, bound child session/interaction IDs, unique marker evidence, and disjoint child refs. If a live child reports `S5_USER_INPUT_TOOL_UNAVAILABLE`, the selected child backend cannot create structured pending user input; switch to a backend or scripted child before treating S5/S6 as a Coordinator failure.
- `s6`: Dial flip semantics. Runs a pace slice that drives `coordinator_chat set_pace` while approval is pending and expects the checkpoint to remain pending, plus a childAsk slice that starts with Me, waits for a real pending child question, flips to Director through `coordinator_chat set_autonomy`, and expects the same interaction to be answered once by the Director after the user dial-change decision.
- `s7`: Stop semantics. Starts a deterministic child question, stops the Mission through `coordinator_chat stop_mission`, and expects a user irreversible stop decision, `agent_run.cancel` routing for active child work, stopped mission status, no running/ready work, no pending decision row, at least one cancelled node, and receipt capture when requested.
- `s8`: Trusted revision-proposal lifecycle. Approves an initial plan, waits for the owning Director to file a summary-only proposal, proves stable proposal/contract/checkpoint identities and a no-execution/no-self-resolution pause across repeated observations, submits external `revise_plan` using identity-only action fields, requires a concrete materially revised plan at a distinct exact-approval checkpoint, approves it externally, and expects execution to resume and complete with the accepted proposal resolution preserved.
- `smoke`: runs `s1` then `s2` with the same options.

## Visual Checkpoints

The runner does not make screenshots pass/fail in v1. It prints checkpoint names when useful so Codex/computer-use can capture the visible app:

- `plan-visible`
- `running-fanout`
- `convergence-ready` / `convergence-running` / `convergence-completed`
- `childask-ask` / `childask-auto`
- `child-question-visible`
- `child-question-answered`
- `revision-requested`
- `revision-visible`
- `stale-submit-rejected`
- `current-submit-accepted`
- `pace-set-auto`
- `stop-submitted`
- `stopped`
- `completed`
