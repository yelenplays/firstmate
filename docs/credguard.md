# Credential read guard

This document is the human-readable contract for the credential read guard.
`bin/fm-credguard-read.mjs` is the single decision owner and the hook entry point for every wired harness.
`bin/fm-credguard-install.mjs` owns wiring it into each harness's user-level hook surface.
Both are ported from [korallis/agent-stack](https://github.com/korallis/agent-stack) (`system/credguard-read-hook` and `system/credguard-read-install`) under the Apache License 2.0; see [`NOTICE`](../NOTICE) and [`LICENSES/agent-stack-Apache-2.0`](../LICENSES/agent-stack-Apache-2.0).

## Purpose and boundary

A worker that prints a credential file puts the secret into its transcript, where it stays and gets copied, summarised, and synced.
The guard refuses a worker tool call that would print a protected file, or a process environment, before it runs.
Using the values without printing them stays allowed: `set -a; . .env; set +a; npm run migrate`, `--env-file .env`, dotenv loaders in scripts, and `grep -q '^NAME=' .env`.

The guard is best effort against accidental printing, not a sandbox.
It parses shell commands, including subshells, `bash -c`, `eval`, wrappers such as `sudo` and `timeout`, globs, variables, copies, links, and `cd`, but a script that reads and prints a file itself is not parsed.
It never denies on its own error, because a broken hook must not stop every tool call.

It keeps its own expansion-aware shell lexer instead of sharing `bin/fm-arm-command-policy.mjs`, because the read guard must follow expansions and copies to a file path while the arm classifier deliberately never expands anything.

## What is protected

Default patterns, in `DEFAULT_PATTERNS` of the guard:

- `**/.env`, `**/.env.*`, `**/*.env`, `**/prod.env`, `**/*runtime-url*`, `**/*.pem`
- `~/.ssh/id_*`, `~/.aws/credentials`, `~/.netrc`, `~/.codex/auth.json`, `~/.config/gh/hosts.yml`

Templates (`.env.example`, `.env.sample`, `.env.template`) and public keys (`*.pub`) are exempt.
On macOS the match ignores case, because the default volume opens `.ENV` as `.env`.

Commands that print an environment are refused too: `env`, `printenv` without a name or with a secret-looking name, `export -p`, `declare -x`, `set`, `ps e`, `/proc/<pid>/environ`, `launchctl getenv` of a secret-looking name, and printing a variable after loading a protected file.

## Local path list

Machine-specific paths go in a local list that is never committed: one glob per line in `${XDG_CONFIG_HOME:-~/.config}/firstmate/credguard-read-paths`.
`FM_CREDGUARD_READ_PATHS` names another file.
Blank lines and `#` comments are ignored, and the entries add to the defaults.

## Key-names-only mode

`bin/fm-credguard-read.mjs --keys <file>...` prints `NAME` for each `NAME=value` line and nothing else.
It prints no value, no line without a name, and nothing from a PEM file.
Every refusal points the worker at this command.

## Install

Run the installer from the primary checkout so its default hook path remains available after task-worktree cleanup, or pass `--hook` with a durable executable path:

```sh
bin/fm-credguard-install.mjs            # wire every installed harness
bin/fm-credguard-install.mjs --check    # change nothing, exit 1 when a covered harness lacks the guard
```

The installer is idempotent, keeps every other hook and setting, backs up each file it changes as `<file>.bak-credguard-<time>`, and writes through a symlinked config.
It prints one line per harness: `ok`, `--` (missing or failed), `absent` (not installed), or `uncovered` (no hook surface a worker launch runs).
A worker account pin uses another Claude or Pi config root, so run it again with `CLAUDE_CONFIG_DIR` or `PI_CODING_AGENT_DIR` set to that root.
`--help` owns the exact targets and flags.

## Harness wiring

| Harness | Surface | Tools guarded |
| --- | --- | --- |
| claude | `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json` PreToolUse, matcher `Bash\|Read\|Grep`; workers load user settings beside their `--settings` file | shell, file read, content search |
| codex | `${CODEX_HOME:-~/.codex}/config.toml` managed PreToolUse block with Codex's own `trusted_hash`, so no review modal appears | shell |
| devin | `~/.config/devin/config.json` PreToolUse, matcher `exec\|read\|grep`; worker configs are snapshots of it (`bin/fm-devin-config.sh`) | shell, file read, content search |
| kimi | `${KIMI_CODE_HOME:-~/.kimi-code}/config.toml` managed `[[hooks]]` PreToolUse block | shell, file read, content search |
| grok | `${GROK_HOME:-~/.grok}/hooks/fm-credguard-read.json`; global hooks are always trusted | shell |
| pi | `${PI_CODING_AGENT_DIR:-~/.pi/agent}/extensions/fm-credguard-read.ts`, auto-discovered | shell, file read |
| omp | `~/.omp/agent/extensions/fm-credguard-read.ts`, auto-discovered | shell, file read |
| OpenCode | `${XDG_CONFIG_HOME:-~/.config}/opencode/plugins/fm-credguard-read.js`, `tool.execute.before` | shell, file read, content search |
| Cursor | `~/.cursor/hooks.json` `preToolUse` hook matching `Shell` | shell |
| Gemini CLI | `${GEMINI_CLI_SYSTEM_SETTINGS_PATH:-~/.gemini/settings.json}` `BeforeTool` hook | shell, file read, content search |

Claude, Codex, Devin, Pi, and omp are live-verified; Grok, Kimi, OpenCode, Cursor, and Gemini CLI are wired from their hook formats but not yet live-verified.
[`docs/verification/runtime-backends.md`](verification/runtime-backends.md#credential-read-guard) holds the dated evidence.

## Uncovered harnesses

The installer lists these on every run so none is skipped silently:

- Codex crewmate and scout launches: `bin/fm-spawn.sh` starts them with `--disable hooks`, so no hook runs; Codex secondmates and interactive sessions are covered.
- muse and agy: no hook or plugin surface.
- rovo: its event hooks cannot refuse a tool call.

## Verification

- `tests/fm-credguard-read.test.sh` pins the deny and allow tables, every runtime's output contract, key-names-only mode, the local list, and the never-block-on-error rule.
- `tests/fm-credguard-install.test.sh` pins idempotency, preserved hooks, backups, symlink write-through, malformed-config refusal, active OpenCode/Cursor/Gemini denial behavior, the absent and uncovered report, and the linked-worktree refusal.
- `FM_CREDGUARD_LIVE=1 bin/fm-test-run.sh tests/fm-credguard-live-e2e.test.sh` drives the default live-probe harnesses for real and refreshes their evidence; set `FM_CREDGUARD_LIVE_HARNESSES` to select supported alternatives.
