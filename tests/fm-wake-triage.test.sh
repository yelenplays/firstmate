#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/environment.sh"
fm_test_sanitize_environment
# tests/fm-wake-triage.test.sh - behavior of bin/fm-wake-triage.sh, the one-call
# wake handler. Real drains run over crafted state; crew state, pane reads,
# captain-hold reads, and the Jev HTTP call are hermetic fakes, so no case
# touches a harness, a backlog tool, or the network.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

unset TYPESAFE_API_KEY OPENROUTER_API_KEY JEV_ROUTE JEV_MODEL JEV_TIMEOUT \
  JEV_URL JEV_BASE JEV_CONFIDENCE_FLOOR FM_WAKE_TRIAGE_JEV

TRIAGE="$ROOT/bin/fm-wake-triage.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-triage-tests)
BASE_PATH=$PATH

PANE_SECRET='PANE-ONLY-CONTENT-sk-never-send'

# A case home: state/, a fake crew-state (FM_FAKE_CREW_STATE_<id>), a fake pane
# reader, a fake captain-hold `open` (tasks listed in FM_FAKE_HELD), and a fake
# curl that records the Jev request body and replies with $FAKE_CURL_RESPONSE.
triage_case() {  # <name>
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/data" "$dir/curl"
  cat > "$dir/fakebin/fm-peek.sh" <<SH
#!/usr/bin/env bash
printf 'last tool output line\n\n$PANE_SECRET\n> \n'
SH
  cat > "$dir/fakebin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = open ] || exit 2
case " ${FM_FAKE_HELD:-} " in *" ${2:-} "*) exit 0 ;; esac
exit 1
SH
  cat > "$dir/fakebin/curl" <<'SH'
#!/usr/bin/env bash
out=''
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac
done
cat > "${FAKE_CURL_LOG:?}/body"
[ "${FAKE_CURL_FAIL:-0}" = 1 ] && exit 7
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '200'
SH
  chmod +x "$dir/fakebin/fm-peek.sh" "$dir/fakebin/fm-captain-hold.sh" "$dir/fakebin/curl"
  # A fresh watcher beacon keeps the drain's liveness guard quiet mid-turn.
  touch "$dir/state/.last-watcher-beat"
  printf '%s\n' "$dir"
}

run_triage() {  # <dir> [args...]
  local dir=$1
  shift
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_BACKEND=tmux \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_PEEK_BIN="$dir/fakebin/fm-peek.sh" \
    FM_CAPTAIN_HOLD_BIN="$dir/fakebin/fm-captain-hold.sh" FAKE_CURL_LOG="$dir/curl" \
    PATH="$dir/fakebin:$BASE_PATH" "$TRIAGE" "$@"
}

write_meta() {  # <dir> <task> <kind> [extra-line]
  printf 'kind=%s\nwindow=fm-%s\n%s\n' "$3" "$2" "${4:-}" > "$1/state/$2.meta"
}

has() { assert_contains "$1" "$2" "triage output"; }
lacks() { assert_not_contains "$1" "$2" "triage output"; }

queued_rows() {  # <dir>
  awk 'END { print NR }' "$1/state/.wake-queue" 2>/dev/null || echo 0
}

test_all_routine_batch_is_summarized_and_auto_acked() {
  local dir out
  dir=$(triage_case all-routine)
  write_meta "$dir" busy ship
  write_meta "$dir" held ship 'pr=https://github.com/o/r/pull/7'
  write_meta "$dir" mate secondmate
  printf 'working: running the test suite\n' > "$dir/state/busy.status"
  append_wake "$dir/state" signal busy.status "signal: $dir/state/busy.status"
  append_wake "$dir/state" stale fm-held "stale: fm-held"
  append_wake "$dir/state" signal mate.turn-ended "signal: $dir/state/mate.turn-ended"
  append_wake "$dir/state" check execution:gone "check: execution gone"

  out=$(FM_FAKE_CREW_STATE_busy='state: working · source: run-step · running' \
    FM_FAKE_CREW_STATE_held='state: parked · source: status-log · waiting' FM_FAKE_HELD=held \
    run_triage "$dir" --auto-ack --no-jev) || fail "triage failed on an all-routine batch: $out"
  has "$out" 'WAKE TRIAGE: 4 wake row(s); 0 act-now'
  lacks "$out" 'ACT NOW'
  has "$out" 'held (idle alert; held for the captain)'
  has "$out" 'mate (secondmate turn ended)'
  has "$out" 'WAKE_ACKED: every item was routine'
  lacks "$out" 'WAKE_ACK_REQUIRED'
  assert_equals 0 "$(queued_rows "$dir")" "rows left queued after --auto-ack"
  pass "an all-routine batch prints one summary and --auto-ack consumes it"
}

test_act_now_items_carry_next_action_pr_and_findings_and_block_auto_ack() {
  local dir out
  dir=$(triage_case act-now)
  write_meta "$dir" rev ship
  write_meta "$dir" shipped ship
  write_meta "$dir" broke ship
  printf 'needs-decision [key=nm-r1-review]: ask-user findings=f1 file=/x/data/rev/nm-r1-findings.txt\n' > "$dir/state/rev.status"
  printf 'done: PR https://github.com/o/r/pull/42 checks green\n' > "$dir/state/shipped.status"
  printf 'failed: pipeline rejected the push\n' > "$dir/state/broke.status"
  for t in rev shipped broke; do
    append_wake "$dir/state" signal "$t.status" "signal: $dir/state/$t.status"
  done

  out=$(run_triage "$dir" --auto-ack --no-jev) || fail "triage failed: $out"
  has "$out" '- rev | needs a decision:'
  has "$out" 'findings: /x/data/rev/nm-r1-findings.txt'
  has "$out" '- shipped | reports done with a PR | next: run bin/fm-pr-check.sh shipped https://github.com/o/r/pull/42'
  has "$out" 'pr: https://github.com/o/r/pull/42'
  has "$out" '- broke | failed: pipeline rejected the push'
  has "$out" 'not auto-acknowledged'
  has "$out" 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through'
  [ "$(queued_rows "$dir")" -gt 0 ] || fail "act-now rows were acknowledged: $out"
  pass "act-now items name the next action, PR URL, and findings file, and block --auto-ack"
}

test_unknown_state_shows_pane_lines_to_firstmate() {
  local dir out
  dir=$(triage_case unknown-pane)
  write_meta "$dir" quiet ship
  append_wake "$dir/state" stale fm-quiet "stale: fm-quiet"
  out=$(run_triage "$dir" --no-jev) || fail "triage failed: $out"
  has "$out" '- quiet | idle alert; state unknown'
  has "$out" '    pane: last tool output line'
  has "$out" "    pane: $PANE_SECRET"
  pass "an idle alert with unknown state is act-now and carries the pane's last lines"
}

test_busy_execution_reminder_is_routine_and_idle_one_is_act_now() {
  local dir fake out
  dir=$(triage_case execution-reminder)
  write_meta "$dir" runner ship
  write_meta "$dir" stopped ship
  write_meta "$dir" merging ship 'pr=https://github.com/o/r/pull/9'
  fake="$dir/fakebin/fm-wake-drain.sh"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --ack-through ] && { echo "acked through $2"; exit 0; }
printf '1\t1\tcheck\texecution:runner\tcheck: execution runner\n'
printf '1\t2\tcheck\texecution:stopped\tcheck: execution stopped\n'
printf '1\t3\tcheck\texecution:merging\tcheck: execution merging\n'
printf 'UNFINISHED EXECUTION (task, accountable owner, next action; acknowledgement is not handling):\n'
printf 'runner\tfirstmate\tverify-progress-not-launch-seed\n'
printf 'stopped\tfirstmate\tverify-idle-or-failed-owner-and-recover-or-escalate\n'
printf 'merging\tfirstmate\tverify-landing-with-configured-approval-authority\n'
printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 2 --recovery-generation g1\n' >&2
SH
  chmod +x "$fake"
  out=$(FM_WAKE_DRAIN_BIN="$fake" FM_FAKE_CREW_STATE_runner='state: working · source: pane · busy' \
    FM_FAKE_CREW_STATE_stopped='state: unknown · source: none · idle' run_triage "$dir" --auto-ack --no-jev) \
    || fail "triage failed: $out"
  has "$out" 'runner (execution reminder; worker busy (verify-progress-not-launch-seed))'
  has "$out" 'merging (execution reminder; PR https://github.com/o/r/pull/9 awaits merge authority)'
  has "$out" '- stopped | execution obligation: verify-idle-or-failed-owner-and-recover-or-escalate'
  has "$out" 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 2 --recovery-generation g1'
  pass "an execution reminder is routine while the worker is busy and act-now once it is not"
}

test_open_decisions_are_act_now_only_when_the_set_changes() {
  local dir out
  dir=$(triage_case decisions)
  write_meta "$dir" waiting ship
  printf 'needs-decision [key=pick-db]: postgres or sqlite\n' > "$dir/state/waiting.status"
  out=$(run_triage "$dir" --no-jev) || fail "first triage failed: $out"
  has "$out" '- waiting | open decision: [key=pick-db] needs-decision: postgres or sqlite'
  out=$(run_triage "$dir" --auto-ack --no-jev) || fail "second triage failed: $out"
  lacks "$out" 'ACT NOW'
  has "$out" 'OPEN DECISIONS unchanged since the last triage (1): waiting [key=pick-db]'
  printf 'needs-decision [key=pick-cache]: redis or none\n' >> "$dir/state/waiting.status"
  out=$(run_triage "$dir" --no-jev) || fail "third triage failed: $out"
  has "$out" 'open decision: [key=pick-cache]'
  lacks "$out" 'open decision: [key=pick-db]'
  pass "OPEN DECISIONS surface as act-now on change and as one unchanged line otherwise"
}

jev_response() {  # <file> <choice> <confidence>
  printf '{"answers":{"i1":{"type":"choice","choice":"%s","confidence":%s}}}\n' "$2" "$3" > "$1"
}

test_ambiguous_status_uses_jev_status_text_only_and_fails_toward_showing() {
  local dir out resp ack_out
  dir=$(triage_case jev)
  resp="$dir/response.json"
  write_meta "$dir" mate secondmate
  printf 'done: routine sync of the wiki clone finished\n' > "$dir/state/mate.status"
  : > "$dir/state/mate.turn-ended"

  append_wake "$dir/state" signal mate.status "signal: $dir/state/mate.status"
  out=$(run_triage "$dir" --no-jev) || fail "triage failed: $out"
  has "$out" '- mate | unclassified status: done: routine sync of the wiki clone finished | next: read it and decide (Jev off)'
  ack_out=$(printf '%s\n' "$out" | grep '^WAKE_ACK_REQUIRED' | sed 's/.*--ack-through \([0-9]*\) --recovery-generation \(.*\)$/\1 \2/')
  FM_STATE_OVERRIDE="$dir/state" "$DRAIN" --ack-through "${ack_out% *}" --recovery-generation "${ack_out#* }" >/dev/null 2>&1

  printf 'done: second routine sync finished\n' >> "$dir/state/mate.status"
  append_wake "$dir/state" signal mate.status "signal: $dir/state/mate.status"
  jev_response "$resp" routine 0.93
  out=$(TYPESAFE_API_KEY=ts-fake-key-for-tests FAKE_CURL_RESPONSE="$resp" run_triage "$dir" --auto-ack) || fail "triage failed: $out"
  has "$out" 'mate (status line judged routine by Jev)'
  has "$out" 'WAKE_ACKED'
  grep -F 'second routine sync finished' "$dir/curl/body" >/dev/null \
    || fail "Jev was not given the status line: $(cat "$dir/curl/body")"
  if grep -F "$PANE_SECRET" "$dir/curl/body" >/dev/null || grep -F 'last tool output' "$dir/curl/body" >/dev/null; then
    fail "pane content reached Jev"
  fi
  grep -F '"purpose":"wake-triage"' "$dir/state/jev-wake-triage.jsonl" >/dev/null || fail "no Jev audit record"
  if grep -F 'routine sync' "$dir/state/jev-wake-triage.jsonl" >/dev/null; then
    fail "the Jev audit record stored status text"
  fi

  printf 'done: third sync\n' >> "$dir/state/mate.status"
  append_wake "$dir/state" signal mate.status "signal: $dir/state/mate.status"
  jev_response "$resp" routine 0.4
  out=$(TYPESAFE_API_KEY=ts-fake-key-for-tests FAKE_CURL_RESPONSE="$resp" run_triage "$dir" --auto-ack) || fail "triage failed: $out"
  has "$out" 'next: read it and decide (Jev did not confidently call it routine)'
  has "$out" 'not auto-acknowledged'
  pass "ambiguous lines reach Jev as status text only; only a confident routine answer quiets them"
}

test_jev_failure_keeps_ambiguous_line_act_now() {
  local dir out
  dir=$(triage_case jev-fail)
  write_meta "$dir" worker ship
  printf 'note: switched approach to the streaming parser\n' > "$dir/state/worker.status"
  append_wake "$dir/state" signal worker.status "signal: $dir/state/worker.status"
  out=$(TYPESAFE_API_KEY=ts-fake-key-for-tests FAKE_CURL_FAIL=1 FAKE_CURL_RESPONSE=/dev/null run_triage "$dir" --auto-ack) \
    || fail "triage failed: $out"
  has "$out" '- worker | unclassified status: note: switched approach to the streaming parser'
  has "$out" '(Jev unavailable)'
  has "$out" 'WAKE_ACK_REQUIRED'
  pass "a failed Jev call keeps the ambiguous line act-now and blocks --auto-ack"
}

test_drain_failure_is_passed_through() {
  local dir fake out rc=0
  dir=$(triage_case drain-fail)
  fake="$dir/fakebin/fm-wake-drain.sh"
  printf '#!/usr/bin/env bash\necho "wake drain: durable wakes have invalid recovery state" >&2\nexit 1\n' > "$fake"
  chmod +x "$fake"
  out=$(FM_WAKE_DRAIN_BIN="$fake" run_triage "$dir" 2>&1) || rc=$?
  assert_equals 1 "$rc" "drain exit status"
  has "$out" 'invalid recovery state'
  has "$out" 'WAKE TRIAGE: the drain failed (exit 1)'
  pass "a failing drain is reported unchanged with its exit status"
}

test_all_routine_batch_is_summarized_and_auto_acked
test_act_now_items_carry_next_action_pr_and_findings_and_block_auto_ack
test_unknown_state_shows_pane_lines_to_firstmate
test_busy_execution_reminder_is_routine_and_idle_one_is_act_now
test_open_decisions_are_act_now_only_when_the_set_changes
test_ambiguous_status_uses_jev_status_text_only_and_fails_toward_showing
test_jev_failure_keeps_ambiguous_line_act_now
test_drain_failure_is_passed_through
