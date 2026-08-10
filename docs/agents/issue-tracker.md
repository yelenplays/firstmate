# Issue tracker for installed skills

An installed skill that will create or update issues for this repository uses GitHub Issues on `yelenplays/firstmate`, the captain's fork, and only when the captain explicitly authorizes issue-tracker work.
That target is an intentional bounded convention tracked for the captain's fork rather than a portable upstream default, because the local `origin` remote may point at upstream `kunchenguid/firstmate`.
Do not publish these issues to upstream `kunchenguid/firstmate` unless the captain explicitly redirects that concrete operation.
Pull requests are not a request or triage surface for this work.

## Tracker prerequisite

GitHub Issues must be enabled on `yelenplays/firstmate` before any operation in this guide can run.
Confirm the surface is live with `gh-axi api repos/yelenplays/firstmate` and read `has_issues`, because a `false` value makes every read and write fail with `error: the 'yelenplays/firstmate' repository has disabled issues`.
Enabling issues is a repository-settings change the captain owns, so report that blocker instead of changing the setting or retargeting the work to another repository.

## GitHub workflow

Use `gh-axi` for every GitHub read or write, and pass `-R yelenplays/firstmate` so the operation never depends on the local `origin` remote.
Consult `gh-axi issue --help` and, when labels are involved, `gh-axi label --help` immediately before acting because those help surfaces own the current commands and flags.
A read-only request does not authorize creating, editing, commenting on, labelling, assigning, closing, or otherwise mutating an issue.
Do not interpret a skill's generic suggestion to publish as captain authorization for a GitHub write.

## Wayfinding operations

A wayfinding map is one issue labelled `wayfinder:map`, with sections for notes, decisions so far, and fog.
Each ticket is a child issue when native subissues are available, or is linked from a task list on the map and names `Part of #<map>` otherwise.
Ticket labels use `wayfinder:<type>`, where the type is `research`, `prototype`, `grilling`, or `task`.
Use native issue dependencies when available, or record `Blocked by: #<number>` in the dependent issue otherwise.
Resolving a ticket means recording its answer, closing it, and adding a pointer to the map's decisions-so-far section.
All wayfinding writes remain subject to the explicit authorization rule above.

## Firstmate backlog boundary

Firstmate's operational queue remains `data/backlog.md` through the configured backlog backend.
Do not mirror routine fleet work into GitHub Issues unless the captain explicitly requests that separate tracking record.
