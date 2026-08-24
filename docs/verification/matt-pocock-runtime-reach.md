# Verification: which runtimes reach the Matt Pocock skills

Audience: maintainer verification.

Records how each supported harness reaches Matt Pocock's skill suite, and the evidence behind the pointer bridge that lets a runtime without Claude plugin discovery load the installed original rather than any copy.
Firstmate copies no upstream skill content, so this record pins what was validated rather than what is vendored.

Verified 2026-08-24 on macOS 25.5.0 with `claude` 2.1.228, `grok` 1.0.5, `kimi` 0.36.1, `codex` 0.145.0, and `pi` 0.84.2.

## Plugin identity

The suite is installed once, as the Claude plugin `mattpocock-skills@claude-plugins-official`.

```sh
jq -r '.plugins["mattpocock-skills@claude-plugins-official"][0]' ~/.claude/plugins/installed_plugins.json
jq -r '.enabledPlugins["mattpocock-skills@claude-plugins-official"]' ~/.claude/settings.json
```

Observed:

```text
scope           user
version         1.2.3
installPath     ~/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.2.3
gitCommitSha    2ab958093e83e0ec752e6c1c5932da465bf23e0c
enabled         true
```

The manifest's own `skills` list is the authority on what this install exposes, not the source tree.

```sh
jq -r '.skills | length' <installPath>/.claude-plugin/plugin.json   # 25
find <installPath>/skills -name SKILL.md | wc -l                    # 35
```

Ten skills ship in the checkout without being promoted by the manifest, which is why `bin/fm-skill-path.sh` resolves against the declared list and refuses anything outside it with exit 5.
Resolution reads only the plugin registry, so a stale copy under `~/.agents/skills` can never satisfy a request.

## The loader prints the installed original, proven by digest

A pointer's body carries no procedure.
Its first instruction runs `bin/fm-matt-skill.sh <skill>`, which prints the installed original behind an identity header.
The header's `skill_file_sha256` is the discriminator: no source other than the resolved file can produce it.

```sh
bin/fm-matt-skill.sh code-review --check
shasum -a 256 "$(bin/fm-matt-skill.sh code-review --path)"
```

Observed:

```text
resolved_version=1.2.3
resolved_commit=2ab958093e83e0ec752e6c1c5932da465bf23e0c
skill_file=~/.claude/plugins/cache/.../mattpocock-skills/1.2.3/skills/engineering/code-review/SKILL.md
skill_file_sha256=9cf46653dd9c710ea1e6c22423caf31a794c88773bc94bdaa23140277f470442
resolved_by=bin/fm-skill-path.sh

9cf46653dd9c710ea1e6c22423caf31a794c88773bc94bdaa23140277f470442
```

`resolved_by` is always `bin/fm-skill-path.sh`.
That script is the repo's single owner of plugin-skill resolution, and the loader carries no resolver of its own: without that owner beside it the loader exits 127 with nothing on stdout rather than guessing a path.

## Version drift is reported, not fatal

The install is version 1.2.3 against a validated pin of 1.2.0, at the same source commit.
The loader still prints the installed original and reports the difference, because refusing on every upstream bump would turn each release into a fleet outage:

```text
pin=changed

!!! PLUGIN CHANGED !!!
The installed plugin is 1.2.3 (2ab9580...), not the 1.2.0 (2ab9580...) this pointer was validated against.
```

`--require-validated-pin` restores the strict reading and refuses with exit 6.

## The bridge names an executable the repo ships

The failure this section exists to prevent: every installed pointer named `bin/fm-matt-skill.sh` as its Step 1 while the repo shipped no such file, so each load exited 127 and every pointer's own contract stopped the worker.
The generated pointer set and the executable it invokes must ship together or the bridge is inert.

```sh
bin/fm-matt-skill.sh code-review        # exit 0, original bytes
bin/fm-matt-skill.sh diagnosing-bugs    # exit 0, original bytes
```

`tests/fm-matt-pointers.test.sh` pins this from the pointer inward: it generates a pointer set with the default loader, reads the `loader=` path back out of the generated marker, and runs that exact path as the pointer's Step 1.
The case fails with `loader is missing or not executable` when the repo does not ship it.

## An installed set whose loader vanished is detectable

`--check` audits each pointer's recorded loader rather than the one beside the running script, so an audit from a healthy checkout still reports an install whose loader has gone:

```sh
bin/fm-matt-pointers.sh --check --dest ~/.agents/skills
```

It reports `MISSING` for a declared skill with no pointer, `DRIFTED` for front matter behind the installed plugin, `RETIRED` for a marked pointer whose upstream skill is no longer declared, and `BROKEN` for a recorded loader that is no longer executable.
This mode writes nothing.

The live set is currently behind the install: 22 pointers against 25 declared skills, `drift=25`.
That is front-matter staleness only, which weakens automatic triggering and can never make a worker follow a stale procedure, since no pointer contains any procedure.
Re-running `bin/fm-matt-pointers.sh --prune` then a plain install from the stable checkout clears it.

## Where each runtime looks for skills

| Runtime | Version | Reads the Claude plugin | Bridge needed |
|---|---|---|---|
| `claude` | 2.1.228 | yes, it owns the plugin | no |
| `grok` | 1.0.5 | yes, re-verified below | no |
| `kimi` | 0.36.1 | no reference to the plugin cache at 0.31.0 | yes |
| `codex` | 0.145.0 | no reference to the plugin cache at 0.145.0 | yes, with `--dest ~/.codex/skills` |
| `pi` | 0.84.2 | not established | not established |

Grok reaches the plugin natively, re-verified at 1.0.5:

```text
$ grok inspect | grep 'mattpocock-skills ('
  └ mattpocock-skills (user, enabled)  25 skills
$ grok inspect | grep -c 'plugin: mattpocock-skills'
25
$ grok inspect | grep -c ' matt-'
22
```

Grok therefore sees both the 25 plugin skills and the 22 pointers, so for grok alone the pointers are duplication rather than reach.
`bin/fm-matt-pointers.sh --uninstall` exists for exactly that case.

The `kimi` and `codex` rows carry forward observations taken on 2026-07-30 at `kimi` 0.31.0 and `codex` 0.145.0, when `kimi`'s discovery constants read `USER_GENERIC_DIRS = [".agents/skills"]` with no plugin-cache reference and `codex` named only `$CODEX_HOME/skills` and `~/.codex/skills`.
`codex` is unchanged at 0.145.0; `kimi` has moved to 0.36.1 and its row has not been re-established since.
`pi` 0.84.2 discovers skills by default, since `--no-skills` disables discovery, but it exposes no listing command and its roots were not established in this pass.
Re-establish any unverified row before relying on it to add or remove a pointer set.

## Regression coverage

`tests/fm-skill-path.test.sh` covers the resolver: identity, support-file resolution, a custom `CLAUDE_CONFIG_DIR`, paths containing spaces, expected version and commit pins, and refusal of missing, disabled, ambiguous, tampered, symlinked, and malformed installs.

`tests/fm-matt-pointers.test.sh` builds a fake plugin under a private `CLAUDE_CONFIG_DIR` and covers the loader and the generator without touching the real install: original bytes plus attribution on success; silent-stdout refusal for a moved, absent, disabled, swapped, undeclared, symlinked, or misnamed install; loud but non-fatal version drift and outright refusal under `--require-validated-pin`; delegation to `bin/fm-skill-path.sh` including its exit statuses, and the loader's own silent-stdout 127 refusal without that owner; pointers that carry attribution and no procedure; mirrored invocation flags; the hard-stop instruction; `--check` catching edited, missing, inert, and retired pointers; unmarked directories surviving install and uninstall; a generated pointer's Step 1 running against the loader the repo ships; and `--check` naming a recorded loader that later vanished.

`test_check_reports_retired_pointers_and_their_recorded_loaders` proves that `--check` reports a retired pointer with an executable recorded loader and reports its recorded loader as `BROKEN` after it becomes non-executable.
