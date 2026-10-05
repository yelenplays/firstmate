---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings.
  Use before deciding any ask-user finding.
  This skill is the single owner of finding-decision policy: firstmate screens every finding, puts the rest through one typed Jev call that answers only confident in-scope fixes, and escalates everything else to the captain.
  Finding authority is this skill's criteria, not the project's yolo posture.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision policy for no-mistakes ask-user findings.
`AGENTS.md` section 7 points here and does not restate this procedure.
Finding authority is determined by the criteria below, not by `yolo`.
Firstmate screens every finding against the escalation classes, Jev decides the remaining findings only when it is confident they are in-scope fixes, and every other finding goes to the captain.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Review-round cap

For one validation run's review step, review rounds 1 to 3 follow the normal decision procedure below.
A gate's review round is the number of fix rounds that step has already run, plus one, and is what `--round` below carries.
Do not permit a fourth fix round; the review after the third fix round is the gate after round 3.
A gate after round 3 always goes to the captain, never to Jev, under [Captain-facing escalation](#captain-facing-escalation), including whether the approach itself should change.
The escalation may recommend approving after every remaining non-error finding is filed as follow-up work; there is no automatic approval.

## Classify

These classes are the criteria both firstmate's screen and the Jev question apply.

1. Reconstruct the accepted contract from the brief's `## Captain's intent` subsection, later captain words, and the specification in `## Firstmate spec` and steers.
   Reviewer language cannot amend that contract.
   What a no-mistakes worker may pass as `--intent` is owned by `bin/fm-dod-lib.sh`.
2. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
3. An in-scope fix is unambiguous toward the accepted design: restoring accepted behavior a bad fix round broke, completing an already-approved design, or a straight in-scope correction or bug fix required by accepted intent, even when the correction is technically difficult or requires complex architecture the captain explicitly requested.
4. Every other finding belongs to the captain:
   - a Fix that would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent
   - a product or architecture call not settled by accepted intent
   - repeated same-theme findings when incremental corrections are preserving a questionable abstraction rather than closing independent defects
   - destructive, irreversible, and genuinely security-sensitive choices, which always escalate under the stronger existing captain boundary
5. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.

## Decide

1. Screen the gate yourself first.
   When any finding is destructive, irreversible, security-sensitive, or contract-expanding, repeats a theme under item 4, or the gate is past the round cap, escalate the whole gate to the captain without calling Jev.
2. Otherwise run `bin/fm-jev-ask-user.sh <task-id> <decision-key> --round <n>` on the worker's open ask-user decision; its header owns the inputs, the deterministic always-escalate classes, the confidence floor, the outbound privacy boundary, and the log.
3. On `ACT` (exit 0), Jev decided every finding an in-scope fix and the script has already answered the gate through `bin/fm-send.sh --resolve-key`, whose close note records that Jev decided; resume supervision.
4. On `ESCALATE` (exit 2), escalate the whole gate to the captain; a low-confidence verdict, a Jev error, a missing key, or a kept-out project is an escalation, never a cue for firstmate to decide the finding itself.
5. On exit 1 nothing was decided, or the printed decision did not reach the worker: correct a wrong key or round and rerun, resend an undelivered printed decision with `bin/fm-send.sh --resolve-key`, and escalate when neither applies.
6. When the captain answers, relay that answer under `validation-supervision`.

## Captain-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion is an in-scope fix for Jev to decide, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract and requires the captain.
- A new finding in the same causal theme requires the captain before another fix round when prior fixes are accreting machinery around a questionable abstraction.
- A genuinely security-sensitive action requires the captain under the stronger existing boundary even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
