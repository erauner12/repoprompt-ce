## 1. Prerequisite and Contract Audit

- [x] 1.1 Record the current status and relevant seams of `add-coordinator-mode` tasks 13.3, 13.6, 13.7, and 13.8 without asserting that any prerequisite is complete.
- [x] 1.2 Audit exact Mission contract fields and lifecycle seams for objective/scope, predecessor lineage, workstreams, nodes/dependencies/workflow/execution policy/done criteria, planned write/worktree strategy, policy/autonomy/pace/`childAsk`/concurrency, pinned context/skills, guidance, Stop, continuation, child interactions, and projection.
- [x] 1.3 Record the implementation partial order: sections 2–3 and pure proposal parsing/validation may begin after this audit; prompt/schema/doctor surfaces wait for 13.6; sections 5–8 integration waits for hard prerequisites 13.7 and 13.8.
- [x] 1.4 Treat task 13.3 legacy `not_required` recovery as soft/independent; promote it to a blocker only if this audit demonstrates a shared authority path.

## 2. Canonical Material Contract Identity

- [x] 2.1 Implement a versioned canonical material-contract snapshot shared by proposal ingress, approved-contract immutability, resolution CAS, diagnostics, projection, and tests.
- [x] 2.2 Exclude runtime worktree IDs, node status, bindings, evidence, decisions, events, child observations, terminal provenance, and continuation bookkeeping while retaining planned write/worktree strategy.
- [x] 2.3 Deterministically sort workstreams, nodes, dependency lists, autonomy keys, pinned context/skills, and all map/set-like inputs before canonical encoding.
- [x] 2.4 Derive deterministic SHA-256 fingerprints from canonical snapshots and use structural snapshot equality—not `plan.revision`—as the authoritative CAS.
- [x] 2.5 Add focused tests covering every material field, every excluded runtime field, deterministic ordering, stable evidence-only identity, and stale material-contract detection.

## 3. Proposal and Resolution Ledger

- [x] 3.1 Add Codable summary-only proposal records with app-owned stable proposal IDs, deterministic `canonicalRequestIdentity`, base plan/snapshot/fingerprint, representation kind, summary/rationale, advisory categories/remedy/evidence/change metadata, runtime actor metadata, and app-owned filing time.
- [x] 3.2 Add separate append-only resolution records with app-owned identity/time, user decision/checkpoint linkage, resulting contract identity, and accepted-for-concrete-revision/rejected/invalidated/stopped outcomes.
- [x] 3.3 Implement dedicated append and resolve mutators with one-pending enforcement, exact current-pending request retry idempotency, first-resolution-wins, conflicting resolution rejection, and terminal resolution before freezing.
- [x] 3.4 Derive `canonicalRequestIdentity` server-side from identity version, base contract, sorted affected fields, remedy, sorted evidence IDs, and raw `requested_change` canonicalized with Unicode NFC, surrounding trim, and whitespace-run collapse while preserving case/punctuation; exclude summary, rationale, timestamps, and app-owned metadata and reject caller-authored identity fields.
- [x] 3.5 Return the existing proposal ID for an exact logical retry while pending, report the pending ID for a different canonical request while pending, and allow a new proposal occurrence after resolution without any prior-rejection lookup or suppression state.
- [x] 3.6 Keep proposal/resolution fields out of `CoordinatorMissionPlanUpdate`; preserve them across generic updates and reject injection/resolution attempts.
- [x] 3.7 Add empty decode defaults, fresh-Mission reset clearing, restart persistence, and exactly one non-decision Director/runtime-attributed proposal event for receipt honesty; reject decision-record shapes and all user-decision metadata at filing.
- [x] 3.8 Add reducer/serialization tests for Unicode NFC/trim/whitespace exact retry identity, case and punctuation preservation, summary/rationale exclusion, differently written request IDs, post-resolution re-proposal without suppression, identity-version stability, one-pending rules, reset/decode/restart, generic-update back doors, and terminal races.

## 4. MCP Proposal Ingress and Public Schema

- [x] 4.1 After Item 1, implement pure `propose_revision` parsing/validation for base identity, summary-only fields, raw `requested_change`, and supporting evidence; derive `canonicalRequestIdentity` server-side. This pure work may begin before 13.x completion.
- [x] 4.2 Restrict ingress to the verified owning Coordinator runtime and reject external, missing-identity, internal non-owner, cross-Mission, unapproved, terminal, and stale-base callers without UI-selection fallback.
- [x] 4.3 Route successful ingress through a dedicated environment callback/mutator, append only a non-decision Director/runtime proposal event, and persist the installed pause before returning success.
- [x] 4.4 Reject exact replacement plans/diffs and any attempt to mutate approval, contract fields, user decisions, nodes, bindings, or resolution state.
- [ ] 4.5 After task 13.6, update established doctor output so `supported_ops` includes `propose_revision` and `features.revision_proposals` equals version 1 / `summary_only` / `revise_plan`, `keep_current_plan`, `stop_mission`; update public input schema only with the op/fields and no duplicate feature object or extra wrapper plumbing, then test doctor plus schema independently.
- [ ] 4.6 After task 13.6, update the owning Coordinator runtime prompt to teach `propose_revision` only for contract-changing remedies, distinguish ordinary evidence/failure/tool-error/changed-assumption prose, and forbid self-revision, self-resolution, and user-decision impersonation; add explicit `SystemPromptServiceCoordinatorModeTests` traceability and assertions.

## 5. Pending-Proposal Advancement Pause

- [ ] 5.1 After the Item 1 audit confirms hard integration prerequisites 13.7 and 13.8 are available, block delegated starts, including preapproval planning/probe exceptions, before capacity checks in the Coordinator Mission run policy.
- [ ] 5.2 Add an early proposal-specific hold to Auto-mode classification that blocks `childAsk:auto` and other automatic user-surrogate decisions.
- [ ] 5.3 Hold follow-through after terminal reconciliation but before continuation delivery, resume, coordinator-only completion, or other advancement.
- [ ] 5.4 Enforce the pending transition table in MCP and reducer layers: reject new starts/bindings, pending/blocked-to-running, advancement status, contract changes, and Director-authored user decisions.
- [ ] 5.5 Persist existing and newly arriving questions from already-running children as unavailable/disabled with reason `held pending revision proposal`; fail all answer submits without recording or queuing an answer, while continuing terminal/evidence bookkeeping and removing obsolete questions when children terminalize.
- [ ] 5.6 Add policy/classifier/MCP/reducer/view-model tests for every blocked/allowed pause row, proposal-first checkpoint priority, existing/new child-question holds, fail-closed answer submits with no answer record, terminal child cleanup, planning exceptions, and `childAsk:auto`.

## 6. Trusted Durable Resolution Transactions

- [ ] 6.1 After the Item 1 audit confirms hard integration prerequisites 13.7 and 13.8 are available, implement app-owned Revise/Keep transactions carrying action, proposal ID, expected contract identity, and expected checkpoint instance ID.
- [ ] 6.2 CAS authoritative state for unresolved proposal, nonterminal Mission, rendered proposal/checkpoint identity, and structural equality with the proposal base snapshot.
- [ ] 6.3 For Revise plan, create one authoritative generation containing the linked user decision, `acceptedForConcreteRevision`, `revisionRequested`, old-continuation invalidation, and durability hold; persist the full generation before clearing the hold and still require later concrete-plan approval.
- [ ] 6.4 For Keep current plan, create one authoritative generation containing the linked user decision, `rejected`, unchanged approved state, restored continuation disposition, and durability hold; after persistence restore any still-pending child interaction as active/answerable and evaluate eligible follow-through once.
- [ ] 6.5 Integrate Stop so one authoritative generation contains the linked Stop decision, stopped/terminal proposal resolution, terminal state, continuation invalidation, and durability hold, with Stop winning all races.
- [ ] 6.6 For trusted manual revision or pace/`childAsk`/autonomy/policy contract changes, create one authoritative generation containing `invalidatedContractChanged`, old-continuation invalidation, checkpoint removal, and durability hold; after persistence return existing unanswered child interactions to ordinary policy and require re-proposal against the new base.
- [ ] 6.7 Reuse or add a generation-aware persistence barrier and explicit durability hold so resolution, linked decision, approval/terminal state, continuation disposition, and child-question availability persist together; after barrier failure keep every authority/question gate fail-closed and reconcile from the last durable generation.
- [ ] 6.8 Add view-model/integration tests for Revise, Keep, Stop, stale actions, conflicting decisions, persistence failure, Stop races, and atomic pace/`childAsk`/autonomy/policy invalidation covering checkpoint removal, old-continuation invalidation, unanswered-child return to ordinary policy, durability ordering, and required re-proposal.

## 7. Continuation Authority Lifecycle

- [ ] 7.1 After the Item 1 audit confirms hard integration prerequisites 13.7 and 13.8 are available, defer an otherwise deliverable post-approval continuation with a proposal-specific reason when a proposal is filed without invalidating it.
- [ ] 7.2 Restore deferred continuation only after durable Keep; invalidate old-contract continuation after durable Revise and terminal continuation after Stop/terminalization.
- [ ] 7.3 Revalidate no pending proposal and Stop precedence at every final delegated-start and continuation enqueue.
- [ ] 7.4 Add focused continuation tests for filing deferral, Keep restoration/evaluate-once, Revise invalidation, Stop invalidation, persistence ordering, and final-enqueue races.
- [ ] 7.5 Add focused child-question outcome tests: Keep restores active/answerable state; Revise holds through `revisionRequested` and drafting; revised-plan approval restores only still-applicable questions and cancels/supersedes others; Stop cancels; independent child terminal completion removes obsolete questions.

## 8. Needs You Projection and User Actions

- [ ] 8.1 After the Item 1 audit confirms hard integration prerequisites 13.7 and 13.8 are available, project exactly one revision-proposal decision item as the highest-priority active checkpoint; keep child questions persisted but unavailable/disabled with the hold reason.
- [ ] 8.2 Build stable checkpoint identity from Coordinator session, proposal ID, and base contract fingerprint; resolve display payload from `rail.missionPlan` by proposal ID at render time.
- [ ] 8.3 Add the proposal-specific card with exact labels **Revise plan**, **Keep current plan**, and **Stop Mission**, with no exact replacement payload or **Approve revised plan** action.
- [ ] 8.4 Enforce checkpoint precedence: revision proposal first; selected-Mission child interaction only when no proposal is pending; then concrete plan approval and step boundary.
- [ ] 8.5 Extend external `submit` with `revise_plan` and `keep_current_plan` plus required proposal/contract/checkpoint identities; retain app-owned Stop parity and reject runtime self-resolution.
- [ ] 8.6 Add projection/UI/MCP tests for proposal-first uniqueness/precedence, disabled held-question rendering/reason, answer rejection without recording, stable identity, outcome transitions, stale rendering, labels, action parity, restart reprojection, trusted contract-dial invalidation/removal, required re-proposal, and absence of exact replacement payload.

## 9. Status, Waits, Events, and Migration Safety

- [ ] 9.1 Expose pending proposal ID, base contract identity, summary representation, summary, material fields, lifecycle/outcome, checkpoint instance, submit hints, held child-question state/reason, and recent resolution identity/outcome in Mission status surfaces.
- [ ] 9.2 Add proposal lifecycle parts directly to compact status/wait fingerprints and event-journal candidates so append and resolution wake `wait_for_update`.
- [ ] 9.3 Add minimal receipt history explaining the non-decision Director/runtime proposal event and trusted user resolution without broad receipt redesign, Director decision-ledger entries, user-decision impersonation, or claims of exact approval/execution/merge/deployment.
- [ ] 9.4 Document and test the rollback rule that pending proposals must be resolved or the Mission stopped before reverting to a pre-feature binary.
- [ ] 9.5 Add status/fingerprint/wait/journal/receipt tests for append, each resolution outcome, evidence-only changes, restart, and backward decode.

## 10. Validation and Handoff

- [ ] 10.1 Run focused reducer, MCP, policy, classifier, view-model, projection, persistence, status, wait, event-journal, and prompt/schema test lanes covering the design validation matrix.
- [ ] 10.2 Run the smallest coordinated Swift builds and tests for affected products, then coordinated formatter and strict lint for Swift changes.
- [ ] 10.3 Run one live CE narrative: Director proposes revision → Needs You → Revise plan → trusted revision flow → concrete plan → user approval → execution resumes.
- [ ] 10.4 Keep Keep current, Stop, stale actions, pause gates, retries, and decode/restart as required focused/integration coverage even when omitted from the first live narrative.
- [ ] 10.5 Run `openspec validate add-coordinator-plan-revision-proposals --strict` and resolve every validation error before implementation handoff.
