# Local product validation — round 4

Candidate: `61863f7de1001fb76c0d7e4eb5ab35288e3e7203`
Base: `0bcd790e7a3895afe8f71919f0cdcf50b3ff1237`

## Result: no-go — inherited YAML templates bypass test-author attribution

The previous overlapping-template defect is fixed: all three previous overlap reproductions now refuse Sonnet-authored test repairs. Ordinary, quoted, flow-root and indented-root configurations also enforce the restriction or refuse unreadable configuration as intended.

A valid YAML merge inside `commit` remains silently ignored:

```yaml
repair_style: &repair_style
  fix_message: "repair[{{.Step}}] {{.Branch}}: {{.Summary}}"
commit:
  <<: *repair_style
```

The normalized `commit.fix_message` is `repair[{{.Step}}] {{.Branch}}: {{.Summary}}`. Ruby's YAML consumer confirms this for both scalar and sequence merge forms; see `round4-yaml-meaning.json`.

With this configuration recorded for a task's previous round, a successful `review / review-fix / claude-sonnet-5-5` invocation, and a test-changing commit titled `repair[review] fm/local: adjust assertion`, the real product command:

```sh
FM_HOME=<worktree-local marked lab home> NM_HOME=<worktree-local database directory> bin/fm-tdd-split.sh mutation local --timeout 10
```

exits 0 and reports:

```text
tdd-split: local mutation gate passed at d4f5db7438c719364d6e442c454e1ea04d9e7025
```

The product-created mutation log proves the protected command ran:

```text
ASSERTION_EXECUTED

fm-tdd-split: head=d4f5db7438c719364d6e442c454e1ea04d9e7025 exit=0 command=for t; do bash "$t" || exit 1; done
```

The equivalent ordinary block configuration refuses the same repair and names Sonnet. Both `<<: *repair_style` and `<<: [*repair_style]` bypassed attribution in each of the four configuration locations: current global, checked-head repository, recorded round global, and recorded round repository. These are one parser defect, not eight separate findings. Recognize inherited settings or reject unsupported merge syntax rather than treating it as no configured template.

## Product checks performed

`round4-cli-driver.py` drove production mutation and dispute entrypoints using real isolated Git repositories, marked lab homes, and SQLite databases. No harness, forge, control command, or pipeline executable was replaced. Constructed invocation rows are policy inputs, not evidence that authenticated models authored these commits.

`round4-cli-results.json` records exact configurations, invocation rows, command, candidate, exit status, stdout, stderr, mutation logs and rollback comparisons for:

- Global, checked-head repository, and both recorded round configuration sources.
- Opus acceptance and unrelated worker commits, Sonnet refusal, dotted default steps, step-less templates, combined housekeeping, read-only review exclusion and failed-invocation exclusion.
- Quoted keys, unsupported block scalars/placeholders, flow and indented roots, overlapping templates and default-versus-template attribution.
- Dispute and mutation relaunch failures, with and without a previous dispute head. Real `fm-control` refused the absent endpoint and the product restored all record fields.
- The inherited-template bypass above.

Existing focused checks passed on the candidate:

```sh
bash tests/fm-control-relaunch.test.sh --tdd-split
bash tests/fm-pr-check-security.test.sh --test-ban
bash tests/fm-tdd-split.test.sh
```

These checks simulate terminal, forge or control dependencies and are not live authenticated worker evidence. Logs are `round4-relaunch-tests.log`, `round4-author-tests.log`, and `round4-tdd-tests.log`.

The candidate's two changed regression scripts were copied into a worktree-local `git archive` extraction of the base and run with the same selectors. They failed at `the recovered seat lost its tests-first section` and `a recorded custom-template Sonnet review fix registered`. See `round4-base-relaunch.log` and `round4-base-author.log`.

## Live lifecycle limits

Successful seat recovery, Sonnet handoff, dispute return and mutation return remain untested live. `tmux` is not on PATH. Herdr and Claude are on PATH, but the production Claude spawn calls `fm-claude-trust.sh`, which writes `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json`. `CLAUDE_CONFIG_DIR` is unset, and the workspace boundary forbids that user-level configuration mutation. No empty configuration was used to judge the normal login. No tool installation, credential mutation, or Herdr session provisioning was attempted.

Provide an authenticated worktree-local `CLAUDE_CONFIG_DIR`, or explicitly authorize trust registration in a later run, to exercise successful Claude lifecycle through the prescribed named Herdr lab helper. Merely installing tmux would not resolve the trust-write authority restriction.

The exercised surfaces are CLI policy and generated worker instructions, not visual layout. The authority restriction prevented reaching a live worker TUI; no screenshot is claimed.

PyYAML was unavailable; YAML semantics were verified with the existing `/usr/bin/ruby` YAML consumer instead, without installation or tool searches.

All scratch homes, Git repositories, databases, archived base files and temporary test data were confined to the worktree and removed after testing. New evidence remains only in the designated evidence directory. No full suite, linter, formatter, static analysis, outer-pipeline control, push, PR or CI phase was run.
