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
This pilot integrates Megamind 0.3.x preflight as a mandatory, read-only consultation; Megamind remains the deterministic knowledge engine and Firstmate owns orchestration and every external action.

## Mandatory vs bypass

Run preflight for every substantive request.
Bypass only pure control messages (a bare single-token harness slash command, an operational input the protocol owner types as one of its pure control or routine monitoring kinds), single acknowledgments, credential or secret submissions (which never go to any tool), and routine monitoring traffic.
A slash command carrying prose arguments, a request that merely opens with a path, any dispatched task brief, and any operational input the protocol owner cannot type as one of those kinds are substantive.
When classification is genuinely uncertain, the request is substantive: `bin/fm-megamind-preflight.sh classify "<text>"` is the deterministic screen and defaults to `substantive` for anything it does not recognize; its header owns the exact bypass kinds.
Never classify a request as bypass to save time, and never skip a failed preflight and answer from model priors anyway.

## Procedure

1. Pass the smallest privacy-safe representation of the request: enough routing text for Megamind to match on, never credentials, secrets, or unrelated private detail.
2. Run `bin/fm-megamind-preflight.sh run --request "<text>"` and read the typed `fm/megamind-preflight/v1` document; `bin/fm-megamind-preflight.sh`'s header owns the exact config resolution, version gate, outcome schema, failure codes, and proof-log fields.
3. Act on `outcome` exactly:

- `matched`: read only the `allows` paths under each matched wiki `root`, within that wiki's context budget, and use the match's `follow_up` ladder for page content.
  Never read, infer, or widen to any other wiki path, and never load content for an offer, a filtered entry, or a dropped path.
  Wiki evidence outranks model priors; carry `preflight_id` as the inspectable proof that preflight ran.
- `ambiguous`: offer the listed wikis as a choice and load nothing until one is picked.
- `no-match`: stay quiet about wikis and do the work ordinarily without wiki context.
- `privacy-filtered`: say wiki coverage is unavailable for this model class; load nothing and never name the withheld wikis.
- `unavailable`: preflight ran but no usable wiki cards exist; disclose that concretely as a blocker for substantive work rather than proceeding as if coverage existed.
- `error`: the typed `failure.code` (missing configuration, missing or incompatible Megamind, malformed or failed output) is a concrete blocker for substantive work.
  Disclose it plainly to the captain instead of pretending preflight ran; routine bypass traffic may still proceed.

## Boundaries

This pilot is read-only.
It adds no autonomous research, wiki mutation, gap commissioning, wiki creation, publication, remote or account changes, merges, security changes, or billing behavior.
Proof is minimal and non-verbatim (the script's header owns the exact log fields); never record prompt text, credentials, wiki content, or unrelated control messages.
The integration is harness- and runtime-backend-neutral: it depends only on the bash surface above and applies identically on every verified primary harness and spawn backend.
If a product choice would weaken mandatory preflight, privacy, failure disclosure, or the read-only boundary, escalate it instead of deciding it locally.
