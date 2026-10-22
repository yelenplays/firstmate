# Local CLI validation — round 3

Candidate: `14d6d2f08254a87b8b4122a9282212838cd2bd88`
Base: `0bcd790e7a3895afe8f71919f0cdcf50b3ff1237`

## Result: no-go

The previous quoted-key, flow-root and indented-root bypasses now refuse correctly. A different attribution bypass remains when multiple subject interpretations match: the check uses the first matching template, or skips templates altogether for a default-looking subject.

### Reproduction and observed product output

The recorded configuration for a previous round is:

```yaml
commit:
  fix_message: "{{.Summary}}"
```

The checked-head repository configuration is:

```yaml
commit:
  fix_message: "repair[{{.Step}}] {{.Branch}}: {{.Summary}}"
```

The task database records successful `review / review-fix / claude-opus-5-5` and `lint / lint-fix / claude-sonnet-5-5` invocations on the same repository and branch. A commit changes `tests/feature.test.sh` with subject `repair[review] fm/local: adjust assertion`. Both templates match it. The step-less template requires checking every step, including the Sonnet lint fixer.

The real command:

```sh
FM_HOME=<marked local lab home> NM_HOME=<local database directory> bin/fm-tdd-split.sh mutation local --timeout 10
```

instead exits 0:

```text
tdd-split: local mutation gate passed at c8a12a543151b4c8d31b8928c98eb5fd0690c089
```

Its product-created mutation log contains:

```text
ASSERTION_EXECUTED

fm-tdd-split: head=c8a12a543151b4c8d31b8928c98eb5fd0690c089 exit=0 command=for t; do bash "$t" || exit 1; done
```

`overlap-recorded-stepless` in `round3-cli-results.json` contains the complete input and output. `overlap-global-stepless` reproduces the same bypass with the step-less template in the current global config. `default-versus-stepless` needs only the step-less global template: a subject `no-mistakes(review): adjust assertion` short-circuits template inspection and likewise bypasses the Sonnet lint author. These are the same ambiguity/short-circuit defect, not three separate findings. Union the author requirements of all matching templates and the default syntax; do not stop at the first permissive interpretation.

## What ran

`round3-cli-driver.py` executes production mutation and dispute entrypoints with real isolated Git repositories and SQLite databases. It does not replace any harness, forge, control command or pipeline executable. Database rows and commits are constructed policy inputs, not a claim that a real model authored them or that another no-mistakes run was started.

The driver checks global, checked-head repository, recorded global-round and recorded repository-round templates; Opus acceptance; Sonnet refusal; unrelated worker commits; step-less templates; unsupported templates; dotted default steps; combined housekeeping; read-only review exclusion; failed-invocation exclusion; quoted YAML keys; flow and indented roots; overlapping templates; and rollback after refused relaunches. Exact configuration, invocation rows, commands, exit status, stdout, stderr and mutation output are in `round3-cli-results.json`.

Both real dispute and mutation return paths attempted production `fm-control` against a deliberately absent endpoint. They refused safely and restored all task record fields, with and without an existing dispute head. Record-field comparison ignores serialization order, which is not part of this contract.

The focused existing checks passed:

- `bash tests/fm-control-relaunch.test.sh --tdd-split`
- `bash tests/fm-pr-check-security.test.sh --test-ban`
- `bash tests/fm-tdd-split.test.sh`

These checks use simulated terminal/forge/control dependencies and are not live authenticated worker evidence. The candidate's changed regression scripts were also copied into a worktree-local `git archive` extraction of the base and run with the same selectors. They failed on the base at `the recovered seat lost its tests-first section` and `a recorded custom-template Sonnet review fix registered`, respectively. No full suite, linter, formatter, static analysis, pipeline-control, push, PR or CI phase was run.

The driver was initially corrected to compare restored record fields rather than byte ordering, and to place pre-existing tests at the base so broad templates cannot reject an unrelated earlier test commit and mask the target repair. It was rerun completely afterward; the published JSON is the final run.

## Live authenticated lifecycle limitation

Successful seat recovery, implementer handoff, dispute return and mutation return remain untested live. `tmux` is absent from PATH. Although Herdr and Claude are present, the production Claude spawn path invokes `fm-claude-trust.sh`, which writes the user's `.claude.json`. `CLAUDE_CONFIG_DIR` is unset, and the workspace boundary forbids that out-of-worktree configuration mutation. No empty configuration was used to infer missing login, no credentials were modified, and no Herdr session was provisioned.

Provide an authenticated worktree-local `CLAUDE_CONFIG_DIR`, or explicitly authorize the required trust registration in a subsequent run, then drive successful lifecycle checks through the prescribed named Herdr lab helper. No installed-tool search or installation was attempted.

This change affects CLI policy and generated worker instructions rather than visual layout. No live TUI could be reached within that authority boundary, so no screenshot is claimed.

All manual homes, databases, configuration and scratch repositories stayed within `.phase-test/`, were removed after execution, and left the source worktree clean. Evidence files remain in the designated evidence directory.
