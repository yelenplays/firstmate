---
name: resolving-merge-conflicts
description: Resolve an in-progress Git merge or rebase conflict, including conflicts encountered during no-mistakes rebase or CI repair. Load when Git has stopped on unmerged paths.
license: MIT
metadata:
  internal: true
---

# Resolve merge conflicts

Firstmate-maintained compatibility skill, adapted from Matt Pocock's MIT-licensed `resolving-merge-conflicts` procedure.
Upstream [archived it without a replacement](https://github.com/mattpocock/skills/blob/49dd158d1076134a641b33efb035946536778336/docs/engineering/resolving-merge-conflicts.md) in v1.3.0.
This is bundled repository content, not a skill offered by the installed plugin.
The accompanying [LICENSE](LICENSE) preserves the upstream notice.

1. Confirm the authorized repository and the in-progress operation with `git status`, `git diff --name-only --diff-filter=U`, and relevant history.
   Preserve unrelated edits and record the starting commit before changing any conflict.
2. Trace both sides of every conflict to their intent using commit messages and, where available, their PRs or issues.
   During a rebase, inspect the replayed commit rather than assuming `ours` and `theirs` mean the same thing as in a merge.
3. Resolve each hunk to preserve both intents where compatible, without inventing new behavior.
   If they are incompatible and the authorized goal does not determine the answer, stop and report the concrete decision through the caller's escalation channel.
   Preserve the in-progress operation and resolution work; do not abort, reset, discard edits, or force-push to make the conflict disappear.
4. Discover and run the project's checks for the affected behavior, including tests, type checks, and formatting where applicable.
   Verify there are no remaining unmerged paths or conflict markers in the resolved files, and inspect the staged diff for lost changes.
5. Stage only the resolved paths belonging to the authorized operation.
   Continue that existing merge or rebase; for a multi-commit rebase, repeat these steps for each conflict until it finishes.
   Report the resulting commit and checks, or the precise blocker with the resolution work preserved.
   Completing an existing local merge/rebase does not authorize publishing, merging a PR, or changing unrelated files.
