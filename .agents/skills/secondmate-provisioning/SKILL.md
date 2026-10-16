---
name: secondmate-provisioning
description: >-
  Load before creating, seeding, validating, launching, recovering, handing backlog to, pushing inherited material into, or retiring a persistent secondmate, or editing data/secondmates.md.
user-invocable: false
metadata:
  internal: true
---

# secondmate-provisioning

Route by natural-language scope, not non-exclusive project clone lists; local-only work stays with main.
Secondmates reconcile their own existing work then idle, never survey/audit; main reconciles direct reports only, never their child tree.

## Create

Read [setup](references/setup.md) before scaffold/seed/registry/pins.
Keep registry single-line, suffix intact; charter owns lifecycle/escalations.
Fill placeholders, preserve sections except domain rules; direct seed requires charter text.
Require projects XOR `--no-projects`, never omission; refuse populated-home conversion unchanged, re-scaffold stale charters.
Seed transactionally, rolling back new material/registry on validation/clone/init/registry failure.
Only no-mistakes/direct-PR projects; initialize new clones only, refuse uninitialized preexisting clones.
Preserve parent/identity markers; leases survive idle/restarts, release only on retirement/seed rollback.
Validate registry with `fm-home-seed.sh validate`.

Remote placement is whole-home only, Herdr for the agent, ordinary backend for workers.
Doctor-gate seed/launch/liveness relaunch; unready hosts stop.
Resolve origins explicitly; remote seed creates only route/charter/launch records here, never local clones, initialization or fleet sync.
Remote requires verified adapters, never raw commands; SSH/unreadable completion is unknown, preserve routes, never local failover.
Pins are secondmate-only: explicit axis flags win, local harness/raw overrides clear implicit model/effort, per-id replaces shared.
Before lighter pins, charters must keep captain/design judgment off-seat; only captain changes account pins, never edit/remove to bypass refusal.

Before acting/handoff in existing/inherited domains, fetch projects and reconcile every plan against origin/main plus live deployment, never backlog/notes/instruction prose/absent views.
Seed only open work and live knowledge/posture; drop shipped plans or close with merged evidence, list uncertainty, never inherit blind.
Greenfield needs no intake.

## Sync and inheritance

Read [inheritance](references/inheritance.md) before launch/recovery/bootstrap/config push.
Tracked sync only fast-forwards or reconciles clean redundant divergence; dirty, unique divergence or in-flight homes remain unchanged with warnings and durable divergence evidence.
Local bootstrap never fetches/touches operational data/projects/backlog; remote sync targets the supplied primary commit without moving/retargeting host root, reports unavailable commits.
Only `/updatefirstmate` refreshes remote root from origin.
Propagate only declared items independently of tracked sync; source inspection error preserves destination, only proven absence removes, and failures retain safely validated results.
Local failure warns, never blocks launch/startup; remote prelaunch failure refuses.
Inherited runtime/harness defaults affect future spawns, never live endpoints or explicit choices; environment grants remain separate.
Shared preferences are main-authoritative/read-only: require primary header, route discoveries to main, never copy back.
Converge bytes/absence; quarantine drift/interrupted publication collision-safely first, reject unsafe directories, symlinks/nonordinary artifacts and hardlinked destinations, restore read-only mode even on recoverable failure.
Captain files stay domain-local; trim by deliberate human edit, never automated/silent deletion; learnings remain fully local, fleet machinery knowledge follows tracked delivery.
Secondmate/account pins and engine setting are not inherited; each home's worker pins need its own files.

Running-home instruction advances need AGENTS reread; changed config needs literal reread.
Reread exact changed bytes/ABSENT in declaration order, never hashes/summaries/profiles/shared preferences; unchanged homes get no message unless retry pending.
Serialize propagation/publication/delivery per home; retain exact generations/retries on failure without claiming reread, bound delivered history/quarantine, and supersede pending generations on launch.
Remote rereads use their own delivery path, never primary-local pointers; live inherited changes use `fm-config-push.sh`, not respawn/tracked sync.

## Handoff, recovery, retirement

Read [lifecycle](references/lifecycle.md) first.
Handoff only scoped Queued work after intake, never local-only/In flight/Done; move dependency-closed whole blocks atomically byte-exact, refuse ambiguous indentation and unsafe/nonseeded homes.
Use helper even in manual mode; durable placement/remote receipt precedes correlated wake, retain outboxes until receipt, retry idempotently.
Rebind moved public-reply commitments to the receiving home, never leave main-home links for routed work.
Recover from recorded home/registry only; local pin changes use control-plane relaunch, remote the explicit-profile helper, never a host leg leaving stale parent identity.
Update restart requires persist, even on current commits.

Retire only on explicit captain/main decision, never idle.
Non-force refuses in-flight children/unresolved parent replies; remote also refuses handoff outboxes, transport uncertainty preserves records.
Prove endpoint close before deleting its records; force may bypass only the retiring endpoint's stop, never a child's, naming remaining reconciliation.
Require safe generation-bound process-event registration/claim cleanup before removal/return; uncertainty stops, never raw-delete.
Lease return failure preserves home/records; never raw-remove leased homes or return another task's descendant slot.
Force discards child work only with explicit captain discard authority; publication contention is terminal, inspect the other operation before retrying.
