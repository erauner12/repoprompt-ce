# Director Mode — deliverable set (mock v3.2.2)

Everything here is current as of this export; superseded drafts have been removed. The mock is verified by a 170-check harness (all green), including a static check that every UI action has a handler.

## The mock
- **RepoPrompt_Command_Center.html** — the interactive mock, v3.2.2. Open in a browser. Demo beats (child question + deferral, bar miss, review-driven rework) play **once per reload** on the first Scoped Change run; reload to replay them. The ▸ Try chips on the New Mission policy cards prefill the four showcase directives — your words choose the plan (shape inference), the policy chooses how much stops for you.

## Specs & design (normative)
- **Mock_Iteration_Spec_v2.md** — the spec of record: per-version deltas (v2 → v3.2.2), state map, component → Swift mapping, interaction contracts, open questions Q1–Q19. Read the newest delta paragraphs first.
- **Director_Design_v2.3.md** — chapter 1: shape inference, mission policies, decision counting, close-conflict rule. Complementary to v2.4, not superseded by it.
- **Director_Design_v2.4.md** — chapter 2: autonomy as decision classes, ⚙ decision logging, child questions, the four built-in policies, standing guidance (four channels), Swift table.
- **Director_Prompt_Design.md** — verbatim prompt skeletons for every model call (§1 inference incl. namedClose · §2 drafting incl. revision + multi-land contracts · §3 delegation · §4 steer/re-review · §5 adjudication · §9b cross-step rework · §9c discovered-scope · §10 landing, once per land node).

## Implementation & demo
- **Swift_Implementation_Preflight.md** — decide-before-day-one items (naming collision: Director vs the repo's Coordinator stack), the v1 cutline (3 shapes; defer bake-off/measured/reshape), data-model unifications (one MissionDecision record; checkpoints as state), architecture cross-check, and the multi-land/workspace notes (build the runner land-node-parameterized from day one).
- **Mission_Demo_Scripts.md** — cold open, walkthrough scripts V0–V6, the policy × scenario matrix (Try chips), mechanics bullets, and the reviewer question bank.
