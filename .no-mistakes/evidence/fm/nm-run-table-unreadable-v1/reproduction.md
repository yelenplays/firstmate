# Run-table regression validation

Real crew-state and task-execution CLI interfaces ran against an isolated Git repository, a real tasks-axi backlog, a generation-bound implementation receipt, and a semantic busy event. Existing test fakes supplied external no-mistakes and tmux responses. No live workers or pipelines were controlled.

The baseline used a disposable bin copy with only fm-nm-run-lib.sh restored from a0ef7ba2612b5944674525c19731e60a856aabb4. A foreign-branch status response leads to the empty overview. Three reads reproduce the old false recovery alarm; the target retains the busy owner. A missing endpoint with a stale busy record still requires recovery.

The initial fixture omitted the status response, bypassing overview parsing. That setup was corrected before the final transcripts were collected.

The harness loaded function definitions preceding the invocation list in tests/fm-crew-state.test.sh, then ran the shell body below. It uses existing test helpers and does not assert implementation source. Temporary harness and executable copies were removed after validation.

```bash

set -e
if [ "${VALIDATE_BASELINE:-0}" = 0 ]; then
  test_runs_table_empty_is_absent_corrupt_stays_unreadable
  test_capped_overview_with_no_same_branch_row_is_absent
  test_capped_inventory_failures_report_unknown
  test_competing_live_runs_report_unknown_with_both_ids
fi
reset_fakes
d=$(new_case guard-end-to-end)
make_repo_on_branch "$d/wt" fm/busy-worker
make_fakebin "$d" >/dev/null
mkdir -p "$d/data" "$d/config" "$d/project"
cp "$ROOT/.tasks.toml" "$d/.tasks.toml"
export FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" FM_BACKEND=tmux
export PATH="$d/fakebin:$PATH"
unset FM_CREW_STATE_BIN
EXEC="$ROOT/bin/fm-task-execution.sh"
if [ "${VALIDATE_BASELINE:-0}" = 1 ]; then
  CREW_STATE="$ROOT/.test-run-table/base-bin/fm-crew-state.sh"
  EXEC="$ROOT/.test-run-table/base-bin/fm-task-execution.sh"
fi
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$d/data/backlog.md"
tasks-axi add busy-worker 'Implement approved change' --kind ship --start --file "$d/data/backlog.md" >/dev/null
fm_write_meta "$d/state/busy-worker.meta" "window=fm:fm-busy-worker" "worktree=$d/wt" "project=$d/project" "kind=ship" "harness=claude" "spawn_gen=fixture1"
printf 'working: implementing approved change\n' > "$d/state/busy-worker.status"
"$EXEC" approve busy-worker --basis captain-approved
token=$("$EXEC" attempt busy-worker)
(cd "$d/wt" && "$EXEC" started busy-worker "$token")
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" busy-worker)
"$ROOT/bin/fm-busy-event.sh" apply "$d/state" busy-worker busy --gen "$gen" --source claude-hook --event user-prompt-submit
FM_FAKE_AXI_STATUS=$(run_running fm/other-worker)
FM_FAKE_AXI_HOME='count: 0 of 0 total
runs[0]{id,branch,status,head,pr}:'
printf '\nScenario: confirmed busy implementation owner, valid empty run table (baseline=%s)\n' "${VALIDATE_BASELINE:-0}"
printf 'AXI fixture input:\n%s\n' "$FM_FAKE_AXI_HOME"
for round in 1 2 3; do
  out=$(run_crew_state "$d" busy-worker)
  verdict=$("$EXEC" show busy-worker)
  printf 'Observation %s\nfm-crew-state busy-worker: %s\nfm-task-execution show busy-worker: %s\n' "$round" "$out" "$verdict"
  if [ "${VALIDATE_BASELINE:-0}" = 1 ]; then
    assert_contains "$out" 'unreadable runs table' 'baseline reproduces false corruption'
    assert_contains "$verdict" 'verify-idle-or-failed-owner' 'baseline reproduces false recovery alarm'
  else
    assert_contains "$out" 'state: working' 'busy worker must be working'
    assert_contains "$verdict" 'continue-implementation' 'guard must retain busy implementation owner'
  fi
done
printf '\nScenario: same owner endpoint now dead, stale busy record retained\n'
FM_FAKE_TMUX_MISSING=1
out=$(run_crew_state "$d" busy-worker)
verdict=$("$EXEC" show busy-worker)
printf 'fm-crew-state busy-worker: %s\nfm-task-execution show busy-worker: %s\n' "$out" "$verdict"
assert_contains "$out" 'state: unknown' 'dead owner not working'
assert_contains "$verdict" 'verify-idle-or-failed-owner' 'dead owner must require recovery'

```
