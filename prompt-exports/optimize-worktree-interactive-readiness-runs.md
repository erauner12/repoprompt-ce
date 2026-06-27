# Worktree Interactive Readiness Optimization Runs

Append-only campaign log. Never rewrite historical rows or delete valid slow
samples. Corrections are new dated entries referencing the superseded entry.
Synthetic fixtures are parser/test evidence only and are never authoritative
baseline samples.

## Target

Primary cohort: fully loaded steady-state real RepoPrompt CE non-worktree main
root in the dedicated `RPCE Search Bench Main 20260618` workspace → fresh
app-managed Agent Mode linked worktree, warm process, width 1.

Primary metric:
`max(first successful direct file_search completion,
first successful direct read_file completion) - bindingTransitionStarted`.

Pass:
- exact `diffSeedServing={"diffSeedServing":1}`;
- empty fallbacks;
- primary p95 at least 30% below same-build forced-full;
- no secondary regression above 10%;
- all correctness, cleanup, resource, and transcript gates pass.

## Frozen environment and provenance

- Campaign plan SHA-256: `<pending>`
- Confirmation plan SHA-256: `<pending>`
- App build SHA: `<pending>`
- CE CLI version/schema hashes: `<pending>`
- Workspace/window/context/root IDs: `<pending>`
- Authoritative root: `/Users/pvncher/Documents/Git/repoprompt-ce-release`
- Fixture classification: real repository; synthetic fixtures non-authoritative
- Commit/tree/blob SHA-256: `<pending>`
- Observed tracked/loaded file count: `<pending>`
- Host model/RAM/macOS: `<pending>`
- Power/thermal/sleep evidence: `<pending>`
- Benchmark artifact root: `<pending>`

## Historical evidence — not iteration 0

| source | route validity | metric | p50 ms | p95 ms | CV | disposition |
|---|---|---|---:|---:|---:|---|
| synthetic production-equivalent | synthetic only | reported total | 3224.305 | 3430.394 | unavailable | historical, not live gate evidence |
| retained synthetic | synthetic only | reported total | 3060.035 | 3332.038 | unavailable | ~2.87% p95 improvement only |
| live ~1996-file forced-full | valid forced-full | materialize→rootReady | 352.287 | 456.622 | unavailable | historical |
| live ~1996-file forced-full | valid forced-full | materialize→first search | 670.437 | 2505.763 | 79–84% tail range | historical |
| live ~1996-file forced-full | valid forced-full | materialize→first read | 792.739 | 2967.240 | 79–84% tail range | historical |
| prior serving attempts | invalid | interactive readiness | — | — | — | not established: base snapshot/catalog/receipt/witness/mixed fallback failures |

Historical search/read p95 values do not establish historical interactive
readiness p95 because per-sample maxima are unavailable.

Warm marker closure at checkpoint `52b69926` is transcript-proven by exactly two
successful `get_code_structure` calls followed by passive tree `Tool.swift +`.
It is correctness evidence, not campaign latency evidence.

## Iterations

| iteration | single change | forced-full artifact | serving artifact | widths/process states | primary values ms | primary p50/p95/CV | serving vs forced p95 | secondary gates | route/correctness | decision |
|---:|---|---|---|---|---|---|---:|---|---|---|
| 0 | DEBUG instrumentation/schema-v5 and baseline only | `<pending>` | `<pending>` | warm width 1 first; 4/8 and aged only after valid serving | `<pending>` | `<pending>` | `<pending>` | `<pending>` | serving not yet established | pending |
| 1 | streamed loaded-root Git authority evidence | `20260626T172258Z-warm-forced-full-w1-75e14e0f` | `20260626T172537Z-warm-projected-w1-1558494c` | warm width 1 only | valid `[]`; invalid forced `[738.472, 871.169, 839.719]` | unavailable / unavailable / unavailable | unavailable | correctness and projected export incomplete | setup reached `diffSeedServing`; exact serving/fallback sample absent | incomplete |
| 2 | narrowed Git worktree mutation lock | `<pending>` | `<pending>` | same valid matrix | `<pending>` | `<pending>` | `<pending>` | `<pending>` | `<pending>` | pending |
| 3 | demand-reserved CodeMap capacity, only if attributed | `<pending>` | `<pending>` | same valid matrix | `<pending>` | `<pending>` | `<pending>` | `<pending>` | `<pending>` | pending |
| 4 | reserved one-variable refinement | `<pending>` | `<pending>` | same valid matrix | `<pending>` | `<pending>` | `<pending>` | `<pending>` | `<pending>` | pending |
| 5 | reserved one-variable refinement | `<pending>` | `<pending>` | same valid matrix | `<pending>` | `<pending>` | `<pending>` | `<pending>` | `<pending>` | pending |

## Per-series retained samples

Append one section per artifact containing all retained values in ordinal order;
p50, p95, and CV; route/fallback maps; root/search/read/codemap/tree/selection,
Git/filesystem/lock/planner/resource evidence; correlation/session/context
identity; raw transcript/direct-probe status; and invalid attempts without
replacement.

## Stop record

- Stop reason: `<gate passed | deterministic diminishing returns | iteration 5 exhausted | incomplete serving baseline | inconclusive>`
- Accepted cumulative changes: `<pending>`
- Rejected/reverted changes: `<pending>`
- Final artifact and evidence paths: `<pending>`

## 2026-06-26 — Iteration 0 baseline attempt (append-only)

### Frozen real-repository provenance

- Workspace: `RPCE Search Bench Main 20260618`
- Window/workspace/context/root IDs: `1` /
  `163E658F-4313-4894-B003-595287E59AE9` /
  `E7BC2FDA-0CBD-4DE9-9C94-C31984E5F783` /
  `004BC297-1943-43E6-BE23-5BBF32699F85`
- Authoritative root: `/Users/pvncher/Documents/Git/repoprompt-ce-release`
- Commit OID: `52b69926dd3f5a2e1ee78b89d50ab0711e488bba`
- Observed counts: 2,137 tracked files; 2,120 loaded searchable files
- Final primary/confirmation plan SHA-256 fields:
  `daace6e4c9106227bf669cbdb1cda38da940fecb78db6d9a166126bc549712f5` /
  `<predeclared but unused after invalid projected setup>`
- Exact plan-file SHA-256: `22c3147346334243095633f3beaf8e490008dbfbb47168287a28630dfa9e421e`
- Exact confirmation-plan-file SHA-256:
  `777919e317d0749bd99dc1f96757f4376a59d43d4f021831a8b80b3fa49f2d92`
- App binary SHA-256:
  `3c367ad3ca93fc0a5e73e0a2420ddc0461488bd593edd8002fd9ea78481e5878`
- CLI: `rpce-cli-debug (repoprompt-mcp) 1.0.21`
- Host: `Mac16,7`, 48 GiB RAM, macOS 26.5 (25F71), AC power, battery 80%
- Ownership: dedicated real-repository marker removed after cleanup; no benchmark
  marker remains.

### Preflight

- Final preflight: `/tmp/rpce-worktree-startup/v1/20260626T150906Z-preflight-b252dcb7`
- Earlier valid preflight:
  `/tmp/rpce-worktree-startup/v1/20260626T150710Z-preflight-9091287d`
- Result: passed exact workspace/root/commit/blob/schema scope.
- Frozen read blob SHA-256:
  `fdb8770f38746a62e319cc3b4cef530caad2ada603eb5e0fd66c360bca5cd6ed`

### Forced-full width 1

Final artifact:
`/tmp/rpce-worktree-startup/v1/20260626T151126Z-warm-forced-full-w1-adaf08ea`

- Predeclared: one warmup + five retained.
- Recorded: one invalid warmup; ordinal 2 then terminated on an exact
  `get_code_structure` timeout. No ordinal was replaced.
- Retained primary values: `[]`.
- Primary p50/p95/CV: unavailable / unavailable / unavailable.
- Invalid warmup primary value: `901.150 ms` interactive readiness.
- Invalid warmup component values:
  - materialize→root ready `411.839 ms`
  - materialize→search `901.150 ms`
  - materialize→read `838.398 ms`
  - direct search/read `246.381 / 101.972 ms`, concurrent
  - first/warm codemap `9231.979 / 85.966 ms`
  - passive tree `18648.134 ms`
  - selection `11015.273 ms`
- Actual route/fallback: `{"fullCrawl":1}` / `{}`.
- Git: 20 commands; `579.908 ms` duration; `168.660 ms` queue.
- Filesystem: 1 operation, 1 item, `350.292 ms`.
- Mutation lock: queue `0.001 ms`, held `397.453 ms`, mutation `349.149 ms`,
  post-mutation finalization `30.813 ms`.
- Codemap/tree/selection correctness: codemap returned the exact real
  `WorkspaceRootSeedPlanner` content twice, but the raw result used the intended
  logical-root display plus session-bound worktree scope. The strict direct
  validator rejected logical binding attribution, passive tree did not show the
  required current `+` marker/legend, and selection root attribution was absent.
  The sample is invalid (`content_oracle_mismatch`), not timing evidence.
- Resource session (diagnostic only): 623 samples over 64.6 s; average/peak
  core 120.4%/358.1%; resident baseline/peak/final 332.2/354.7/349.6 MiB;
  physical footprint baseline/peak/final 197.9/217.0/200.7 MiB.
- Cleanup: complete; owned Agent session/worktree removed, route restored,
  memory sampler stopped, scope reset.

Earlier non-replacement setup attempts retained as invalid evidence:

- `/tmp/rpce-worktree-startup/v1/20260626T150744Z-warm-forced-full-w1-aab80d53`
  — follow-on codemap binding validator required the physical rather than logical
  displayed root; zero samples recorded; cleanup complete.
- `/tmp/rpce-worktree-startup/v1/20260626T150939Z-warm-forced-full-w1-5445ff52`
  — passive tree marker gate failed before export; zero samples recorded;
  cleanup complete.

### Projected width 1

Artifact:
`/tmp/rpce-worktree-startup/v1/20260626T151309Z-warm-projected-w1-d727c2ef`

- Failed before arming or starting a sample.
- Exact error: `base_snapshot_unavailable`.
- Stage: `discovery_authority_capture`.
- Cause: `git_record_limit_exceeded`.
- Actual route counts: unavailable because route setup failed before start.
- Fallback counts: unavailable because no sample was armed.
- `diffSeedServing` serving baseline: **not established**.
- Cleanup found no owned Agent session/worktree or active memory sampler; scope
  reset succeeded. `restore_route` was false because no route control lease had
  ever been created. The ownership marker was removed separately.

### Correctness and stop decision

- Timing used direct correlated diagnostics and raw structured CLI results;
  assistant prose was not accepted.
- Actual `agent_run` starts occurred in forced-full attempts, but the dedicated
  transcript smoke gate was not reached after projected setup failed. Therefore
  no inference transcript is claimed as passing evidence.
- Widths 4/8 and aged cohorts were not run because width-1 projected serving was
  invalid.
- Confirmation plan was predeclared but not run because there was no valid
  primary series to confirm.
- Iteration 0 decision: **incomplete**. Exact reason: projected setup could not
  prepare a reusable base snapshot (`discovery_authority_capture` /
  `git_record_limit_exceeded`), and forced-full produced zero valid retained
  samples. No optimization or repair was attempted.

## 2026-06-26 — Iteration 0 instrumentation-hardening correction (append-only)

This corrects the preceding preflight provenance; no raw artifact is superseded.

### Exact preflight correction

- `20260626T150906Z-preflight-b252dcb7` belongs to revision-2 plan SHA `bb1e5459275c1756af16a71ab69cac9ac635a838931c726b28461a6943c5d861` (file SHA `16fc77f0afc6992d5f7785fa87d5c740b8640ebf38cfbb33cb57b3f9ab32cb3d`), not the final plan.
- New exact unchanged-final-plan preflight: `/tmp/rpce-worktree-startup/v1/20260626T153947Z-preflight-dba72e60`.
- Final plan field/file SHA: `daace6e4c9106227bf669cbdb1cda38da940fecb78db6d9a166126bc549712f5` / `22c3147346334243095633f3beaf8e490008dbfbb47168287a28630dfa9e421e`; exact marker SHA: `494b00e3f833acd3d4feb52eabfc183b5696f52769ab8d024682916275e86d6c`.
- Preflight proved workspace/context/root `163E658F-4313-4894-B003-595287E59AE9` / `E7BC2FDA-0CBD-4DE9-9C94-C31984E5F783` / `004BC297-1943-43E6-BE23-5BBF32699F85`, commit `52b69926dd3f5a2e1ee78b89d50ab0711e488bba`, and blob `fdb8770f38746a62e319cc3b4cef530caad2ada603eb5e0fd66c360bca5cd6ed`.

### Width-1 hardening probe

- DEBUG relaunch ticket `adc13aee-d68c-482d-9615-5b71e171033f` exited 0. App/CLI SHA: `6faae945141c20dd8d77f99b11ddf99f2aecd2e7a81728247e14d2e591e2e9f8` / `d11a2c84a56349ba6d7fd6b5145746a08599619df01c4be61f094fdf1c7a84f5`.
- Relaunch loaded the same real root with runtime root UUID `BE7E1E7D-D4A4-4FDB-A3D1-7A3121A25A6E`, 2,121 searchable entries, one crawl, and one watcher. The UUID differs from the frozen plan.
- Artifact `/tmp/rpce-worktree-startup/v1/20260626T154721Z-warm-projected-w1-746449e0` failed closed at `scope mismatch for root_id`, before route control, sampler, arm, worktree, or export. State has zero sessions/worktrees and null control/sampler.
- Samples `[]`; p50/p95/CV unavailable; route/fallback counts unavailable. No serving baseline is claimed.
- Prior projected artifact `/tmp/rpce-worktree-startup/v1/20260626T151309Z-warm-projected-w1-d727c2ef` remains the exact `base_snapshot_unavailable` / `discovery_authority_capture` / `git_record_limit_exceeded` evidence. It was not repaired or retested past the new scope failure.

### Transcript/correlation evidence

- Actual inference `B5CFE3AC-3A5F-4C00-AF78-7F77314B5220` logged exactly one `file_search` then one `read_file` in `/tmp/rpce-hardening-gate-clean-log.txt`. Tool-result elements were absent and same-context direct probes returned `worktree_scope_unavailable`; sentinel prose is rejected and this live gate is incomplete.
- Related raw files: `/tmp/rpce-hardening-gate-clean-start.txt`, `/tmp/rpce-hardening-gate-clean-wait.txt`, `/tmp/rpce-hardening-direct-bind.txt`, `/tmp/rpce-hardening-direct-search.txt`, `/tmp/rpce-hardening-direct-read.txt`, and `/tmp/rpce-current-runtime-snapshot.txt`.
- Focused Swift correlation/boundary test passed (ticket `187ddc6c-73fe-43a2-ba69-ce6a338f551f`). Python py_compile and all 129 harness self-checks passed.

### Decision

Iteration 0 remains **incomplete**. No valid retained forced-full or exact `diffSeedServing` sample exists. Widths 4/8 and aged were not attempted; no optimization, `git_record_limit_exceeded` repair, or frozen-root-UUID repair was attempted.

## 2026-06-26 — Iteration 0 post-relaunch current-root follow-up (append-only)

### Current scope and steady-state proof

- Window/workspace: `1` / `163E658F-4313-4894-B003-595287E59AE9`
  (`RPCE Search Bench Main 20260618`).
- The window listing reported active tab context
  `065F8ED3-433A-4F5F-9E1F-CC2AE2986220`; the dedicated main-root benchmark
  control context used by every exact call was
  `E7BC2FDA-0CBD-4DE9-9C94-C31984E5F783`.
- Current post-relaunch main-root UUID:
  `BE7E1E7D-D4A4-4FDB-A3D1-7A3121A25A6E`.
- Commit: `52b69926dd3f5a2e1ee78b89d50ab0711e488bba`.
- Full root tree: 2,501 lines / 146,085 bytes, untruncated, one root. Exact
  fixed search/read both succeeded before planning. Runtime steady state was
  one crawl, one watcher, no active freshness flight, no queued/applying/
  outstanding publication, and projection generation lag zero. Search/catalog
  counts were 2,120 searchable files and one visible root.
- Raw discovery: `/tmp/rpce-worktree-startup/followup-discovery-20260626`.

### Fresh frozen plans and exact preflights

- Control directory:
  `/tmp/rpce-worktree-startup/followup-20260626T-current-root`.
- Primary plan: `primary-plan.json`; plan/file SHA-256
  `4963cd5aa1a7683ecfb841347c7eef59b6d811dd9fddcafe141d7fcb9a1bd2ce` /
  `e2b82b1591e401f20400de872aa268c7e6c8b47ee39a4fa0f3ba3888eaf5282a`.
- Confirmation plan: `confirmation-plan.json`; plan/file SHA-256
  `26f7375004fa04e8800262628ddcb46bde7d3e90aac652cf022b67eb1a848d23` /
  `84bd2a6ab6b004384a7c309df4fae1fc16cff490fd2307a4d532e383962c6b3e`.
- Both plans froze exactly one excluded warmup plus five retained samples after
  discovery of the current root UUID. Confirmation was not run after the
  mandatory projected-setup stop.
- Primary exact preflight:
  `/tmp/rpce-worktree-startup/v1/20260626T160314Z-preflight-a1b2a919`.
- Confirmation exact preflight:
  `/tmp/rpce-worktree-startup/v1/20260626T160315Z-preflight-f27a2fb7`.
- Both preflights passed the exact window/workspace/context/root, commit,
  tracked blob, schema, gate, and one-root workspace checks.
- Marker SHA-256: `6712a849bdcf656044628a68647e1a64cf77aea297a7804f2143fef86b3ab542`.
- App/CLI SHA-256:
  `6faae945141c20dd8d77f99b11ddf99f2aecd2e7a81728247e14d2e591e2e9f8` /
  `d11a2c84a56349ba6d7fd6b5145746a08599619df01c4be61f094fdf1c7a84f5`.

### Width-1 forced-full, run first

Artifact:
`/tmp/rpce-worktree-startup/v1/20260626T160355Z-warm-forced-full-w1-34f593f1`

- Frozen count: one warmup + five retained. Four samples were exported (warmup
  plus ordinals 2–4); ordinal 5 then stopped on exact
  `get_code_structure returned 'timeout', not ready`. No ordinal was replaced.
- Valid retained raw primary values: `[]`.
- Valid retained p50 / p95 / CV: unavailable / unavailable / unavailable.
- Invalid raw diagnostic interactive-readiness values were warmup `724.620 ms`
  and retained ordinals 2–4 `[883.632, 1025.205, 861.304] ms`. These are
  correctness-failed evidence only and are excluded from statistics.
- Every exported sample reported configured `forcedFullCrawl`, actual
  `{"fullCrawl":1}`, and fallback counts `{}`.

| ordinal | class | readiness ms | materialize→root/search/read ms | direct search/read ms | first/warm codemap ms | tree/selection ms | Git count; duration/queue ms | filesystem ms | lock held/mutation/finalize/queue ms |
|---:|---|---:|---|---|---|---|---|---:|---|
| 1 | invalid warmup | 724.620 | 346.712 / 724.620 / 662.523 | 231.227 / 134.488 | 2525.081 / 84.422 | 5894.284 / 10451.255 | 1024; 9396.093 / 8070.324 | 292.819 | 348.446 / 303.987 / 28.237 / 0.001 |
| 2 | invalid retained | 883.632 | 407.602 / 883.632 / 814.031 | 324.122 / 219.741 | 5856.728 / 143.192 | 6105.762 / 10733.949 | 1024; 9503.208 / 8200.793 | 350.215 | 348.741 / 302.168 / 29.411 / 0.002 |
| 3 | invalid retained | 1025.205 | 399.135 / 1025.205 / 958.735 | 396.769 / 293.337 | 6056.859 / 88.492 | 8111.965 / 10760.995 | 1024; 9622.600 / 8241.752 | 350.368 | 343.663 / 296.627 / 29.601 / 0.000 |
| 4 | invalid retained | 861.304 | 375.398 / 861.304 / 794.620 | 328.916 / 226.380 | 6440.314 / 86.824 | 3931.422 / 10944.437 | 1024; 9511.104 / 8197.932 | 320.118 | 381.453 / 332.419 / 30.573 / 0.000 |

- Raw structured direct calls showed exact correlated search success and the
  intended physical `session_worktree`, but read validation failed with
  `read_file expected file content missing`. Both codemap calls returned the
  exact content on ordinals 1–4. Passive tree failed the required exact current
  marker/legend and selection omitted structured `worktree_scope`; every
  exported sample was therefore invalid as `content_oracle_mismatch`.
- Raw evidence is in `samples.ndjson`, `resources.json`, `cleanup.json`, and
  `raw/` under the artifact. In particular, `first-search`, `first-read`,
  `first-codemap`, `warm-codemap`, `passive-tree`, `selection-get`, and
  `export` files were inspected rather than accepting assistant prose.
- Resource session: 1,438 samples over 148.8 s; average/peak core
  121.3%/394.0%; resident baseline/peak/final 362.5/430.5/430.5 MiB;
  physical footprint baseline/peak/final 122.6/187.6/187.6 MiB.

### Width-1 projected/diff-seed, run second

Artifact:
`/tmp/rpce-worktree-startup/v1/20260626T160751Z-warm-projected-w1-0606aae2`

- Failed before control acquisition, sampler start, arm, Agent session,
  worktree, or sample export.
- Exact error: `base_snapshot_unavailable`; reason `failed`; stage
  `discovery_authority_capture`; cause `git_record_limit_exceeded`.
- Valid retained raw primary values: `[]`.
- Valid retained p50 / p95 / CV: unavailable / unavailable / unavailable.
- Actual route and fallback counts are unavailable because setup failed before
  a projected sample was armed. Exact `diffSeedServing` remains unestablished.
- Per the frozen stop rule, no width 4/8, aged, confirmation, or dedicated small
  transcript correctness gate was attempted. The forced-full `agent_run`
  starts used actual inference, but their no-tools prompt is not claimed as the
  transcript gate. No assistant prose is accepted as correctness evidence.

### Cleanup and disposition

- Forced-full recorded five owned sessions and five owned app-managed
  worktrees. All sessions reached `completed`; all five worktrees were removed;
  the sampler was ownership-matched and verified stopped; the route was
  restored; diagnostics reset; the DEBUG gate remained enabled; and the main
  workspace returned to its one-root inventory.
- Session deletion was limited to those five exact recorded IDs. The batch and
  subsequent single-ID calls closed their CLI connections after deletion, so
  the call responses themselves are not accepted as success. A fresh
  `list_sessions` returned none of the five IDs; proof is
  `owned-session-cleanup-proof.json` in the control directory. No unrelated
  session was targeted.
- Projected cleanup recorded zero sessions/worktrees, `start_not_attempted` for
  the sampler, `not_acquired` for the route, successful diagnostic reset, and
  restored one-root workspace inventory.
- The ownership marker was unlinked only after its SHA, owner token, workspace
  ID, current root UUID, canonical path, and purpose all matched. Proof:
  `marker-cleanup.json` in the control directory.
- Disposition: **incomplete / fail closed**. Forced-full has zero valid retained
  samples, and projected serving again failed at
  `discovery_authority_capture/git_record_limit_exceeded`. No timing comparison,
  p95 improvement, or serving claim is made. No repair, relaunch, build, test,
  width 4/8, aged run, or commit was attempted.

## 2026-06-26 — Iteration 1 streamed loaded-root Git authority evidence (append-only)

### Attributed implementation and focused validation

- Implemented only the iteration-1 loaded-root Git authority optimization:
  prefix-control evidence and full `ls-tree` inventory are streamed through
  authenticated spill-backed manifests instead of being accumulated under the
  legacy 10,000-record all-or-nothing limit. Memory, record/batch bytes, open
  runs/files, and aggregate spool bytes are bounded; total repository records
  are not capped. Snapshot schema/content domains advanced to v5.
- Exact fail-closed currentness checks remain around authority capture, catalog
  batching, manifest finalization, and admission. Corrupt/truncated manifests,
  stale catalog batches, cancellation, resource exhaustion, sparse/submodule/
  nested/external/ambiguous topology, and unsupported Git evidence still reject
  reuse or fall back to the existing full crawl. Non-Git roots and non-Git
  search/read were not routed through the new representation.
- Focused compile passed: coordinated RepoPrompt product build ticket
  `299fe0bc-8eff-4a47-aba2-1fbc92fc1119`.
- New focused authority suite passed: ticket
  `0dcae8d8-4139-4129-9b2e-04200cdffde2`. It includes a control file after
  10,001 lazy non-control candidates, lazy 100,000 candidate and tree records,
  corruption/cancellation/resource cleanup, and stale-currentness zero-admission
  coverage. The large-record test asserts buffered bytes, open runs, aggregate
  artifact bytes, verified EOF, exact record count, and zero active artifacts
  after lease release without first materializing the logical stream.
- The opt-in 1,000,000 logical candidate/tree-record test passed in `100.489 s`
  with the same bounded assertions. It was run directly with
  `RPCE_RUN_MILLION_RECORD_GIT_AUTHORITY_TESTS=1` because conductor does not
  forward that opt-in environment key.
- Touched-path compatibility tests passed: seed planner ticket
  `30490418-bfb6-4832-b02a-b214d28745d9`, initialization API
  `d9115991-...`, authority `bc1fd509-...`, projected path search
  `4c2f152a-...`, and creation receipt final rerun
  `d1a89a6d-f7dc-4453-a8b0-f4b69bee7aee`. No release build, full suite, lint,
  benchmark-gate change, or unrelated repair was performed.

### Post-relaunch frozen scope and preflight

- Coordinated DEBUG relaunch ticket
  `987de240-65ad-4752-922f-89f5146d5650` exited 0; visible app PID `71554`.
  App/CLI SHA-256:
  `a28a4c93e4193cd2fbd2a4a62bb73a8c670436996ebc1b748093627c297ed32a` /
  `457eed710e7537a06e83ba129ad085e41d827c6f857066bea6c757e3f7b7acf6`.
  CLI version: `repoprompt_ce_cli_debug (repoprompt-mcp) 1.0.21`.
- Window/workspace/context/current root: `1` /
  `163E658F-4313-4894-B003-595287E59AE9` /
  `E7BC2FDA-0CBD-4DE9-9C94-C31984E5F783` /
  `54F3CDD8-BC02-4863-9B5C-24A7A88ADFA2`.
- Real root `/Users/pvncher/Documents/Git/repoprompt-ce-release`, commit
  `8103b122f23f1087ada2e0a5db16eb69feef2fc3`, 2,138 tracked files.
- Primary/confirmation plans:
  `/tmp/rpce-worktree-startup/iteration1-20260626/primary-plan.json` and
  `confirmation-plan.json`. Plan SHA fields:
  `818759584a3e38237fc2e8c99781750b1194d5f16dc2e476fe87db2fa112a385` /
  `7cc2fa332e71902f1c9d5fd70b32a32cdaed725498225ab3f489259daa84fa23`;
  file SHA-256:
  `7d7d62fc09cbc1dff1ecd92dbc64c634bc7e3ae84a774f54257fe23f2278538e` /
  `bd166647033be89fd6d1701fda16b33f67ee5aeb4919667256f5a5bb31918eeb`.
- Exact post-relaunch preflights passed:
  `/tmp/rpce-worktree-startup/v1/20260626T172215Z-preflight-10bb0b9a` and
  `/tmp/rpce-worktree-startup/v1/20260626T172216Z-preflight-e5a548f7`.
  Both froze the same scope/commit and read blob
  `a2133dce4c6c67cfdfaa47173e2ce03c8b8f818b486eadf985ba8fa7b5e170e8`.
- Host: `Mac16,7`, 48 GiB RAM, macOS 26.5 (25F71), AC power, battery 80%.

### Width-1 forced-full, run first

Artifact:
`/tmp/rpce-worktree-startup/v1/20260626T172258Z-warm-forced-full-w1-75e14e0f`

- Frozen count: one warmup + five retained. Three samples were exported
  (warmup plus ordinals 2–3); ordinal 4 then stopped on exact
  `get_code_structure returned 'timeout', not ready`. No ordinal was replaced.
- Valid retained raw primary values: `[]`.
- Valid retained p50 / p95 / CV: unavailable / unavailable / unavailable.
- Invalid raw diagnostic readiness values were warmup `738.472 ms` and retained
  `[871.169, 839.719] ms`. For transparency only, that excluded two-value
  diagnostic series has p50 `855.444 ms`, nearest-rank p95 `871.169 ms`, and
  population CV `0.018382`; it is **not** retained performance evidence.
- Every exported sample reported actual route/fallback
  `{"fullCrawl":1}` / `{}` and was invalid as `content_oracle_mismatch`.

| ordinal | class | readiness ms | materialize→root/search/read ms | direct search/read ms | first/warm codemap ms | tree/selection ms | Git count; duration/queue ms | filesystem ms | lock held/mutation/finalize/queue ms |
|---:|---|---:|---|---|---|---|---|---:|---|
| 1 | invalid warmup | 738.472 | 338.446 / 738.472 / 698.924 | 136.332 / 135.701 | 4168.747 / 91.569 | 8168.621 / 10519.256 | 1024; 10234.858 / 9128.258 | 281.798 | 384.345 / 337.819 / 29.598 / 0.002 |
| 2 | invalid retained | 871.169 | 381.561 / 871.169 / 791.191 | 243.268 / 96.117 | 4906.019 / 84.144 | 10937.180 / 10728.058 | 1024; 10190.607 / 9240.803 | 323.752 | 332.766 / 285.996 / 30.118 / 0.000 |
| 3 | invalid retained | 839.719 | 352.772 / 839.719 / 760.905 | 248.653 / 93.897 | 7345.174 / 97.974 | 5571.362 / 10835.733 | 1024; 10286.848 / 9236.798 | 299.882 | 386.359 / 342.375 / 27.350 / 0.000 |

- Phase attribution: interactive readiness was dominated after root readiness by
  first search; Git diagnostic work was almost entirely queued
  (`9.13–9.24 s` of `10.19–10.29 s`) and attributed to 896–897 codemap-authority
  plus 127–128 tree-resolution commands. Codemap demand recorded 92 requests in
  warmup and 68 in each retained diagnostic sample; no codemap builds or permit
  waits were attributed. Content-read admission wait/execution stayed below
  `0.010 / 0.262 ms`.
- Secondary correctness gates failed exactly as before the optimization: direct
  read reported `read_file expected file content missing`, passive tree omitted
  the required exact current marker/legend, and selection omitted structured
  `worktree_scope`; search and both codemap calls returned expected content.
  These are out-of-scope validator/codemap readiness issues and were not repaired.
- Resource session: 1,184 samples over 122.3 s; average/peak core
  119.0%/346.4%; resident baseline/peak/final 316.2/379.5/379.5 MiB
  (peak delta 63.3 MiB); physical footprint baseline/peak/final
  115.4/176.1/176.1 MiB (peak delta 60.6 MiB); session CPU 145,456.1 ms.

### Width-1 projected/diff-seed, run second

Artifact:
`/tmp/rpce-worktree-startup/v1/20260626T172537Z-warm-projected-w1-1558494c`

- The iteration-0 blocker is removed: projected route setup successfully
  prepared base snapshot identity
  `bcf385c2e8163e4000272f45a8b90139e204da1ce6a9dfade4f59c0a4fe23053`
  and returned route `diffSeedServing`. There was no
  `discovery_authority_capture/git_record_limit_exceeded`.
- The first sample then stopped on exact
  `get_code_structure returned 'timeout', not ready` before export. Recorded
  samples `[]`; valid retained primary values `[]`; p50/p95/CV unavailable.
- Because no sample export exists, actual per-sample route counts and fallback
  counts are unavailable. Setup route `diffSeedServing` is not accepted as proof
  of the required exact `{"diffSeedServing":1}` / `{}` serving series.
- Per the frozen stop rule, no replacement, confirmation, width 4/8, aged, or
  additional repair was attempted.
- Resource session: 137 samples over 14.1 s; average/peak core
  117.1%/346.8%; resident baseline/peak/final 496.0/508.1/508.0 MiB
  (peak delta 12.1 MiB); physical footprint baseline/peak/final
  187.9/203.0/202.9 MiB (peak delta 15.1 MiB); session CPU 16,531.8 ms.

### Cleanup, artifacts, and recommendation

- Both original run summaries recorded `cleanup_complete: true`. State and raw
  cleanup calls prove all five owned Agent sessions terminal, all five owned
  worktrees removed, both memory samplers stopped, routes restored, diagnostics
  reset, and the one-root workspace restored. The raw proof remains under each
  artifact (`raw/`, `state.json`, `resources.json`, and `samples.ndjson`).
- A later explicit idempotence recheck rewrote the forced-full `cleanup.json`;
  it correctly refused to re-delete the already-absent worktrees because a live
  session/worktree relationship could no longer be proven, while independently
  verifying sampler stopped, route restored, diagnostics reset, and roots
  restored. The pre-recheck proof remains in raw calls `0097`–`0104` and
  `state.json`; the projected original `cleanup.json` was unchanged.
- The dedicated real-root ownership marker was removed only after SHA, owner
  token, workspace/root IDs, canonical path, and purpose all matched. Proof:
  `/tmp/rpce-worktree-startup/iteration1-20260626/marker-cleanup.json`.
- Recommendation: **do not retain from current measurement; revert unless the
  independent reviewer explicitly accepts another measurement cycle**. The
  attributed optimization clears the 10,000-record authority blocker and its
  focused boundedness/fail-closed tests pass, but the mandatory valid projected
  serving cohort, correctness gates, p95 improvement, and memory-regression
  comparison were not established. No commit was created.

## 2026-06-26 — Iteration 1 scoreboard-row correction (append-only)

The top iteration-1 summary row previously named a planned
`sparse/delta-proportional seed plan`, which was not the implemented change.
It now names the actual single change, **streamed loaded-root Git authority
evidence**, points to the recorded forced-full and projected artifacts, and
marks the measurement **incomplete**. This correction changes only the campaign
index row; it does not replace or reinterpret any raw sample or appended
iteration-1 measurement detail above.

## 2026-06-26 — Oracle iteration-1 disposition (append-only)

- Oracle chat `readiness-optimization-66CC5D` decision: **RETAIN iteration 1**.
- This retains the single streamed loaded-root Git authority evidence change;
  it is not a performance-gate pass and does not reinterpret the invalid prior
  timing ordinals. The implementation removed the attributed 10,000-record
  authority blocker, retained fail-closed behavior, and passed its focused
  boundedness/currentness evidence.
- The prior live run could not decide primary performance because the harness
  coupled completed root/search/read timing to codemap/tree/selection follow-on
  acceptance. The approved measurement-support correction is to preserve a
  correlation-bound `primary_performance` result independently while keeping
  failed `follow_on_acceptance` visible and campaign-blocking.
- Campaign status remains **incomplete** until a fresh same-build forced-full
  and projected one-plus-five width-1 series establishes valid primary values,
  exact routes with empty fallbacks, separate follow-on status, resource and
  cleanup proof, and any required high-CV confirmation. No production
  scheduling, Git locking, seed planning, codemap behavior, or threshold change
  is authorized by this disposition.

## 2026-06-26 — Iteration-1 measurement-support rerun (append-only)

### Frozen build, scope, plans, and preflights

- Single approved coordinated relaunch: ticket
  `7063e284-c1c0-44a6-b660-f46ea70692d2`, PID `45589`.
- Build/checkout identity: CLI SHA-256
  `4fdd50df7891d354d9ea3cfcd4f447e8d028e458a8f451f2965c2fa1500873d8`,
  HEAD `be61584899ed2ef5623817b2ad80815c13e4cbeb`, 2,141 tracked files.
- Window/workspace/control-context/current-root:
  `1` / `163E658F-4313-4894-B003-595287E59AE9` /
  `E7BC2FDA-0CBD-4DE9-9C94-C31984E5F783` /
  `8377314A-3965-414D-A5A4-BFCE60810763`. Runtime showed the fully loaded
  real root current with no session-worktree owners.
- Fresh primary/confirmation plans:
  `/tmp/rpce-worktree-startup/iteration1-measurement-split-20260626T182119Z/primary-plan.json`
  (`dea1b3b16557a6d13dfba7b46c16184485355ab0884ca4deeab704e1e198d367`)
  and `confirmation-plan.json`
  (`bb46ca42c3c083719a6cfed0cf74fdc257f473009739d7ba29d7ab0d7d5d550b`).
  Both used search marker `WorkspaceRootSeedPlanner`, first-80-line read marker
  `import CryptoKit`, and read blob SHA-256
  `72df72ed69de7c24a1efbdfa7ffee41f0b32815b5b3ec303c95dc1c0bb7a5aba`.
- Fresh preflights passed at
  `/tmp/rpce-worktree-startup/v1/20260626T182307Z-preflight-ef10ec53`
  and `/tmp/rpce-worktree-startup/v1/20260626T182308Z-preflight-d374efd7`.

### Forced-full primary performance and separate follow-on status

Artifact:
`/tmp/rpce-worktree-startup/v1/20260626T182344Z-warm-forced-full-w1-c7e4f414`

- One excluded warmup plus all five retained ordinals completed; no replacement
  or retry occurred. Corrected primary revalidation is preserved separately at
  `/tmp/rpce-worktree-startup/iteration1-measurement-split-20260626T182119Z/forced-full-primary-revalidation.json`.
- Retained primary raw values: `[898.364, 1021.922, 972.808, 946.328,
  866.379] ms`.
- Primary p50 / nearest-rank p95 / population CV:
  `946.328 ms` / `1021.922 ms` / `0.058147`.
- Warmup primary value: `726.572 ms` (excluded).
- Every checkpoint independently passed correlation/session/child-context and
  frozen-scope identity, build/invocation/ordinal, ordered root/search/read
  boundaries, direct structured search+read logical/physical worktree binding,
  committed path/content, terminal receipt, actual route `{"fullCrawl":1}`,
  `{}` fallbacks, resource evidence, and cleanup.
- The original artifact summary recorded primary invalid because the first
  harness revision compared the diagnostic's frozen control-scope context to
  the separate child context and required the non-live sampler spelling
  `physical_footprint_available`. The immutable checkpoints/resources were
  revalidated only after correcting those two validators; no ordinal or raw
  value was rewritten.
- `follow_on_acceptance`: **failed for all six attempts** and remains
  campaign-blocking. Passive tree omitted the required exact current
  marker/legend and selection evidence omitted structured `worktree_scope`;
  the initial collector also mislabeled successful codemap evidence until its
  success default was corrected. Final diagnostic reason was
  `content_oracle_mismatch`. Thus these valid primary values do not make the
  campaign acceptable.
- Resource session: 2,352 samples over 243.4 s; average/peak core
  123.2%/370.1%; resident baseline/peak/final 306.2/390.1/390.1 MiB
  (peak/retained delta 83.9 MiB); physical footprint baseline/peak/final
  117.8/193.3/193.3 MiB (peak/retained delta 75.5 MiB); CPU 299,833.7 ms.

### Projected primary/follow-on status and confirmation rule

Artifact:
`/tmp/rpce-worktree-startup/v1/20260626T183107Z-warm-projected-w1-79fadf26`

- The single predeclared projected invocation timed out after 300 seconds while
  awaiting correlation-scoped `set_flags`. No sample, route, fallback, or
  primary value was produced; acquired session/worktree/resource counts were
  zero and cleanup completed. It was not retried or replaced.
- Projected retained primary raw values: `[]`; p50/p95/CV unavailable.
  Therefore no forced-full/projected improvement claim is possible.
- The predeclared confirmation plan was not run: projected primary CV does not
  exist, so the `>50%` confirmation trigger cannot be evaluated. Series were
  not pooled.

### Transcript/direct-probe smoke and cleanup

- Smoke artifact:
  `/tmp/rpce-worktree-startup/v1/20260626T183642Z-correctness-smoke-4bed38a5`.
  The run timed out after 300 seconds at watcher `apply_edits`, so it is failed
  evidence. The completed parent emitted only eight alternating calls and no
  paired result events; direct structured search passed exact logical/physical
  scope, while direct read lacked unambiguous path attribution. Evidence:
  `/tmp/rpce-worktree-startup/iteration1-measurement-split-20260626T182119Z/smoke-transcript-direct-probe-evidence.json`.
- Both smoke-owned sessions are terminal, the owned parent worktree/branch and
  temporary roots/directories are absent, and raw workspace inventory again
  shows the sole real root. Forced-full and projected cleanup were complete;
  the dedicated diagnostic scope was reset. The exact ownership marker was
  deleted only after purpose/path/workspace/root/owner verification. Proof:
  `/tmp/rpce-worktree-startup/iteration1-measurement-split-20260626T182119Z/final-owned-cleanup-proof.json`.
- Final campaign disposition: **incomplete / fail closed**. Iteration 1 remains
  retained per the Oracle disposition above, but projected primary performance,
  all follow-on acceptance, transcript/direct-probe smoke, and the same-build
  comparison are not established.

## Iteration 1 measurement-support P1 closure correction — 2026-06-26

- Correction to the projected wording above: the 300-second `set_flags`
  timeout was **scope-bound and pre-correlation**, not correlation-scoped. No
  benchmark arm token/correlation was established and no sample, route,
  fallback, or primary value was produced. This wording correction does not
  change the incomplete/fail-closed campaign disposition.
- Reproducible offline primary revalidation provenance is persisted at
  `prompt-exports/worktree-readiness-iteration1-forced-full-revalidation-provenance.json`.
  It records SHA-256 hashes for the frozen plan, artifact plan, summary,
  `samples.ndjson`, resources, cleanup, every source record, and every primary
  checkpoint; validator source SHA-256
  `1ce57f9421137aacc5f0140eae183ea27edf7540b372b9c4c9e7ae73579eef85`
  at validator version 1; and the exact offline command/cwd.
- Source and revalidated retained values are independently recorded as the
  unchanged ordered list `[898.364, 1021.922, 972.808, 946.328, 866.379] ms`;
  the excluded warmup remains `[726.572] ms`. Six unique
  correlation/session identities, exact ordinals 1–6, matching source and
  revalidated checkpoint hashes, exact artifact identity, valid resources,
  and complete cleanup prove the values were neither rewritten nor mixed.
- The harness now fails primary validity for either a false recorded concurrent
  outcome/mark failure or non-overlapping search/read intervals; applies an
  exact single-terminal receipt oracle; and fails follow-on acceptance closed
  on incomplete typed operation/mark/failure inventories or selection
  completion before selection-get. Follow-on failure remains visible and
  campaign-blocking without erasing a valid primary value.
- Closure validation was limited to
  `python3 -m py_compile Scripts/worktree_startup_live_benchmark.py` and
  `python3 Scripts/worktree_startup_live_benchmark.py self-test`; both passed,
  including sequential-operation, receipt, follow-on totalization, provenance,
  cleanup, and unchanged high-CV confirmation-policy cases. No live run,
  relaunch, production edit, broad test, retry/replacement, or commit occurred.
- Oracle iteration-1 decision remains **RETAIN**. Work stops here for independent
  re-review; campaign acceptance remains incomplete because follow-ons and the
  projected comparison are not established.

## 2026-06-26 — Iteration 3 currentness-keyed prefix-control evidence cache (append-only)

### Single attributed implementation and focused validation

- Implemented only the response-bound projected `set_flags` optimization: a
  process-local cache of the verified prefix-control evidence footer, keyed by
  repository identity, canonical worktree-root path plus `lstat` device/inode,
  loaded-root prefix, collector format, authority invalidation/publication
  generations, accepted monitor watermark, and existing mutation state.
- Typed prefix-control monitor coverage observes repository-root-to-prefix
  controls, controls below the prefix, and directory/symlink topology; `.git`
  descendants are excluded. Activation/flush barriers and the synchronous
  accepted-watermark cut fail closed on event, gap, root replacement,
  ambiguity, or stale actor state. The unchanged collector still performs
  no-follow descriptor/path/NFC/corruption checks and preserves cancellation,
  manifest, byte, and lease budgets plus existing topology fallbacks.
- Completed entries and in-flight admissions have separate count/resident/
  artifact-byte limits. Identical work coalesces by exact currentness key;
  waiter cancellation is scoped and flight-ID cleanup cannot remove a newer
  flight. Only the fixed footer and typed monitor token are retained.
- New exact deterministic tests passed for cold/warm/bypass scan counts and
  snapshot parity; coalescing plus scoped waiter cancellation; accepted
  watermark invalidation before actor delivery; corrupt-footer and byte-budget
  cleanup; monitor-unavailable fallback and typed matcher; preparation schema,
  saturation, scope/capacity/expiry, and cancellation-before-lease zero-control.
  Existing 10,001 and 100,000 collectors passed through conductor; the opt-in
  1,000,000 collector passed directly in 192.402 s because conductor cannot
  forward its opt-in environment key. No full suite, release build, or lint ran.
- Coordinated product builds passed: RepoPrompt ticket
  `06edc430-7ea8-4437-bd69-cb3ec81a1ac6`; `repoprompt-mcp` ticket
  `a0fd5d81-e0cc-4234-8c94-2b05b502058b`. Harness Python compile/self-test and
  `git diff --check` passed. The unchanged scoped-control test still expects
  `stale_currentness` while unchanged product logic returns
  `loaded_root_owner_stale`; it was recorded and not repaired.

### Relaunch, frozen scope, plans, and preflights

- The single approved coordinated relaunch passed: ticket
  `23f2e446-cadf-4101-a474-179a617e224a`, PID `24495`.
- Exact build/checkout: HEAD `7bbbd3ec9e966a52065b7398106d877bcba4ce49`,
  2,142 tracked files; app/CLI SHA-256
  `7f14d7b46867bd3d44714933b4270921a211670611d52e800cd72560a365c66b` /
  `78b9037683c1d8322bd34d2d266e286049c075a01577fa3f8339051da15ca647`.
- Fresh window/workspace/context/root: `1` /
  `163E658F-4313-4894-B003-595287E59AE9` /
  `E7BC2FDA-0CBD-4DE9-9C94-C31984E5F783` /
  `A8E3ED38-B9D4-44DE-87C2-4717FFE9DAA0` in
  `RPCE Search Bench Main 20260618` with the sole real checkout root.
- Primary/confirmation plans are under
  `/tmp/rpce-worktree-startup/iteration3-prefix-cache-20260626T195803Z/`.
  File SHA-256: primary
  `38611fb688b033d45203fb6854ca2831a548983a7ce501bfa2876dccb12e38c3`,
  confirmation
  `8e564a5fa6507d8e63a33d504dad381e782f871698fa5e1ba4ae75d52696d356`.
  Frozen plan SHA fields: primary
  `c627812ab2a8c3e15e1545abc842eddd9b97afd402e5822974be2868f065302d`,
  confirmation
  `6d2556de593b0343c3f5a1ac241d22765dfbe2a145d575be5514852bff4a19d2`.
- Fresh exact preflights passed at
  `/tmp/rpce-worktree-startup/v1/20260626T195839Z-preflight-92d45719` and
  `/tmp/rpce-worktree-startup/v1/20260626T195840Z-preflight-572b0ad4`.

### Projected `set_flags` attribution

Artifact raw call:
`/tmp/rpce-worktree-startup/v1/20260626T200311Z-warm-projected-w1-59d08950/raw/0003-set-route-projected.json`.

- Setup returned in 7.466 s wall / 7.425 s attributed total, prepared snapshot
  `2284181fc0644c2a2beac957623287c36bf851ef60de19efcef20f5ffbd496d1`,
  and configured route `diffSeedServing`; it did not hit the 300 s timeout.
- Exact cache counters: 2 authority captures, 1 physical scan, 1 miss, 1 hit,
  1 admission, 0 bypass/coalesce/invalidation/eviction. The two setup consumers
  therefore shared one physical scan. The scan enumerated 115,848 candidates,
  pruned 209 `.git` directories, and hashed 340 controls; the directory counter
  remained 0 and loaded-searchable counters remained 0, so those attributions
  are unavailable rather than inferred.
- Major phase durations: prefix scan 4,545.623 ms; combined authority metadata
  4,702.651 ms; discovery capture 4,626.857 ms; catalog manifest build
  2,621.477 ms; captured capture 76.148 ms; snapshot materialization 69.958 ms;
  tree spool 27.001 ms; cache lookup/admit 0.583/0.170 ms. Scan time was 61.2%
  of `set_flags_total`; physical candidates were 54.1x the exact tracked count.
- Forced-full preparation was the zero-work control: 0 captures/scans/cache
  events and 0.113 ms `set_flags_total`. Thus forced→projected counter deltas
  were +2 captures, +1 scan/miss/hit/admission, +115,848 candidates, +209 prunes,
  and +340 controls. A real bypass/warm setup A/B was not run after the mandated
  cohorts; deterministic tests prove 2/1/0 bypass/cold/warm scan behavior.

### Width-1 numeric cohorts (forced-full first, projected second)

Forced-full artifact:
`/tmp/rpce-worktree-startup/v1/20260626T195921Z-warm-forced-full-w1-5dc66787`.

- One excluded warmup plus five retained completed without replacement. Warmup
  raw primary: `[815.105] ms`; retained raw primary:
  `[1027.499, 963.629, 873.941, 966.917, 939.151] ms`.
- Raw p50 / nearest-rank p95 / population CV:
  `963.629 ms` / `1027.499 ms` / `0.051959`.
- Actual route/fallback was exactly `{"fullCrawl":1}` / `{}` per sample
  (aggregate `{"fullCrawl":6}` / `{}`). All six primary records were invalid
  solely as `resource_evidence_invalid` (`inconsistent_resident_peak_delta`),
  while all six separate follow-ons were accepted. Valid retained count: 0.
- Resources: 2,039 samples over 210.9 s; average/peak core 132.7%/405.0%;
  resident baseline/peak/final 329.2/437.4/431.0 MiB (peak delta 108.3 MiB);
  physical footprint baseline/peak/final 119.7/225.5/198.6 MiB
  (peak delta 105.8 MiB); session CPU 279,736.6 ms.

Projected artifact:
`/tmp/rpce-worktree-startup/v1/20260626T200311Z-warm-projected-w1-59d08950`.

- One excluded warmup plus five retained completed without replacement. Warmup
  raw primary: `[1286.730] ms`; retained raw primary:
  `[1180.898, 1171.841, 1132.876, 1456.798, 1227.935] ms`.
- Raw p50 / nearest-rank p95 / population CV:
  `1180.898 ms` / `1456.798 ms` / `0.093511`.
- Every sample was invalid: actual route/fallback was
  `{"diffSeedServing":1,"fullCrawl":1}` /
  `{"compatibilityMismatch":1}` (aggregate each count 6), not the required
  projected-only route with empty fallback. Valid retained count: 0; no timing
  improvement or p95 claim is made.
- All six follow-ons failed and remain separate: route/fallback/receipt contract,
  incomplete planner evidence, first-codemap timeout in at least the warmup,
  passive-tree current-marker validation, and selection `worktree_scope`
  validation. These were not repaired.
- Resources: 3,515 samples over 364.6 s; average/peak core 121.1%/389.7%;
  resident baseline/peak/final 521.5/579.5/573.9 MiB (peak delta 58.0 MiB);
  physical footprint baseline/peak/final 246.8/267.4/239.3 MiB
  (peak delta 20.6 MiB); session CPU 441,393.7 ms.

### Stop, follow-on smoke, cleanup, and recommendation

- The projected mixed route plus `compatibilityMismatch` fallback triggered the
  frozen stop rule. No confirmation, replacement, numeric rerun, bypass cohort,
  or additional correctness repair was attempted.
- The requested correctness-only live Agent Mode smoke was therefore **skipped**:
  running it after an invalid projected route would violate the earlier
  stop-on-route/fallback rule. No inference timing claim was created.
- Both cohort summaries report cleanup complete. All 12 owned Agent sessions are
  terminal, all 12 owned worktrees are absent, memory samplers stopped, route and
  diagnostics reset, and the sole workspace root restored. The ownership marker
  was removed only after exact identity verification. Proof:
  `/tmp/rpce-worktree-startup/iteration3-prefix-cache-20260626T195803Z/final-owned-cleanup-proof.json`.
  Harness-created sample branch refs were preserved as immutable provenance.
- Machine-readable rollup:
  `/tmp/rpce-worktree-startup/iteration3-prefix-cache-20260626T195803Z/iteration3-measurement-summary.json`.
- Recommendation: **REVERT / do not retain**. The cache removed the duplicated
  physical scan and made projected setup return in 7.5 s, but mandatory serving
  route/fallback, valid primary cohorts, warm setup A/B, resource comparison,
  and follow-on acceptance gates did not pass. No commit was created.

## 2026-06-26 — Prefix-cache iteration identity and disposition supersession (append-only)

- The section headed `Iteration 3 currentness-keyed prefix-control evidence
  cache` is superseded **for iteration identity and disposition only**. Its raw
  measurements, hashes, artifact paths, invalid route/fallback evidence, and
  cleanup proof remain unchanged.
- The prefix-control evidence cache is **iteration 2**, the next sequential
  campaign after completed iteration 1. The planned iteration-2 narrowed
  mutation-lock row was never implemented or measured and confers no iteration
  identity; this cache did not change mutation-lock behavior.
- Iteration 3 remains the distinct reserved
  `demand-reserved CodeMap capacity, only if attributed` row. No CodeMap
  scheduler/capacity change is part of prefix-cache iteration 2.
- Historical `/tmp/.../iteration3-prefix-cache-...` directory names and the
  `iteration3-measurement-summary.json` filename are immutable artifact labels,
  not the corrected campaign identity; they are not renamed or rewritten.
- Independent verdict supersedes the earlier `REVERT / do not retain`
  recommendation with **REPAIR THEN RETAIN**, limited to four P1 repairs:
  separated prefix/full-monitor recovery authority, bounded saturated/cancelled
  single-flight accounting, recoverable DEBUG preparation-owned route controls,
  and this append-only identity correction. Retention remains pending the
  requested exact focused validation and independent re-review; no new live or
  performance claim is introduced here.

## Worktree startup live benchmark — 20260626T211823Z-3d45d8c0

- Plan SHA-256: `892f2d5c6a20d60a2505f80cadc4c5bc94a879b56b694abf37cd1fcdcd81fdc7`
- Decision: **fail**
- Generated: `2026-06-26T21:18:23.910608Z`

| cohort | metric | N | p50 µs | p95 µs | CV |
|---|---|---:|---:|---:|---:|
| `warm/linked-worktree/forced-full/1` | `materialize_to_root_ready` | 0 | None | None | None |
| `warm/linked-worktree/forced-full/1` | `materialize_to_first_search` | 0 | None | None | None |
| `warm/linked-worktree/forced-full/1` | `materialize_to_first_read` | 0 | None | None | None |
| `warm/linked-worktree/forced-full/1` | `interactive_readiness_us` | 0 | None | None | None |
| `warm/linked-worktree/forced-full/1` | `first_search` | 0 | None | None | None |
| `warm/linked-worktree/forced-full/1` | `first_read` | 0 | None | None | None |
| `warm/linked-worktree/forced-full/1` | `first_codemap` | 0 | None | None | None |
| `warm/linked-worktree/forced-full/1` | `warm_codemap` | 0 | None | None | None |
| `warm/linked-worktree/forced-full/1` | `passive_tree` | 0 | None | None | None |
| `warm/linked-worktree/forced-full/1` | `selection` | 0 | None | None | None |
| `warm/linked-worktree/projected/1` | `materialize_to_root_ready` | 0 | None | None | None |
| `warm/linked-worktree/projected/1` | `materialize_to_first_search` | 0 | None | None | None |
| `warm/linked-worktree/projected/1` | `materialize_to_first_read` | 0 | None | None | None |
| `warm/linked-worktree/projected/1` | `interactive_readiness_us` | 0 | None | None | None |
| `warm/linked-worktree/projected/1` | `first_search` | 0 | None | None | None |
| `warm/linked-worktree/projected/1` | `first_read` | 0 | None | None | None |
| `warm/linked-worktree/projected/1` | `first_codemap` | 0 | None | None | None |
| `warm/linked-worktree/projected/1` | `warm_codemap` | 0 | None | None | None |
| `warm/linked-worktree/projected/1` | `passive_tree` | 0 | None | None | None |
| `warm/linked-worktree/projected/1` | `selection` | 0 | None | None | None |

### Route and work attribution

| cohort | primary retained | follow-on accepted | routes | fallbacks | Git commands p50 | Git µs p50 | FS ops p50 | FS µs p50 | CPU ms | peak physical Δ MB | retained physical Δ MB |
|---|---:|---:|---|---|---:|---:|---:|---:|---:|---:|---:|
| `warm/linked-worktree/forced-full/1` | 0 | 5 | `{}` | `{}` | None | None | None | None | None | None | None |
| `warm/linked-worktree/projected/1` | 0 | 0 | `{}` | `{}` | None | None | None | None | None | None | None |

### Gates

| gate | result |
|---|---|
| projected interactive-readiness p95 improvement >= 30% | `incomplete` |
| zero correctness mismatches | `incomplete` |
| zero invalid attempted samples | `fail` |
| zero eligible warm fallbacks | `fail` |
| other p95 regression <= 10% | `incomplete` |
| peak memory regression <= 10% | `incomplete` |
| complete route/process/checkout/width matrix | `incomplete` |
| exact actual routes and zero fallbacks | `incomplete` |
| complete Git/filesystem attribution | `incomplete` |
| complete CPU attribution | `incomplete` |
| stable owned-resource teardown | `pass` |
| required external process/main-root evidence | `incomplete` |

### Evidence

- Correctness results: `{'campaign_count': 0, 'mismatch_count': 0, 'covered_scenarios': []}`
- Invalid attempted samples: `12`
- Invalid retained samples: `10`
- Primary-invalid attempted samples: `12`
- Follow-on-failed attempted samples: `6`
- Artifact directories: `/private/tmp/rpce-worktree-startup/v1/20260626T210605Z-warm-forced-full-w1-d854359d, /private/tmp/rpce-worktree-startup/v1/20260626T211136Z-warm-projected-w1-aa4258a3`

### 2026-06-26 prefix-cache final closure measurement detail

- Single approved post-closure relaunch: conductor ticket `7b085439-023d-4db7-95e4-bce309211b4a`; app PID `14526`; CLI SHA-256 `c00311f7ad82d44d5f3867fccf584950cae595afef93986e4a73e5fa48cc8b0c`.
- Fresh live scope: window `1`, workspace `163E658F-4313-4894-B003-595287E59AE9`, context `C4022447-5D29-4E76-99CA-36D6826F2428`, root `0E948144-824D-412F-97F1-347E0B4DD59A`, sole root `/Users/pvncher/Documents/Git/repoprompt-ce-release`; commit `eaaf34f1d8213d1ff30ca70ba6be9014e1d4f9fe`; tracked files `2142`.
- Primary plan file/embedded SHA-256: `ac11e6da69e7dfa7144d774c58287b2752b7b53fb9020fff2133961181d5f3f2` / `892f2d5c6a20d60a2505f80cadc4c5bc94a879b56b694abf37cd1fcdcd81fdc7`; confirmation: `c8d41f1bab84b46909eb83fe5dd2818950e2094fd81159d4f53e64a3c1431030` / `c2d265b5b9de209aba36c05a5909334dea70bd688f8563b1a1bd9bde0f2e4d4a`.
- Exact preflights passed at `/tmp/rpce-worktree-startup/v1/20260626T210528Z-preflight-13b9f1d5` and `/tmp/rpce-worktree-startup/v1/20260626T210530Z-preflight-f2b42736`.
- Forced-full raw diagnostic routes were exactly `{"fullCrawl":1}` with `{}` fallbacks for all six ordinals. All five retained follow-ons passed, but no primary value was accepted because each resource proof reported `inconsistent_resident_peak_delta`, `inconsistent_resident_retained_delta`, and `inconsistent_physical_footprint_retained_delta`. Unaccepted retained raw interactive-readiness values were `[1071739, 942214, 920476, 1069231, 936891]` µs (p50 `942214`, nearest-rank p95 `1071739`, population CV `6.8458%`).
- Projected preparation succeeded in `7212568` µs with terminal `admitted`, route `diffSeedServing`, and exact counters: authority captures `2`; prefix cache misses `1`, hits `1`, admissions `1`, scans `1`; bypasses/coalesces/invalidations/evictions all `0`; no saturated counter. The scan enumerated `115864` candidates, pruned `209` directories, and produced `340` control records.
- Every projected ordinal then recorded mixed raw routes `{"diffSeedServing":1,"fullCrawl":1}` and fallback `{"compatibilityMismatch":1}`. No projected primary or follow-on was accepted. Unaccepted retained raw interactive-readiness values were `[1175865, 1343948, 1376082, 1304783, 1251463]` µs (p50 `1304783`, nearest-rank p95 `1376082`, population CV `5.4851%`).
- Stop rule applied: no repair, replacement, numeric rerun, confirmation, or correctness-only Agent Mode smoke. Confirmation was both untriggered (CVs were below 50%) and barred because no valid primary comparison existed and projected fell back.
- Aggregate: `/tmp/rpce-worktree-startup/iteration2-prefix-cache-final-20260626T210455Z/aggregate/summary.json` (SHA-256 `ca9b22b67653727850fa26226edb52a5c32f736892278841339adbc8013feafb`). Final owned cleanup proof: `/tmp/rpce-worktree-startup/iteration2-prefix-cache-final-20260626T210455Z/final-owned-cleanup-proof.json`; 12/12 sessions terminal, 12/12 worktrees absent, samplers stopped, route/diagnostics restored, benchmark gate unchanged, sole workspace root restored, exact ownership marker removed, harness branch refs preserved.

## 2026-06-26 projected compatibility diagnostics-first hardening stop

- Decision: **stop after diagnostics; no compatibility correction authorized**.
- Relaunch: conductor ticket `a4d07091-fc37-47fb-a781-9658d3119d64`, app PID `80403`; CLI SHA-256 `414fb2ab1410ebb19ab468b0da97b0246e47361875d875d12b5ab9b1cb692743`.
- Fresh sole-root real-repository scope: workspace `D5EB121C-2FB4-4700-9804-61140152F7E9`, context `18AFF07C-9663-442E-989D-90FC0599417F`, root `B4A0BB39-FF17-4F12-9C02-402E3A9241C1`; commit `b0673caf0fdb21ac90326b004b41607514dafb96`, tracked files `2142`.
- Plan: `/tmp/rpce-worktree-startup/compatibility-hardening-20260626T213859Z/plan.json`, embedded SHA-256 `b4fea8caa0325ac6828eac5050e808d431342fb7f3cecbf446ac597f2fed8041`. Exact preflight: `/tmp/rpce-worktree-startup/v1/20260626T213902Z-preflight-addef09e`.
- One diagnostic projected sample used the committed harness with an ephemeral diagnostic-only `0 + 1` cohort override because the production runner enforces `1 + 5`. Artifact: `/tmp/rpce-worktree-startup/v1/20260626T213928Z-warm-projected-w1-13a02e8f`; `samples.ndjson` SHA-256 `beaab292970d815f652bbdc9a774845361f522e93910a62c99c422f15a5566e6`; `summary.json` SHA-256 `7960fe0b5d6823bd92addfc23372c68ae44feb1b34a5cf5ad00c7482c10ccdf0`.
- Preparation was terminal `admitted` and configured `diffSeedServing`. The sample recorded exactly one correlation-scoped evaluator compatibility evaluation, no eviction, duplicate, or contradiction, and no planner evaluation because the evaluator failed closed.
- Every namespace/object/prefix/inventory/search-ABI/external-authority field matched. The exact mismatch set was `[committedIgnoreControlDigest, attributePolicyDigest]`; `correctionRuleApplied=none`; tree was `sameExcludedFromDeltaCompatibility`; current-search-ABI was not reached after the incompatible decision.
- Raw route/fallback evidence was `{"diffSeedServing":1,"fullCrawl":1}` / `{"compatibilityMismatch":1}`. The primary was invalid; accepted N=`0`, p50=`None`, p95=`None`, CV=`None`. The single unaccepted raw interactive-readiness value was `1288575` µs.
- Follow-on acceptance: **false**, with `actual_route_counts_mismatch`, `unexpected_fallback`, and `incomplete_planner_evidence`. No forced-full/projected `1 + 5`, performance comparison, or correctness-only Agent Mode smoke was run because the evidence gate failed before correction.
- Recommendation: retain the diagnostics/evaluator/planner hardening for independent review, but do not normalize or waive either semantic policy digest. A follow-on repair requires a separate design proving layout-neutral committed ignore/attribute policy construction; it is outside this atomic change.
- Final owned cleanup: `/tmp/rpce-worktree-startup/compatibility-hardening-20260626T213859Z/final-owned-cleanup-proof.json`; session terminal, sampler stopped, route restored, diagnostics reset, worktree/branch absent, three owned temporary workspaces deleted, and ownership marker removed.
- Final focused validation passed: format/lint tickets `9569fea1-5345-4490-b5ca-51345127ea78` / `c8c4150b-9de3-41e7-bd7a-6c2a1ef53f79`; exact compatibility, mismatch-pair, instrumentation, schema-v5, and non-Git filters; RepoPrompt compile ticket `f7ca9c51-b599-4049-80c8-d13396e5d82d`; harness self-test `175/175`. Broader class attempts exposed unrelated existing currentness/race expectation failures and were not used as acceptance evidence.

### 2026-06-26 independent-review correction

- The two observed digest mismatches are stable **identity mismatches**, not proof of semantic committed-ignore or attribute-policy differences. The prior wording that characterized them as semantic policy differences was too strong; no compatibility correction is authorized by this evidence.
- The live policy scan produced `340` records and included ignored `.build` content, while the committed-tree control inventory contained `5` tracked controls. Consequently, the effective-policy meaning of the two identities remains unresolved and requires separate investigation.
- The prior final-cleanup statement incorrectly claimed that the benchmark branch was absent. Dated ownership evidence subsequently matched the artifact state, exact branch identity, prior worktree removal, and immutable head before the exact owned branch was deleted; ref absence was then verified.
- Redacted correction proof: `/tmp/rpce-worktree-startup/compatibility-hardening-20260626T213859Z/cleanup-correction-20260626T220016Z/branch-cleanup-proof.json`; SHA-256 `676bba7b36b679eb91b23e9757ac2b40411f9b9da766521fdb90d1073ec727f1`; private directory mode `0700`, proof mode `0600`. Artifact identity SHA-256 `71d251057d4581744a9225deb392c6ee8ecd4500922b8ce8baf6d88638b0214c`; branch identity SHA-256 `0c077941979b086ae4a889eeaa67cc0451acd2b7ab10d4be56e1ffde69b73933`. The proof contains no raw path or session ID.

## 2026-06-26 schema-6 physical-receipt diagnostics-first stop

- Decision: **stop before numeric cohorts; no source or gate changes authorized**.
- The single approved coordinated relaunch passed: conductor ticket `da5e517b-5ff3-444d-82e5-8ccf6487c75f`, app PID `92868`. Exact checkout HEAD: `4fa053db37a7045291b76753b48c10f3457209cf`; tracked files: `2142`; app/CLI SHA-256: `fa03cb6c908f50ba92a04bec3ed29c094d25a6b30885f3a88591431ddee8c8ac` / `f625b800ed054975bc3085b5df00e6fe53a318bf174fcaa731329c3442f2193a`.
- Fresh dedicated sole-root scope: window `2`, workspace `B4B552C4-CA1E-42E7-96FD-905C30A89281`, context `48005112-CB62-449B-9A45-E7C9AF1EDA86`, root `757AD1FE-7B18-4B1A-8119-659F22208F7F`, workspace `RPCE Search Bench Final 20260626T230739Z`.
- Frozen primary/confirmation plans: `/tmp/rpce-worktree-startup/final-physical-receipt-20260626T230739Z/primary-plan.json` and `confirmation-plan.json`; file SHA-256 `c4d3fcbf1bf8bb3e0c44d33fa7a732b63a11e8d3408a01243a5653cc4c12d5ff` / `dac341835144a54dfb02acb943248c0c5ca802b2c9ef085744866c402d743f68`; embedded plan SHA-256 `d2973433ea38f0bea139c2e96b45554fb2f6551b5a8cd167349112114ca447cc` / `347391c06f5f348ee9ce360174eee5b6ee535550d8520c6a385ae5f22ee7832f`. Exact preflights passed at `/tmp/rpce-worktree-startup/v1/20260626T230911Z-preflight-33895816` and `/tmp/rpce-worktree-startup/v1/20260626T230912Z-preflight-bbdef138`.
- The required non-aggregatable schema-6 policy/receipt probe failed closed: `/tmp/rpce-worktree-startup/v1/20260626T230927Z-policy-digest-probe-53ccbf64`; `summary.json` / `samples.ndjson` / `cleanup.json` SHA-256 `a7bff55e9c00ce55237b5f4816e6ebb5cf86800f0ff23b8dc40277b2fe77e406` / `05cd259089511c8dc4be9278fe6b21e305565762bb28370215888e8ee86057a6` / `116ec1b20dacfb50c7f76bb152e359a132a0517ff6176e13f9bbffd1bd11ea94`.
- Raw physical receipt capture succeeded: one decision, one terminal consumption decision, `receiptEmitted`, current snapshot present/content-address valid, target authority capture `succeeded`, witness interval proved, and selected route `diffSeedServing`. The strict committed receipt oracle nevertheless rejected the expanded creation payload as `receipt_projected_decision_contract_mismatch`; the captured payload includes the new physical fields and `include_copy_result_present=false`.
- Evaluator then planner both reported `compatible`, empty mismatch sets, and `correctionRuleApplied=none`; all delta identity digests matched. Schema-6 canonicalization still failed: base was `complete` with 5 committed controls while target was `cachedWithoutDetail` with 0, yielding `classification=incomplete` for both sources.
- Actual final diagnostic route/fallback was `{"diffSeedServing":4}` / `{}`, not the required exact `{"diffSeedServing":1}` / `{}`. Primary root readiness and search succeeded with exact logical/physical scope. Direct read transport/content succeeded, but the frozen marker `WorkspaceRootSeedPlanner` was outside the harness's first-80-line read slice, so the primary content oracle was invalid; resource proof also reported `inconsistent_physical_footprint_retained_delta`.
- Follow-on acceptance remained separate and failed for passive-tree current-marker and selection `worktree_scope` validation. These follow-on failures did not overwrite the independent primary failures above.
- Because the mandatory policy/receipt probe failed, no forced-full/projected `1 + 5` numeric cohorts were started, no primary CV existed, confirmation was not eligible, and the actual Agent Mode smoke was not run. No aggregate or performance claim was produced.
- Probe cleanup completed: owned session terminal, memory sampler verified stopped, route restored, diagnostics reset, benchmark setting unchanged, owned worktree/branch absent, and sole workspace root restored. Final operator cleanup removes the ownership marker and dedicated workspace/window after this append.
- Final operator cleanup then passed: the exact ownership marker was hash-verified and removed, the dedicated workspace was deleted, window `2` closed, and post-cleanup inventory contained only window `1` with no benchmark workspace. Proof: `/tmp/rpce-worktree-startup/final-physical-receipt-20260626T230739Z/final-owned-cleanup-proof.json`; SHA-256 `21b8c7ab6065e0018fcf361f001d07d9bb9c8ebc9892a7af149deca3689db9e6`.

### 2026-06-26 closure correction

- The schema-6 policy/receipt probe above **failed and remained incomplete**. It made no acceptance, correctness, route-parity, performance, or retention claim; no projected result from that probe is valid acceptance evidence.

## 2026-06-26 fresh current-source real-repository measurement — INVALID DIAGNOSTIC

- Decision: **invalid / incomplete; baseline unchanged**. No timing below is accepted performance evidence.
- Current-source launch used coordinated `./conductor app relaunch`: ticket `721b3271-4605-421a-a94f-e3b139b78abd`, PID `30291`, log `/tmp/rpce-worktree-startup/fresh-live-20260626T234745Z/conductor-app-relaunch.log`. Benchmark build identity was commit `4fa053db37a7045291b76753b48c10f3457209cf`, 2,142 tracked files, CLI SHA-256 `89795c14c2eb51a9b80ec294c292fd9a5aee1bdce48dc150e45b0bd78a46c568`.
- Dedicated real-repository scope: window `1`, workspace `RPCE Search Bench Main 20260618` / `163E658F-4313-4894-B003-595287E59AE9`, control context `E7BC2FDA-0CBD-4DE9-9C94-C31984E5F783`, fresh root `A2B5F7F9-A325-4E75-96FA-73022B97AE00`, sole primary root `/Users/pvncher/Documents/Git/repoprompt-ce-release`.
- Frozen plan: `/tmp/rpce-worktree-startup/fresh-live-20260626T234745Z/plan.json`; file SHA-256 `a5ad12c0d26cdc3d7692a047bd4982f0107154ad3eaf107fa9b3dab19c624cb3`; embedded plan SHA-256 `74359cf3ebcdaa94d0cda1d2e4f47e1b96fa310d8dcaa6489a7504318a0b6536`. Preflight passed at `/tmp/rpce-worktree-startup/fresh-live-20260626T234745Z/artifacts/20260626T235158Z-preflight-edc80246`.

### Exact commands

```bash
./conductor app relaunch
rpce-cli-debug -w 1 -e 'workspace switch "RPCE Search Bench Main 20260618"'
rpce-cli-debug --raw-json -w 1 -c app_settings -j '{"op":"set","key":"agent_mode.worktree_startup_benchmark_diagnostics_enabled","value":true}'

python3 Scripts/worktree_startup_live_benchmark.py create-marker \
  --root-path /Users/pvncher/Documents/Git/repoprompt-ce-release \
  --workspace-id 163E658F-4313-4894-B003-595287E59AE9 \
  --root-id A2B5F7F9-A325-4E75-96FA-73022B97AE00 \
  --owner-token 5028F88B-1D15-41EB-AF89-E199CF1EB2AC \
  --confirm-real-repository-benchmark --confirm-dedicated-workspace

python3 Scripts/worktree_startup_live_benchmark.py plan \
  --workspace-name 'RPCE Search Bench Main 20260618' --window-id 1 \
  --workspace-id 163E658F-4313-4894-B003-595287E59AE9 \
  --context-id E7BC2FDA-0CBD-4DE9-9C94-C31984E5F783 \
  --root-id A2B5F7F9-A325-4E75-96FA-73022B97AE00 \
  --root-path /Users/pvncher/Documents/Git/repoprompt-ce-release \
  --owner-token 5028F88B-1D15-41EB-AF89-E199CF1EB2AC \
  --dataset-label rpce-real-readiness-fresh-20260626T235126Z \
  --asserted-file-count 2142 --base-ref HEAD \
  --search-marker WorkspaceRootSeedPlanner \
  --read-path Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/WorkspaceRootSeedPlanner.swift \
  --read-marker 'import CryptoKit' --invocations-per-series 1 \
  --confirm-real-repository-benchmark --confirm-dedicated-workspace \
  --output /tmp/rpce-worktree-startup/fresh-live-20260626T234745Z/plan.json

python3 Scripts/worktree_startup_live_benchmark.py preflight \
  --plan /tmp/rpce-worktree-startup/fresh-live-20260626T234745Z/plan.json \
  --cli "$(command -v rpce-cli-debug)" \
  --output-root /tmp/rpce-worktree-startup/fresh-live-20260626T234745Z/artifacts \
  --confirm-live-debug-app --confirm-dedicated-workspace

python3 Scripts/worktree_startup_live_benchmark.py run \
  --plan /tmp/rpce-worktree-startup/fresh-live-20260626T234745Z/plan.json \
  --cli "$(command -v rpce-cli-debug)" \
  --output-root /tmp/rpce-worktree-startup/fresh-live-20260626T234745Z/artifacts \
  --route forced-full --process-state warm --checkout-kind linked-worktree \
  --width 1 --invocation 1 --warmups 1 --samples 5 \
  --confirm-live-debug-app --confirm-process-state --confirm-dedicated-workspace

python3 Scripts/worktree_startup_live_benchmark.py run \
  --plan /tmp/rpce-worktree-startup/fresh-live-20260626T234745Z/plan.json \
  --cli "$(command -v rpce-cli-debug)" \
  --output-root /tmp/rpce-worktree-startup/fresh-live-20260626T234745Z/artifacts \
  --route projected --process-state warm --checkout-kind linked-worktree \
  --width 1 --invocation 1 --warmups 1 --samples 5 \
  --confirm-live-debug-app --confirm-process-state --confirm-dedicated-workspace
```

### Raw, unaccepted timing statistics

Population variance is in µs². Projected has only one retained ordinal, so its zero variance and p95 are arithmetic artifacts, not distribution evidence.

| cohort | metric | raw retained N | median µs | nearest-rank p95 µs | population variance µs² | population CV |
|---|---|---:|---:|---:|---:|---:|
| forced-full | materialize to root ready | 5 | 444,522 | 534,956 | 2,302,078,987.84 | 10.6273% |
| forced-full | materialize to first search | 5 | 1,077,587 | 1,124,547 | 2,547,814,074.56 | 4.7651% |
| forced-full | materialize to first read | 5 | 978,534 | 1,171,765 | 8,766,232,278.24 | 9.3343% |
| forced-full | interactive readiness | 5 | 1,077,587 | 1,171,765 | 4,137,179,509.44 | 6.0185% |
| forced-full | first search | 5 | 410,525 | 477,625 | 1,110,059,068.24 | 7.9912% |
| forced-full | first read | 5 | 269,897 | 395,015 | 3,644,043,871.44 | 19.3328% |
| forced-full | first codemap | 5 | 4,451,197 | 7,139,946 | 1,338,280,276,915.04 | 23.7796% |
| forced-full | warm codemap | 5 | 118,060 | 132,843 | 45,037,018.24 | 5.5481% |
| forced-full | passive tree | 5 | 4,243,395 | 5,849,075 | 1,883,061,753,896.96 | 34.2449% |
| forced-full | selection | 5 | 21,318,133 | 21,613,823 | 65,918,032,625.44 | 1.2077% |
| projected | materialize to root ready | 1 | 3,193,741 | 3,193,741 | 0 | N/A (N=1) |
| projected | materialize to first search | 1 | 3,716,490 | 3,716,490 | 0 | N/A (N=1) |
| projected | materialize to first read | 1 | 3,663,904 | 3,663,904 | 0 | N/A (N=1) |
| projected | interactive readiness | 1 | 3,716,490 | 3,716,490 | 0 | N/A (N=1) |
| projected | first search | 1 | 319,672 | 319,672 | 0 | N/A (N=1) |
| projected | first read | 1 | 215,912 | 215,912 | 0 | N/A (N=1) |
| projected | first codemap | 1 | 5,275,112 | 5,275,112 | 0 | N/A (N=1) |
| projected | warm codemap | 1 | 125,458 | 125,458 | 0 | N/A (N=1) |
| projected | passive tree | 1 | 11,517,582 | 11,517,582 | 0 | N/A (N=1) |
| projected | selection | 1 | 21,904,070 | 21,904,070 | 0 | N/A (N=1) |

- Forced-full retained raw interactive readiness: `[1040749, 973445, 1077587, 1080091, 1171765]` µs. All six ordinals had exact `{"fullCrawl":1}` and `{}` fallback; aggregate attempted routes `{"fullCrawl":6}`. All five retained follow-ons passed, but every primary failed `inconsistent_physical_footprint_retained_delta`; accepted primary N=`0`.
- Projected preparation reached terminal `admitted` in `3172401` µs: authority captures `2`, prefix misses/hits/admissions/scans `1/1/1/1`, `2,664` candidates, `431` directories, `8` pruned directories, `5` control records, no bypass/coalesce/invalidation/eviction/saturation.
- Projected completed only the excluded warmup plus retained ordinal 2. Each recorded `{"diffSeedServing":4}` and `{}` fallback, aggregate attempted routes `{"diffSeedServing":8}`. This is **not** the required exact per-ordinal `{"diffSeedServing":1}` route and was rejected as `actual_route_counts_mismatch`; resources also failed resident peak/retained-delta consistency and cleanup completeness. Retained raw interactive readiness was `[3716490]` µs; accepted N=`0`.
- Raw retained work attribution: forced-full Git command count median/p95/variance `1024/1024/0`, Git duration `9986857/10273370/30890406346.96` µs², Git queue `9240920/9523577/24912909158.56` µs², filesystem ops `1/1/0`, filesystem duration `360685/411777/619958638.24` µs². Projected N=`1`: Git commands `1024`, Git duration `10809714` µs, Git queue `9327348` µs, filesystem ops/duration `0/0`; none is accepted comparison evidence.

### Failure, smoke, and cleanup disposition

- The third projected `agent_run start` timed out after 180 seconds. The run stopped with 2/6 attempted samples; `restore_flags` then timed out after 300 seconds, and the first idempotent cleanup attempt timed out after 300 seconds in `manage_worktree list`.
- Recovery used coordinated `./conductor app relaunch`: ticket `4e13d1d5-5c6d-4a23-97d2-855533312a03`, PID `70173`, log `/tmp/rpce-worktree-startup/fresh-live-20260626T234745Z/conductor-recovery-relaunch.log`. The restart expired both recorded session control handles. Because ownership continuity and route reset could not be proven across restart, harness cleanup remains correctly `false` even though the sampler is stopped, the sole workspace root is restored, and the final live inventory contains zero benchmark-owned worktrees.
- The exact marker SHA/owner matched the frozen plan before removal. The timed-out third start left one clean worktree at the frozen HEAD; it was removed after exact head/branch/clean verification while its branch was preserved. Proof: `/tmp/rpce-worktree-startup/fresh-live-20260626T234745Z/orphan-worktree-cleanup-proof.json`, SHA-256 `d7de4695b7aa48bca4d605f589e6500a0833f10d1f558d1521a052f09b1a64eb`.
- The conditional real Agent Mode functional smoke was **not run**. Projected did not satisfy exact `diffSeedServing` attribution, the planned `1 + 5` cohort did not complete, and accepting the four-observation route as projected would violate the gate.
- Raw receipts: forced-full `/tmp/rpce-worktree-startup/fresh-live-20260626T234745Z/artifacts/20260626T235234Z-warm-forced-full-w1-d85350b3` (`summary`/`samples`/`cleanup` SHA-256 `0aff84f4d1429dd6fe1972c55df48ca153e1c0f679e6a018cc69a4799311b9c2` / `d8443a864281232843aac2b0d439a3b41938a6862225d1d5edba9430dcc8048f` / `2f983b5307d6bd704cf2ed0891c4746dcabb1c6e672f2c5e5cd7c0e0ffa8362e`); projected `/tmp/rpce-worktree-startup/fresh-live-20260626T234745Z/artifacts/20260626T235627Z-warm-projected-w1-160baa2e` (`aed858be58ffcf6bc09c540400945e0cbaac6d0a808805e60f92ee521965e9b0` / `65809dccbf62ca6123764651dc478f1bbc68104183ee9e5e135fff97ae27ac97` / `1882e121193432ef2db05d4f5887e6ffbd3af99f774417c1e7eee1cb972f8296`). Derived raw rollup: `/tmp/rpce-worktree-startup/fresh-live-20260626T234745Z/derived-measurement-summary.json`, SHA-256 `2c56c0c99808e13bbc3979113fe6f5bbc7b4f84e809f0a6aa1394020b588f233`. Full logs and 285 artifact hashes remain under `/tmp/rpce-worktree-startup/fresh-live-20260626T234745Z/`.

## 2026-06-27 current-source measurement attempt — INVALID: concurrent source drift

- Decision: **invalid diagnostic; no accepted performance row and baseline unchanged**. The exact packaged source changed during the forced-full sequence and continued changing through two bounded stability monitors, so the completed raw samples are not comparable current-stable-source evidence.
- Coordinated package/relaunch passed: conductor ticket `594ef9ca-05b3-42b1-afee-88fa0591d870`, app PID `17729`, log `/tmp/rpce-worktree-startup/current-stable-20260627T003347Z/conductor-app-relaunch.log` (daemon log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/594ef9ca-05b3-42b1-afee-88fa0591d870.log`). HEAD was `4fa053db37a7045291b76753b48c10f3457209cf`; packaged source manifest covered 1,225 build/harness files and had SHA-256 `757dd0ccb1e8650a88a506249ba09d91c96545fc10ac5770556af55cf93d06ee`. The before/after-relaunch manifest files were byte-identical (file SHA-256 `db97644a4c5c8eeef763d9e97f568f9367a05bd09d7e2133cdc748f9d6df194f`). Packaged app/CLI SHA-256: `c85b7f50f47de192dd0ffc82b45f8e812207f1a865b39187c290b065add6cfa3` / `f060c3d6073dffb12852180c3fac09acba059081494aa3325d167aea85f16dc1`.
- Dedicated scope: window `1`, workspace `RPCE Search Bench Main 20260618` / `163E658F-4313-4894-B003-595287E59AE9`, control context `E7BC2FDA-0CBD-4DE9-9C94-C31984E5F783`, root `F1FDF00B-CD0B-4139-85E6-61B50545E4BC`, sole root `/Users/pvncher/Documents/Git/repoprompt-ce-release`. Plan `/tmp/rpce-worktree-startup/current-stable-20260627T003347Z/plan.json`: file/embedded SHA-256 `f955b20f656a10b72b96f60c924d458fef3243686443012ee9b9fe0ae31ff973` / `007c13a6c30e37da7c6a1b6e90c3a5d694bcb1c74dd63032f56c3d1ae98346b4`.
- Documented preflight passed at `/tmp/rpce-worktree-startup/current-stable-20260627T003347Z/artifacts/20260627T003538Z-preflight-ff36bc14`; `summary.json` SHA-256 `9314fce95f8a263ea8c295248497c0a6c10a63bc47a4f73e98fa0c66e6913d39`.

### Raw corrected forced-full statistics (unaccepted)

All values are retained N=`5`; p95 is nearest-rank and population variance is in µs².

| metric | median µs | p95 µs | population variance µs² | population CV |
|---|---:|---:|---:|---:|
| materialize to root ready | 408,793 | 523,484 | 2,267,679,177.20 | 11.0864% |
| materialize to first search | 1,096,427 | 1,206,745 | 4,250,002,581.84 | 5.9279% |
| materialize to first read | 1,083,785 | 1,120,089 | 722,388,594.64 | 2.4877% |
| interactive readiness | 1,096,427 | 1,206,745 | 2,049,748,749.36 | 4.0362% |
| first search | 456,080 | 505,612 | 1,592,585,315.76 | 8.8840% |
| first read | 386,293 | 408,821 | 1,217,690,479.76 | 9.3416% |
| first codemap | 10,135,879 | 10,143,795 | 13,792,454.00 | 0.0366% |
| warm codemap | 136,018 | 10,144,638 | 18,270,993,553,551.44 | 120.8642% |
| passive tree | 6,570,834 | 7,908,013 | 1,342,322,161,228.24 | 18.0190% |
| selection | 22,172,294 | 22,765,425 | 63,174,542,333,425.36 | 43.2897% |

- Corrected forced-full artifact: `/tmp/rpce-worktree-startup/current-stable-20260627T003347Z/artifacts/20260627T003932Z-warm-forced-full-w1-776290ed`. All six ordinals had exact intended `{"fullCrawl":1}` and `{}` fallback (aggregate `{"fullCrawl":6}` / `{}`); all five retained follow-ons accepted. Every primary failed exact `resource_evidence_invalid`, so accepted N=`0` even before source drift invalidated the cohort. `summary`/`samples`/`resources`/`cleanup` SHA-256: `aca16fbcc4af6d2a18b6a83b49ddb6869f59ffbbeda6ae2d592703fd53034152` / `774134f05f1b17d4002dacafbbf6b6da8b21bcf2f2177ed1172952ff0065a96b` / `900fa73f8e69fbbc72d9213befc16ec5a55041a4c6f7efa5aea716d6ad3c1b6e` / `3ab134859e9e5e2248e3d720694adaa66d37109fa315bf5a7d5900a6b51afb83`.
- A preceding operator-cardinality diagnostic mistakenly applied projected cardinality `4` to forced-full, which actually has one typed `fullCrawl` observation. It is excluded and explicitly invalid: `/tmp/rpce-worktree-startup/current-stable-20260627T003347Z/artifacts/20260627T003557Z-warm-forced-full-w1-3b2c22d1`; aggregate routes/fallbacks `{"fullCrawl":6}` / `{}`, six primary plus six follow-on `actual_route_counts_mismatch` failures. `summary`/`samples`/`resources`/`cleanup` SHA-256: `32123617033fad876beb325c659eb263088eba310d4ec6f7e94d3ce4971da036` / `c9d414c062377e0d26ce5e6402b6acf0864eaf6132b29511d3323cbbb5e5f058` / `5d6438c9cc0b34fa75f7ee259d3d19ec3c9e27bdaf246c6b7bb46b40b0b03c8a` / `1846d8103469d3c19f73a27e0c1d9cdfbaf9fe4a23053e2582cd34e195b810ee`.

### Drift, projected/smoke disposition, and cleanup

- The projected acquisition was stopped before route preparation or sampling when its pre-acquisition source check observed `d82c84afa3675e7a64df235070015ad4b46baddd56c436faf225243606508aaf` instead of packaged `757dd0ccb1e8650a88a506249ba09d91c96545fc10ac5770556af55cf93d06ee`. The next complete manifest was already `ade85e9b155eb1290815b16ec244ef2b280922e30f5dbb958be04d8dcd279abb`; changed files then included `Scripts/worktree_startup_live_benchmark.py`, `IgnoreRulesManager.swift`, and `GitWorkspaceMetadataMonitor.swift`.
- Source continued moving. Four 20-second hashes were `978f2c2463893c4458e474b6ae251e9ccf91e58ed5088891a12ce2f4e0579980`, `b372ac8428c7f982896887670953263abd2cfb6c304a23e0ae228d5c5ecc160d`, `636490adec4b771759791322660f12e97d1ec0705014f847ade47adba852037c`, and `dca8926b0b0bd2be21762c674820e8dab598d5942a780e5de4c6d7ec4117adb2`. The bounded 30-second settling monitor then produced `02b113410707a80d56d6953bd813317e6251b92eed335f0a1381f15cb45a6f63` twice, followed by `ed7ba860c91b62f5a3bd05ef640be7755c793bc43cd50e2bb5855c687ace4ffe` and `1d03710badd58267e07474d6b61898869304d23e0e84b6a49ef0213c909cb307`; source never qualified as stable. Monitor artifact SHA-256: `ae03a2398d0e07c4fffb9465dc2d114c8234abeabd7b6eebeba4ae246718bd27` / `4ca89e3415ecc6917207c2c687f8ea3f90bd73c8d343e2a8c802a94420b8667e`.
- Projected route statistics therefore do not exist; the required four typed `diffSeedServing` observations were never sampled. The conditional actual `rpce-cli-debug agent_run` smoke was **not run**, because there was no valid projected cohort.
- Both forced diagnostic artifacts report `cleanup_complete=true`. For the corrected run, all six sessions terminalized `completed`, all six owned worktrees and branches were proven absent, route/diagnostics/workspace scope were restored, and the memory sampler stopped. The exact owned marker hash matched before removal and the marker is absent. Cleanup proof SHA-256 is `3ab134859e9e5e2248e3d720694adaa66d37109fa315bf5a7d5900a6b51afb83`.
- Derived rollup: `/tmp/rpce-worktree-startup/current-stable-20260627T003347Z/derived-invalid-summary.json`, SHA-256 `d3ae6efeecb770c25489bd58ba2d2ce12b19239a851c659e462fcc56d6543a75`. Full artifact hash manifest: `/tmp/rpce-worktree-startup/current-stable-20260627T003347Z/artifact-hashes.txt`, SHA-256 `cf3d540c47d3bd57fe02c3c436f1d814dcd6dc6cb79c1bbba63340560ed9c24a`.
