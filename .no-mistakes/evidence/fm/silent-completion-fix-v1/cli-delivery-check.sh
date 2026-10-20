#!/usr/bin/env bash
set -eu
LAB="$PWD/.local-test-tmp/durable-cli-home"
bin/fm-lab-home.sh create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND
printf '%s\n' '$ fm-tasks-axi.sh add cli-bench "Calculate requested bench result" --kind scout'
bin/fm-tasks-axi.sh add cli-bench 'Calculate requested bench result' --kind scout
printf '%s\n' '$ fm-tasks-axi.sh done cli-bench --note "Result: 6 * 7 = 42"'
bin/fm-tasks-axi.sh done cli-bench --note 'Result: 6 * 7 = 42'
printf '%s\n' '$ fm-crew-state.sh cli-bench'
bin/fm-crew-state.sh cli-bench
printf '%s\n' '$ fm-branch-outcome.sh append --promote-finished --task cli-bench --verdict routine --summary "Requested calculation finished: 42"'
bin/fm-branch-outcome.sh append --promote-finished --task cli-bench --verdict routine --summary 'Requested calculation finished: 42'
printf '%s\n' '$ fm-branch-outcome.sh lookup --seqs 1'
row=$(bin/fm-branch-outcome.sh lookup --seqs 1)
printf '%s\n' "$row"
printf '%s\n' "$row" | jq -e '.task == "cli-bench" and .verdict == "captain" and .summary == "Requested calculation finished: 42"' >/dev/null
printf '%s\n' '$ fm-branch-outcome.sh append --promote-finished --task cli-bench --verdict routine --silent true --summary "No new update"'
bin/fm-branch-outcome.sh append --promote-finished --task cli-bench --verdict routine --silent true --summary 'No new update'
printf '%s\n' '$ fm-branch-outcome.sh lookup --seqs 2'
row=$(bin/fm-branch-outcome.sh lookup --seqs 2)
printf '%s\n' "$row"
printf '%s\n' "$row" | jq -e '.verdict == "routine" and .silent == true' >/dev/null
printf '%s\n' '$ fm-branch-outcome.sh append --promote-finished --task unknown-task --verdict routine --summary "Still investigating"'
bin/fm-branch-outcome.sh append --promote-finished --task unknown-task --verdict routine --summary 'Still investigating'
row=$(bin/fm-branch-outcome.sh lookup --seqs 3)
printf '%s\n' "$row"
printf '%s\n' "$row" | jq -e '.verdict == "routine"' >/dev/null
printf '%s\n' '$ fm-branch-report.sh --task cli-bench --verdict captain --summary "Unauthorized report" (no branch actor or host turn)'
set +e
bin/fm-branch-report.sh --task cli-bench --verdict captain --summary 'Unauthorized report'
rc=$?
set -e
[ "$rc" -eq 3 ] || exit 1
printf 'Refused exit: %s\n' "$rc"
[ "$(bin/fm-branch-outcome.sh list | jq -s length)" -eq 3 ] || exit 1
printf '%s\n' '$ fm-branch-outcome.sh present'
bin/fm-branch-outcome.sh present
printf '%s\n' '$ fm-branch-outcome.sh mark-processed --through 1 (before presentation acknowledgement)'
set +e
bin/fm-branch-outcome.sh mark-processed --through 1
rc=$?
set -e
[ "$rc" -ne 0 ] || exit 1
printf 'Refused premature processing exit: %s\n' "$rc"
printf '%s\n' '$ fm-branch-outcome.sh mark-read --through 3; fm-branch-outcome.sh unprocessed'
bin/fm-branch-outcome.sh mark-read --through 3
bin/fm-branch-outcome.sh unprocessed
printf '%s\n' '$ fm-branch-outcome.sh mark-processed --through 1; fm-branch-outcome.sh unprocessed'
bin/fm-branch-outcome.sh mark-processed --through 1
[ -z "$(bin/fm-branch-outcome.sh unprocessed)" ] || exit 1
printf '%s\n' '$ fm-branch-outcome.sh list (rows retained after acknowledgement)'
bin/fm-branch-outcome.sh list
