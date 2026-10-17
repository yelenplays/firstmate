# Secondmate lifecycle reference

## Record intake for an existing or inherited domain

Classify the domain before seeding, because this step applies to only one of the two cases.
A greenfield domain has no delivered domain work yet: nothing already shipped in its projects, no live deployment, and no predecessor records to import.
Seed a greenfield domain normally; there is nothing to reconcile and this section adds no work to it.
An existing or inherited domain is any domain whose product is already in development, and any predecessor's domain a new mate takes over, including a consolidation after a retirement.
Both of those cases require record intake before the new mate acts on any inherited plan.

For an existing or inherited domain, the creating agent must:

1. Reconcile every inherited plan against the domain's authoritative shipped state, which is `origin/main` for each relevant project plus the live deployment.
   A fetched clone of each relevant project is a precondition of that reconciliation, so wire the home to its projects before reconciling rather than on first task.
   The imported backlog, the predecessor's own notes, instruction-surface prose, and an absent or unfetched local view are all inadmissible as shipped-state evidence.
2. Seed the new home with only genuinely open work plus the domain's durable knowledge, meaning the learnings, decisions, and delivery posture that are still live.
3. Never inherit a plan backlog blind.
   A plan row whose work is already shipped is dropped, or recorded as done with the merged evidence that settles it, and is never carried forward as open.

A live backlog keeps only the configured recent Done entries by design, so an inherited queue structurally over-represents plans and under-represents deliveries.
Treat an inherited queue that carries plans with no matching delivery record as unreconciled rather than as open work, and record whatever could not be reconciled as an explicit residual-uncertainty list in the new home rather than leaving that gap silent.

## Backlog handoff

Apply `AGENTS.md` section 10's work-items-only backlog contract before creation or handoff.
When a secondmate is created for a domain, existing main-backlog items that fall under its scope should become its work instead of staying stranded in the main backlog.
Scope-matching is firstmate's judgment against the secondmate's natural-language scope, not a keyword rule.
Read `data/backlog.md`, pick queued items that fit the new scope, and move them with:

```sh
bin/fm-backlog-handoff.sh <secondmate-id> <item-key>...
```

After seeding, run this handoff for the new secondmate's in-scope queued items.
For an existing or inherited domain, complete record intake first so no already-shipped plan row is handed off as open work.
For a local route, the helper resolves and validates the secondmate home from `data/secondmates.md`, then delegates the item move to `tasks-axi mv` (the single owner of the backlog format), which moves each named item - and a whole connected set, blocker plus dependents, atomically - from the main `data/backlog.md` into the secondmate home's `data/backlog.md`.
For a remote route, the same helper first moves the dependency-closed set atomically from the main backlog into `data/handoff/<id>.outbox.md`, then transfers that backlog-format outbox through `fm-on.sh` and lets the remote home's `fm-backlog-receive.sh` move every not-already-present key under the destination lock.
After a new local placement or a remote outbox receipt becomes durable, the helper attempts one marked routed-work instruction through the receiving secondmate's recorded endpoint.
[`bin/fm-backlog-handoff.sh`](../../../../bin/fm-backlog-handoff.sh) owns route-specific wake outcomes, remote outbox release after durable receipt, and stable wake-correlation retry behavior.
There is no two-phase handoff journal and no tasks-axi release beyond the already-required atomic `mv` capability.
Bootstrap retries pending outboxes and wakes when mutation is authorized and emits `SECONDMATE_HANDOFF:` for any outboxes that remain.
This delegated route remains required when `config/backlog-backend=manual`, which controls only routine firstmate backlog edits.
It moves each queued item's whole block - the `- [ ] <id> ...` header plus every following two-or-more-space-indented body line and blank separator, up to the next item or column-0 section heading - byte-exact under the same section, treating an indented `## ...` line as body rather than a section boundary, so neither the header nor its body is duplicated or orphaned.
It refuses a selected item with a single-space or tab-indented continuation rather than risk leaving content orphaned in the main backlog.
It accepts in-scope `## Queued` entries only and refuses `## In flight` and historical `## Done` entries.
Done records stay with their home for pruning or archiving.
It is idempotent; an item already in the secondmate backlog is skipped.
After a successful move it warns for any moved key that still owes a public relay reply bound to `main/<key>`, because that binding no longer names the home owning the work; rebind the commitment to `secondmate:<id>` through the `fmx-respond` promised-final procedure, which owns those commands.
That same rule governs routing generally: a Relay-linked request whose work goes to a secondmate cannot use the home-local mention link at all and needs a promised-final commitment bound to that secondmate's home.
It refuses any destination that is not a genuine seeded firstmate home with safe operational directories and a matching `.fm-secondmate-home` marker, so a move can never land in a project.
Do not hand off `local-only` items.

## Recovery

For local `kind=secondmate` meta with no window, treat the secondmate as a dead persistent direct report and respawn it with:

```sh
bin/fm-spawn.sh <id> --secondmate
```

Use the recorded `home=` in meta.
If meta is missing but `data/secondmates.md` still registers the secondmate, respawn from the registry entry and its persistent home.
For a remote route, the same command probes and relaunches only on the configured host.
An SSH transport failure or unreadable remote endpoint remains unknown and must be reconciled on that host; never launch a local replacement.
`stuck-crewmate-recovery`'s remote-secondmate note owns why the endpoint-dead and send-failed verdicts that seem to justify this are themselves unreliable.
Respawn re-resolves the secondmate harness from current config, uses the same guarded pre-launch sync, and re-propagates inherited local material, so recovered secondmates converge inherited config items and shared captain preferences whenever their home validates; tracked-file sync remains guarded separately.
If the secondmate is already running and only inherited local material changed, prefer `bin/fm-config-push.sh` over respawning.
To move a live LOCAL secondmate onto a newly pinned harness, model, or effort without a full recovery, set `config/secondmate-harness` and then relaunch it with `bin/fm-control.sh <id> relaunch`, which re-resolves that pin, stops the agent, and launches the replacement in the same home ([`docs/agent-control.md`](../../../../docs/agent-control.md)).
That plane refuses a remotely placed secondmate by name, because its agent runs on another host where none of the plane's postconditions can be read.
Move a REMOTE one with `bin/fm-remote-secondmate-relaunch.sh <id> <harness> <model|default|-> <effort|default|->`, which runs that same control-plane relaunch on its host and then republishes this primary's own route metadata from the identity the host confirmed; pass the profile explicitly and use `default` for an absent pin, because `config/secondmate-harness` is not inherited and the copy on that host belongs to a different home ([`docs/remote-secondmates.md`](../../../../docs/remote-secondmates.md)).
Never call `fm-remote-secondmate-control.sh relaunch` through `fm-on.sh` directly for this: it leaves this primary's own record naming the runtime the mate used to run.
A successful update restarts every live mate of both placements on its own, including one already on the target commit; the `/updatefirstmate` skill owns that pass, and `bin/fm-secondmate-restart.sh` owns its persist gate and failure vocabulary.

Do not reconstruct a secondmate's whole tree from the main home.
The main firstmate reconciles only direct reports.
Each secondmate is a firstmate in its own home, so it runs recovery on startup and reconciles its own crewmates.
A secondmate's recovery reconciles only work that is already its own and then idles.
It never initiates a survey or audit during recovery.

## Retirement and teardown

A secondmate is persistent by default.
An empty queue is healthy and does not trigger teardown.
Run `bin/fm-teardown.sh <id>` for `kind=secondmate` only when the captain or main firstmate explicitly decides to retire that persistent second mate.

The safety check is the secondmate's own home.
Teardown refuses while its `state/*.meta` contains in-flight work.
Non-forced retirement also refuses while any parent pending-reply for that id is still unresolved.
A remote route delegates the in-flight guard to its configured host and additionally refuses while the primary has a pending handoff outbox.
SSH exit 255 preserves the route and local records because remote completion is unknown.
When retirement proceeds, teardown kills the direct endpoint, removes every parent pending-reply record for that id including resolved leftovers and its delivery confirmation, removes the `data/secondmates.md` route, clears the main home metadata, and removes the retired secondmate home.
An endpoint close that could not be made stops the retirement before any record naming that endpoint is removed, so a cleanup never reports success for an agent that may still be live with nothing left on disk naming it.
`--force` overrides that stop only for the retiring secondmate's own endpoint, never for a child endpoint inside forced cleanup, and a forced continue still names the endpoint you must then reconcile yourself; [`docs/verification/runtime-backends.md`](../../../../docs/verification/runtime-backends.md) "Endpoint close" owns what each backend can prove about its own close.
Removing a leased home releases its durable treehouse lease via `treehouse return`, so the pool slot is freed for reuse rather than left leased forever.
A plain-clone home with no pool slot is simply removed.
If `treehouse return` fails for a leased home, teardown stops with state intact rather than raw-removing the directory and hiding a held lease.
Before either return or direct removal, teardown asks the target home's process-event runner to retire its registrations and physically owned machine-wide claims through the safe generation-bound path.
It refuses retirement while that cleanup is uncertain or unavailable, preserving the home and retirement records for a later retry.
Raw deletion is unsupported because a blocking process-event child can outlive its home.

With `--force`, teardown is the explicit discard path.
The worktree-slot ownership contract in `bin/fm-teardown.sh` still applies: `--force` never authorizes returning a descendant pool slot that another task may own.
It kills child windows, discards child work and state inside the secondmate home, removes the route, releases the lease, and removes the retired secondmate home.
If forced teardown contends with a fresh task publication in any affected home, one command refuses without publishing or removing task state; treat that refusal as terminal and inspect the other operation before retrying.
`fm-spawn.sh --relaunch` and non-forced teardown remain outside that task-set serialization; [`fm-secondmate-liveness-lib.sh`'s header](../../../../bin/fm-secondmate-liveness-lib.sh) owns automatic recovery serialization.
Never use `--force` unless the captain explicitly said to discard the work.
