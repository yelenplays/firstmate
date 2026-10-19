#!/usr/bin/env bash
# Behavior tests for bin/fm-updates.sh: the missed-outcome backstop, the
# cleanup flags on every drain, settle before cleanup, and the morning digest.
#
# Slack is a fake slack-axi on PATH that logs every call as a JSON argument
# list and answers `draft` and `draft send` the way the real one does, so each
# case drives the real bin/fm-slack-bridge.sh and bin/fm-slack-render.mjs. The
# cases pin that a finished task is reported to #updates exactly once even when
# nobody posted it, that the supervisor's own post is never duplicated, that
# finished work is listed for cleanup on every drain until its record is gone,
# and that the digest posts once a morning in at most five lines. No case
# contacts Slack.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

UPDATES="$ROOT/bin/fm-updates.sh"
BRIDGE="$ROOT/bin/fm-slack-bridge.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-updates)
command -v node >/dev/null 2>&1 || fail "fm-updates tests need node"

NOW=1791140100
OLD=$((NOW - 3600))
FRESH=$((NOW - 60))

# make_home <name>: a scratch home with a fake slack-axi and an empty backlog.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/fakebin"
  cat > "$home/fakebin/slack-axi" <<'SH'
#!/usr/bin/env bash
node -e 'require("fs").appendFileSync(process.env.FM_TEST_SLACK_LOG, JSON.stringify(process.argv.slice(1)) + "\n")' -- "$@"
case "$1 ${2:-}" in
  "draft send")
    [ "${FM_TEST_SLACK_SEND_FAIL:-0}" = 1 ] && { echo "error: channel_not_found"; exit 1; }
    n=$(( $(cat "$FM_TEST_SLACK_LOG.n" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$n" > "$FM_TEST_SLACK_LOG.n"
    printf 'ts: "17911400000000%02d"\n' "$n"
    ;;
  "draft discard") echo "discarded: $3" ;;
  draft*)
    case "$2" in '#updates') id=C0UPDATES1 ;; '#entscheidungen') id=C0DECIDE01 ;; *) id=C0REPORT01 ;; esac
    printf 'draft: d_test0001\nchannel: "%s (%s)"\n' "$2" "$id"
    ;;
esac
SH
  chmod +x "$home/fakebin/slack-axi"
  printf '## In flight\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

write_config() {  # <home> [extra-line]...
  local home=$1
  shift
  printf '%s\n' 'report-channel=#fm-yelen' 'decisions-channel=#entscheidungen' \
    'updates-channel=#updates' 'captain-user=U0CAPTAIN1' 'language=de' "$@" > "$home/config/slack-bridge"
}

# add_task <home> <id> <title> <meta-lines> <status-line|-> [merged]
add_task() {
  local home=$1 id=$2 title=$3 meta=$4 status=$5
  printf -- '- [ ] %s - %s data/%s/report.md\n' "$id" "$title" "$id" >> "$home/data/backlog.md"
  printf 'project=/x/projects/%s\nspawn_gen=s-%s\n%s\n' "${id%%-*}" "$id" "$meta" > "$home/state/$id.meta"
  [ "$status" = - ] || printf '%s\n' "$status" > "$home/state/$id.status"
  if [ "${6:-}" = merged ]; then
    printf 'https://github.com/o/r/pull/9\n' > "$home/state/$id.pr-poll-merge-notified"
    fm_touch_epoch "$OLD" "$home/state/$id.pr-poll-merge-notified"
  fi
}

run() {  # <home> <now> <command> [args...]
  local home=$1 now=$2
  shift 2
  env FM_HOME="$home" PATH="$home/fakebin:$PATH" FM_TEST_SLACK_LOG="$home/slack.log" \
    FM_SLACK_BRIDGE_NOW="$now" FM_CHECK_TIMEOUT=30 "$@"
}

# The text of every posted draft, one JSON string per line, in order.
drafts() {  # <home>
  [ -f "$1/slack.log" ] || return 0
  node -e '
    for (const line of require("fs").readFileSync(process.argv[1], "utf-8").split("\n").filter(Boolean)) {
      const a = JSON.parse(line);
      if (a[0] === "draft" && a[1] !== "send" && a[1] !== "discard") console.log(JSON.stringify([a[1], a[2]]));
    }' "$1/slack.log"
}

draft_count() { drafts "$1" | grep -c . || true; }

local_epoch() {  # <YYYY-MM-DD HH:MM> in local time
  date -j -f '%Y-%m-%d %H:%M' "$1" +%s 2>/dev/null || date -d "$1" +%s
}

seed_fleet() {  # <home>
  local home=$1
  add_task "$home" bochum-rank "Ranking-Messung" 'kind=scout' "done [at=$OLD]: report written"
  add_task "$home" lay-hero "Neue Startseite" $'kind=ship\nmode=no-mistakes\nyolo=off\npr=https://github.com/o/lay/pull/3' \
    "done [at=$OLD]: PR https://github.com/o/lay/pull/3 checks green"
  add_task "$home" auto-ship "Auto ship" $'kind=ship\nmode=no-mistakes\nyolo=on\npr=https://github.com/o/a/pull/4' \
    "done [at=$OLD]: PR https://github.com/o/a/pull/4 checks green"
  add_task "$home" handoff-ship "Handoff ship" $'kind=ship\nmode=no-mistakes\nyolo=off' "done [at=$OLD]: implemented"
  add_task "$home" broken-task "Kaputter Import" $'kind=ship\nmode=direct-PR' "failed [at=$OLD]: tests cannot run"
  add_task "$home" mylina-live "Akzent-Test" $'kind=ship\nmode=direct-PR\nyolo=on\npr=https://github.com/o/m/pull/9' \
    "done [at=$OLD]: PR https://github.com/o/m/pull/9" merged
  add_task "$home" busy-task "Noch dran" $'kind=ship\nmode=direct-PR' "working [at=$OLD]: building"
  add_task "$home" lay "Lay mate" 'kind=secondmate' "done [at=$OLD]: idle"
}

test_backstop_reports_each_missed_outcome_once() {
  local home out
  home=$(make_home backstop)
  write_config "$home"
  seed_fleet "$home"

  out=$(run "$home" "$((OLD + 60))" "$UPDATES" scan) || fail "scan must succeed: $out"
  assert_equals "" "$out" "nothing is owed before the supervisor's grace period ends"
  out=$(run "$home" "$((OLD + 60))" "$UPDATES" tick) || fail "tick must succeed: $out"
  assert_equals "" "$out" "a tick inside the grace period posts nothing"

  out=$(run "$home" "$NOW" "$UPDATES" scan) || fail "scan must succeed: $out"
  assert_contains "$out" "unreported bochum-rank finished: Ranking-Messung" "a finished scout nobody reported is listed"
  assert_contains "$out" "unreported lay-hero ready: Neue Startseite" "an approval nobody asked for is listed"
  assert_contains "$out" "unreported broken-task stuck: Kaputter Import" "a failed task is listed as stuck"
  assert_contains "$out" "unreported mylina-live merged: Akzent-Test" "an unreported merge is listed"
  assert_equals 4 "$(printf '%s\n' "$out" | grep -c .)" \
    "auto-merge waits, a handoff without a PR, running work, and a second mate owe nothing"

  out=$(run "$home" "$NOW" "$UPDATES" tick) || fail "tick must succeed: $out"
  assert_equals 4 "$(printf '%s\n' "$out" | grep -c '^posted ')" "the tick posts every owed outcome"
  # shellcheck disable=SC2016 # JavaScript, not shell
  drafts "$home" | node -e '
    const posts = require("fs").readFileSync(0, "utf-8").split("\n").filter(Boolean).map(JSON.parse);
    const find = (s) => posts.filter(([, text]) => text.includes(s));
    const ok = (c, why) => { if (!c) { console.error(why); process.exit(1); } };
    const scout = find("Ranking-Messung");
    ok(scout.length === 1 && scout[0][0] === "#updates", "the scout result goes to #updates once");
    ok(scout[0][1] === "*✅ bochum · Ranking-Messung*\nDas Ergebnis ist fertig; frag Firstmate nach der Zusammenfassung.", "two plain German lines");
    const ask = find("Neue Startseite");
    ok(ask.length === 2 && ask[0][0] === "#fm-yelen" && ask[1][0] === "#updates", "the approval goes to the report channel and is pointed at from #updates");
    ok(ask[1][1] === "*🙋 lay · Freigabe nötig: Neue Startseite*\nAntworte dort: <#C0REPORT01>\n🔗 <https://github.com/o/lay/pull/3|PR #3>", "the #updates entry is one line, the pointer, and the link");
    ok(find("Kaputter Import hängt")[0][0] === "#updates", "a stuck task goes to #updates");
    ok(find("Akzent-Test")[0][1].startsWith("*✅ mylina · Akzent-Test*\nIst übernommen."), "the merge says it is merged");
    ok(posts.every(([, text]) => text.split("\n").length <= 3), "every post keeps the short shape");
  ' || fail "the backstop posts the short shape to the right channels"
  local before
  before=$(draft_count "$home")
  out=$(run "$home" "$NOW" "$UPDATES" tick) || fail "a second tick must succeed: $out"
  assert_equals "" "$out" "a second tick posts nothing"
  assert_equals "$before" "$(draft_count "$home")" "no outcome is posted twice"
  pass "fm-updates: the backstop reports every missed outcome exactly once"
}

test_cleanup_due_is_listed_until_closed() {
  local home out
  home=$(make_home cleanup)
  write_config "$home"
  seed_fleet "$home"
  run "$home" "$NOW" "$UPDATES" tick >/dev/null || fail "tick must succeed"
  out=$(run "$home" "$NOW" "$UPDATES" scan) || fail "scan must succeed: $out"
  assert_contains "$out" "cleanup-due bochum-rank: finished and reported" "a reported finished scout is due for cleanup"
  assert_contains "$out" "cleanup-due mylina-live: merged and reported" "a reported merge is due for cleanup"
  assert_not_contains "$out" "lay-hero" "a task waiting for approval is not cleaned up"
  assert_not_contains "$out" "broken-task" "a stuck task needs a look, not a cleanup"
  out=$(run "$home" "$((NOW + 86400))" "$UPDATES" scan) || fail "a later scan must succeed: $out"
  assert_contains "$out" "cleanup-due bochum-rank" "the flag stays until the record is gone"
  rm -f "$home/state/bochum-rank.meta"
  out=$(run "$home" "$NOW" "$UPDATES" scan) || fail "scan must succeed: $out"
  assert_not_contains "$out" "bochum-rank" "a closed task is no longer listed"

  local off
  off=$(make_home bridge-off)
  add_task "$off" bochum-rank "Ranking-Messung" 'kind=scout' "done [at=$OLD]: report written"
  out=$(run "$off" "$NOW" "$UPDATES" scan) || fail "scan without a bridge must succeed: $out"
  assert_contains "$out" "cleanup-due bochum-rank" "without Slack the chat is the report, so cleanup is due at once"
  out=$(run "$off" "$NOW" "$UPDATES" tick) || fail "tick without a bridge must succeed: $out"
  assert_equals "" "$out" "without Slack nothing is posted"
  pass "fm-updates: finished work is flagged for cleanup until its record is gone"
}

test_supervisor_post_is_never_duplicated() {
  local home out
  home=$(make_home own-post)
  write_config "$home"
  add_task "$home" mylina-live "Akzent-Test" $'kind=ship\nyolo=on\npr=https://github.com/o/m/pull/9' "done [at=$OLD]: PR" merged
  out=$(run "$home" "$FRESH" "$BRIDGE" post merged --task mylina-live --project MyLINA \
    --title "Akzent-Test ist drin" --context "Läuft ab morgen live." --url https://github.com/o/m/pull/9) \
    || fail "the supervisor's own post must succeed: $out"
  assert_contains "$out" "posted merged C0UPDATES1" "a merge goes to #updates"
  out=$(run "$home" "$FRESH" "$BRIDGE" post merged --task mylina-live --title again) || fail "a repeat must succeed: $out"
  assert_contains "$out" "already posted merged for mylina-live" "the same outcome is not posted twice"
  run "$home" "$NOW" "$BRIDGE" posted --task mylina-live merged || fail "posted names the recorded outcome"
  if run "$home" "$NOW" "$BRIDGE" posted --task mylina-live finished; then fail "another kind is not recorded"; fi
  out=$(run "$home" "$NOW" "$UPDATES" tick) || fail "tick must succeed: $out"
  assert_equals "" "$out" "the backstop leaves an outcome the supervisor already posted alone"
  assert_equals 1 "$(draft_count "$home")" "exactly one post reached Slack"
  pass "fm-updates: the supervisor's own post is never duplicated"
}

test_settle_reports_before_cleanup() {
  local home out rc=0
  home=$(make_home settle)
  write_config "$home"
  add_task "$home" bochum-rank "Ranking-Messung" 'kind=scout' "done [at=$FRESH]: report written"
  out=$(FM_TEST_SLACK_SEND_FAIL=1 run "$home" "$NOW" "$UPDATES" settle bochum-rank 2>&1) || rc=$?
  expect_code 1 "$rc" "settle fails when the report cannot be posted, so cleanup keeps the record"
  assert_contains "$out" "could not report bochum-rank" "the failure names the task"
  out=$(run "$home" "$NOW" "$UPDATES" settle bochum-rank) || fail "settle must post inside the grace period: $out"
  assert_equals "posted bochum-rank finished" "$out" "settle posts the outcome at once"
  out=$(run "$home" "$NOW" "$UPDATES" settle bochum-rank) || fail "a repeat settle must succeed: $out"
  assert_equals "" "$out" "a repeat settle posts nothing"
  out=$(run "$home" "$NOW" "$UPDATES" settle busy-task) || fail "settle of an unknown task must succeed: $out"
  assert_equals "" "$out" "a task without an outcome owes nothing"
  pass "fm-updates: settle reports a finished task before its cleanup"
}

test_bridge_check_runs_the_backstop() {
  local home out
  home=$(make_home check)
  write_config "$home"
  add_task "$home" bochum-rank "Ranking-Messung" 'kind=scout' "done [at=$OLD]: report written"
  out=$(run "$home" "$NOW" "$BRIDGE" check 2>&1) || fail "check must succeed: $out"
  assert_contains "$out" "slack: posted missed outcome(s) and digest to Slack: bochum-rank finished" \
    "a poll that posted a missed outcome says so in one line"
  out=$(run "$home" "$NOW" "$BRIDGE" check 2>&1) || fail "a second check must succeed: $out"
  # The fake slack-axi has no reader module, so inbound reports itself off;
  # the backstop part of this poll has nothing left to post.
  assert_not_contains "$out" "posted missed outcome" "the next poll posts nothing again"

  local failing
  failing=$(make_home check-fail)
  write_config "$failing"
  add_task "$failing" bochum-rank "Ranking-Messung" 'kind=scout' "done [at=$OLD]: report written"
  out=$(FM_TEST_SLACK_SEND_FAIL=1 run "$failing" "$NOW" "$BRIDGE" check 2>&1) || fail "a failing check must succeed: $out"
  assert_contains "$out" "a missed outcome could not be posted to Slack" "a failed post is reported"
  out=$(FM_TEST_SLACK_SEND_FAIL=1 run "$failing" "$NOW" "$BRIDGE" check 2>&1) || fail "a failing check must succeed: $out"
  assert_equals "" "$out" "a lasting failure is reported once, not every poll"
  pass "fm-slack-bridge: every poll runs the outcome backstop"
}

test_morning_digest_posts_once_in_five_lines() {
  local home out morning
  home=$(make_home digest)
  write_config "$home" 'digest-hour=8' 'board-url=https://deck.example.com/board'
  seed_fleet "$home"
  morning=$(local_epoch "2026-10-20 09:00")
  printf 'v1\tC0UPDATES1\t1791140000.000009\tmerged\t%s\tlay: old merge\n' "$((morning - 3600))" > "$home/state/slack-bridge.posts.seed"
  mkdir -p "$home/state/slack-bridge"
  mv "$home/state/slack-bridge.posts.seed" "$home/state/slack-bridge/posts"
  printf 'v1\tC0UPDATES1\t1791140000.000010\tlive\t%s\tmylina: live\n' "$((morning - 600))" >> "$home/state/slack-bridge/posts"
  printf 'v1\tC0UPDATES1\t1791140000.000011\tmerged\t%s\told\n' "$((morning - 3 * 86400))" >> "$home/state/slack-bridge/posts"
  # Everything owed was reported already, so this morning's tick posts only the digest.
  for pair in bochum-rank:finished lay-hero:ready broken-task:stuck mylina-live:merged; do
    printf 'v1\t%s\ts-%s\t%s\t0\tC0UPDATES1\t1791140000.000001\n' "${pair%%:*}" "${pair%%:*}" "${pair#*:}" \
      >> "$home/state/slack-bridge/outcomes"
  done

  out=$(run "$home" "$(local_epoch "2026-10-20 07:30")" "$UPDATES" tick) || fail "an early tick must succeed: $out"
  assert_not_contains "$out" digest "no digest before digest-hour"
  out=$(run "$home" "$morning" "$UPDATES" tick) || fail "the morning tick must succeed: $out"
  assert_contains "$out" "posted digest" "the digest posts after digest-hour"
  # shellcheck disable=SC2016 # JavaScript, not shell
  drafts "$home" | node -e '
    const posts = require("fs").readFileSync(0, "utf-8").split("\n").filter(Boolean).map(JSON.parse);
    const digest = posts.filter(([, text]) => text.startsWith("*☀️"));
    if (digest.length !== 1 || digest[0][0] !== "#updates") process.exit(1);
    const want = [
      "*☀️ Guten Morgen - dein Überblick*",
      "🙋 Wartet auf dich: 1 - Neue Startseite",
      "✅ Letzte 24 Stunden: 0 fertig, 1 übernommen, 1 live",
      "⏳ Läuft gerade: 3",
      "🔗 <https://deck.example.com/board|Öffnen>",
    ];
    if (digest[0][1] !== want.join("\n")) { console.error(digest[0][1]); process.exit(1); }
  ' || fail "the digest is five lines: needs-you, the last day, running work, and the board link"
  out=$(run "$home" "$((morning + 1800))" "$UPDATES" tick) || fail "a later tick must succeed: $out"
  assert_not_contains "$out" digest "the digest posts once a day"
  out=$(run "$home" "$(local_epoch "2026-10-21 14:00")" "$UPDATES" tick) || fail "an afternoon tick must succeed: $out"
  assert_not_contains "$out" digest "a missed morning is skipped rather than posted in the afternoon"
  out=$(run "$home" "$(local_epoch "2026-10-22 08:10")" "$UPDATES" digest --print) || fail "digest --print must succeed: $out"
  assert_equals 5 "$(printf '%s\n' "$out" | grep -c .)" "the printed digest has five lines"
  pass "fm-updates: the morning digest posts once a day in at most five lines"
}

test_drain_lists_report_and_close() {
  local dir out
  dir=$(make_case drain)
  mkdir -p "$dir/config" "$dir/data"
  : > "$dir/config/supervision-host-off"
  printf 'kind=scout\nspawn_gen=s1\n' > "$dir/state/bochum-rank.meta"
  printf 'done [at=%s]: report written\n' "$OLD" > "$dir/state/bochum-rank.status"
  out=$(FM_CONFIG_OVERRIDE="$dir/config" FM_DATA_OVERRIDE="$dir/data" FM_STATE_OVERRIDE="$dir/state" "$DRAIN" 2>/dev/null) \
    || fail "the drain must succeed: $out"
  assert_contains "$out" "REPORT AND CLOSE" "the drain has the report-and-close section"
  assert_contains "$out" "cleanup-due bochum-rank" "the finished scout is listed"
  out=$(FM_CONFIG_OVERRIDE="$dir/config" FM_DATA_OVERRIDE="$dir/data" FM_STATE_OVERRIDE="$dir/state" "$DRAIN" 2>/dev/null) \
    || fail "a second drain must succeed: $out"
  assert_contains "$out" "cleanup-due bochum-rank" "the drain lists it again until it is closed"
  pass "fm-wake-drain: finished work is listed on every drain until it is closed"
}

test_backstop_reports_each_missed_outcome_once
test_cleanup_due_is_listed_until_closed
test_supervisor_post_is_never_duplicated
test_settle_reports_before_cleanup
test_bridge_check_runs_the_backstop
test_morning_digest_posts_once_in_five_lines
test_drain_lists_report_and_close
