#!/usr/bin/env bash
# Regression for report-before-close across a failed Slack post and startup
# close-marker replay. Slack and the absent terminal are transport doubles;
# tasks-axi, teardown, marker replay, and updates are the real implementations.
# This is executable-interface evidence, not a live Slack or worker proof.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null 2>&1 || fail "this regression needs tasks-axi on PATH"

home=$(fm_test_tmproot fm-updates-teardown)
mkdir -p "$home"/{state,data,config,fakebin}
export FM_HOME="$home"
export PATH="$home/fakebin:$PATH"
cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
echo "can't find session: isolated" >&2
exit 1
SH
cat > "$home/fakebin/slack-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/transport.log"
case "$1 ${2:-}" in
  'draft send')
    if [ "${FM_TEST_UPDATES_HEALTHY:-0}" = 1 ]; then
      printf 'ts: "1791140000000001"\n'
    else
      echo 'error: ratelimited'
      exit 1
    fi ;;
  'draft discard') echo discarded ;;
  *) printf 'draft: d_test1234\nchannel: "#updates (C0TESTUPDATES)"\n' ;;
esac
SH
chmod +x "$home/fakebin/"*
printf '%s\n' 'report-channel=#reports' 'decisions-channel=#decisions' \
  'updates-channel=#updates' 'language=de' 'captain-user=U0TESTCAPTAIN' \
  "digest-hour=$(( (10#$(date +%H) + 8) % 24 ))" > "$home/config/slack-bridge"
printf 'kind=ship\nmode=no-mistakes\nspawn_gen=g1\nwindow=isolated:fm-result\nendpoint_task_id=result\nworktree=%s/absent-worktree\nproject=%s/absent-project\n' \
  "$home" "$home" > "$home/state/result.meta"
# An overdue result whose terminal and scratch copy have already gone away.
printf 'done [at=%s]: Ergebnis fertig\n' "$(( $(date +%s) - 3600 ))" > "$home/state/result.status"
"$ROOT/bin/fm-tasks-axi.sh" add result 'Ergebnis fertig' --kind ship >/dev/null
"$ROOT/bin/fm-tasks-axi.sh" start result >/dev/null

rc=0
"$ROOT/bin/fm-teardown.sh" result > "$home/teardown.out" 2> "$home/teardown.err" || rc=$?
expect_code 1 "$rc" "cleanup must refuse while the outcome cannot be posted"
assert_grep 'outcome has not been reported to Slack' "$home/teardown.err" "the refusal must be caused by failed reporting"
assert_present "$home/state/result.meta" "failed reporting must retain the task identity"
assert_present "$home/state/result.status" "failed reporting must retain the outcome"
printf 'After failed reporting: task metadata retained; cleanup exit=%s\n' "$rc"

# Bootstrap uses this replay consumer for pending cleanup receipts. A restart
# must not silently close an unreported task merely because teardown staged one.
if [ -f "$home/state/result.backlog-close" ]; then
  . "$ROOT/bin/fm-tasks-axi-lib.sh"
  . "$ROOT/bin/fm-backlog-transition-lib.sh"
  fm_backlog_close_marker_replay "$home/state" "$home/state/result.backlog-close" "$home/data"
fi
printf 'After startup close-marker replay: metadata=%s\n' \
  "$(test -f "$home/state/result.meta" && echo retained || echo MISSING)"
"$ROOT/bin/fm-tasks-axi.sh" show result

export FM_TEST_UPDATES_HEALTHY=1
before=$(wc -l < "$home/transport.log")
scan=$("$ROOT/bin/fm-updates.sh" scan)
tick=$("$ROOT/bin/fm-updates.sh" tick)
printf 'After Slack recovery: scan=%s; tick=%s; new transport calls=%s\n' \
  "${scan:-EMPTY}" "${tick:-EMPTY}" "$(( $(wc -l < "$home/transport.log") - before ))"
assert_present "$home/state/result.meta" "startup replay must preserve an unreported task so recovered Slack can receive its result"
"$ROOT/bin/fm-slack-bridge.sh" posted --task result finished \
  || fail "the recovered backstop must post the retained finished result"
pass "fm-updates: failed cleanup reporting remains retryable across startup receipt replay"
