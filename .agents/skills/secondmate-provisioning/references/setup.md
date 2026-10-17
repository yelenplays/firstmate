# Secondmate setup reference

## Routing table

`data/secondmates.md` has one parser-compatible line per persistent second mate.
A local route uses:

```markdown
- <id> - <one-sentence charter summary> (home: <absolute-home-path>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)
```

A whole-home remote route uses:

```markdown
- <id> - <one-sentence charter summary> (host: <ssh-alias>; root: <absolute-remote-code-root>; home: <absolute-remote-home>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)
```

Each registry entry stays concise and single-line: the summary is one sentence naming the durable charter, `scope:` is the natural-language intake responsibility, `projects:` is the non-exclusive clone list, and any extra prose is limited to genuinely domain-specific hard rules that change routing or safety for that secondmate.
Natural-language summary and `scope:` text may contain parentheses and semicolons; keep the generated `(home: ...; scope: ...; projects: ...; added ...)` suffix intact so operational consumers resolve its explicit field markers.
The `home:` path points to the seeded home containing `data/charter.md`; no extra registry pointer field is needed.
For a remote route, `host:` is an OpenSSH config alias and `root:` is that host's separate tracked Firstmate code root.
A remote second-mate agent always runs on the Herdr backend and every seed, launch, and liveness relaunch first gates its host on `bin/fm-remote-doctor.sh` readiness, so an unready host refuses with that doctor's own gap text rather than half-creating a route; the workers that second mate supervises keep the home's ordinary backend selection.
This release places whole secondmate homes remotely and never individual workers.
[`docs/remote-secondmates.md`](../../../../docs/remote-secondmates.md) owns current operator setup and transport behavior.
The home-seeded `data/charter.md` is the sole owner of boilerplate idle-by-default behavior, the normal delegation lifecycle, and standard escalation contracts, so point to that charter rather than restating those contracts in the registry entry.
The `scope:` field is used during intake.
The `projects:` field is a non-exclusive clone list, not ownership.

## Charter and seed

Scaffold a secondmate charter with:

```sh
bin/fm-brief.sh <id> --secondmate {<project>...|--no-projects}
```

The scaffold writes a charter brief instead of a task brief.
Set `FM_SECONDMATE_CHARTER='<charter>'` to fill the charter text and `FM_SECONDMATE_SCOPE='<scope>'` when the routing scope differs.
If you scaffold without `FM_SECONDMATE_CHARTER`, replace the `{TASK}` placeholder before seeding.
Pass `--no-projects` instead of a project list to scaffold a project-less charter for a domain whose subject is the firstmate repo itself, whose home is a firstmate worktree and whose crews take pooled worktrees of the same repo.
`--no-projects` is mutually exclusive with a project list, and omitting both still fails loudly, so an accidental omission is never mistaken for a deliberate project-less seed.
Re-seeding a populated home as project-less is refused non-destructively when the home contains project clones or `data/projects.md` entries.
Retire or clean that home first, and re-scaffold a stale project-bearing charter with `--no-projects` before seeding.
Keep custom charter text focused on the persistent responsibility, available project clones, and genuinely domain-specific hard rules.
The scaffolded charter, later copied to `data/charter.md`, owns the standard lifecycle and escalation wording.
Preserve the generated charter sections unless the domain genuinely needs a hard rule.

Provision a local persistent home and registry entry after the charter is filled:

```sh
bin/fm-home-seed.sh <id> <home|-> {<project>...|--no-projects}
```

Provision a whole remote home through its configured SSH host with:

```sh
bin/fm-remote-home-seed.sh <id> <ssh-alias> <remote-root> <remote-home> {<project>[=<origin-url>]...|--no-projects}
```

You resolve each project's origin yourself - from the captain, the project registry, a clone that exists elsewhere, `gh-axi`, or an explicit paste - and name it as `<project>=<origin-url>`; the seed validates and transports what you supply.
A remote seed therefore creates nothing in this home beyond the route, the charter brief, and a launch record once it is launched: never clone a project into `projects/`, initialize no-mistakes here, or run a fleet sync just to seed a remote secondmate.
A bare `<project>` remains a convenience for a project this home already has cloned, whose configured origin is read instead.
[`docs/remote-secondmates.md`](../../../../docs/remote-secondmates.md#provision-a-route) owns the rest of the operator contract, and [`bin/fm-project-origin-lib.sh`](../../../../bin/fm-project-origin-lib.sh) owns the accepted origin forms.
Pass `--no-projects` in the project position to seed the project-less home described above; the same mutual-exclusion and fail-loud-on-omission rules apply.
It may only seed a home with no project clones or project-registry entries, and refuses conversion of populated homes without changing them.
`-` durably leases a fresh firstmate worktree via `treehouse get --lease` under the secondmate id.
The lease survives with no live process and is never recycled by later `treehouse get` or `prune`.
The slot stays reserved across restarts until the lease is released.
Release happens only on explicit retirement or seed rollback, never on routine restart or recovery.

`bin/fm-home-seed.sh` copies the charter into the secondmate home as `data/charter.md`.
It also writes the gitignored `.fm-secondmate-parent` durable binding before the required `.fm-secondmate-home` identity marker; the parser header in [`bin/fm-secondmate-parent-lib.sh`](../../../../bin/fm-secondmate-parent-lib.sh) owns the record contract, and both files must remain in place.
`bin/fm-spawn.sh --secondmate` launches it through the secondmate harness path, resolving `config/secondmate-harness` -> `config/crew-harness` -> the primary's own harness unless an explicit per-spawn harness override is passed.

`config/secondmate-harness` may also pin a concrete model and effort for the secondmate agent, in the SAME file rather than a new one: the format is a single whitespace-separated line `<harness> [<model>] [<effort>]`, with only the first non-empty, non-comment line parsed.
A bare `<harness>` (today's format, e.g. `claude`) behaves exactly as before - harness only, no model/effort flag - so this is fully backward-compatible.
`bin/fm-harness.sh secondmate-model` and `bin/fm-harness.sh secondmate-effort` print the optional 2nd/3rd tokens (empty when absent, or when the file is absent/`default`/harness-only); they read only `config/secondmate-harness`, never `config/crew-harness`, which stays a bare adapter name.
For a `--secondmate` spawn, `bin/fm-spawn.sh` populates `MODEL`/`EFFORT` from those tokens only when the harness itself came from the secondmate config path for that spawn.
For a local route, an explicit per-spawn `--harness` flag, positional harness arg, or raw launch command starts clean on model and effort too, unless the caller also passes explicit `--model` or `--effort`.
A remote route accepts only a verified harness adapter and refuses a raw launch command at the host boundary.
Follow the [per-launch override contract](../../../../docs/configuration.md#per-launch-overrides-and-inherited-defaults) for model and effort precedence and launch-time limits.
Because this resolves from the file on every spawn, the pin is durable across every respawn (recovery, `/updatefirstmate`, restart) exactly like the harness axis itself - e.g. `config/secondmate-harness` containing `claude opus` keeps a secondmate pinned to Opus even if the primary's own default model later changes.
This is secondmate-only: crewmate/scout model resolution is untouched by this file.
The pinned model runs the secondmate's routine supervision; the scaffolded charter (`bin/fm-brief.sh --secondmate`) keeps captain-decision and design judgment off that seat, so a home seeded before that rule needs it added to its `data/charter.md` before its pin moves to a lighter model.
To give one secondmate its own profile, write `config/secondmate-harness.d/<id>` in the same format; it replaces the shared file for that id only, below explicit per-spawn flags, on every spawn, relaunch, liveness recovery, and `/updatefirstmate` restart, and is primary-only like the shared file ([`docs/configuration.md`](../../../../docs/configuration.md) owns its precedence and parsing).

`bin/fm-home-seed.sh` refuses to copy a missing or placeholder charter.

Direct seed without a preexisting brief requires `FM_SECONDMATE_CHARTER`.
Run `bin/fm-home-seed.sh validate` when checking registry integrity; its header owns the complete validation and refusal mechanics.

Seeding is transactional.
If validation, cloning, no-mistakes initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.

Secondmate project lists may include `no-mistakes` and `direct-PR` projects only.
`local-only` projects stay with the main firstmate.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.
