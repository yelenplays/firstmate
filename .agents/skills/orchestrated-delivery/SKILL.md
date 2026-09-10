---
name: orchestrated-delivery
description: >-
  Load before briefing a delegated task as an orchestrated role pipeline, or when leading that pipeline.
  Applies only to genuinely complex or risky tasks or an explicit captain request, not ordinary delegated work.
user-invocable: false
metadata:
  internal: true
---

# Orchestrated delivery

## Select the delivery shape

Use orchestration only when the task is genuinely complex or risky, or the captain explicitly requested it.
Ordinary delegated work stays with one worker rather than acquiring this pipeline by default.
Firstmate launches one ordinary orchestrator crewmate through `bin/fm-spawn.sh`, using harness `pi`, model `openai-codex/gpt-6-astra`, and effort `xhigh`.
The orchestrator receives the task brief and owns planning, role selection, handoffs, and the whole pipeline.
Dispatch prerequisites remain owned by [AGENTS.md section 4](../../../AGENTS.md#4-harness-and-runtime-dispatch) and [harness-adapters](../harness-adapters/SKILL.md).
Firstmate supervises only the orchestrator endpoint and never tracks individual sub-agents.

## Choose the smallest sufficient roster

| Role | Agent definition | Harness | Model | Effort | Purpose |
| --- | --- | --- | --- | --- | --- |
| Explorer | `scout` | pi | `openai-codex/gpt-5.6-luna` | `max` | Map relevant code, behavior, dependencies, and unknowns. |
| Researcher | `researcher` | pi | `openai-codex/gpt-5.6-luna` | `high` | Resolve external knowledge gaps with primary-source evidence. |
| Worker | `worker` | pi | `openai-codex/gpt-5.6-luna` | `max` | Implement the accepted change against explicit criteria. |
| Tester | `worker` | pi | `openai-codex/gpt-5.6-luna` | `max` | Exercise the implementation and report reproducible results. |
| Reviewer | `worker` | pi | `openai-codex/gpt-6-astra` | `xhigh` | Independently assess correctness and scope in a fresh context. |
| Integrator | `worker` | pi | `openai-codex/gpt-6-astra` | `xhigh` | Verify the final joined or landed result against the accepted criteria. |

The orchestrator records the selected roles and the concrete coverage reason for each before spawning them.
Any implementation requires the minimum chain Worker -> Tester -> Reviewer.
Add Explorer only for real unknowns about the repository or existing behavior, and Researcher only for real unknowns requiring external evidence; name the unanswered question before adding either.
Add Integrator when the task's final state must be verified after joining or landing, rather than relying on checks against separate or earlier results.
Knowledge-only tasks select the evidence-producing roles they need without inventing implementation stages.
The roster is not fixed: omit every optional role whose coverage condition is absent.

## Verify sub-agent support before using the roster

The `subagent` tool is supplied by the installed [pi-interactive-subagents package](https://github.com/amosblomqvist/pi-interactive-subagents), not Pi core or Firstmate scripts.
Check `pi list`, the loaded tool schema, and the installed package's README and launch implementation before claiming the selected roster is runnable.
The installed fork requires tmux, an orchestrator running inside it, and a saved Pi session; a Pi crewmate does not gain usable sub-agents merely by being on Pi.
Use `subagents_list` to discover definitions, not to poll running children, and inspect any project or global overrides of the bundled `scout`, `researcher`, and `worker` definitions.
Keep the orchestrator as the ordinary Firstmate-launched crewmate: the bundled `worker` sub-agent may spawn only `scout` and `researcher`, not the full roster.

Effort is a compatibility prerequisite, not an instruction to put in a role's prompt.
The installed package exposes a per-call `model` override but no per-call effort field, takes `thinking` from the agent definition, and appends that level to the model passed to Pi.
Its bundled definitions use `low` for `scout`, `medium` for `researcher`, and `high` for `worker`, so they do not satisfy the roster above.
Adding `:max`, `:high`, or `:xhigh` to the per-call model does not fix this: the definition's appended suffix wins in Pi's model resolver.
Consequently, the exact roster is not currently runnable with those unmodified definitions and this tool schema.
Stop before dispatching roles and report the incompatible effort control to firstmate unless the installed tool and effective definitions demonstrably support every selected role's required effort.
Do not silently reduce effort, alter shared profiles, or introduce tooling to hide that mismatch; any compatibility repair is separate from this instructions-only contract.

## Spawn and carry the handoff

After the compatibility check passes, call `subagent` with the table's `agent` definition, a unique role-specific `name`, an explicit per-call `model`, the absolute task-worktree `cwd`, and a self-contained `task`.
For example, the Worker call shape is `subagent({agent: "worker", name: "worker-implementation", model: "openai-codex/gpt-5.6-luna", cwd: taskWorktree, task: handoff})`; this specifies the model, not the required effort.
The `name` labels a role and does not select its definition.
Create the Reviewer as a new `worker` session with a fresh name and an effective session mode of `standalone` or `lineage-only`, never `fork` or a resumed implementation session.
The Reviewer must never be the agent that implemented the change under review.
Give Tester, Reviewer, and Integrator verification-only assignments rather than the general worker's implementation remit.

Every handoff carries the accepted task scope, acceptance criteria, constraints, selected delivery path, task-worktree boundary, relevant files and revision or diff identity, evidence so far, unresolved questions, and the receiving role's precise deliverable.
Pass evidence and reproduction instructions, not an assumption that a fresh session remembers earlier turns.
These role handoffs prepare the task deliverable; the selected delivery path and landing gates remain owned by [AGENTS.md section 7](../../../AGENTS.md#7-task-lifecycle).

1. Resolve the selected Explorer and Researcher questions before planning changes that depend on their answers.
   Explorer returns a code map and observed behavior; Researcher returns sourced findings and remaining uncertainty.
   Independent questions may run concurrently.
2. The orchestrator turns those findings, or the already sufficient brief, into a bounded implementation handoff for Worker.
   Worker returns the change summary, exact changed-state identity, criteria covered, and any known gaps.
3. Tester receives that implementation plus the criteria and exercises the relevant end-user behavior and regressions.
   Its handoff includes exact commands or steps, results, failures, and untested limits tied to the tested state.
4. Reviewer receives the accepted criteria, diff, and test evidence in its fresh context.
   It returns actionable findings or a supported clean assessment, with each finding tied to the reviewed state and criterion.
5. Before selected delivery validation begins, corrections go back through Worker -> Tester -> a fresh Reviewer so earlier evidence is not reused for changed code.
   Delivery validation and finding ownership after that point remain with [AGENTS.md section 7](../../../AGENTS.md#7-task-lifecycle), not a competing sub-agent fix loop.
6. When selected, Integrator receives the component results, join or landing identity, review findings and resolutions, and prior test evidence.
   It verifies the actual final state and reports discrepancies or evidence that the joined result satisfies the criteria; this assignment grants no landing authority.

The tool returns an acknowledgement immediately, then delivers each completed result asynchronously to the orchestrator, not firstmate.
After spawning, work on independent tasks or end the turn for automatic result delivery; never poll or infer completion from the acknowledgement.

## Boundaries and reporting

Every sub-agent stays inside the orchestrator's task worktree and receives that boundary explicitly; `cwd` selects a directory, not a filesystem sandbox.
The orchestrator coordinates writes and verification so evidence refers to a stable result rather than another role's changing files.
Sub-agents' prohibition on addressing the captain is owned by [AGENTS.md section 1](../../../AGENTS.md#1-identity-and-prime-directives).
For destructive, irreversible, outward-facing, and security-sensitive actions, preserve the accepted task scope and the authority boundaries in [AGENTS.md section 7](../../../AGENTS.md#7-task-lifecycle).
A sub-agent needing a decision uses `ask_question` to return it to the orchestrator, which routes it through the normal `needs-decision` path in [AGENTS.md section 7](../../../AGENTS.md#7-task-lifecycle).

Only the orchestrator writes Firstmate status reports; child summaries and questions return through the sub-agent tools.
Emit sparse `working:` lines naming the current role and gate when that transition matters to supervision, and one `done:` or `failed:` line for the delivery outcome.
The existing status protocol and lifecycle completion criteria remain owned by [AGENTS.md section 7](../../../AGENTS.md#7-task-lifecycle) and the generated task brief.
