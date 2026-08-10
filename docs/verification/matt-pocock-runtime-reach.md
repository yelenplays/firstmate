# Verification: which runtimes reach the Matt Pocock skills

Records how each supported harness reaches Matt Pocock's skill suite, and that the pointer bridge in `bin/fm-matt-pointers.sh` loads the installed original rather than any copy.
Verified 2026-07-30 on macOS 25.5.0.

The suite is installed once, as the Claude plugin `mattpocock-skills@claude-plugins-official` version 1.2.0, source pin `2ab958093e83e0ec752e6c1c5932da465bf23e0c`, at `~/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.2.0`.
It declares 22 skills: 9 the model may invoke on its own, and 13 carrying `disable-model-invocation: true`, which the user reaches by slash command only.

## Grok reaches the plugin natively, with no bridge

`grok` 0.2.114 discovers `~/.claude/plugins/` as a first-class plugin location, so it lists and loads all 22 skills without anything installed under `.agents/skills`.
This is a plugin-discovery path, not the `[compat.claude] skills` cell, which covers only `~/.claude/skills/` and `<cwd>/.claude/skills/`.
Setting `GROK_CLAUDE_SKILLS_ENABLED=false` therefore does not remove them.

```
$ grok inspect | grep -c 'plugin: mattpocock-skills'
22
$ grok inspect | grep 'mattpocock-skills (user'
  └ mattpocock-skills (user, enabled)  22 skills
```

A live session loads the original bytes.
The model-invocable case:

```
$ grok -p "/tdd Do not start any TDD work. Instead, answer two things only: (1) the absolute
  filesystem path of the SKILL.md you just loaded, (2) copy the three bold anti-pattern names
  from its Anti-patterns section verbatim." --max-turns 4

**(1)** `/Users/yelen/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.2.0/./skills/engineering/tdd/SKILL.md`

**(2)** Implementation-coupled, Tautological, Horizontal slicing
```

The user-invoked case, which confirms that `disable-model-invocation` blocks automatic invocation only and never the slash command:

```
$ grok -p "/wayfinder Do not plan any work or create any tickets. Answer only: the absolute path
  of the SKILL.md you loaded, and its first markdown heading verbatim." --max-turns 4

`/Users/yelen/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.2.0/skills/engineering/wayfinder/SKILL.md`

## Plan, don't do
```

Both answers match the installed file.
`wayfinder`'s first two headings are `## Plan, don't do` and `## Refer by name`.

## The pointer bridge loads the original, proven by digest

Runtimes without Claude plugin discovery need the bridge.
A pointer's body carries no procedure; its first instruction is to run `bin/fm-matt-skill.sh <skill>`, which prints the installed original preceded by an identity header.
The header's `skill_file_sha256` is the discriminator: no source other than the loader can produce it.

```
$ shasum -a 256 .../skills/engineering/tdd/SKILL.md
5363bb2775679fe9311fbb67947f95359169c6e7f1fac77c0f25e190bca6cf2f

$ grok -p "/matt-tdd Do not start any TDD work. Follow the pointer's Step 1 exactly, then answer
  only: (a) the skill_file_sha256 and resolved_by values the command printed, (b) the three bold
  anti-pattern names from the loaded Anti-patterns section, verbatim." --max-turns 5

**(a)**
- `skill_file_sha256`: `5363bb2775679fe9311fbb67947f95359169c6e7f1fac77c0f25e190bca6cf2f`
- `resolved_by`: `fm-matt-skill.sh built-in fallback (bin/fm-skill-path.sh not installed)`

**(b)**
- **Implementation-coupled**
- **Tautological**
- **Horizontal slicing**
```

The same holds for a user-invoked skill through its pointer, where the reported digest again equals `shasum -a 256` of the installed `wayfinder/SKILL.md`:

```
$ grok -p "/matt-wayfinder ... answer only: the skill_file_sha256 the command printed, and the
  first two markdown headings of the loaded skill verbatim." --max-turns 5

`skill_file_sha256=257e40665b28ae959ffdcb97d7a72b074360f4a3d201bd84786505308546e434`

## Plan, don't do
## Refer by name
```

## A missing plugin stops the work instead of degrading it

With the install directory moved aside, the loader exits 3, prints the reason on stderr, and prints nothing on stdout:

```
$ mv <install> <install>.moved && bin/fm-matt-skill.sh tdd; echo "rc=$?"
fm-matt-skill.sh: mattpocock-skills@claude-plugins-official install directory is missing (moved or removed): <install>
rc=3
```

A live session in that state stops rather than improvising:

```
$ grok -p "/matt-tdd Follow the pointer's instructions exactly." --max-turns 4

**`tdd` could not be loaded.** I am stopping here and will not apply or improvise the TDD procedure.

Exact diagnostic:
    fm-matt-skill.sh: mattpocock-skills@claude-plugins-official install directory is missing (moved or removed): ...

Exit code: **3** (nothing on stdout).

The pointer says there is no second source for this procedure, so I will not reconstruct it from
memory or other copies on disk.
```

The install directory was restored immediately, and `bin/fm-matt-skill.sh tdd --check` again reports `pin=validated` with the digest above.

## Where each runtime looks for skills

| Runtime | Version | Reads the Claude plugin | Skill directory | Bridge needed |
|---|---|---|---|---|
| `claude` | current | yes, it owns the plugin | `~/.claude/skills` | no |
| `grok` | 0.2.114 | yes, `~/.claude/plugins/` is a plugin location | `~/.agents/skills` among others | no |
| `kimi` | 0.31.0 | no reference to the plugin cache | `~/.agents/skills` | yes |
| `codex` | 0.145.0 | no reference to the plugin cache | `~/.codex/skills`, not `.agents/skills` | yes, with `--dest ~/.codex/skills` |
| `pi` | 0.82.1 | not established | not established | not established |

`kimi`'s discovery constants are visible in its binary as `USER_GENERIC_DIRS = [".agents/skills"]` with no `.claude/plugins` reference.
`codex` names `$CODEX_HOME/skills` and `~/.codex/skills`, and uses `.agents` only for `~/.agents/plugins/marketplace.json`, so pointers placed in `~/.agents/skills` are invisible to it.
`pi --list-models` returned nothing on this machine, so no live `pi` session could be run and its behavior is untested rather than assumed.

## Regression coverage

`tests/fm-matt-pointers.test.sh` builds a fake plugin under a private `CLAUDE_CONFIG_DIR` and covers the guarantees above without touching the real install: original bytes plus attribution on success; silent-stdout refusal for a moved, absent, disabled, swapped, undeclared, symlinked, or misnamed install; loud but non-fatal version drift, and outright refusal under `--require-validated-pin`; delegation to `bin/fm-skill-path.sh` including its exit statuses; pointers that carry attribution and no procedure; mirrored invocation flags; the hard-stop instruction; `--check` catching edited, missing, and inert pointers; and unmarked directories surviving both install and uninstall.
