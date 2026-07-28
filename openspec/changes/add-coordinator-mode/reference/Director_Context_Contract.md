# Director Context Contract — from-code architecture (RPCE main @ July 2026)

*Answers the five questions from upstream source. Separates: **proven** (file-referenced) / **inference** / **buildable** / **risk**.*

## 1. Oracle invocation path

**Proven.** The Oracle is fully headless via MCP — four tools: `oracle_utils`, `ask_oracle`, `oracle_send`, `oracle_chat_log` (`Infrastructure/MCP/WindowTools/MCPOracleToolProvider.swift`). But its context is **structurally tab-coupled**: `MCPOracleToolService.swift` (~L170–235) requires a compose-tab context (`requireCurrentTabContext` — it *throws* without one) and assembles `OracleSendPackagingContext { promptText, tabSnapshot.selection, lookupContext, reviewGitContext(worktree bindings, base: HEAD), sourceAgentSessionID/runID, selectionRevision }`. It is also **conversation-stateful by policy**: `chat_id` continuation, `new_chat` "discouraged" in the schema, and a dedicated `AgentOracleAuthoritativeChatIDPolicy.swift`. There is also an artifact path: `export_response → oracle_export_path` via `OracleExportFileWriter.swift`, plus `oracle_chat_log` for post-compaction recovery.

**Verdict: sibling judge, not "the Oracle with a different bundle assembler."** The three properties the Director judge needs — stateless one-shot, ledger-bundle input, no tab/selection dependence — are the three properties `ask_oracle` enforces the opposite of, *by construction*. Retrofitting would fight `requireCurrentTabContext`, the selection packaging, and the authoritative-chat-ID policy simultaneously. **Reuse instead:** the `MCPWindowToolProviding` provider pattern, model resolution (`oracle_utils op=models` / `ModelPreset.swift`), the export-file machinery for judgment records, and the review-packaging git-context assembly for diff-stat exhibits. Buildable shape: `MissionJudgeService` — sibling of `MCPOracleToolService`, `judge(bundle) → {verdict, gap, citations}`, one call per judgment, nothing retained.

## 2. Context Builder internals

**Proven.** `context_builder` (`MCPContextBuilderToolProvider.swift`, 740 lines) is itself a **delegated discovery agent**: it explores the codebase, selects files **within a token budget**, rewrites instructions, and returns a `StoredSelection` + optional follow-up response (`response_type: clarify | question | plan | review`), chaining into `ask_oracle` via a returned `chat_id`. Its currency is the *selection object*, not a text blob.

**Verdict: do not point it at the Director's judgment path — it IS the escalation probe, already shipped.** Calling CB from the Director for judgment would be code-reading by another name (re-importing context pollution through the side door). But the contract's "read-only probe" is *literally* `context_builder(response_type: "question", export_response: true)`: fresh curated context, budgeted, answer + exportable artifact. **The probe's evidence artifact = the answer text + `oracle_export_path`, recorded into the mission ledger as node evidence.** What must *not* be reused: the returned `StoredSelection` itself must never be mounted into Director context — the answer is the deliverable, the selection stays below.

## 3. Session/sub-agent spawning & structured results

**Proven.** `Infrastructure/MCP/Agent/`: `AgentRunMCPToolService.swift` (2,572 lines; default spawn role `.pair`, L200), `AgentExploreMCPToolService.swift`, `AgentManageMCPToolService.swift` (ops incl. `list_agents`, `list_sessions`, `get_log`, **`extract_handoff`**, `create_session`, `resume_session`, `stop_session`), `AgentRunSessionStore.swift`, `AgentMCPStartWorktreeCoordinator.swift` (worktree minting at spawn — the mock's minting matches reality). **Structured results beyond transcripts already exist**: `AgentRunMCPSnapshot.swift` carries terminal-aware status, full **WorktreeBinding** (branch, head, visual label/color — the mock's worktree chips are native fields), and **`Interaction { kind: instruction|question|user_input|approval|mcp_elicitation; responseType: text|choice|structured|decision; Option{label, description}; Field{options, allowsOther, …} }`** — i.e., the childAsk / interview-panel / options substrate is upstream, typed, today.

**Buildable:** evidence is a new structured handoff DTO on the existing channel — `MissionEvidence { node_id, done_bar, claims[], artifacts[{path|diffstat|test_output}], exhibits[{source, excerpt ≤ N tokens}] }` — produced via `extract_handoff` / a snapshot extension, consumed by the ledger. No new transport.

## 4. Delegation / depth limits

**Proven.** Depth is enforced **at the API in tool executors by role**, not merely UI convention: `AgentExploreMCPToolService.swift:344–359` — the caller must be an MCP-started session with a `taskLabelKind`, and **"Explore agents cannot start additional explore agents."** Roles: `TaskLabelKind { explore, engineer, pair, design }` (`AgentModelCatalog.swift:1769`). `ToolAvailabilityStore.swift` handles user toggles + advertisement filtering (policy-gated tools hidden from normal MCP clients) — a second, coarser gate.

**Buildable:** "the Director spawns orchestrators" is consistent with today's model — add a `director`/coordinator caller identity and express its powers/limits as executor checks in exactly the `AgentExploreMCPToolService` pattern (Director may `agent_run` at pair/engineer; workers may not call judge/mission tools). Eric's depth framing is confirmed as enforcement reality, not folklore.

## 5. Coordinator / Mission seams

**Proven (by absence):** zero upstream hits for `coordinator_chat`, Mission state, evidence/decision ledgers, or snapshot *projection* in that sense — the `Coordinator` hits in `WindowState.swift` are UI coordinators (selection/close). **All coordinator substrate is local work**, so the contract below is greenfield-with-good-neighbors, not a retrofit.

## The contract (safe to commit to spec now)

1. **Stateless Director over a curated mission ledger** — every Director call assembled fresh from `{directive, plan@rev, per-node {bar, evidence, summary}, decision trail, guidance}`; no long-lived Director conversation. O(nodes), and the ledger doubles as the restart/resume substrate (G6).
2. **Judgment = one-shot sibling judge** (`MissionJudgeService`), bundle recorded verbatim into the receipt (auditable: "judged on exactly this").
3. **Exhibits, not files** — code content enters Director context only as bounded excerpts attached to evidence from below; the Director has no files tab.
4. **Escalation = `context_builder(question)` probe**, answer + export path ledgered as evidence; never a transcript or selection import. Human "open the session" remains the human's escalation, logged.
5. **Evidence rides the existing structured channel** (`AgentRunMCPSnapshot`/`extract_handoff` extension), and asks ride `Interaction` — the mock's decision-queue semantics map 1:1 onto upstream types.
6. **Depth via roles** — a coordinator caller identity with executor-level checks, upstream's own pattern.

## Remaining implementation uncertainties (do not spec as fact)

- CB's internal token-budget mechanics (didn't read the packing line-by-line) — treat exhibit budgeting as new code until verified.
- Judge model routing/cost defaults (which `ModelPreset` tier judgments use).
- Your local coordinator code — unseen; where it diverges from these seams, reconcile toward the upstream types above (especially `Interaction` — don't parallel-invent it).

## Risks / compatibility

- `ask_oracle`'s authoritative-chat-ID policy suggests upstream values conversation continuity for *session* oracles — a stateless sibling avoids policy collision entirely.
- `Interaction` is upstream API surface; extending it (new `responseType` or a `MissionEvidence` payload) should be PR'd upstream early, before local drift makes it a fork-only shape.
- The advertisement filter (`isAdvertisedToolName`) is the right place to keep mission/judge tools invisible to normal MCP clients — reuse, don't bypass.
