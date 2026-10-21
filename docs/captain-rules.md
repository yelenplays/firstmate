# Captain rules

A captain rule is a correction of how firstmate works that the captain gave once and expects never to repeat.
This page owns the operator contract: what a rule is, where it is loaded, how a correction becomes a rule, precedence, the rule-to-check pattern, and the weekly report.
`bin/fm-rules.sh` and `bin/fm-rule-guard.sh` own exact flags, the file format, state files, and exit codes in their headers.

Rules use a dedicated context block rather than relying on optional memory recall.
Repeated corrections are surfaced for a deterministic check or a recorded reason why one is not possible.

## The one source

All rules live in gitignored `config/captain-rules.md` of the primary home, one line per rule with a stable id and a small metadata comment.
Every write goes through `bin/fm-rules.sh` (`add`, `confirm`, `revoke`, `check`, `nocheck`); hand edits are possible but lose the repeat count if the comment is broken.
Writes are serialized by a store lock, so corrections recorded in parallel never overwrite each other.
Secondmate file propagation and config reread instructions follow the [inherited-local-material contract](../.agents/skills/secondmate-provisioning/references/inheritance.md); [delivery to running consumers](#delivery-to-running-consumers) below owns rule-change delivery.
A secondmate never records its own rules; route new corrections to main.

Rules are for how firstmate works.
Facts about the captain, projects, or the world still go to the [memory store](memory.md) or the curated `data/` files; [automatic capture](memory.md#automatic-capture) never writes a rule.

## Where rules are loaded

Rules are included in these context surfaces, regardless of model:

| Consumer | Surface | When |
| --- | --- | --- |
| Claude main or secondmate | SessionStart hook `bin/fm-rules.sh session` | startup, resume, clear, and every compaction |
| Codex, Pi, and other primaries | `CAPTAIN RULES` section of `bin/fm-session-start.sh`, inside the operating stage | full and compact digests |
| Ship and scout workers | `# Captain rules` section of the brief from `bin/fm-brief.sh`, then steering-inbox updates | every scaffold and rule-set change |

Every surface carries every rule whole; no projection cuts the block.
The size limit is enforced when a rule is written instead: an `add`, `confirm`, or `check` that would grow the block beyond its budget is refused before it is saved, and the refusal asks to consolidate rules by restating an existing rule more briefly or revoking an obsolete one.
Writes that do not grow the block remain possible even when it is already over budget.
The [`fm-rules.sh` header](../bin/fm-rules.sh) owns the budget and its exit code.

## Delivery to running consumers

A change to the worker-facing rule set triggers delivery to running consumers before the save returns; no restart or manual push is needed when delivery succeeds.

- Secondmate homes get the new `config/captain-rules.md` through the guarded config push, with that home's reread instruction.
- Each secondmate home, local or remote, then hands its own copy to its own running ship and scout workers; main reaches a remote home through its configured route, and finds a home from the live record or, for older records, from the secondmate registry.
- Every running ship or scout worker gets the complete new set as one steering-inbox record instructing it to replace its brief's rules section.

Successful delivery does not confirm that the receiving agent has read or applied the update.

Additions, changed texts, revocations, and linked checks are delivered alike, in write order; an unchanged repeat sends nothing.
When a consumer cannot be reached, the change stays saved, the command names that consumer and exits 5, and `bin/fm-rules.sh deliver` retries.
A secondmate whose home cannot be found, whose route fails, or whose copy is still the older set counts as not reached.
Until delivery is retried successfully, that home's workers can retain or receive older rules.
The [`fm-rules.sh` header](../bin/fm-rules.sh) owns generation-check ordering, record wording, and exit codes; resolve any config-push failure before retrying.
Secondmate charters carry no rules section because the secondmate session loads them itself.
Task worktrees, no-mistakes gates, and the supervision branch get no session block.

## Precedence

The rendered block states that captain rules outrank generic harness, tool, and skill hints that conflict with them.
The motivating case is a harness system prompt that suggests handing the captain a `! <command>` line, which fails for sudo and interactive logins.
Inside a worker brief, the brief's task scope and safety rules still win over a captain rule.

## From correction to rule

1. The Claude UserPromptSubmit hook `bin/fm-rules.sh prompt-hook` reads each captain prompt in the primary home's main session and matches correction and standing-rule phrasing such as "ab jetzt", "nie wieder", "hab ich dir schon gesagt", "from now on", or "do it yourself".
   Recognized wakes and notifications are skipped, and `<pasted_content>` blocks are excluded from matching.
2. A match writes a candidate under `state/captain-rules/candidates/` and tells main to decide.
3. Main either records the rule with `bin/fm-rules.sh confirm <candidate> <rule-id> "<rule>"` and confirms it in one chat line ending with `"nein" nimmt sie zurueck`, or drops the candidate with `dismiss` and says nothing.
   A confirm that exits 5 saved the rule but could not reach every consumer; main says so in that line and retries with `deliver`.
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
The [guard header](../bin/fm-rule-guard.sh) owns quoted-rule exemptions, the negation window, clause boundaries, and exceptions, with regressions in [`tests/fm-rule-guard.test.sh`](../tests/fm-rule-guard.test.sh).
A violating reply never ends the turn as a success.
The guard keeps blocking each forced continuation that still hands over the line, up to a small cap per session.
Past the cap it halts the turn instead, and the captain sees a stop reason saying not to run the `!` line and to use a real Terminal window.
The guard header owns the cap and its state.
A missing or non-string reply payload is allowed without a check.
Only Claude primary replies are checked here; other harnesses and workers receive rules as context only.

## Weekly report

`bin/fm-rules.sh report` prints the last seven days: rules added and repeated, guard blocks and halts, rules repeated without a check, candidate counts, and correction-like captain prompts found in the Claude transcripts of this home.
`bin/fm-rules.sh weekly-arm` binds a watcher check that reminds main to run the report and send a short version to the captain; it does not generate or send the report automatically.
The reminder appears once when no report exists or the last report is at least a week old, and stays quiet until another report runs; `weekly-disarm` removes the check.
Running the report restarts the reminder timer; the report itself remains a rolling lookback.

## Verification

[`tests/fm-rules.test.sh`](../tests/fm-rules.test.sh) and [`tests/fm-rule-guard.test.sh`](../tests/fm-rule-guard.test.sh) cover the store, capture instructions, brief projection, delivery to running consumers, report, and guard behavior offline.
[`tests/fm-session-start.test.sh`](../tests/fm-session-start.test.sh) covers non-Claude rule delivery in full and compact digests.
The opt-in [`tests/fm-rules-live-e2e.test.sh`](../tests/fm-rules-live-e2e.test.sh) exercises the three Claude registrations against the real harness: SessionStart context, action on an injected candidate, and Stop-guard interception followed by either a clean rewrite or a captain-facing halt, plus a forced halt that proves Claude Code honors it.
Its header owns invocation and model selection; offline coverage alone does not establish live context delivery or interception.

## Migration after this change

These steps touch captain-private stores and dotfiles, so they are done by hand from the primary home, not by this repository:

1. Run `bin/fm-rules.sh weekly-arm` once.
2. Record the corrections that already exist as rules with `bin/fm-rules.sh add`, starting with the `! <command>` rule and linking it with `--check bang-interactive`.
3. Remove the rule-shaped duplicates from the older stores once they are rules: Claude auto-memory `MEMORY.md`, `data/learnings.md`, `data/captain.md`, and the memory store.
4. Delete or correct any memory-store entry that contradicts a rule, for example an auto-captured merge preference that disagrees with the captain's current merge rule.
5. Teach the dotfiles recall hook to skip `FIRSTMATE SUPERVISION WAKE` and `<task-notification` prompts, which today inject keyword matches into wakes.
