# Issue tracker: GitHub

Issues and specs for this repo live in GitHub Issues on `yelenplays/firstmate`.
Use `gh-axi` for GitHub operations, with `--repo yelenplays/firstmate` after the command to select this repo explicitly.
This config locates engineering tickets, not Firstmate's private fleet backlog, which remains governed by `AGENTS.md` section 10.

## Conventions

- **Create an issue**: `gh-axi issue create --repo yelenplays/firstmate --title "..." --body-file <file>`.
- **Read an issue**: `gh-axi issue view <number> --repo yelenplays/firstmate --comments --full`.
- **List issues**: `gh-axi issue list --repo yelenplays/firstmate --state open --label <label> --limit 30`.
  Adjust filters and the limit as needed; read each relevant issue for its complete body and comments.
- **Make an issue a sub-issue of a parent**: create the child, then run `gh-axi issue subissue add <parent> <child> --repo yelenplays/firstmate`.
  Where sub-issues are unavailable, put `Part of #<parent>` at the top of the child body and add the child to a task list in the parent.
- **Comment on an issue**: `gh-axi issue comment <number> --repo yelenplays/firstmate --body-file <file>`.
- **Apply / remove labels**: `gh-axi issue edit <number> --repo yelenplays/firstmate --add-label "..."` / `--remove-label "..."`.
- **Close**: `gh-axi issue close <number> --repo yelenplays/firstmate --comment "..."`.

## Pull requests as a triage surface

**PRs as a request surface: no.**
Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.

When set to `yes`, PRs run through the same labels and states as issues, using the `gh-axi pr` equivalents:

- **Read a PR**: `gh-axi pr view <number> --repo yelenplays/firstmate --comments --full` and `gh-axi pr diff <number> --repo yelenplays/firstmate --full`.
- **List external PRs for triage**: `gh-axi api 'repos/yelenplays/firstmate/pulls?state=open' --paginate --jq '.[] | select(.author_association | IN("OWNER","MEMBER","COLLABORATOR") | not) | {number, title, author: .user.login, author_association, labels: [.labels[].name]}'`.
- **Comment / label / close**: `gh-axi pr comment`, `gh-axi pr edit --add-label`/`--remove-label`, `gh-axi pr close`, selecting this repo explicitly.

GitHub shares one number space across issues and PRs, so a bare `#42` may be either: resolve with `gh-axi pr view 42 --repo yelenplays/firstmate` and fall back to `gh-axi issue view 42 --repo yelenplays/firstmate`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Read it as in **Read an issue** above.

## Wayfinding operations

Used by `/wayfinder`.
The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body.
  Create it with `gh-axi issue create --repo yelenplays/firstmate --title "..." --body-file <file> --label wayfinder:map`.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue (see **Make an issue a sub-issue of a parent**).
  Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`).
  Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: GitHub's native issue dependencies are the canonical, UI-visible representation.
  Add an edge with `gh-axi api POST repos/yelenplays/firstmate/issues/<child>/dependencies/blocked_by --input <file>` using a JSON body `{"issue_id": <blocker-db-id>}`.
  Obtain the blocker's numeric database id with `gh-axi api repos/yelenplays/firstmate/issues/<n> --jq .id`, not its issue number or `node_id`.
  GitHub reports `issue_dependencies_summary.blocked_by` as the number of open blockers.
  Where dependencies are unavailable, fall back to a `Blocked by: #<n>, #<n>` line at the top of the child body.
  A ticket is unblocked when every blocker is closed.
- **Frontier query**: list the map's open children with `gh-axi issue subissue list <map> --repo yelenplays/firstmate`, or read its task list.
  Drop any child with an open blocker or an assignee; first in map order wins.
- **Claim**: `gh-axi issue edit <n> --repo yelenplays/firstmate --add-assignee @me`, the session's first write.
- **Resolve**: `gh-axi issue comment <n> --repo yelenplays/firstmate --body-file <file>`, then `gh-axi issue close <n> --repo yelenplays/firstmate`, then append a context pointer (gist + link) to the map's Decisions-so-far.
