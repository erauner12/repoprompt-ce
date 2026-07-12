# Director / Coordinator reference archive

The files in this directory are historical design, mock, prompt, demo, and preflight references. They are retained for archaeology and traceability only.

## Normative source of truth

The current normative contract for `add-coordinator-mode` lives in the capability specs under:

```text
openspec/changes/add-coordinator-mode/specs/
```

Use those specs, plus the change proposal/design/tasks, for implementation and validation. If a reference file conflicts with the current specs, the specs win.

## Historical references

- **RepoPrompt_Command_Center.html** — interactive mock export. Useful for visual/layout archaeology; not a current contract by itself.
- **Mock_Iteration_Spec_v2.md** — historical mock-era deltas, state maps, component mapping, interaction notes, and open questions. Superseded by current capability specs unless explicitly re-adopted there.
- **Director_Design_v2.3.md** and **Director_Design_v2.4.md** — historical design chapters for shape inference, mission policies, decision logging, child questions, and standing guidance.
- **Director_Prompt_Design.md** — historical prompt skeletons and model-call notes.
- **Swift_Implementation_Preflight.md** — historical implementation preflight and v1 cutline notes.
- **Mission_Demo_Scripts.md** and **coordinator-demo-use-cases.md** — historical demo/use-case material.
- **Problem_Statement.md**, **Architecture_Review.md**, and **Director_Context_Contract.md** — historical framing and review notes.

Do not treat this archive as a live spec pack. Any behavior that should remain normative must be represented in `../specs/`.
