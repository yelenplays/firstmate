# Matt Pocock skills bridge verification

Audience: maintainer verification.

Reusable version-scoped evidence for the guarantees behind `bin/fm-skill-path.sh`, the `grill-intake` adapter, and the generated-brief safety rules.
Firstmate copies no upstream skill content, so this record pins what was validated rather than what is vendored.
The adapter deliberately does not enforce these values at runtime: it resolves whatever is installed and reports the version and source pin, so an upstream bump arrives on its own instead of breaking on a hardcoded version.

## Plugin identity

Verified on 2026-07-30 against the user-scope install of `mattpocock-skills`.

```sh
jq -r '.plugins["mattpocock-skills@claude-plugins-official"][0]' ~/.claude/plugins/installed_plugins.json
jq -r '.enabledPlugins["mattpocock-skills@claude-plugins-official"]' ~/.claude/settings.json
```

Observed:

```text
scope           user
version         1.2.0
installPath     ~/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.2.0
gitCommitSha    2ab958093e83e0ec752e6c1c5932da465bf23e0c
enabled         true
```

The plugin manifest advertises `1.2.0` while `package.json` still advertises `1.1.0`, so the source commit and file bytes are the identity and the package version alone must never be treated as the pin.
The manifest promotes 22 skills; the source tree carries further non-promoted skills that the plugin does not expose, which is why resolution reads the manifest's own `skills` list.

Byte verification of the skills tree used git rather than a rolled-up hash, because the cache is a real checkout and git compares every tracked file against the pinned commit directly:

```sh
git -C <installPath> rev-parse HEAD
git -C <installPath> status --porcelain -- skills
shasum -a 256 <installPath>/.claude-plugin/plugin.json <installPath>/package.json
find <installPath>/skills -type l
```

Observed:

```text
2ab958093e83e0ec752e6c1c5932da465bf23e0c
(no output: skills/ is unmodified at the pinned commit)
e712cc026f5e78058067d17cd1fdf9665388d70db59dc50688286cb029e38eba  .claude-plugin/plugin.json
bce70fe1a4fe94109c78b4a51824bacd33898287a6e14df40376dc6ea2d8edc8  package.json
(no output: no symlinks under skills/)
```

A whole-tree roll-up is reproducible only with its exact command, so record the command beside any future digest:

```sh
cd <installPath> && find skills -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256
# 76c808f7c44cfa232d6501f50e7f79bdc1307106703d71e6033811ad2761a3fe
```

## Invocation mode

Three channels exist and they are not interchangeable.
A skill marked user-invoked-only is excluded from the model's own reach, so it loads only when its slash command is typed into a composer; model-invocable skills need no send.

The load-bearing case is the typed slash command reaching a supervised worker through `bin/fm-send.sh`, because that is the only channel by which firstmate can put a skill body into a worker it supervises.
Verified on 2026-07-30 by sending `/mattpocock-skills:tdd` with a bounded load-probe argument into a live `claude` crewmate's composer.

Observed in the worker: the harness announced the skill's base directory and rendered the original body.

```text
Base directory for this skill:
  ~/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.2.0/skills/engineering/tdd
Section headings loaded:
  What a good test is / Seams - where tests go / Anti-patterns / Rules of the loop
```

Those headings are the pinned 1.2.0 headings, and the announced directory is the pinned install path, so the bytes came from the plugin.
The send submitted on the first attempt with no swallowed Enter.

The same probe also settled a name-collision question.
At the time of the probe an older user-level copy of the same skill was present at `~/.agents/skills/tdd`; those Matt-derived copies were removed later the same day, so re-running these two commands now finds no stale copy.
The comparison is recorded because the collision is the durable hazard, not the particular copy:

```sh
grep -c '^## ' ~/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.2.0/skills/engineering/tdd/SKILL.md
grep '^## ' ~/.agents/skills/tdd/SKILL.md
shasum -a 256 ~/.agents/skills/tdd/SKILL.md
```

Observed:

```text
pinned 1.2.0 headings   What a good test is, Seams - where tests go, Anti-patterns, Rules of the loop
stale copy headings     Philosophy, Anti-Pattern: Horizontal Slices, Workflow, Checklist Per Cycle
stale copy sha256       af059705061156fd4845ddbb736fe92b564118ac5f03551e09ef9e8f6d970638
```

The worker loaded the pinned headings, so on `claude` the plugin copy won and the stale copy did not participate.
That holds for `claude` only: the other harnesses read `~/.agents/skills`, so whatever sits there is what they would load, which is why skill-dependent work is routed by discovery source rather than by name.
The guarantee does not depend on that directory being empty today - `bin/fm-skill-path.sh` resolves only through the plugin registry, and `tests/fm-skill-path.test.sh` proves it refuses even when a same-named copy is present.

## Resolver output

`bin/fm-skill-path.sh` resolved the same directory the harness reported for the probe, which is the cross-check that its answer matches what a worker actually loads.

```sh
bin/fm-skill-path.sh mattpocock-skills tdd
bin/fm-skill-path.sh mattpocock-skills domain-modeling --list-files
bin/fm-skill-path.sh mattpocock-skills caveman
```

Observed:

```text
plugin=mattpocock-skills
marketplace=claude-plugins-official
scope=user
version=1.2.0
commit=2ab958093e83e0ec752e6c1c5932da465bf23e0c
skill=tdd
skill_dir=<installPath>/skills/engineering/tdd
skill_file=<installPath>/skills/engineering/tdd/SKILL.md

ADR-FORMAT.md
CONTEXT-FORMAT.md
SKILL.md
agents/openai.yaml

fm-skill-path.sh: skill 'caveman' is not declared by mattpocock-skills 1.2.0   (exit 5, no stdout)
```

The support-tree listing matters because upstream skills reach their own format references by relative link from the skill directory, so the directory is what makes those links resolve.
`caveman` exists in the upstream source tree but is not promoted by the plugin, so it is correctly unresolvable.

## Boundary tests

`tests/fm-skill-path.test.sh` builds a synthetic Claude configuration for every case, so the guarantees hold in CI with no plugin installed and no dependence on this machine.
Each case asserts exit status, stdout, and stderr of a real run; a refusal must print no path at all, which is what lets an adapter treat any stdout as resolved.

Covered: a clean resolve with full identity; support-file resolution through the returned directory; the default `$HOME/.claude` root with `CLAUDE_CONFIG_DIR` unset; a configuration root containing spaces; a missing registry, unregistered plugin, and vanished install directory; an explicitly disabled plugin, an absent enablement decision, and a local settings file overriding the shared one; a skill absent from the manifest though present on disk; ambiguity across marketplaces and across install scopes, each resolvable by naming one explicitly; a manifest naming another plugin; a manifest version disagreeing with the registry; a missing manifest; a missing `SKILL.md`; front matter naming a different skill; a traversing manifest path; a symlinked skill directory and a symlink inside the support tree; expected-version and expected-commit pin mismatches; and the usage errors.

One case is a direct regression guard on the drift hazard: with a stale copy present under `~/.agents/skills` and the plugin unregistered, the resolver still refuses and prints nothing, proving resolution never falls back to a same-named local copy.

`tests/fm-brief.test.sh` covers the generated-brief safety rules behaviorally, asserting that each rule appears in the task shapes whose hazard it addresses and is absent from the ones it does not apply to.

## Re-audit triggers

Re-run this record when any of these changes:

- the plugin version or `gitCommitSha` moves, since both the invocation posture of a skill and the names of its support files have changed across upstream revisions;
- a skill moves between model-invocable and user-invoked-only, which changes which channel can load it;
- the plugin gains hooks, MCP servers, agents, or LSP servers, none of which it ships today;
- a harness other than `claude` gains Claude-plugin discovery, or `opencode` is probed and its state becomes known.
