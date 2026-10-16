Your scout task has been promoted to a ship task, mode=local-only. Your window, worktree, and context stay as they are; only the contract below changes.

# Task
## Captain's intent
Add one line "lab check" to the end of README.md in the scratch project.

## Firstmate spec
If these promotion steps were already completed before a relaunch, preserve the existing `fm/promote-live` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean default-branch base, then create your branch: `git checkout -b fm/promote-live --`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Firstmate spec and any unmarked legacy `# Task` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule, except where the current contract below explicitly replaces scout-only delivery or status reporting rules.


# Current delivery mode contract
This task is now kind=ship with mode=local-only.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
This replaces the scout rule limiting outside-worktree writes to the report and status file.
Keep project edits inside this worktree; keep proof and scratch output outside it, under `/var/folders/9d/8w50jhgd79x63rgbq_5cyyvm0000gn/T//fm-lab.9clb7a/data/promote-live/` or a temporary directory.
Outside the worktree, write only that task material and the status and steering-inbox records authorized below.
Leave the worktree clean before reporting done.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
1. Never push to any remote and never open a PR. Work only on your `fm/promote-live` branch; firstmate handles the merge into local `main`.

# Definition of done
Delivery contract: mode=local-only
Ship branch: fm/promote-live
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch `fm/promote-live`. Do NOT push, do NOT open a PR, do NOT merge.
A `done:` is accepted when the named head is on this project's shared local branch, not only on a detached copy; the check tests that head, not merely that a branch moved.
Keep your branch a clean fast-forward onto the current default branch - if `main` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append `done [at=<epoch>]: ready in branch fm/promote-live` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.

# Current implementation status reporting
This replaces the earlier status append command. Report from the isolated worker copy using:
`FM_HOME=/var/folders/9d/8w50jhgd79x63rgbq_5cyyvm0000gn/T//fm-lab.9clb7a /Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M501F6GW79SHVEH679B3J25J/bin/fm-task-execution.sh status promote-live e1792096616.55176.15450 "{state} [at=<epoch>]: {one short line}"`

After verifying isolation, execute before implementation:
`FM_HOME=/var/folders/9d/8w50jhgd79x63rgbq_5cyyvm0000gn/T//fm-lab.9clb7a /Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M501F6GW79SHVEH679B3J25J/bin/fm-task-execution.sh started promote-live e1792096616.55176.15450`
