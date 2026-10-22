# CLI validation — round 2

Candidate: `6033d2a3f11076882f14189698f7433a4479e106`
Base: `0bcd790e7a3895afe8f71919f0cdcf50b3ff1237`

## Verdict: no-go

The prior quoted-key bypass is fixed. Two different valid YAML layouts still bypass the required repair-author restriction:

```yaml
{commit: {fix_message: "repair[{{.Step}}] {{.Branch}}: {{.Summary}}"}}
```

```yaml
  commit:
    fix_message: "repair[{{.Step}}] {{.Branch}}: {{.Summary}}"
```

Ruby's YAML consumer normalized both, the ordinary block mapping, and the quoted-key mapping to identical objects (`round2-yaml-meaning.json`). For each layout, an isolated local Git repository committed `.no-mistakes.yaml` and `tests/feature.test.sh` with subject `repair[review] fm/local: adjust assertion`. The task database recorded a successful `review` / `review-fix` invocation on `claude-sonnet-5-5`. Its worker was allowlisted Opus, so the pipeline-fixer restriction had to independently refuse the repair.

The real command `bin/fm-tdd-split.sh mutation local --timeout 10` instead exited 0 and printed `tdd-split: local mutation gate passed at <head>`. Its product-created mutation log contained `ASSERTION_EXECUTED`, proving the unauthorized repair proceeded into execution. The ordinary and quoted block mappings correctly refused the identical subject before mutation execution. The two failures are recorded as `flow-root` and `indented-root` in `round2-cli-results.json`.

Recognize these YAML layouts or conservatively refuse unreadable configurations instead of treating them as having no template. This is a different input shape from the previous quoted-key finding, not a re-report of that repaired case.

## Public CLI scenarios exercised

All manual runs used production shell entrypoints, real local Git repositories and real SQLite databases. Invocation rows were seeded inputs, not an actual no-mistakes run or proof of a model having authored those commits. No forge, harness, control command, or other executable was replaced in these manual runs. No pipeline was initialized, advanced, pushed, or published.

`round2-cli-results.json` records the exact configuration, invocation inputs, exit status, stdout, stderr and mutation output for each case:

- Global, checked-head repository, recorded global-round and recorded repository-round repair templates refuse Sonnet test modifications.
- The same recorded template permits an Opus repair; an Opus worker's unrelated commit is not misattributed.
- A template without Step checks every author and refuses a Sonnet lint fixer.
- An unsupported block-scalar template refuses an otherwise unrecognized Opus worker commit.
- A default dotted gate subject checks its Sonnet author and refuses.
- Combined document/lint housekeeping allows recorded Opus and refuses recorded Sonnet.
- A read-only Sonnet review does not contaminate an Opus review-fix attribution.
- Double-quoted keys work for all four configuration sources; single-quoted keys also refuse Sonnet. An escaped key conservatively refuses.
- Flow-root and indented-root mappings incorrectly allow the Sonnet repair.
- A real dispute return with no window endpoint fails relaunch and restores the entire task record, both with and without a prior dispute head.

`round2-mutation-rollback.json` also exercises the real mutation-return failure: a mutation command prints `MUTANT_SURVIVED` and exits 1, production control refuses the missing window endpoint, and the task record is restored exactly in both prior-head cases.

Each manual home was minted with `bin/fm-lab-home.sh create` inside this worktree. Every fixture, configuration, scratch repository and database stayed inside `.phase-test/`; those files were removed after collecting evidence. No production fleet state or credentials were modified.

## Targeted regression commands

These passed on this candidate with TMPDIR set to the worktree-local `.phase-test/tmp`:

- `bash tests/fm-pr-check-security.test.sh --test-ban`
- `bash tests/fm-control-relaunch.test.sh --tdd-split`
- `bash tests/fm-tdd-split.test.sh`

These checks use fake terminal/forge/control dependencies and are not counted as live authenticated worker scenarios. No full suite, linter, formatter, or static analyzer was run.

For fail-before comparison, `git archive` extracted the base inside `.phase-test/base`. Only the candidate's existing two changed regression scripts were copied into that scratch copy. The focused relaunch selector failed with `the recovered seat lost its tests-first section`; the focused test-ban selector failed with `a recorded custom-template Sonnet review fix registered`. Logs are `round2-base-relaunch.log` and `round2-base-test-ban.log`.

## Successful authenticated relaunches remain untested

`tmux` is not on PATH; no host search or install was attempted. Herdr, Claude, Treehouse and SQLite are present, but the Claude spawn path calls `fm-claude-trust.sh`, intentionally writing the launching user's `.claude.json` outside the allowed worktree. No authenticated worktree-local Claude configuration was supplied, and the write boundary forbids changing the user's trust configuration. This is an authority blocker, not evidence of missing login. No real primary or worker was launched and no Herdr session was provisioned in this round.

To exercise successful seat recovery, implementer handoff, dispute return and mutation return, supply an authenticated worktree-local `CLAUDE_CONFIG_DIR`, or authorize the narrowly required trust registration, then rerun through the prescribed named Herdr lab helper. The deterministic relaunch checks passed, but cannot substitute for those live scenarios.

This change exposes CLI policy and generated launch instructions, not a rendered visual change. No live TUI was reached; therefore no screenshot is claimed.
