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
.agents/skills/rpce-director-e2e/scripts/director_e2e.py --scenario s2 --workspace homelab-garden --window 1 --sandbox-root /path/to/director-e2e-sandbox --clean-sandbox
```

Use `--scenario smoke` to run S1 then S2. The smoke command requires `--sandbox-root` because S2 writes marker files.

Useful knobs:

- `--idle-timeout-seconds 120`: fail only after no observable progress and no running work.
- `--repeat N`: produce per-attempt reports plus `repeat_report.json`.
- `--events-mode auto|snapshot|required`: use future `mission_events` when available; default falls back to snapshot history.
- `--receipt-mode auto|summary|required`: use future receipt markdown when available; default falls back to receipt-ready summary.
- `--clean-sandbox`: clean a known throwaway Director E2E sandbox before writable scenarios.

## Runtime Contract

- Require an already running CE debug app by default. Use `--launch` only when an intentional relaunch is acceptable.
- Use `rpce-cli-debug` or `REPOPROMPT_DEBUG_CLI_INSTALL_PATH`; the script falls back to the user-space debug CLI and bundled debug app helper.
- Treat structured MCP status as the authority. Do not assert transcripts.
- Store artifacts under `tmp/director-e2e-runs/<run-id>/`: command logs, compact/full statuses, status history, capabilities, timings, report JSON, and receipt summary/markdown when available.
- On timeout or assertion failure, keep the mission state intact for inspection and write the last compact/full status to artifacts.

## Scenarios

- `s1`: read-only investigation. Expects a completed mission, route/evidence records, receipt readiness, no post-approval user decisions, and a clean optional sandbox.
- `s2`: parallel fan-out and convergence. Expects two parents to run concurrently, a dependent summary node to wait until parents complete, then observes convergence as ready/running/completed depending on polling speed, no extra human submit after approval, cap discipline, completion, and exactly `A.md`, `B.md`, `SUMMARY.md` in the sandbox.
- `smoke`: runs `s1` then `s2` with the same options.

## Visual Checkpoints

The runner does not make screenshots pass/fail in v1. It prints checkpoint names when useful so Codex/computer-use can capture the visible app:

- `plan-visible`
- `running-fanout`
- `convergence-ready` / `convergence-running` / `convergence-completed`
- `completed`
