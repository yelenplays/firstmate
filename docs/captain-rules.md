# Captain rules

A captain rule is a correction of how firstmate works that the captain gave once and expects never to repeat.
This page owns the operator contract: what a rule is, where it is loaded, how a correction becomes a rule, precedence, the rule-to-check pattern, and the weekly report.
`bin/fm-rules.sh` and `bin/fm-rule-guard.sh` own exact flags, the file format, state files, and exit codes in their headers.

Rules use a dedicated context block rather than relying on optional memory recall.
Repeated corrections are surfaced for a deterministic check or a recorded reason why one is not possible.

## The one source

All rules live in gitignored `config/captain-rules.md` of the primary home, one line per rule with a stable id and a small metadata comment.
Every write goes through `bin/fm-rules.sh` (`add`, `confirm`, `revoke`, `check`, `nocheck`); hand edits are possible but lose the repeat count if the comment is broken.
Secondmate propagation timing, live reread delivery, and failure handling follow the [inherited-local-material contract](../.agents/skills/secondmate-provisioning/references/inheritance.md).
A secondmate never records its own rules; route new corrections to main.

Rules are for how firstmate works.
Facts about the captain, projects, or the world still go to the [memory store](memory.md) or the curated `data/` files; [automatic capture](memory.md#automatic-capture) never writes a rule.

## Where rules are loaded

Rules are included in these context surfaces, regardless of model:

| Consumer | Surface | When |
| --- | --- | --- |
| Claude main or secondmate | SessionStart hook `bin/fm-rules.sh session` | startup, resume, clear, and every compaction |
| Codex, Pi, and other primaries | `CAPTAIN RULES` section of `bin/fm-session-start.sh`, inside the operating stage | full and compact digests |
| Ship and scout workers | `# Captain rules` section of the brief from `bin/fm-brief.sh` | every scaffold |

The session block is bounded; when it is cut, its notice directs the agent to `bin/fm-rules.sh list` for the complete set.
The [`fm-rules.sh` header](../bin/fm-rules.sh) owns the size controls.
Worker briefs include the complete rule set at scaffold time; existing briefs are not rewritten when a rule changes.
Secondmate charters carry no rules section because the secondmate session loads them itself.
Task worktrees, no-mistakes gates, and the supervision branch get no session block; a worker gets the rules only through its brief.

## Precedence

The rendered block states that captain rules outrank generic harness, tool, and skill hints that conflict with them.
The motivating case is a harness system prompt that suggests handing the captain a `! <command>` line, which fails for sudo and interactive logins.
Inside a worker brief, the brief's task scope and safety rules still win over a captain rule.

## From correction to rule

1. The Claude UserPromptSubmit hook `bin/fm-rules.sh prompt-hook` reads each captain prompt in the primary home's main session and matches correction and standing-rule phrasing such as "ab jetzt", "nie wieder", "hab ich dir schon gesagt", "from now on", or "do it yourself".
   Wakes, notifications, and pasted content are skipped.
2. A match writes a candidate under `state/captain-rules/candidates/` and tells main to decide.
3. Main either records the rule with `bin/fm-rules.sh confirm <candidate> <rule-id> "<rule>"` and confirms it in one chat line ending with `"nein" nimmt sie zurueck`, or drops the candidate with `dismiss` and says nothing.
4. A bare "nein" right after a confirmation makes the hook inject the matching `revoke` command.

The hook never writes a rule itself; only main's `confirm` or an explicit `add` does.
Recording a rule id that already exists is a repeat: the count grows and the text is replaced, so main should reuse the existing id when a correction comes back.
Codex and Pi primaries have no capture hook here, so main records corrections there with `bin/fm-rules.sh add`.

## From rule to check

A rule whose mistake has a fixed shape gets a deterministic check right away, and a rule recorded a second time must get one or a recorded reason why not.

- Checks live in `bin/fm-rule-guard.sh`, are always on, and are listed by `bin/fm-rule-guard.sh list`.
- `bin/fm-rules.sh check <rule-id> <check-id>` links a rule to a check; `nocheck <rule-id> "<reason>"` records the decision that none is possible.
- A rule seen twice without either is listed under `REPEATED WITHOUT A CHECK` in the rendered block, by `bin/fm-rules.sh unchecked`, and in the weekly report.

The first check is `bang-interactive`.
The Claude Stop hook `bin/fm-rule-guard.sh --claude` blocks a primary reply that hands the captain a `! <command>` line for sudo, a rebuild, a login, a password, or a keychain step, and tells the agent to put the command on the clipboard with `pbcopy`, ask for a real Terminal window, and verify the result itself.
Quoted-rule exceptions use a nearby negation, not any earlier negation on the line; the [guard header](../bin/fm-rule-guard.sh) owns the exact window and exception, with regressions in [`tests/fm-rule-guard.test.sh`](../tests/fm-rule-guard.test.sh).
If the same blocked reply comes back on the forced continuation, the guard releases it and logs the release instead of looping.
A missing or non-string reply payload is allowed without a check.
Only Claude primary replies are checked here; other harnesses and workers receive rules as context only.

## Weekly report

`bin/fm-rules.sh report` prints the last seven days: rules added and repeated, guard blocks and releases, rules repeated without a check, candidate counts, and correction-like captain prompts found in the Claude transcripts of this home.
`bin/fm-rules.sh weekly-arm` binds a watcher check that reminds main to run the report and send a short version to the captain; it does not generate or send the report automatically.
The reminder appears once when no report exists or the last report is at least a week old, and stays quiet until another report runs; `weekly-disarm` removes the check.
Running the report resets the week.

## Verification

[`tests/fm-rules.test.sh`](../tests/fm-rules.test.sh) and [`tests/fm-rule-guard.test.sh`](../tests/fm-rule-guard.test.sh) cover the store, capture instructions, brief projection, report, and guard behavior offline.
[`tests/fm-session-start.test.sh`](../tests/fm-session-start.test.sh) covers non-Claude rule delivery in full and compact digests.
The opt-in [`tests/fm-rules-live-e2e.test.sh`](../tests/fm-rules-live-e2e.test.sh) exercises the three Claude registrations against the real harness: SessionStart context, action on an injected candidate, and Stop-guard interception followed by either a rewrite or a logged release.
Its header owns invocation and model selection; offline coverage alone does not establish live context delivery or interception.

## Migration after this change

These steps touch captain-private stores and dotfiles, so they are done by hand from the primary home, not by this repository:

1. Run `bin/fm-rules.sh weekly-arm` once.
2. Record the corrections that already exist as rules with `bin/fm-rules.sh add`, starting with the `! <command>` rule and linking it with `--check bang-interactive`.
3. Remove the rule-shaped duplicates from the older stores once they are rules: Claude auto-memory `MEMORY.md`, `data/learnings.md`, `data/captain.md`, and the memory store.
4. Delete or correct any memory-store entry that contradicts a rule, for example an auto-captured merge preference that disagrees with the captain's current merge rule.
5. Teach the dotfiles recall hook to skip `FIRSTMATE SUPERVISION WAKE` and `<task-notification` prompts, which today inject keyword matches into wakes.
