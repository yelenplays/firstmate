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
  TZ=Europe/Berlin FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    "$ROOT/bin/fm-tasks-axi.sh" "$@"
}

run_history() {
  PATH="$BASE_PATH" TZ=Europe/Berlin FM_HOME="$HOME_DIR" \
    FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" "$HELPER" "$@"
}

run_captain() {
  TZ=Europe/Berlin FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
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
  jq -e --arg id decision-one 'any(.decisions[]; .id == $id)' \
    "$HOME_DIR/data/history/days/$today.logbook.json" >/dev/null \
    || fail 'captain answer did not regenerate the Logbook immediately'
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
      and ((.open | keys | sort) == ["ids","incomplete_homes","omitted","registry_complete","running","unlisted_homes","waiting_on_you"])
      and .open.running == 2 and .open.waiting_on_you == 1
      and (.open.ids | index("main/open-queued") != null)
      and .open.omitted == [] and .open.unlisted_homes == 0
      and .open.incomplete_homes == [] and .open.registry_complete == true
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

test_unclassified_reports_and_verbatim_decisions_are_logged() {
  local today at answer path card meta_line encoded metadata
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$HOME_DIR/data/unclassified-report"
  printf '# Finished report\n' > "$HOME_DIR/data/unclassified-report/report.md"
  run_axi add unclassified-report 'A report without project metadata' --kind scout --start >/dev/null
  run_axi "done" unclassified-report --report data/unclassified-report/report.md >/dev/null

  run_axi add decision-marker 'A decision without project metadata' --kind captain --start >/dev/null
  run_captain hold decision-marker --reason 'Needs a captain answer' >/dev/null
  answer=$'Decision text before the marker.\nResolution recorded by fm-captain-hold.\nDecision text after the marker.'
  printf '%s' "$answer" > "$TMP_ROOT/marker-answer.txt"
  FM_CAPTAIN_HOLD_NOW="$at" run_captain answer decision-marker --decision-file "$TMP_ROOT/marker-answer.txt" >/dev/null
  run_history task decision-marker >/dev/null
  card="$HOME_DIR/data/history/tasks/decision-marker.md"
  meta_line=$(grep 'fm-history:task:v1' "$card")
  encoded=${meta_line#*fm-history:task:v1 }
  encoded=${encoded% -->}
  if [ "$(uname -s)" = Darwin ]; then metadata=$(printf '%s' "$encoded" | base64 -D); else metadata=$(printf '%s' "$encoded" | base64 -d); fi
  jq -e --arg answer "$answer" '
    .project == null and any(.decisions[]; .words == $answer and .project == null)
  ' <<< "$metadata" >/dev/null || fail 'the task card lost a marker-shaped captain decision or invented a project'

  run_history logbook >/dev/null
  path="$HOME_DIR/data/history/days/$today.logbook.json"
  jq -e --arg answer "$answer" '
    any(.reports[]; .id == "unclassified-report" and .project == null)
    and any(.decisions[]; .id == "decision-marker" and .project == null and .words == $answer)
  ' "$path" >/dev/null || fail 'the Logbook omitted unclassified work or truncated verbatim decision text'
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" '(unclassified)' \
    'the readable Logbook did not label a missing project safely'
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" "$answer" \
    'the readable Logbook omitted the complete captain decision'
  pass 'unclassified work and marker-shaped captain words survive task and Logbook capture'
}

test_cleanup_card_does_not_infer_merge_from_pr_url() {
  local today url card meta_line encoded metadata
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  url='https://github.com/acme/sample-repo/pull/77'
  cat > "$HOME_DIR/data/backlog.md" <<EOF
## In flight
- [ ] open-pr - A cleanup card with an open PR (repo: sample-repo) (kind: ship) <$url>

## Queued

## Done
EOF
  run_history task open-pr --completed >/dev/null
  card="$HOME_DIR/data/history/tasks/open-pr.md"
  assert_present "$card" 'completed cleanup did not write its task card'
  meta_line=$(grep 'fm-history:task:v1' "$card")
  encoded=${meta_line#*fm-history:task:v1 }
  encoded=${encoded% -->}
  if [ "$(uname -s)" = Darwin ]; then metadata=$(printf '%s' "$encoded" | base64 -D); else metadata=$(printf '%s' "$encoded" | base64 -d); fi
  jq -e --arg url "$url" '.completion.verb == "done" and .pr_url == $url' <<< "$metadata" >/dev/null \
    || fail 'the PR URL was recorded as merge evidence in the task card'

  cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  run_history logbook >/dev/null
  jq -e 'all(.landed[]; .id != "open-pr")' "$HOME_DIR/data/history/days/$today.logbook.json" >/dev/null \
    || fail 'the Logbook treated a completed cleanup card with an open PR as landed'
  pass 'cleanup preserves an open PR URL without inferring merge or landing'
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
    and (.open.ids | index("main/open-only") != null)
    and .open.omitted == []
    and ((keys | sort) == ["closed","date","decisions","generated","landed","open","reports","schema","tz"])
  ' "$path" >/dev/null || fail 'queued work was absent from the quiet-day Logbook'
  assert_contains "$output" "wrote data/history/days/$today.logbook.json" 'the queued-only Logbook was not reported as written'
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" 'Task ids: main/open-only' 'the readable Logbook omitted queued work'
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
  rm -f "$HOME_DIR/data/history/days/$today.md"
  run_history logbook > "$TMP_ROOT/frozen.out"
  cmp -s "$TMP_ROOT/before-closed.json" "$path" || fail 'a closed day was rewritten without --rebuild'
  assert_present "$HOME_DIR/data/history/days/$today.md" 'a closed-day retry did not restore its Markdown projection'
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

test_secondmate_landed_rows_reach_the_logbook() {
  local today mate url
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  mate="$TMP_ROOT/landed-mate"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '%s\n' 'registered-mate' > "$mate/.fm-secondmate-home"
  printf '%s\n' '# Registered secondmate fixture' > "$mate/AGENTS.md"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  url='https://github.com/acme/sample-repo/pull/52'
  TZ=Europe/Berlin FM_HOME="$mate" FM_DATA_OVERRIDE="$mate/data" \
    "$ROOT/bin/fm-tasks-axi.sh" add mate-landed 'A secondmate landed task' --kind ship --repo sample-repo --start >/dev/null
  TZ=Europe/Berlin FM_HOME="$mate" FM_DATA_OVERRIDE="$mate/data" \
    "$ROOT/bin/fm-tasks-axi.sh" "done" mate-landed --pr "$url" >/dev/null
  printf '%s\n' "- registered-mate - Delegated work (home: $mate; scope: landed work; projects: sample-repo; added $today)" \
    > "$HOME_DIR/data/secondmates.md"
  FM_HOME="$mate" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$mate/data" FM_STATE_OVERRIDE="$mate/state" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$mate/state/home-summary.json" \
    || fail 'the secondmate landed summary could not be prepared'
  run_history logbook >/dev/null
  jq -e --arg url "$url" '
    any(.landed[]; .id == "mate-landed" and .home == "registered-mate"
      and .project == "sample-repo" and .pr_url == $url and .via == "pull_request")
  ' "$HOME_DIR/data/history/days/$today.logbook.json" >/dev/null \
    || fail 'the Logbook rejected terminal secondmate landed evidence without a state field'
  pass 'secondmate landed rows are retained from their terminal producer inventory'
}

test_secondmate_open_inventory_omissions_and_identity_are_preserved() {
  local today mate index
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  run_axi add duplicate-open 'A main-home task with a shared id' --kind ship --repo sample-repo >/dev/null
  mate="$TMP_ROOT/open-mate"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '%s\n' 'registered-mate' > "$mate/.fm-secondmate-home"
  printf '%s\n' '# Registered secondmate fixture' > "$mate/AGENTS.md"
  {
    printf '## In flight\n\n## Queued\n'
    printf -- '- [ ] duplicate-open - A secondmate task with the same id (repo: sample-repo) (kind: ship) (since %s)\n' "$today"
    index=1
    while [ "$index" -le 20 ]; do
      printf -- '- [ ] mate-queued-%02d - A queued secondmate task (repo: sample-repo) (kind: ship)\n' "$index"
      index=$((index + 1))
    done
    printf '\n## Done\n'
  } > "$mate/data/backlog.md"
  printf '%s\n' "- registered-mate - Delegated work (home: $mate; scope: queued work; projects: sample-repo; added $today)" \
    > "$HOME_DIR/data/secondmates.md"
  FM_HOME="$mate" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$mate/data" FM_STATE_OVERRIDE="$mate/state" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$mate/state/home-summary.json" \
    || fail 'the secondmate open-work summary could not be prepared'
  FM_SNAPSHOT_SECONDMATE_QUEUED=20 run_history logbook >/dev/null
  jq -e '
    ([.open.ids[] | select(endswith("/duplicate-open"))] | length) == 2
    and (.open.ids | index("main/duplicate-open") != null)
    and (.open.ids | index("registered-mate/duplicate-open") != null)
    and (.open.ids | length) == 21
    and any(.open.omitted[]; .home == "registered-mate" and .surface == "queued" and .count == 1)
  ' "$HOME_DIR/data/history/days/$today.logbook.json" >/dev/null \
    || fail 'the Logbook collapsed home-scoped ids or lost capped secondmate work'
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" \
    'Not individually listed: 1 queued item(s) from registered-mate' \
    'the readable Logbook omitted the secondmate truncation count'
  pass 'Logbook open work preserves home identity and explicitly reports capped rows'
}

test_secondmate_truncated_and_unknown_home_coverage_is_disclosed() {
  local today unknown_home omitted_home home
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  unknown_home="$TMP_ROOT/mate-01-unknown"
  omitted_home="$TMP_ROOT/mate-02-omitted"
  for home in "$unknown_home" "$omitted_home"; do
    mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/bin"
    cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
    printf '%s\n' "${home##*/}" > "$home/.fm-secondmate-home"
    printf '%s\n' '# Registered secondmate fixture' > "$home/AGENTS.md"
    cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  done
  cat > "$omitted_home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] omitted-home-task - Work from a home beyond the snapshot cap (repo: sample-repo) (kind: ship)

## Done
EOF
  printf '%s\n' \
    "- mate-01-unknown - Unknown summary (home: $unknown_home; scope: queued work; projects: sample-repo; added $today)" \
    "- mate-02-omitted - Omitted summary (home: $omitted_home; scope: queued work; projects: sample-repo; added $today)" \
    > "$HOME_DIR/data/secondmates.md"
  FM_SNAPSHOT_SECONDMATES=1 run_history logbook >/dev/null
  jq -e '
    .open.registry_complete == true
    and .open.unlisted_homes == 1
    and .open.incomplete_homes == ["mate-01-unknown"]
    and (.open.ids | index("mate-02-omitted/omitted-home-task") == null)
  ' "$HOME_DIR/data/history/days/$today.logbook.json" >/dev/null \
    || fail 'the Logbook hid omitted homes or an unknown home inventory'
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" \
    'Secondmate home summaries not sampled: 1' 'the readable Logbook omitted snapshot-level home truncation'
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" \
    'Open-work inventory incomplete for: mate-01-unknown' 'the readable Logbook omitted an unknown home inventory'
  pass 'the Logbook discloses omitted secondmates and unknown home inventories'
}

test_logbook_markdown_retries_when_json_is_unchanged() {
  local today path markdown
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  add_done_pr landed-pr 'A landed item' sample-repo 'https://github.com/acme/sample-repo/pull/63'
  run_history logbook >/dev/null
  path="$HOME_DIR/data/history/days/$today.logbook.json"
  markdown="$HOME_DIR/data/history/days/$today.md"
  cp "$path" "$TMP_ROOT/unchanged-logbook.json"
  rm "$markdown"
  run_history logbook > "$TMP_ROOT/retry-logbook.out"
  cmp -s "$TMP_ROOT/unchanged-logbook.json" "$path" || fail 'a Markdown-only retry rewrote unchanged JSON'
  assert_present "$markdown" 'a retry did not recreate the missing Markdown projection'
  assert_contains "$(<"$markdown")" 'Landed (1)' 'a retry recreated Markdown without the current Logbook'
  assert_contains "$(<"$TMP_ROOT/retry-logbook.out")" 'Logbook unchanged' 'the retry did not retain JSON idempotence'
  pass 'daily Markdown is synchronized even when its JSON source is unchanged'
}

test_closed_older_logbook_retries_markdown_sync() {
  local today previous path
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  previous=$(day_before)
  mkdir -p "$HOME_DIR/data/history/days"
  path="$HOME_DIR/data/history/days/$previous.logbook.json"
  jq -n --arg date "$previous" '
    {schema:"fm-logbook.v1",date:$date,tz:"Europe/Berlin",closed:true,generated:"2026-01-01T00:00:00.000Z",
      landed:[{id:"prior-landed",project:"sample",title:"Prior day result",kind:"ship",mode:"no-mistakes",via:"local",pr_url:null,home:"main",order:1}],
      reports:[],decisions:[],open:{running:0,waiting_on_you:0,ids:[],omitted:[]}}
  ' > "$path"
  chmod 600 "$path"
  run_history logbook --date "$today" >/dev/null
  assert_contains "$(<"$HOME_DIR/data/history/days/$previous.md")" 'Prior day result' \
    'a retry skipped Markdown synchronization for an already-closed day'
  pass 'already-closed older Logbooks retry their Markdown projection'
}

test_explicit_closed_day_retries_markdown_sync() {
  local previous path
  fresh_home
  previous=$(day_before)
  mkdir -p "$HOME_DIR/data/history/days"
  path="$HOME_DIR/data/history/days/$previous.logbook.json"
  jq -n --arg date "$previous" '
    {schema:"fm-logbook.v1",date:$date,tz:"Europe/Berlin",closed:true,generated:"2026-01-01T00:00:00.000Z",
      landed:[],reports:[],decisions:[],open:{running:0,waiting_on_you:0,ids:[],omitted:[]}}
  ' > "$path"
  chmod 600 "$path"
  run_history logbook --date "$previous" >/dev/null
  assert_present "$HOME_DIR/data/history/days/$previous.md" \
    'an explicit closed-day retry did not restore its Markdown projection'
  pass 'explicit retries synchronize Markdown for an already-closed day'
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
  jq -e 'any(.open.ids[]; . == "registered-mate/mate-queued")' "$HOME_DIR/data/history/days/$today.logbook.json" >/dev/null \
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
test_unclassified_reports_and_verbatim_decisions_are_logged
test_cleanup_card_does_not_infer_merge_from_pr_url
test_queued_only_day_writes_a_logbook
test_captured_markers_remain_content_when_logbook_is_written
test_closed_day_requires_explicit_rebuild
test_first_later_day_closes_the_previous_logbook
test_secondmate_landed_rows_reach_the_logbook
test_secondmate_open_inventory_omissions_and_identity_are_preserved
test_secondmate_truncated_and_unknown_home_coverage_is_disclosed
test_logbook_markdown_retries_when_json_is_unchanged
test_closed_older_logbook_retries_markdown_sync
test_explicit_closed_day_retries_markdown_sync
test_registered_secondmate_queued_work_is_open
test_secondmate_home_is_the_project_fallback
