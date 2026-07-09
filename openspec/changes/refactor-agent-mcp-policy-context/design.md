## Context

Agent Mode MCP policy state flows through run lease creation, connection-policy installation, pending policy admission, run-scoped policy cache, reconnect/handover restoration, and request metadata capture. These values are security-sensitive because they decide which tools are available, which run/window/tab owns a connection, and whether `coordinator_chat` should treat a caller as the Coordinator runtime/Director actor or as an external user/CLI caller.

The current branch has a named `AgentModeMCPPolicyContext` with `isCoordinatorRuntime`. `MCPConnectionManager` stores the marker in pending policies and run-scoped policy state, reapplies it on reconnect, and exposes it through request metadata. `CoordinatorChatMCPToolService` then uses request metadata to gate runtime callers, external-only user actions, Mission scoping, and Director actor attribution.

## Goals / Non-Goals

**Goals:**

- Preserve the named policy context shape and avoid positional privilege plumbing.
- Preserve and normalize the durable `isCoordinatorRuntime` marker through every Agent Mode MCP policy hop.
- Treat `.coordinator` task-label context as a Coordinator runtime marker only when produced by the trusted Agent Mode policy path.
- Fail closed or fall back to non-Coordinator behavior when Coordinator runtime context is missing, stale, ambiguous, or unverified.
- Keep run-scoped policy cache/reconnect behavior from dropping Coordinator runtime context.

**Non-Goals:**

- Defining Coordinator Mission Plan, childAsk, receipt, or lifecycle semantics; see `add-coordinator-mode`.
- Granting additional Coordinator tools or broad session visibility.
- Letting caller-provided tool arguments, session names, model prose, or UI demo booleans spoof Coordinator runtime policy.

## Decisions

### 1. `isCoordinatorRuntime` is typed policy context, not cosmetic metadata

The marker is privilege-bearing context. It must be carried in the Agent Mode policy context, pending connection policies, effective run policy state, and captured request metadata. It is used by Coordinator control surfaces to distinguish runtime calls from external user/CLI calls.

### 2. Normalization is trusted-path-only

A `.coordinator` task label emitted by a trusted Coordinator runtime launch/policy path may normalize to `isCoordinatorRuntime=true`. The same string arriving as an ordinary `model_id`, tool argument, session title, transcript text, or unverified metadata must not grant Coordinator runtime context.

### 3. Attribution is conservative

Only request metadata with verified Coordinator runtime policy context may be treated as Director/runtime actor. If the runtime cannot be resolved to an owning Mission, runtime-scoped operations must fail closed rather than falling back to the selected UI Mission. External user-action parity operations remain external-only and must not be recorded by runtime callers as user decisions.

### 4. Cache and reconnect preserve privilege context

Run-scoped policy state exists so live Agent Mode reconnects and handovers keep their policy restrictions/additional tools and runtime context. Reapplying cached policy must preserve `isCoordinatorRuntime`; cache misses or stale policy must not infer Coordinator status from client names or labels alone.

## Risks / Trade-offs

- **Privilege widening through spoofing** → never trust caller-provided strings or demo markers as policy context.
- **Privilege loss on reconnect** → include the marker in run-scoped policy state and request metadata rehydration.
- **Actor ambiguity** → prefer non-Coordinator/default behavior or explicit rejection over guessing a runtime Mission.
- **Overloading this change** → keep tool availability and Mission semantics in dependent changes.
