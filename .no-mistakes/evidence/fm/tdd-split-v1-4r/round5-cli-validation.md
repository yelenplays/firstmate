# Product validation — round 5

Candidate: `3e286c2e48a7698b36fd1db706b69c6e916b9ba5`
Base: `0bcd790e7a3895afe8f71919f0cdcf50b3ff1237`

## Result: no-go — an unreadable global configuration disables attribution

The inherited-YAML bypass from round 4 is fixed. Both scalar and sequence merges inside `commit`, top-level merges, commit aliases and anchors, quoted keys, alias keys and anchor keys now refuse across current global, checked-head repository, recorded-round global and recorded-round repository sources. An unrelated configuration anchor still permits an Opus worker's own test commit in all four sources. Unsupported templates deliberately refuse even an Opus worker's own otherwise unrecognized test commit.

A separate failure remains at `bin/fm-dod-lib.sh:1124`: a failed read of an existing global configuration is treated as if it contained no template.

### Reproduction through the real product

The evidence driver builds isolated real Git repositories and SQLite policy records under the run worktree. For `unreadable-global-sonnet`, it:

1. Writes `NM_HOME/config.yaml` containing:

   ```yaml
   commit:
     fix_message: "repair[{{.Step}}] {{.Branch}}: {{.Summary}}"
   ```

2. Records a successful `review / review-fix / claude-sonnet-5-5` invocation for the same repository and branch, and commits a test change with subject `repair[review] fm/local: adjust assertion`.
3. Sets the configuration's permissions to `000` (the test process runs as UID 501).
4. Runs `FM_HOME=<worktree-local marked lab home> NM_HOME=<worktree-local database directory> bin/fm-tdd-split.sh mutation local --timeout 10`.

Expected: refuse the otherwise unrecognized test-changing commit because the configured template cannot be read.

Actual exit: **0**. Stderr reports `cat: .../nm/config.yaml: Permission denied`, but stdout reports `tdd-split: local mutation gate passed`. The product-created mutation log contains:

```text
ASSERTION_EXECUTED

fm-tdd-split: head=b71e10006d4a1aee928a94b2585309c197ea36a8 exit=0 command=for t; do bash "$t" || exit 1; done
```

The same ordinary readable global configuration (`global-sonnet`) refuses before running the protected command. The second unreadable configuration case (`unreadable-global-opus-own`) also incorrectly passes despite the author's explicit fail-closed requirement for otherwise unrecognized Opus commits under unreadable configuration.

Fix direction: distinguish absent configuration from a failed read of an existing configuration; emit the existing unreadable sentinel on read failure. Add an executable-interface regression for this failure and a readable control.

## Live CLI checks

`round5-cli-driver.py` drives production mutation/dispute entrypoints without replacing the harness, control command, forge or pipeline executable. Git commits, configuration files, marked lab homes and SQLite invocation rows are constructed policy inputs; these rows do not claim authenticated models authored the commits. `round5-cli-results.json` preserves the exact candidate, configurations, invocation rows, command, stdout, stderr, exit status, product mutation logs, protected-command execution and rollback comparisons.

Covered:

- Custom repair templates from all four sources, Opus acceptance, Sonnet refusal and unrelated worker commits.
- Step-less and overlapping templates, including default-looking subjects.
- Dotted default gate steps, combined document/lint author attribution, exclusion of read-only review and failed invocations.
- Quoted, flow-root and indented-root configurations; unsupported block scalars and placeholders.
- Scalar/sequence merges, top-level merges, aliases, anchors, quoted/indirect/explicit keys, unrelated-anchor controls and deliberate refusal of Opus own commits under unreadable settings.
- Real failed dispute and mutation relaunches, with and without an existing dispute head: the absent endpoint causes real `fm-control` to refuse, and all metadata fields are restored.
- Unreadable-file bypass above.

## Focused automated checks and baseline

The following focused commands passed on the candidate; they simulate terminal, forge or control dependencies and are **not** live successful-worker evidence:

```sh
bash tests/fm-control-relaunch.test.sh --tdd-split
bash tests/fm-pr-check-security.test.sh --test-ban
bash tests/fm-tdd-split.test.sh
```

Logs: `round5-relaunch-tests.log`, `round5-author-tests.log`, `round5-tdd-tests.log`.

The two changed regression files were copied into a worktree-local `git archive` extraction of the base. Targeted baseline runs failed as expected:

- `--tdd-split`: `the recovered seat lost its tests-first section`.
- `--test-ban`: `a recorded custom-template Sonnet review fix registered`.
- `--test-ban-yaml`: `global scalar YAML let a Sonnet repair register its test`.

Logs: `round5-base-relaunch.log`, `round5-base-author.log`, `round5-base-yaml.log`.

## Live lifecycle limits and visual evidence

Successful seat recovery, implementer handoff, dispute return and mutation return were not driven live. `tmux` is absent from PATH. Herdr and Claude are available, but production Claude spawn invokes `fm-claude-trust.sh` and writes `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json`. `CLAUDE_CONFIG_DIR` is unset, and this run forbids user-level configuration changes outside the worktree. No empty configuration was used to assess the normal login; no tool installation, login mutation, or lab session provisioning was attempted.

To enable those checks, provide an authenticated worktree-local `CLAUDE_CONFIG_DIR`, or separately authorize trust registration, then rerun through the prescribed named `fm-herdr-lab.sh` prepare/provision/run/teardown contract. Installing tmux alone would not remove the trust-write restriction.

The change concerns CLI policy and generated worker instructions, not visual layout. No real worker TUI was reached under the current authority boundary, so no screenshot is claimed.

All scratch Git repositories, lab homes, databases, base extraction and test temporary directories were confined to the worktree and removed. Evidence remains only in the designated evidence directory. No source changes, full suite, linter, formatter, static analysis, pipeline-control, push, PR or CI phase was performed.
