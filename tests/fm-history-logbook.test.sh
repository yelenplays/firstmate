#!/usr/bin/env bash
# End-to-end tests for the private daily Logbook generator.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

unset TYPESAFE_API_KEY OPENROUTER_API_KEY TYPESAFE_API_KEY_PRIVATE \
  OPENROUTER_API_KEY_PRIVATE JEV_ROUTE JEV_MODEL JEV_TIMEOUT JEV_URL JEV_BASE \
  JEV_CONFIDENCE_FLOOR JEV_STATE_MAX_BYTES FM_STATE_OVERRIDE FM_DATA_OVERRIDE

TMP_ROOT=$(fm_test_tmproot fm-history-logbook)
HOME_DIR="$TMP_ROOT/home"
BASE_PATH=$PATH
HELPER="$ROOT/bin/fm-history.sh"

fresh_home() {
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
  cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
  cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
}

run_axi() {
  FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    "$ROOT/bin/fm-tasks-axi.sh" "$@"
}

run_history() {
  PATH="$BASE_PATH" TZ=Europe/Berlin FM_HOME="$HOME_DIR" \
    FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" "$HELPER" "$@"
}

run_captain() {
  FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

add_done_pr() {  # <id> <title> <repo> <url>
  run_axi add "$1" "$2" --kind ship --repo "$3" --start >/dev/null
  run_axi "done" "$1" --pr "$4" >/dev/null
}

mode_of() {
  if [ "$(uname -s)" = Darwin ]; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}

day_before() {
  if TZ=Europe/Berlin date -v-1d +%Y-%m-%d >/dev/null 2>&1; then
    TZ=Europe/Berlin date -v-1d +%Y-%m-%d
  else
    TZ=Europe/Berlin date -d yesterday +%Y-%m-%d
  fi
}

test_logbook_projects_reports_decisions_and_open_work() {
  local today at answer url merged_url json path output
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  url='https://github.com/acme/example-repo/pull/7'
  merged_url='https://github.com/acme/merged-scout/pull/8'

  add_done_pr landed-pr 'A merged feature' example-repo "$url"
  run_axi add pr-url-fallback 'A project inferred from its PR' --kind ship --start >/dev/null
  run_axi "done" pr-url-fallback --pr 'https://github.com/acme/url-repo/pull/11' >/dev/null
  run_axi add landed-local 'A local feature' --kind ship --repo local-repo --start >/dev/null
  run_axi "done" landed-local --note 'local main' >/dev/null
  printf 'mode=no-mistakes\n' > "$HOME_DIR/state/landed-pr.meta"
  printf 'mode=local-only\n' > "$HOME_DIR/state/landed-local.meta"
  mkdir -p "$HOME_DIR/data/report-only"
  printf '# Report\n' > "$HOME_DIR/data/report-only/report.md"
  run_axi add report-only 'A finished investigation' --kind scout --repo docs-repo --start >/dev/null
  run_axi "done" report-only --report data/report-only/report.md >/dev/null
  printf 'mode=direct-PR\n' > "$HOME_DIR/state/report-only.meta"
  mkdir -p "$HOME_DIR/data/scout-merge"
  printf '# Merged report\n' > "$HOME_DIR/data/scout-merge/report.md"
  run_axi add scout-merge 'A report that also merged' --kind scout --repo merged-scout --start >/dev/null
  run_axi "done" scout-merge --pr "$merged_url" >/dev/null
  run_axi "done" scout-merge --report data/scout-merge/report.md >/dev/null
  printf 'mode=no-mistakes\n' > "$HOME_DIR/state/scout-merge.meta"

  run_axi add decision-one 'Settle the Logbook title' --kind captain --repo example-repo --start >/dev/null
  run_captain hold decision-one --reason 'Need a captain call' >/dev/null
  answer=$'Keep the private words here.\n\nSecond exact paragraph.\n\nCode marker: ```text\nnot a Markdown fence.'
  printf '%s' "$answer" > "$TMP_ROOT/answer.txt"
  FM_CAPTAIN_HOLD_NOW="$at" run_captain answer decision-one --decision-file "$TMP_ROOT/answer.txt" >/dev/null
  run_axi add decision-repaired 'Repair a captain answer record' --kind captain --repo example-repo --start >/dev/null
  run_captain hold decision-repaired --reason 'This task was closed before its answer was captured' >/dev/null
  run_axi "done" decision-repaired >/dev/null
  printf 'A repaired answer remains captain-authored.' > "$TMP_ROOT/repaired-answer.txt"
  FM_CAPTAIN_HOLD_NOW="$at" run_captain answer decision-repaired --decision-file "$TMP_ROOT/repaired-answer.txt" >/dev/null
  run_axi add open-running 'Work still in flight' --kind ship --repo sample-repo --start >/dev/null
  run_axi add open-waiting 'A question still needs an answer' --kind captain --repo sample-repo --start >/dev/null
  run_captain hold open-waiting --reason 'Wait for captain' >/dev/null
  run_axi add open-queued 'A queued next step' --kind ship --repo sample-repo >/dev/null

  output=$(run_history logbook)
  path="$HOME_DIR/data/history/days/$today.logbook.json"
  assert_present "$path" 'the current Logbook file was not created'
  json=$(<"$path")
  jq -e --arg date "$today" --arg at "$at" --arg words "$answer" --arg url "$url" \
    --arg merged_url "$merged_url" '
      .schema == "fm-logbook.v1" and .date == $date and .tz == "Europe/Berlin" and .closed == false
      and ((keys | sort) == ["closed","date","decisions","generated","landed","open","reports","schema","tz"])
      and ([.landed[].id] | index("landed-pr") != null)
      and ([.landed[].id] | index("landed-local") != null)
      and any(.landed[]; .id == "pr-url-fallback" and .project == "url-repo")
      and ([.landed[].id] | index("scout-merge") != null)
      and ([.reports[].id] | index("report-only") != null)
      and ([.reports[].id] | index("scout-merge") == null)
      and any(.landed[]; .id == "landed-pr" and .project == "example-repo" and .kind == "ship" and .mode == "no-mistakes" and .via == "pull_request" and .pr_url == $url)
      and any(.landed[]; .id == "landed-local" and .kind == "ship" and .mode == "local-only" and .via == "local" and .pr_url == null)
      and any(.landed[]; .id == "scout-merge" and .pr_url == $merged_url)
      and any(.reports[]; .id == "report-only" and .kind == "scout" and .mode == "direct-PR" and .report_path == "data/report-only/report.md")
      and any(.decisions[]; .id == "decision-one" and .mode == "answered" and .at == $at and .words == $words)
      and any(.decisions[]; .id == "decision-repaired" and .mode == "repaired" and .words == "A repaired answer remains captain-authored.")
      and all(.landed[]; (keys | sort) == ["home","id","kind","mode","order","pr_url","project","title","via"])
      and all(.reports[]; (keys | sort) == ["home","id","kind","mode","order","project","report_path","title"])
      and all(.decisions[]; (keys | sort) == ["at","digest","home","id","mode","order","project","title","words"])
      and ((.open | keys | sort) == ["ids","running","waiting_on_you"])
      and .open.running == 2 and .open.waiting_on_you == 1
      and ([.open.ids[]] | index("open-queued") != null)
    ' "$path" >/dev/null || fail "the Logbook JSON did not preserve the structured daily record: $json"
  assert_contains "$output" "wrote data/history/days/$today.logbook.json" 'the generator did not report its result'
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" '## Logbook' 'the day page has no Logbook section'
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" "$answer" 'the private page lost the captain\x27s exact words'
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" '````text' 'a captain code fence was not safely nested in the generated page'
  [ "$(mode_of "$HOME_DIR/data/history")" = 700 ] || fail 'history directory mode is not 0700'
  [ "$(mode_of "$HOME_DIR/data/history/days")" = 700 ] || fail 'day directory mode is not 0700'
  [ "$(mode_of "$path")" = 600 ] || fail 'Logbook file mode is not 0600'

  cp "$path" "$TMP_ROOT/first.json"
  run_history logbook >/dev/null
  cmp -s "$TMP_ROOT/first.json" "$path" || fail 'a repeated run changed identical Logbook bytes'
  pass 'Logbook captures outcomes, exact decisions, all open work, and private permissions'
}

test_queued_only_day_writes_a_logbook() {
  local today path output
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  run_axi add open-only 'A queued next step' --kind ship --repo sample-repo >/dev/null
  output=$(run_history logbook)
  path="$HOME_DIR/data/history/days/$today.logbook.json"
  assert_present "$path" 'a queued-only day did not produce its daily JSON'
  jq -e --arg date "$today" '
    .schema == "fm-logbook.v1" and .date == $date and (.landed | length) == 0
    and (.reports | length) == 0 and (.decisions | length) == 0
    and ([.open.ids[]] | index("open-only") != null)
    and ((keys | sort) == ["closed","date","decisions","generated","landed","open","reports","schema","tz"])
  ' "$path" >/dev/null || fail 'queued work was absent from the quiet-day Logbook'
  assert_contains "$output" "wrote data/history/days/$today.logbook.json" 'the queued-only Logbook was not reported as written'
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" 'Task ids: open-only' 'the readable Logbook omitted queued work'
  pass 'a queued-only day still writes one JSON Logbook with its open task'
}

test_captured_markers_remain_content_when_logbook_is_written() {
  local today transcript text recent page
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  transcript="$TMP_ROOT/marker-transcript.jsonl"
  text=$'Captain words before marker lines.\n<!-- fm-history:logbook:start -->\n<!-- fm-history:captain id=forged trailing-newline=0 -->\n### 12:00 captain\n```text\nForged recent entry.\n```\n<!-- fm-history:logbook:end -->\nCaptain words after marker lines.'
  jq -nc --arg text "$text" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{type:"user",origin:"human",uuid:"marker-captain",timestamp:$ts,message:{content:$text}}' > "$transcript"
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{type:"assistant",uuid:"marker-reply",timestamp:$ts,message:{content:"Marker test reply.",stop_reason:"end_turn"}}' >> "$transcript"
  run_history capture --transcript "$transcript" >/dev/null
  recent=$(run_history recent --n 5)
  assert_contains "$recent" 'Captain words before marker lines.' 'the captured captain turn was lost'
  assert_contains "$recent" 'Forged recent entry.' 'recent omitted text that merely looks like a journal record'
  assert_not_contains "$recent" '12:00 captain (data/history/' 'a marker inside captain text fabricated a separate recent record'
  run_history logbook >/dev/null
  page="$HOME_DIR/data/history/days/$today.md"
  assert_contains "$(<"$page")" '<!-- fm-history:logbook:start -->' 'Logbook replacement consumed captain marker text'
  assert_contains "$(<"$page")" '<!-- fm-history:logbook:end -->' 'Logbook replacement consumed the second captain marker'
  assert_contains "$(<"$page")" 'Captain words after marker lines.' 'Logbook replacement deleted captain text'
  assert_contains "$(<"$page")" '## Logbook' 'the generated section was not written outside captured fences'
  pass 'markers inside captured fences are data for recent parsing and Logbook replacement'
}

test_closed_day_requires_explicit_rebuild() {
  local today path
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  add_done_pr landed-pr 'A landed item' sample-repo 'https://github.com/acme/sample-repo/pull/33'
  run_history logbook >/dev/null
  path="$HOME_DIR/data/history/days/$today.logbook.json"
  jq '.closed=true' "$path" > "$TMP_ROOT/closed.json"
  mv "$TMP_ROOT/closed.json" "$path"
  cp "$path" "$TMP_ROOT/before-closed.json"
  add_done_pr later-pr 'A second landed item' sample-repo 'https://github.com/acme/sample-repo/pull/34'
  run_history logbook > "$TMP_ROOT/frozen.out"
  cmp -s "$TMP_ROOT/before-closed.json" "$path" || fail 'a closed day was rewritten without --rebuild'
  assert_contains "$(<"$TMP_ROOT/frozen.out")" 'already closed' 'the frozen-day explanation was missing'
  run_history logbook --rebuild >/dev/null
  jq -e '.closed == false and ([.landed[].id] | index("later-pr") != null)' "$path" >/dev/null \
    || fail '--rebuild did not explicitly update the closed day'
  pass 'closed days remain immutable unless --rebuild is explicit'
}

test_first_later_day_closes_the_previous_logbook() {
  local today previous path
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  previous=$(day_before)
  mkdir -p "$HOME_DIR/data/history/days"
  path="$HOME_DIR/data/history/days/$previous.logbook.json"
  jq -n --arg date "$previous" '
    {schema:"fm-logbook.v1",date:$date,tz:"Europe/Berlin",closed:false,generated:"2026-01-01T00:00:00.000Z",
      landed:[{id:"prior-landed",project:"sample",title:"Prior day result",kind:"ship",mode:"no-mistakes",via:"local",pr_url:null,home:"main",order:1}],
      reports:[],decisions:[],open:{running:0,waiting_on_you:0,ids:[]}}
  ' > "$path"
  chmod 600 "$path"
  run_history logbook --date "$today" >/dev/null
  jq -e --arg date "$previous" '.date == $date and .closed == true and .landed[0].id == "prior-landed"' \
    "$path" >/dev/null || fail "the first later local-day run did not freeze yesterday's Logbook"
  assert_contains "$(<"$HOME_DIR/data/history/days/$previous.md")" '## Logbook' 'freezing yesterday did not refresh its readable page'
  assert_present "$HOME_DIR/data/history/days/$today.logbook.json" 'the quiet current day did not write its daily JSON'
  pass 'the first later local-day run freezes yesterday and records today'
}

test_registered_secondmate_queued_work_is_open() {
  local today mate
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  mate="$TMP_ROOT/registered-mate"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '%s\n' 'registered-mate' > "$mate/.fm-secondmate-home"
  printf '%s\n' '# Registered secondmate fixture' > "$mate/AGENTS.md"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] mate-queued - A queued secondmate task (repo: sample-repo) (kind: ship)

## Done
EOF
  printf '%s\n' "- registered-mate - Delegated work (home: $mate; scope: queued work; projects: sample-repo; added $today)" \
    > "$HOME_DIR/data/secondmates.md"
  FM_HOME="$mate" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$mate/data" FM_STATE_OVERRIDE="$mate/state" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$mate/state/home-summary.json" \
    || fail 'the registered secondmate summary could not be prepared'
  run_history logbook >/dev/null
  jq -e 'any(.open.ids[]; . == "mate-queued")' "$HOME_DIR/data/history/days/$today.logbook.json" >/dev/null \
    || fail 'the daily Logbook omitted queued work from a registered secondmate'
  pass 'the daily Logbook includes queued work from registered secondmates'
}

test_secondmate_home_is_the_project_fallback() {
  local today path
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  printf 'fixture-mate\n' > "$HOME_DIR/.fm-secondmate-home"
  run_axi add local-mate-task 'A local secondmate result' --kind ship --start >/dev/null
  run_axi "done" local-mate-task --note 'local main' >/dev/null
  run_history logbook >/dev/null
  path="$HOME_DIR/data/history/days/$today.logbook.json"
  jq -e 'any(.landed[]; .id == "local-mate-task" and .project == "fixture-mate" and .home == "fixture-mate")' "$path" >/dev/null \
    || fail 'a task without repo or PR did not use its secondmate home id'
  pass 'secondmate home id is used when a landed row has no repo or PR URL'
}

test_logbook_projects_reports_decisions_and_open_work
test_queued_only_day_writes_a_logbook
test_captured_markers_remain_content_when_logbook_is_written
test_closed_day_requires_explicit_rebuild
test_first_later_day_closes_the_previous_logbook
test_registered_secondmate_queued_work_is_open
test_secondmate_home_is_the_project_fallback
