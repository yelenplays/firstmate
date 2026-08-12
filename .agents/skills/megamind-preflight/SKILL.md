---
name: megamind-preflight
description: >-
  Agent-only policy for Firstmate's mandatory read-only Megamind preflight pilot.
  Load before answering, planning, dispatching, or investigating any substantive
  captain request, and before relying on model knowledge for one. Owns the
  mandatory-vs-bypass policy, the run procedure, per-outcome handling, failure
  disclosure, and the minimal proof contract.
user-invocable: false
metadata:
  internal: true
---

# megamind-preflight

Load this before acting on any substantive Firstmate AI request: answering a captain question, planning, scoping, dispatching, investigating, or any other turn that relies on model knowledge.
This pilot integrates Megamind preflight as a mandatory, read-only consultation; Megamind remains the deterministic knowledge engine and Firstmate owns orchestration and every external action.

## Mandatory vs bypass

Run preflight for every substantive request.
Bypass only pure control messages (a bare single-token harness slash command, an operational input the protocol owner types as one of its pure control or routine monitoring kinds), single acknowledgments, credential or secret submissions (whose payload never reaches any tool), and routine monitoring traffic.
A credential supplied through an active trusted credential exchange uses `bin/fm-megamind-preflight.sh classify-provenance credential-submission`; pass only that exact provenance token and never pass the credential payload to `classify`, `run`, shell arguments, or stdin.
Ordinary prose that discusses credentials is substantive, and no regex or content guess may convert it into a credential submission.
A slash command carrying prose arguments, a request that merely opens with a path, any dispatched task brief, and any operational input the protocol owner cannot type as one of those kinds are substantive.
When classification is genuinely uncertain, the request is substantive: `bin/fm-megamind-preflight.sh classify "<text>"` is the deterministic screen and defaults to `substantive` for anything it does not recognize; its header owns the exact bypass kinds.
Never classify a request as bypass to save time, and never skip a failed preflight and answer from model priors anyway.

## Procedure

1. Pass the smallest privacy-safe representation of the request: enough routing text for Megamind to match on, never credentials, secrets, or unrelated private detail.
2. Run `bin/fm-megamind-preflight.sh run --request "<text>"` and read the typed `fm/megamind-preflight/v1` document; `bin/fm-megamind-preflight.sh`'s header owns the exact config resolution, version gate, outcome schema, failure codes, proof-log fields, and private pending-selection record.
3. Act on `outcome` exactly:

- `matched`: read only the `allows` paths under each matched wiki `root`, within the optional numeric `context_budget`, and use the match's `follow_up` ladder for page content.
  Never read, infer, or widen to any other wiki path, and never load content for an offer, a filtered entry, or a dropped path.
  Use the self-describing `thresholds`, safe `freshness`, and non-verbatim `provenance` summary without reconstructing request tokens or inspecting raw Megamind output.
  Wiki evidence outranks model priors; carry `preflight_id` as the inspectable proof that preflight ran.
- `ambiguous`: offer the listed wikis as a choice and load nothing until one is picked.
  When the captain chooses one listed wiki, pass only the exact returned `selection_id` and exact wiki name to `bin/fm-megamind-preflight.sh continue`; it retrieves the original request and packet privately and invokes Megamind's governed `select-offer` command.
  An ambiguous result that carries no `selection_id` cannot be continued in that home - it belongs to no session, or the resolved Megamind release predates `select-offer` - so the choice stands but nothing is loaded.
  Treat `authorized` as an explicit offer selection, not a threshold match, and read only its returned `selected.allows` under `selected.root`, within its optional `selected.context_budget`, using its `selected.follow_up` ladder.
  A continuation refusal leaves the substantive work blocked and never falls back to the ambiguous worker path.
- `no-match`: stay quiet about wikis and do the work ordinarily without wiki context.
- `privacy-filtered`: say wiki coverage is unavailable for this model class; load nothing and never name the withheld wikis.
- `unavailable`: preflight ran but no usable wiki cards exist; disclose that concretely as a blocker for substantive work rather than proceeding as if coverage existed.
- `error`: the typed `failure.code` (missing configuration, missing or incompatible Megamind, malformed or failed output, or unsafe selection continuation) is a concrete blocker for substantive work.
  Disclose it plainly to the captain instead of pretending preflight ran; routine bypass traffic may still proceed.

## Ordinary worker launch guidance

When you dispatch an ordinary ship or scout task, author `data/<task-id>/megamind-request.md` the same way you fill in `{TASK}`: one privacy-safe routing line, enough for Megamind to match on and nothing more.
That file - never the brief - is what `bin/fm-spawn.sh` routes through the owning home's binding before any endpoint, worktree, or task record exists, so an unfilled or oversized request refuses the spawn instead of producing a task that cannot work.
A refusal is a concrete blocker to disclose, not a step to retry around: fix the binding or the routing request, or escalate it.
Every routing-request refusal names the exact file to author or correct, including for a task scaffolded before that file existed - write its one routing line at the named path.
`bin/fm-control.sh relaunch` clears the same binding before it stops anything, so a refusal there leaves the running worker, its record, and its local copy untouched.

As the worker, your launch-time result is already filed at `state/<task-id>.megamind-preflight.json` and your brief's wiki-routing section names it.
Read that file and act on its `outcome` exactly as above; it is the authoritative consultation for your task.
Do not rerun preflight from the isolated project copy and do not point that copy's `FM_HOME` at another home.
A secondmate's own `fm-spawn.sh` performs the same step with that secondmate home's binding, so primary bindings never cross the secondmate boundary.
`bin/fm-worker-preflight.sh`'s header and `docs/configuration.md` own the launch mechanics and binding boundary; this section only gives the conditional worker guidance.

## Boundaries

This pilot is read-only.
It adds no autonomous research, wiki mutation, gap commissioning, wiki creation, publication, remote or account changes, merges, security changes, or billing behavior.
Proof is minimal and non-verbatim (the script's header owns the exact log fields); never record prompt text, credentials, wiki content, the original ambiguous packet, or unrelated control messages.
The private pending-selection record is not worker input and its opaque `selection_id` is the only continuation handle that may appear in the normalized result.
The integration is harness- and runtime-backend-neutral: it depends only on the bash surface above and applies identically on every verified primary harness and spawn backend.
If a product choice would weaken mandatory preflight, privacy, failure disclosure, or the read-only boundary, escalate it instead of deciding it locally.
