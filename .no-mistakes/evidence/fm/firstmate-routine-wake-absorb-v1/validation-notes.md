# Targeted live validation

Candidate: `b9d70e89b7c19252386ce71bb4ef302a76da0e96`.

Ten live CLI scenarios passed, recorded in `live-triage.log` and `live-results.json`.
The reproducer is `live-driver.py`; it requires this repository, Herdr, the existing Claude login, tasks-axi, and Python on PATH.
It launches genuine Claude through `fm-herdr-lab.sh`, verifies working state through `fm-crew-state.sh`, and uses the production triage, drain, execution-approval, and queue interfaces without substituting any executables.
The initial real watcher cycle is intentionally stopped before controlled status-write-before-notification cases, leaving the production autoarm between-turn grace in effect.
The watcher's exit-143 message in `live-watcher.log` is that intentional stop, not a spontaneous failure.
All named Herdr sessions were torn down successfully with the helper's default-session tripwire; disposable homes and temporary test drivers were removed from the worktree.

Additional deterministic checks passed:

- `bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh --per-script-timeout-secs 480`.
- `bin/fm-test-run.sh tests/fm-wake-triage.test.sh --per-script-timeout-secs 420`.
- `/bin/bash tests/fm-wake-triage.test.sh`, using stock Bash 3.2.57.
- `bin/fm-test-run.sh tests/gate-wake-ack.test.sh --per-script-timeout-secs 180`, a temporary focused driver executing the existing `test_ack_rows_retires_only_the_named_presented_rows`, `test_ack_rows_naming_every_row_retires_the_episode`, and `test_ack_rows_and_the_batch_ack_are_both_journaled` cases.

For both triage-suite runs, only the final `test_shellcheck` invocation was temporarily excluded to honor the assigned phase's prohibition on static analysis.
The original test file was restored afterward; no source or test modifications remain.
No complete repository suite, lint, formatter, or static analyzer was run.

Lab setup mistakes were corrected before the successful pass: provision owns initial prepare, and working Herdr panes require `agent read --source visible` rather than history scrolling.
The decision byte-cap probe was expanded to thirty entries because individual decision notes are themselves truncated before the aggregate cap applies.

Real Claude started successfully with its normal login, but this does not prove actual Stop-hook feedback delivery.
`fm_primary_root_matches` returns 1 for the required linked gate worktree, so the primary-only Stop hook stays inert there; tmux is also absent from PATH.
No fake primary, fabricated login, scope override, secondmate marker, or unauthorized checkout was used to bypass this boundary.
The real hook's no-feedback/re-park behavior, one-feedback actionable delivery with oversize embedding, plain-arm successor handoff, and timed retry boundaries therefore remain untested live, although their deterministic regression cases passed.
An approved plain-primary lab recipe is needed to close that previously accepted live-validation limitation.
This is a CLI behavior change, not a renderer/layout change; terminal transcripts provide the reviewer-visible evidence rather than screenshots.
