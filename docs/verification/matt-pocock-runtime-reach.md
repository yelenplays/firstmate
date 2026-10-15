# Verification: which runtimes reach the Matt Pocock skills

Audience: maintainer verification.

Records how each supported harness reaches Matt Pocock's skill suite, and the evidence behind the pointer bridge that lets a runtime without Claude plugin discovery load the installed original rather than any copy.
Firstmate copies no upstream skill content, so this record pins what was validated rather than what is vendored.

The runtime discovery rows were verified 2026-08-28 on macOS 25.5.0 with `claude` 2.1.228, `grok` 1.0.5, `kimi` 0.36.1, `codex` 0.145.0, and `pi` 0.84.2, except where a section names a later date.

## Plugin identity

Plugin identity, loader, pin, and pointer-audit evidence below was re-verified 2026-10-15 on macOS 26.5 with `claude` 2.1.300.

The observed configuration registers two installs of `mattpocock-skills`: Matt Pocock's own marketplace, enabled, and the older `claude-plugins-official` copy, disabled.

```sh
jq -r '.plugins | to_entries[] | select(.key | startswith("mattpocock-skills@")) | "\(.key) \(.value[0].scope) \(.value[0].version) \(.value[0].gitCommitSha)"' ~/.claude/plugins/installed_plugins.json
jq -r '.enabledPlugins | to_entries[] | select(.key | startswith("mattpocock-skills@")) | "\(.key) \(.value)"' ~/.claude/settings.json
```

Observed:

```text
mattpocock-skills@claude-plugins-official user 1.2.3 2ab958093e83e0ec752e6c1c5932da465bf23e0c
mattpocock-skills@mattpocock user 1.3.1 49dd158d1076134a641b33efb035946536778336
mattpocock-skills@claude-plugins-official false
mattpocock-skills@mattpocock true
```

The [resolver header](../../bin/fm-skill-path.sh) owns marketplace selection and refusal statuses.

The manifest's own `skills` list declares the promoted skills, and the source tree carries more.

```sh
jq -r '.skills | length' <installPath>/.claude-plugin/plugin.json   # 27
/usr/bin/find <installPath>/skills -name SKILL.md | wc -l            # 38
bin/fm-skill-path.sh mattpocock-skills --list-skills --include-undeclared \
  | awk -F '\t' '{ split($2, p, "/"); print p[2] }' | sort | uniq -c
```

Observed:

```text
  20 engineering
   7 in-progress
   4 misc
   7 productivity
```

Upstream's own `CLAUDE.md` in the install defines the buckets: `in-progress` is beta and public on purpose but not shipped in the plugin, and `misc` is kept but frozen and not promoted.
Claude lists only the 27 declared skills, the `engineering` and `productivity` ones, as plugin skills.
The observed listing includes all 38 source-tree skills, not only the 27 declared plugin skills.
The [loader header](../../bin/fm-matt-skill.sh) owns its discovery options, and the [generator header](../../bin/fm-matt-pointers.sh) owns partial-install, audit, and prune behavior; regression coverage is linked below.

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
plugin=mattpocock-skills@mattpocock
resolved_version=1.3.1
resolved_commit=49dd158d1076134a641b33efb035946536778336
skill_file=~/.claude/plugins/cache/mattpocock/mattpocock-skills/1.3.1/skills/engineering/code-review/SKILL.md
skill_file_sha256=09eb147f793e4647949edd32dbad278f0554dfb56e0d46b699cd4c2c55bf0357
resolved_by=bin/fm-skill-path.sh

09eb147f793e4647949edd32dbad278f0554dfb56e0d46b699cd4c2c55bf0357
```

`resolved_by` is always `bin/fm-skill-path.sh`.
That script is the repo's single owner of plugin-skill resolution, enablement, and skill listing, and the loader carries no resolver of its own: without that owner beside it the loader exits 127 with nothing on stdout rather than guessing a path.

## Validated pin

No script hardcodes a validated version.
Each generated pointer passes the plugin, version, and commit it was generated from, and the loader compares them with the enabled install.

```sh
bin/fm-matt-skill.sh diagnosing-bugs --check \
  --validated-plugin mattpocock-skills@mattpocock --validated-version 1.3.1 \
  --validated-commit 49dd158d1076134a641b33efb035946536778336 --require-validated-pin \
  | grep -E '^(validated_|pin=)'
```

Observed, exit 0:

```text
validated_plugin=mattpocock-skills@mattpocock
validated_version=1.3.1
validated_commit=49dd158d1076134a641b33efb035946536778336
pin=validated
```

The identity of the disabled install no longer matches:

```sh
bin/fm-matt-skill.sh diagnosing-bugs --check \
  --validated-plugin mattpocock-skills@claude-plugins-official --validated-version 1.2.3 \
  --validated-commit 2ab958093e83e0ec752e6c1c5932da465bf23e0c --require-validated-pin
printf 'exit=%s\n' "$?"
```

Observed:

```text
fm-matt-skill.sh: resolved mattpocock-skills@mattpocock version '1.3.1' commit '49dd158d1076134a641b33efb035946536778336', not the validated mattpocock-skills@claude-plugins-official version '1.2.3' commit '2ab958093e83e0ec752e6c1c5932da465bf23e0c'
exit=6
```

The [loader header](../../bin/fm-matt-skill.sh) owns pin comparison, drift reporting, and strict-mode behavior.

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

The [generator header](../../bin/fm-matt-pointers.sh) owns audit states and regeneration mechanics.
The recorded scratch-destination audit passed for 38 freshly generated pointers:

```sh
bin/fm-matt-pointers.sh --dest <scratch-dir> --loader <stable-checkout>/bin/fm-matt-skill.sh
bin/fm-matt-pointers.sh --check --dest <scratch-dir>
```

Observed:

```text
ok - 38 pointers under <scratch-dir> match mattpocock-skills@mattpocock 1.3.1
```

## Where each runtime looks for skills

| Runtime | Version | Reads the Claude plugin | Bridge needed |
|---|---|---|---|
| `claude` | 2.1.300 | yes, it owns the plugin | no for declared skills; undeclared reach unverified |
| `grok` | 1.0.50 | yes, re-verified below | only for the undeclared skills |
| `kimi` | 0.36.1 | not re-established | not established |
| `codex` | 0.145.0 | no reference to the plugin cache at 0.145.0 | yes, with `--dest ~/.codex/skills` |
| `pi` | 0.84.2 | not established | not established |

Grok reaches the enabled plugin natively, re-verified 2026-10-15 at 1.0.50:

```text
$ grok inspect | grep 'mattpocock-skills ('
  └ mattpocock-skills (user, enabled)  27 skills
```

Grok 1.0.50 no longer marks each plugin skill with a `plugin:` prefix in that listing, so the per-skill count from 1.0.5 is not reproducible.
Grok sees the 27 declared plugin skills on its own, so for grok the pointers to those are duplication rather than reach; the 11 undeclared skills reach grok only through pointers.
`bin/fm-matt-pointers.sh --uninstall` exists for a runtime where every pointer is duplication.

The `kimi` and `codex` rows carry forward observations taken on 2026-07-30 at `kimi` 0.31.0 and `codex` 0.145.0, when `kimi`'s discovery constants read `USER_GENERIC_DIRS = [".agents/skills"]` with no plugin-cache reference and `codex` named only `$CODEX_HOME/skills` and `~/.codex/skills`.
`codex` is unchanged at 0.145.0; `kimi` has moved to 0.36.1 and its row has not been re-established since.
`pi` 0.84.2 discovers skills by default, since `--no-skills` disables discovery, but it exposes no listing command and its roots were not established in this pass.
Re-establish any unverified row before relying on it to add or remove a pointer set.

## Regression coverage

`tests/fm-skill-path.test.sh` covers the resolver: identity, support-file resolution, a custom `CLAUDE_CONFIG_DIR`, paths containing spaces, expected version and commit pins, a bare name following the one enabled marketplace, undeclared skills resolving and listing only under `--include-undeclared` and never from a deprecated bucket, `--list-skills` leaving out, naming, and reporting with status 7 a misnamed, duplicated, or symlinked skill that would not resolve, and refusal of missing, disabled, ambiguous, tampered, symlinked, and malformed installs.

`tests/fm-matt-pointers.test.sh` builds a fake plugin under a private `CLAUDE_CONFIG_DIR` and covers the loader and the generator without touching the real install: original bytes, full identity, a validated matching pin, and support-file discovery on success; silent-stdout refusal for a moved, absent, disabled, swapped, unknown or deprecated, symlinked, or misnamed install; following the one enabled marketplace and refusing none or several; offering undeclared upstream skills, a generator run that leaves out a misnamed or duplicated bucket skill instead of aborting but still fails install and `--check` naming it, and `--prune` keeping the pointer of an offered skill that stopped resolving while removing a retired one; loud but non-fatal version or source-commit drift and outright refusal under `--require-validated-pin`; delegation to `bin/fm-skill-path.sh` including its exit statuses, and the loader's own silent-stdout 127 refusal without that owner; pointers that carry attribution and no procedure; mirrored invocation flags; the hard-stop instruction; `--check` catching edited, missing, inert, and retired pointers; unmarked directories surviving install and uninstall; a generated pointer's Step 1 running against the loader the repo ships; that Step 1 flagging a marketplace switch until the generator runs again; the generator refusing without an enabled plugin; and `--check` naming a recorded loader that later vanished.

`test_check_reports_retired_pointers_and_their_recorded_loaders` proves that `--check` reports a retired pointer with an executable recorded loader and reports its recorded loader as `BROKEN` after it becomes non-executable.

`test_check_audits_all_retired_pointers_without_an_identity_skill` proves that `--check` reports every marked pointer as retired when the install offers no skills, continues to audit their recorded loaders, and leaves an unmarked foreign directory untouched.

`test_check_reports_combined_pointer_faults_once_each` proves that `--check` reports both `DRIFTED` and `BROKEN` or both `MISSING` and `BROKEN` for one pointer while counting that pointer once in `drift`.
