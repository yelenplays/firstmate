# Targeted CLI validation

Candidate: `a0c0160d3aed970e07ac8489898a8996cc5f975e`
Base: `0bcd790e7a3895afe8f71919f0cdcf50b3ff1237`

## Result: do not ship

Valid quoted YAML keys bypass the new repair-subject author check. A repository configuration containing:

```yaml
"commit":
  fix_message: "repair[{{.Step}}] {{.Branch}}: {{.Summary}}"
```

was committed alongside `tests/feature.test.sh`, under subject `repair[review] fm/local: adjust assertion`. The task's invocation database recorded `review`, `review-fix`, `claude-sonnet-5-5`, `ok`. Running the real `bin/fm-tdd-split.sh mutation local --timeout 10` returned exit 0 and printed:

```
tdd-split: local mutation gate passed at 49025c3c1e798c179c50013ae5ffac96509aa4e6
```

The same template with an unquoted `commit` key refused before running the mutation command, identifying Sonnet and `tests/feature.test.sh`. Ruby's YAML consumer normalized the two documents to identical mappings (`quoted-yaml-normalized.json`). The quoted-key case should either recognize the template or conservatively refuse, not allow the test-changing repair.

## Public CLI exercise and isolation

The manual driver created fresh local Git repositories, committed test-changing repair subjects, and used real SQLite databases and production shell entrypoints. No CLI, forge, model, or lifecycle command was replaced. Invocation rows and round configurations were explicitly seeded local inputs; these checks demonstrate runtime policy enforcement, not an actual no-mistakes run or model authorship. No pipeline was initialized, advanced, published, or pushed. All temporary project/state files lived under the gate worktree and were removed after gathering evidence.

Each home was created using `bin/fm-lab-home.sh create <worktree-local-home>`. It contained a task on `fm/local`, `mode=no-mistakes`, `tdd_split=implement`, `base_branch=main`, and a real `origin/main` base ref. The mutation command executed the task's shell assertion against the product-created clone. The initial manual attempt lacked that remote base ref and refused for setup reasons; adding the ref corrected the setup and every case was re-driven. `manual-cli-guard.json` contains only the corrected runs.

Observable results in `manual-cli-guard.json`:

- Sonnet repairs were refused for live global configuration, checked-head repository configuration, and both global and repository configurations saved in step rounds.
- An Opus repair under the same template proceeded and executed the mutation command.
- A template without Step attributed the repair to all steps and refused Sonnet.
- An unsupported block-scalar template refused even an Opus worker's otherwise unrecognized test-changing commit.
- The default dotted gate subject refused Sonnet.
- Document housekeeping refused Sonnet and allowed Opus.
- A read-only Sonnet review did not contaminate an Opus review-fix's attribution.
- The quoted YAML key incorrectly allowed Sonnet's repair.

`relaunch-failure-rollback.json` captures actual `dispute local` calls into production `fm-control.sh`, deliberately supplying no window endpoint. Both refused relaunches restored the entire task record exactly, with and without a pre-existing dispute-head field. No backend or harness was launched for this failure-path check.

## Targeted automated checks

All three commands passed on the candidate (temporary directory set inside this worktree):

- `bash tests/fm-pr-check-security.test.sh --test-ban`
- `bash tests/fm-control-relaunch.test.sh --tdd-split`
- `bash tests/fm-tdd-split.test.sh`

These suites contain fake terminal/forge/control dependencies and are not claimed as live harness scenarios.

For fail-before comparison, `git archive <base>` extracted the base into a worktree-local scratch directory. Only the existing candidate versions of the two changed test scripts were copied into that copy. Running the same focused selectors failed on the base at the missing recovered-seat section and the incorrectly accepted recorded custom-template Sonnet repair, respectively. The real base mutation CLI also accepted a custom-template Sonnet repair and refused Opus document housekeeping as an unrecorded model; the candidate reverses both outcomes (`manual-baseline.json`). No product source was changed.

## Unexercised authenticated seat recovery

`tmux` was not on PATH. `herdr`, `claude`, `sqlite3`, `ruby`, `node`, and `treehouse` were present. An isolated named `fm-lab-tdd-proof-*` session passed `fm-herdr-lab.sh prepare` and was immediately cleaned using its guarded `teardown`; it was not provisioned and no primary or worker was started. A separately named read-only lab status probe returned Herdr 0.9.0, protocol 22, server not running.

Successful real Claude recovery/handoff/dispute/mutation-return launches were not attempted: production Claude spawn pre-registers workspace trust through `fm-claude-trust.sh` in the launching user's `.claude.json`, outside this task's allowed write boundary. An empty isolated config would not establish availability of the normal login and was not used to claim a login failure. Re-run these scenarios with an authenticated, pre-approved worktree-local Claude configuration or explicit scoped permission for the necessary trust registration. The automated relaunch checks passed but cannot substitute for these real harness scenarios.

This is CLI/prompt-generation work. Evidence is CLI output and persisted state; no rendered UI was exercised or screenshot claimed.
