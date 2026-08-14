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

- `matched`: invoke `bin/fm-megamind-content.sh admit --task-id <task-id>` from the owning home, then use its separate content channel.
  The reader validates and bounds only the explicitly returned `allows` paths under the owning estate; never read wiki paths directly, infer or widen paths, or load content for an offer, filtered entry, or dropped path.
  During full-access page descent, the script-owned local route relevance contract has two halves - a floor of 0.5 on Megamind's own per-candidate route confidence, never on its unbounded lexical score, and candidate-local evidence that the page's own index entry matched rather than its wiki; if no ranked page satisfies both, or the resolved build reports neither signal, preserve Megamind's declared allows instead of narrowing, without changing reliance, offer, or ambiguity thresholds.
  Use the self-describing `thresholds`, safe `freshness`, and non-verbatim `provenance` summary without reconstructing request tokens or inspecting raw Megamind output.
  Wiki evidence outranks model priors; carry `preflight_id` as the inspectable proof that preflight ran.
- `ambiguous`: offer the listed wikis as a choice and load nothing until one is picked.
  When the captain chooses one listed wiki, pass only the exact returned `selection_id` and exact wiki name to `bin/fm-megamind-preflight.sh continue`; it retrieves the original request and packet privately and invokes Megamind's governed `select-offer` command.
  An ambiguous result that carries no `selection_id` cannot be continued in that home - it belongs to no session, or the resolved Megamind release predates `select-offer` - so the choice stands but nothing is loaded.
  Treat `authorized` as an explicit offer selection, not a threshold match, and invoke `bin/fm-megamind-content.sh admit --selection-id <selection-id>` from the owning home, then use its separate content channel.
  The reader accepts only the script-issued authorization and its selected allows and budget; it never executes or parses `follow_up`.
  The same local route relevance contract applies when an authorized full-access selection descends pages; a ranking that misses either half preserves the selected declaration.
  A continuation or admission refusal leaves the substantive work blocked and never falls back to the ambiguous worker path.
- `no-match`: stay quiet about wikis and do the work ordinarily without wiki context.
  A `no-match` whose `filtered_count` is greater than 0 withheld a candidate for this model class and is handled exactly like `privacy-filtered` below, not like an ordinary no-match.
- `privacy-filtered`: say wiki coverage is unavailable for this model class; load nothing and never name the withheld wikis.
- `unavailable`: preflight ran but no usable wiki cards exist; disclose that concretely as a blocker for substantive work rather than proceeding as if coverage existed.
- `error`: the typed `failure.code` (missing configuration, missing or incompatible Megamind, malformed or failed output, or unsafe selection continuation) is a concrete blocker for substantive work.
  Disclose it plainly to the captain instead of pretending preflight ran; routine bypass traffic may still proceed.

## Automatic primary mode

A home that opted into automatic primary mode routes every prompt through `bin/fm-megamind-primary.sh` before the turn starts, so a governed turn can arrive already carrying admitted wiki evidence, introduced by the host's bounded-reader guidance line.
That is the same preflight and the same bounded reader this procedure runs, already performed for that exact prompt: act on the evidence the turn carries and do not route the same request a second time.
Nothing else about this contract changes - the per-outcome rules, the evidence gap below, and the failure-disclosure duty apply to admitted evidence however it arrived.
The absence of admitted evidence never proves that routing ran: a `no-match` or `privacy-filtered` decision injects nothing, and a home that never opted in is indistinguishable from one that did, so every turn without it takes the mandatory procedure above.
An ambiguous result never reaches the model in that mode - the coordinator settles it first, through the adapter's own disposition screen where one exists and by selecting the highest-confidence offer itself where none does - and a blocked prompt starts no turn at all.
A resolution that cannot complete continues the prompt without wiki evidence, so a governed turn carrying no admitted evidence still proves nothing about routing.
`docs/configuration.md` "Megamind preflight" owns the coordinator, the adapters, and the opt-in.

## Admitted evidence that cannot answer the request

A successful preflight and a successful admission prove that routing ran, never that the admitted content answers the question.
When the admitted evidence does not answer it, state that evidence gap plainly and stop; name what the wiki does cover and what it does not.
Never close the gap from model knowledge, and never present model synthesis as wiki-grounded, whatever `preflight_id` the turn is carrying.
Admitted content that only names or links pages which were not themselves authorized is exactly this case: those page names are the reportable gap, not permission to reason from them.
This rule applies identically to a threshold `matched` result and to an `authorized` explicit selection, and it is the one case where wiki evidence outranking model priors means answering with less rather than more.

## Ordinary worker launch guidance

When you dispatch an ordinary ship or scout task, author `data/<task-id>/megamind-request.md` the same way you fill in `{TASK}`: one privacy-safe routing line, enough for Megamind to match on and nothing more.
That file - never the brief - is what `bin/fm-spawn.sh` routes through the owning home's binding before any endpoint, worktree, or task record exists, so an unfilled or oversized request refuses the spawn instead of producing a task that cannot work.
A refusal is a concrete blocker to disclose, not a step to retry around: fix the binding or the routing request, or escalate it.
Every routing-request refusal names the exact file to author or correct, including for a task scaffolded before that file existed - write its one routing line at the named path.
`bin/fm-control.sh relaunch` clears the same binding before it stops anything, so a refusal there leaves the running worker, its record, and its local copy untouched.

As the worker, your launch-time result is already filed in the owning home's private `state/<task-id>.megamind-preflight.json` and your brief's wiki-routing section names it.
Do not read that file directly, rerun preflight from the isolated project copy, or point that copy's `FM_HOME` at another home.
Use the owning-home `bin/fm-megamind-content.sh admit --task-id <task-id> --owner-home <owning-home>` command, then use `content --admission-id <opaque-id> --owner-home <owning-home>` for the content channel.
A secondmate's own `fm-spawn.sh` performs the same step with that secondmate home's binding, so primary bindings never cross the secondmate boundary.
`bin/fm-worker-preflight.sh`'s header and `docs/configuration.md` own the launch mechanics and binding boundary; this section only gives the conditional worker guidance.

## Boundaries

This pilot is read-only.
It adds no autonomous research, wiki mutation, gap commissioning, wiki creation, publication, remote or account changes, merges, security changes, or billing behavior.
Proof is minimal and non-verbatim (the script's header owns the exact log fields); never record prompt text, credentials, wiki content, the original ambiguous packet, or unrelated control messages.
The private pending-selection record is not worker input and its opaque `selection_id` is the only continuation handle that may appear in the normalized result.
The integration is harness- and runtime-backend-neutral: it depends only on the bash surface above and applies identically on every verified primary harness and spawn backend.
If a product choice would weaken mandatory preflight, privacy, failure disclosure, or the read-only boundary, escalate it instead of deciding it locally.
