# Coordinator Mode UI Prototype Reference

`RepoPrompt_Command_Center.html` is a standalone UI prototype exported from the design pass.

It is non-normative: use it as visual and structural implementation reference only. The OpenSpec requirements remain the behavioral contract. Do not encode incidental HTML/CSS details, pixel widths, class names, or mock-only interactions as requirements.

The prototype's Coordinator-rail `Chat`/`Agents` toggle and `Agents` roster are non-normative mock chrome from design exploration, not v1 requirements. The board/list is the human-facing active-workspace fleet view. A Coordinator can enumerate available models or child sessions through `agent_manage` tools (`list_agents` for the catalog, `list_sessions` for sessions), so v1 should not add a second by-agent roster in the rail.

`coordinator-demo-use-cases.md` records the production-demo prompt and gesture taxonomy. Use it to distinguish single delegation, one-parent fan-out, sequential multi-parent supervision, simultaneous multi-parent supervision, and switch-back supervision without changing the normative requirements.

Workflow-bearing demo prompts intentionally use Agent Mode workflow names such as `Investigate` and `Review`; those examples rely on the sourced `agent_run workflow_name`/`workflow_id` path rather than Coordinator-only mock state.
