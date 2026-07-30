---
name: grill-intake
description: >-
  Sharpen an intake by running Matt Pocock's original grilling and domain-modeling instructions as firstmate, with the captain.
  Use when the captain asks to be grilled or to stress-test a plan or decision, and immediately before writing a brief when a request's acceptance criteria are materially too unsharp to dispatch.
  Owns only the Firstmate bindings: how the originals are resolved, when a fact is looked up instead of asked, where glossary and decision records are landed, and what ends the session.
user-invocable: true
metadata:
  internal: true
---

# grill-intake

Load this when the captain asks to be grilled or to stress-test a plan, decision, or idea, and immediately before writing a brief when a request's acceptance criteria are materially too unsharp to dispatch.
Ordinary ambiguity is not the trigger: `AGENTS.md` section 7 already has firstmate ask one concise intake question, and that stays the answer for a request that one question resolves.
A relentless interview spends the captain's attention, so start it only when a wrong reading would send a crewmate to build the wrong thing.

**This adapter contains no interview procedure.**
The procedure is Matt Pocock's and is loaded from the installed original every time.
Everything below is only what the original cannot know: which Firstmate contracts bind it, and which of its mechanisms Firstmate must substitute.

## Load the originals

Resolve each skill through [`bin/fm-skill-path.sh`](../../../bin/fm-skill-path.sh), never a remembered path, because the install path changes on every plugin bump:

```sh
bin/fm-skill-path.sh mattpocock-skills grilling --field skill_file
bin/fm-skill-path.sh mattpocock-skills domain-modeling --field skill_dir
bin/fm-skill-path.sh mattpocock-skills grill-with-docs --field skill_file
```

Read the resolved instructions and operate under them as written.
`grill-with-docs` is the composition of the other two rather than a third procedure, so read it to confirm the pairing, not for separate steps.
`domain-modeling` reaches its own format references by relative link from its directory; `--list-files` lists that support tree, and those files are read when a term or decision is actually being recorded.

Prefer the runtime's own skill machinery where it can reach the skill, and read the resolved file where it cannot; `harness-adapters` owns invocation forms.
`grilling` and `domain-modeling` are model-invocable, so firstmate can invoke them directly.
`grill-with-docs` is reachable only by a human typing its name, so firstmate reads its resolved file instead.

If the resolver refuses, say plainly which workflow is unavailable and what is missing, then fall back to section 7's ordinary intake questions.
Never substitute a remembered or paraphrased version of the procedure.
A paraphrase freezes at the moment it was written, stops being Matt's discipline, and drifts silently from the installed original.

Attribution: Matt Pocock, MIT licensed, `https://github.com/mattpocock/skills`, shipped as the `mattpocock-skills` plugin.
Nothing is copied into this repo, so the interview improves whenever the plugin does.
[`docs/verification/matt-pocock-skills.md`](../../../docs/verification/matt-pocock-skills.md) records the validated plugin version and source pin.

## Firstmate bindings

### Firstmate holds the conversation

Firstmate is the only agent that speaks with the captain, so the interview happens in firstmate's own conversation and is never delegated.
A crewmate has no human to interview; hard rule 4 and the generated brief already send a crewmate's genuine decision back through firstmate instead.

Every question put to the captain still obeys section 9: lead with the concrete evidence, use the captain's nouns, and carry a recommended answer.

### Facts are looked up, decisions are asked

The original already draws that line.
Firstmate adds only where the lookup happens:

- Firstmate reads the local clone itself for a bounded fact - a README, an existing glossary, a named file, a grep, whether a symbol exists.
  Reading a project is allowed; writing one is not.
- A scout takes anything needing a reproduction, a multi-file trace, a benchmark, or a design exploration.
  Tell the captain that thread is waiting on it, keep independent threads moving, and resume from the report.

Never put a question to the captain that a bounded read would have answered.

### Glossary and decision records are delivered, never written here

`domain-modeling` writes its glossary and decision records into the project as they crystallise.
Firstmate must not write a project (hard rule 1), so the destination changes while the timing does not:

- Capture immediately, as each term or decision lands, to `data/<effort-id>/domain-delta.md` in this firstmate home.
- Land it through the project's selected delivery path: the delta becomes part of the ship brief, or its own small documentation ship, and a crewmate writes the project's glossary and decision records on its branch in an isolated worktree.

This substitutes a destination, not the discipline, and it grants no licence to edit a project file directly, including a project's `AGENTS.md` (section 6 keeps that with the crewmate and `bin/fm-ensure-agents-md.sh`).

### What ends the session

The original ends on the captain's confirmation of shared understanding, and that confirmation is the authorization to write the brief and dispatch.
Record it where it survives the conversation: in the brief's acceptance criteria, not in chat alone.
Any captain decision the interview surfaced but did not settle follows `decision-hold-lifecycle` before this work is treated as complete.
