# Director Mode — Demo Video Series (mock v3.8.1)

**Series thesis:** *You stop reading turns and start making decisions.*
Six layers, each ≤3 minutes, each building on the last. Video 1 starts where RepoPrompt users already live.

## ★ NEXT VIDEO (committed on Discord) — "Trust, Mid-Run" · ≤3 min · fresh reload

*The hybrid-policy demo loom's cap cost you: start supervised, flip to auto mid-run, watch the handoff.*

1. **Default policy** (both dials on the stopping side: Step · Me) → directive → approve → plan cascades in.
2. **Hit the checkpoints for real.** Step check-in → Continue. The worker's **question** arrives with the Director's drafted answer — point at the two dials in the strip before answering: *"Step and Me — everything stops for me right now."* Send the suggested answer.
3. **The flip.** Toggle **Me → Director**. Seconds later the *second* question lands — and the Director answers it itself: ⚙ card with its reason, the worker's transcript shows the steer.
   > "Same class of question, one toggle apart. That's the whole model: autonomy is read at decision time."
4. **Flip Step → Auto** at the next boundary — the held checkpoint stays ("answer this held check-in and I won't pause after it"). Answer it; it runs.
   > "Settings govern the future; a question already raised stays raised."
5. **It carries the rest itself** — until the **merge, which still asks**. Confirm PR 1; part 2 runs hands-free; confirm PR 2; receipt.
   > "Two dials took me from supervising every step to reading a receipt — and the irreversible stuff asked anyway."

---

**Recording order ≠ presentation order.** The three scripted supervision beats (child question, bar miss, review-blocker rework) play **once per reload**, on the first Scoped Change run. So: record **Video 3 first** on a fresh reload (it needs the beats), then record **Video 2** in the same session (its run is clean because V3 consumed them). Everything else is order-independent.

---

## Video 1 — From Sessions to Missions *(the bridge — start here)*

*Start in Agent mode (⌘1). This is the app they know; the video's job is the mapping.*

1. **The familiar 30 seconds.** Workspace folders bottom-left (repoprompt-ce · swift-sdk · rp-docs). Click the **Orchestrate** workflow card — it **arms** (glows). Then click the **Work locally** pill → the **Execution location** picker opens → choose **⑂ New worktree** (the pill arms green). Type your task → **Enter**. Point at the **colored WT chip**: on the session row and in the composer strip — and the sub-agents carry the *same* color (one worktree, one family).
   > "I picked the execution location up front — an isolated, color-coded worktree. You'll see this exact color convention again on mission-delegated sessions; it's how you tell at a glance where any session lives. Skip the pick and the same orchestration runs on the workspace checkout."  The session starts and *visibly delegates*: two sub-agents pop in under it, work, and report back while the parent narrates; the sidebar shows them nested under the parent.
   > "This is RepoPrompt as you know it — one session, and it can already own sub-agents. You drive."
2. **User input, today: it lives inside the tab.** Back at the start screen, arm **Deep Plan** → type anything → Enter. The session immediately stops on an **interview panel** — "How involved would you like to be?" — pick one, Submit, and the run resumes; the panel collapses to a ✓ line.
   > "This is the second pattern to remember: workflows that need *your input* park it inside the session — you have to be looking at this tab to know it's waiting."
   *(Optional 10s payoff: before answering, ⌘2 → **Decisions** — the standalone session's question is already sitting there; click it and you land back on this panel. The queue catches every input request, whoever raised it.)*
3. **You sequence what runs next — show it.** After the sub-agents finish, click the **Workflow pill** above the composer — the popover opens (point at it: Orchestrate, Review, Deep Plan, Investigate). Pick **Review** → the capsule arms → type "review what the sub-agents changed" → Enter — your message carries the **Review chip**, the session responds in character. Then pick **Orchestrate again** → type a follow-on task → Enter — a *second wave* of sub-agents pops in, same session. Then **× clear** → send a plain message.
   > "Notice who's doing the sequencing: me. Every turn, I decide what runs next — orchestrate again, review, or nothing. That's the job that doesn't scale — and it's exactly the job the Director takes over."
4. **Clean it up — and notice the cascade.** Hover the parent's row → **⤓ Stop & archive** — the parent *and both children* stop and shelve together (Archived Sessions count jumps by three; transcripts retained). Then: open an example session that was *delegated* — point at the attribution bar: **"Delegated by Mission → Open Mission."**
   > "Today, when the work is bigger than one session, *you* are the integration layer — you open tabs, re-explain context, carry progress in your head, and decide when it's done. That role doesn't scale. So we moved it one level up."
5. **The Board — already yours.** Before leaving Agent mode: click **Agent Board** in the sidebar — every run, yours and delegated, one kanban; click a card and it opens the session.
   > "This view isn't a Director feature — it's session awareness, and it works today. What the Director adds is what *fills* it."
6. **⌘2.** The Director. Quick rail tour: **Decisions** (what's blocked on you, across everything — this one *is* the Director's; the badge on the pill told you it was waiting), the **same Board**, **Missions**.
7. **The mapping — open one completed Example mission and narrate over it:**
   - *Your prompt* → a **directive** — "your words choose the plan."
   - *The workflow picker* → a **shape**, inferred and announced ("this reads as a scoped change — not what you meant? say so").
   - *Permissions pills* → a **policy** — how much stops for you, never what the work is.
   - *Your open tabs* → the **plan** — and every step is still a real session: click a node → **Open in Agent Mode** → you're back in the familiar view → **Open Mission** → back. Nothing was replaced; it was organized.
   - *Your memory* → the **evidence ledger**, and at the end, the **receipt**.
   > "The session-mode you is the integration layer. The mission-mode you is the reviewer. One of those scales."
8. **Close the loop in their world.** ⌘1, hover the test session's row → **⤓ Stop & archive** → back at the start screen.
   > "Sessions are working memory now — the durable unit lives one level up. Let's run one for real."

---

## Video 2 — One Mission, Start to Finish *(the loop — clean run)*

*Record after V3 in the same session (beats consumed). Policy: Default → ▸ Try chip → Enter.*

1. **Grounding + shape announcement** → **Draft the plan** (skeleton → the plan cascades in — let it land, don't talk over it).
2. **Watch, don't drive.** The plan follows the Director: lanes open, the working card pulses and centers. Step check-ins come to you; Continue through them.
3. **PR 1 of 2** — the merge asks; confirm. *"Landed PR #142 — continuing."*
4. **Part 2 starts only now** — the swift-sdk companion builds *on the new base*, gets its own review, then **PR 2 of 2** asks when it's actually ready.
   > "Two consecutive landings, each with its own confirmation — irreversible is per-action, and the mission completes when the Done bar clears, not when the first PR lands."
5. **The receipt.** Stat card → *Mission receipt →*: contract, both-sided decisions, evidence, **Close lists both PRs**. Copy Markdown.
   > "The loop: decide, watch, confirm, receipt."

---

## Video 3 — When Steps Fight Back *(supervision — fresh reload, record first)*

*Same Default Try chip; the first run plays all three beats.*

1. **Child question — then the toggle beat.** A worker asks mid-step; the checkpoint arrives *with the Director's suggested answer* — send it.
   > "It never escalates a bare question. And the answer defers the alias removal — that deferral is *recorded*, it'll show in the receipt. If I disagreed, I'd type my own right here" — point at the own-answer input — "or even answer from the session's side: open the worker and it's visibly *held* on this exact question, with the same options. One question, two surfaces, one decision."
   Now flip the questions toggle (beside Step/Auto) to **Director** — seconds later a *second* question lands, and this time the Director answers it itself: point at the ⚙ card with its reason, and at the worker's transcript ("Director: Leave them…") — the answer steered the session.
   > "Same class of question, one toggle apart. Ask stops for me with a drafted answer; Auto answers from mission context and steers the worker — logged, counted on its side, never silent."
2. **Bar miss.** ✗ card — evidence didn't clear the step's bar; the Director re-steers the **same** session.
   > "Recovery is the Director's job at every trust level. Logged, never silent."
3. **Review blocker → rework.** ✗ "cleanup() isn't idempotent — blocker." Watch the implement card flip **Completed → Pending** in the plan — same session, same worktree — fix, re-review, clean, and only then does the landing arm.
   > "A later step's findings are evidence against an earlier bar. The merge stays gated until review actually passes — and if this loop didn't converge, that failure comes to me as a decision, not a token bill."

---

## Video 4 — Trust Is a Dial *(policies & autonomy)*

1. Recall V2/V3 ran under **Default** — count the stops. Now: **Hands-off → ▸ Try** → Enter → approve once.
2. It runs: **⚙ cards** where checkpoints were, each with a reason. The stat reads *Needed you N× / Decided itself M×*.
   > "Identical machinery, different decision surface. Autonomy you can audit."
3. **Merges still ask.** > "No trust level auto-merges — irreversible is locked, per-action."
4. **The held checkpoint** (30s): pause a Step-pace run at a boundary, flip **Step → Auto** — the checkpoint *stays*, labeled: "answer this held check-in and I won't pause after it."
   > "Toggles configure, buttons act — a settings flip never consumes a question already asked."
5. **The close belongs to the policy too:** **Read-only → ▸ Try** ("…and file an issue") — before drafting: *directive names an issue, policy closes with a report — the policy wins unless you say otherwise.*

---

## Video 5 — Words Choose the Plan *(shapes & steering)*

1. **Three directives, three plans** (rapid): Hands-off chip → *Measured loop* (baseline → try/keep-or-revert). Careful-writes chip → *PRD Slices* — the flow aAtila described verbatim, plus ordering: slice the PRD → **two slices run their own deep-plan → orchestrate → review chains in parallel** → a **dependent third slice waits** — its chain starts only after both are done and consolidated, planned against their combined result → one combined review by you → stacked PRs, writes gate arming before every mutable step. Point at the plan: the C chain's first node visibly hangs off BOTH slice reviews.
   > "This one exists because a community member described exactly this: 'hand off the PRD and slices, let each run its own chain, and only come back at the end.' Your words chose this plan."
   > "The words chose each of these. The policy never picks the plan."
2. **Steering is also words.** Mid-run, type: *"this is bigger than one worktree — split the independent parts."* Under Default the Director's proposal checkpoint appears; under Hands-off it applies with a ⚙ card.
   > "Split is a judgment with two initiators — the Director from evidence, or me in words. One machinery. No button."
3. **✎ revision** (plan-pane footer): add a step. The rule to say out loud:
   > "Completed steps are immutable — evidence stands. Running steps take steers. Only pending topology is editable."

---

## Video 6 — The Long Game *(continuity & lifecycle)*

1. **Done extends.** Open a Completed mission, type *"now make the teardown path faster"* → Enter. A **new** mission: shape = Measured (the new words spoke), **◇ Follows** in grounding, plan opens **"Builds on …"** with delta-scoped discovery.
   > "The receipt and the trust I'd earned carry forward. The transcript doesn't. And the old mission's accounting never moves."
2. **Nothing piles up.** The completed mission's thread: *"Retired N delegated sessions — evidence is banked in the receipt."* The board shows live work; "Show archived" for audit.
3. **Archive anything, any time.** Hover rows: ☆ pin, ⤓ archive (a *running* mission stops first — "my decision, recorded — never hidden-but-running"), ⤒ unarchive.
   > "Archive is a view — receipts, ledgers, and follow-up links never break."

---

## Crib sheet (say these, don't show slides)

- Your **words** choose the plan; the **policy** chooses how much stops for you on it.
- **Irreversible is per-action** — every merge asks; the mission completes when the **Done bar** clears.
- **Nothing lands without review — per landing.**
- **Immutability ladder:** completed = immutable · running = steers · pending = editable; downstream findings re-open upstream via *supervision*, not edits.
- **Never silent scope growth** — blocking discoveries reshape (governed); non-blocking are deferred *and recorded*.
- **Options are law; model text is advice** — fixed checkpoint vocabulary, model-supplied context.
- **Toggles configure, buttons act.**
- **The queue never lies** — blocked-on-you ⇒ it's in Decisions.
- **Sessions are working memory; the mission is the durable record** — retire on close, archive as a view, delete never.
- **The receipt is a projection** of state the mission already owned.

## Question bank

- Stacked-lands trigger: keywords, or should the spec's module analysis *propose* it?
- Rework bound: how many passes before escalation; what options should escalation offer?
- "Receipt so far" for live missions — worth the pane space?
- Cross-repo scope in Swift: grounding-time vs exploration-time resolution?
- Follow-up inheritance: receipt + trust — should the plan carry more, or less?
- Are five autonomy classes the right vocabulary?
