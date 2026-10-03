---
name: ship-landing
description: Load when a ship reports a PR or ready branch, when handling a review-ready shared-wiki PR, when deciding or monitoring landing, and before task cleanup.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done [at=<epoch>]: PR <url> checks green` after CI is green, while `direct-PR` reports `done [at=<epoch>]: PR <url>` after opening the PR, each only for a non-draft PR; a lane that deliberately holds a draft declares a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal or the resolved checks-green `fm-crew-state.sh` line - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
`bin/fm-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/fm-crew-state.sh` reports blocked, `bin/fm-pr-check.sh` refuses to register, and a secondmate does not publish that done upstream).
That blocked reading is the gate working, not a stuck worker, so steer the worker on the commit the refusal names rather than waiting.
A direct-PR worker pushes that commit to its PR branch, and a local-only worker commits it on its ship branch.
A no-mistakes worker re-validates it with /no-mistakes so the pipeline stays the one publisher; it never pushes from its copy.
In no-mistakes mode the earlier `done [at=<epoch>]: {summary}` is the pipeline handoff and is not gated.
For a review-ready shared-wiki GitHub PR, use the current advisory printed by `bin/fm-pr-check.sh` at registration or run `bin/fm-jev-pr-verdict.sh <PR URL>` before the review ask, including external contributions without a spawned task.
If it prints an advisory, include the pass/concerns verdict, its labelled Jev probability and reasons beside the full PR URL; if it prints nothing, proceed without a Jev claim.
Its metadata-only judgment does not certify privacy or required checks and never grants or blocks a merge; the captain's merge decision and the existing merge rules remain unchanged.
Every in-scope PR or ready branch also gets a review from another AI family than its builder: run `bin/fm-cross-review.sh plan <id>`, whose header owns the evidence rules and private-vault exclusion. For GitHub PRs it refreshes the exact head from the forge even when `pr_head=` is recorded; for a PR on another forge without `pr_head=`, pass `--head <sha>` from that forge.
On `action=spawn-reviewer`, file the reviewer as its own work item, run that script's `brief` with the printed reviewer id and head, and spawn it as a scout of the task's project with the printed harness, model, and effort; on `action=escalate`, put the stated reason to the captain.
When an unsure merge decision needs a confirmation, the same path runs with `plan <id> --confirm`, and `bin/fm-cross-review.sh verify-confirm <id> <sha>` accepts it only for that exact sha.
This review is evidence for the merge decision and changes no merge rule above.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line, the resolved checks-green crew-state line, or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine merge authority.
Before deciding a PR merge, run `bin/fm-jev-merge-gate.sh decide <PR URL>`; for a team project's PR, pass `--team` (`decide <PR URL> --team`). For a local-only landing, run `bin/fm-jev-merge-gate.sh decide --task <id>`; for a team project's landing, pass `--team` (`decide --task <id> --team`). Then decide exactly as you would without the shadow gate.
Once decided, record your decision with `bin/fm-jev-merge-gate.sh record <PR URL | --task <id>> --head <sha> --firstmate merge|hold`, and after a merge `outcome ... merged`.
The gate is shadow only: its verdict never grants, blocks or delays a merge, a kept-out or failed run needs no follow-up, and it is never named to the captain as a merge reason.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

After a merge the Jev merge gate approved, run `bin/fm-post-merge.sh arm <id>` before cleanup. Pass `--witness <production URL>` for a live-site or team project; otherwise pass `--no-witness <reason>`. Its header owns the phases, the witness, and the revert rules.
On every wake for that watch run `bin/fm-post-merge.sh advance <id>` and relay a `notify:` line to the captain as written; an `approval:` line is a merge ask for the revert, and a `blocked:` line is a blocker.
A `witness:` line means dispatching a fresh scout that built none of the change, its `## Firstmate spec` filled from `bin/fm-post-merge.sh witness-task <id>...` (one per merge on a live-site project, one per wave of task ids on a team project), then recording its report with `witness-result`.
Cleanup refuses while that watch is open and keeps a reverted task queued.

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
