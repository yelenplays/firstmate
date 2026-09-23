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
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_LOG="$TMP_ROOT/jev"
FAKE_RESPONSE="$TMP_ROOT/response.json"
BASE_PATH=$PATH
HELPER="$ROOT/bin/fm-history.sh"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "${FAKE_CURL_LOG:?}"
cat > "$FAKE_CURL_LOG/request.json"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || :
printf 'x\n' >> "$FAKE_CURL_LOG/calls"
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '200'
SH
chmod +x "$FAKEBIN/curl"

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
  PATH="$FAKEBIN:$BASE_PATH" TZ=Europe/Berlin FM_HOME="$HOME_DIR" \
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

set_response() {  # <choice> <confidence> <probabilities-json>
  jq -n --arg choice "$1" --argjson confidence "$2" --argjson probabilities "$3" \
    '{model:"jev-test",answers:{highlight:{type:"choice",choice:$choice,confidence:$confidence,probabilities:$probabilities}}}' \
    > "$FAKE_RESPONSE"
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

  output=$(run_history logbook)
  path="$HOME_DIR/data/history/days/$today.logbook.json"
  assert_present "$path" 'the current Logbook file was not created'
  json=$(<"$path")
  jq -e --arg date "$today" --arg at "$at" --arg words "$answer" --arg url "$url" \
    --arg merged_url "$merged_url" '
      .schema == "fm-logbook.v1" and .date == $date and .tz == "Europe/Berlin" and .closed == false
      and ((keys | sort) == ["closed","date","decisions","generated","highlight","landed","open","reports","schema","tz"])
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
    ' "$path" >/dev/null || fail "the Logbook JSON did not preserve the structured daily record: $json"
  assert_contains "$output" "wrote data/history/days/$today.logbook.json" 'the generator did not report its result'
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" '## Logbook' 'the day page has no Logbook section'
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" '### Highlight' 'the selected daily highlight is not visible on the page'
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" "$answer" 'the private page lost the captain\x27s exact words'
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" '````text' 'a captain code fence was not safely nested in the generated page'
  [ "$(mode_of "$HOME_DIR/data/history")" = 700 ] || fail 'history directory mode is not 0700'
  [ "$(mode_of "$HOME_DIR/data/history/days")" = 700 ] || fail 'day directory mode is not 0700'
  [ "$(mode_of "$path")" = 600 ] || fail 'Logbook file mode is not 0600'

  cp "$path" "$TMP_ROOT/first.json"
  run_history logbook >/dev/null
  cmp -s "$TMP_ROOT/first.json" "$path" || fail 'a repeated run changed identical Logbook bytes'
  pass 'Logbook captures landed work, reports, exact answers, open work, and private permissions'
}

test_jev_receives_only_allowed_candidates_and_reuses_the_daily_choice() {
  local today url1 url2 record request
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  url1='https://github.com/acme/private-repo/pull/17'
  url2='https://github.com/acme/another-repo/pull/18'
  add_done_pr landed-pr 'A private-title marker landed' private-repo "$url1"
  add_done_pr another-pr 'Another title marker' another-repo "$url2"
  mkdir -p "$HOME_DIR/data/report-one"
  printf '# private report body marker\n' > "$HOME_DIR/data/report-one/report.md"
  run_axi add report-one 'A report title marker' --kind scout --repo docs-repo --start >/dev/null
  run_axi "done" report-one --report data/report-one/report.md >/dev/null
  run_axi add decision-one 'A private decision title marker' --kind captain --repo sample-repo --start >/dev/null
  run_captain hold decision-one --reason 'A private hold reason marker' >/dev/null
  printf 'Captain words must stay local marker.' > "$TMP_ROOT/answer.txt"
  FM_CAPTAIN_HOLD_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)" run_captain answer decision-one --decision-file "$TMP_ROOT/answer.txt" >/dev/null
  jq -n '{"landed-pr":0.05,"another-pr":0.05,"report-one":0.8,"decision-one":0.05,"none?":0.05}' > "$TMP_ROOT/probabilities.json"
  set_response report-one 0.8 "$(<"$TMP_ROOT/probabilities.json")"
  rm -rf "$FAKE_LOG"
  PATH="$FAKEBIN:$BASE_PATH" FAKE_CURL_LOG="$FAKE_LOG" FAKE_CURL_RESPONSE="$FAKE_RESPONSE" \
    TYPESAFE_API_KEY='test-api-key-not-for-request-body' JEV_URL='https://jev.invalid/test' \
    TZ=Europe/Berlin FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$HELPER" logbook >/dev/null
  record="$HOME_DIR/data/history/days/$today.logbook.json"
  jq -e '.highlight.id == "report-one" and .highlight.by == "jev" and .highlight.confidence == 0.8' "$record" >/dev/null \
    || fail 'a confident offered Jev choice did not become the highlight'
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" 'A report title marker (docs-repo) - task report-one' \
    'the selected Jev highlight is not rendered into the day page'
  request=$(<"$FAKE_LOG/request.json")
  assert_not_contains "$request" 'Captain words must stay local marker' 'captain decision words reached Jev'
  assert_not_contains "$request" 'private report body marker' 'report body reached Jev'
  assert_not_contains "$request" "$url1" 'a PR URL reached Jev'
  assert_not_contains "$request" 'data/report-one/report.md' 'a report path reached Jev'
  assert_not_contains "$request" 'private hold reason marker' 'a hold reason reached Jev'
  assert_not_contains "$request" 'test-api-key-not-for-request-body' 'the API key reached Jev request content'
  jq -e '(.state | keys) == ["entries"] and all(.state.entries[]; (keys | sort) == ["id","kind","title"])' \
    "$FAKE_LOG/request.json" >/dev/null || fail 'Jev received fields beyond ids, kinds, and titles'
  [ "$(wc -l < "$FAKE_LOG/calls" | tr -d ' ')" = 1 ] || fail 'the first daily highlight did not make exactly one Jev call'

  cp "$record" "$TMP_ROOT/first.json"
  PATH="$FAKEBIN:$BASE_PATH" FAKE_CURL_LOG="$FAKE_LOG" FAKE_CURL_RESPONSE="$FAKE_RESPONSE" \
    TYPESAFE_API_KEY='test-api-key-not-for-request-body' JEV_URL='https://jev.invalid/test' \
    TZ=Europe/Berlin FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$HELPER" logbook >/dev/null
  cmp -s "$TMP_ROOT/first.json" "$record" || fail 'the cached same-day highlight changed the JSON bytes'
  [ "$(wc -l < "$FAKE_LOG/calls" | tr -d ' ')" = 1 ] || fail 'the unchanged candidate set caused a second Jev call'

  perl -0pi -e 's/A private-title marker landed/A changed private-title marker landed/' "$HOME_DIR/data/backlog.md"
  PATH="$FAKEBIN:$BASE_PATH" FAKE_CURL_LOG="$FAKE_LOG" FAKE_CURL_RESPONSE="$FAKE_RESPONSE" \
    TYPESAFE_API_KEY='test-api-key-not-for-request-body' JEV_URL='https://jev.invalid/test' \
    TZ=Europe/Berlin FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$HELPER" logbook >/dev/null
  [ "$(wc -l < "$FAKE_LOG/calls" | tr -d ' ')" = 2 ] || fail 'changing an offered title reused a stale Jev choice'
  jq -e '.highlight.id == "report-one" and .highlight.by == "jev"' "$record" >/dev/null \
    || fail 'the fresh candidate-set decision was not recorded'
  pass 'Jev sees only allowed ids, kinds, and titles, and caches by the full candidate set'
}

test_low_confidence_uses_deterministic_rule() {
  local today url1 url2 fallback choice probabilities
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  url1='https://github.com/acme/first-repo/pull/1'
  url2='https://github.com/acme/second-repo/pull/2'
  add_done_pr first-pr 'First landed item' first-repo "$url1"
  add_done_pr second-pr 'Second landed item' second-repo "$url2"
  run_history logbook >/dev/null
  fallback=$(jq -r '.highlight.id' "$HOME_DIR/data/history/days/$today.logbook.json")
  if [ "$fallback" = first-pr ]; then choice=second-pr; else choice=first-pr; fi
  probabilities=$(jq -nc --arg choice "$choice" --arg fallback "$fallback" \
    '{($choice):0.69,($fallback):0.26,"none?":0.05}')
  set_response "$choice" 0.69 "$probabilities"
  rm -rf "$FAKE_LOG"
  PATH="$FAKEBIN:$BASE_PATH" FAKE_CURL_LOG="$FAKE_LOG" FAKE_CURL_RESPONSE="$FAKE_RESPONSE" \
    TYPESAFE_API_KEY='test-api-key' JEV_URL='https://jev.invalid/test' \
    TZ=Europe/Berlin FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$HELPER" logbook >/dev/null
  jq -e --arg fallback "$fallback" '.highlight.id == $fallback and .highlight.by == "rule"' \
    "$HOME_DIR/data/history/days/$today.logbook.json" >/dev/null \
    || fail 'a below-floor Jev choice bypassed the deterministic fallback'
  pass 'a below-floor Jev choice falls back to the first landed pull request'
}

test_quiet_day_does_not_write_a_zero_logbook() {
  local today
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  run_axi add open-only 'Open work is not a daily event' --kind ship --repo sample-repo --start >/dev/null
  run_history logbook > "$TMP_ROOT/quiet.out"
  assert_contains "$(<"$TMP_ROOT/quiet.out")" 'quiet day; no Logbook written' 'a quiet day was not reported as absent'
  assert_absent "$HOME_DIR/data/history/days/$today.logbook.json" 'a quiet day wrote an empty Logbook file'
  pass 'a quiet day remains absent rather than publishing zero activity'
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
      reports:[],decisions:[],open:{running:0,waiting_on_you:0,ids:[]},highlight:{id:"prior-landed",by:"rule",confidence:null}}
  ' > "$path"
  chmod 600 "$path"
  run_history logbook --date "$today" >/dev/null
  jq -e --arg date "$previous" '.date == $date and .closed == true and .landed[0].id == "prior-landed"' \
    "$path" >/dev/null || fail "the first later local-day run did not freeze yesterday's Logbook"
  assert_contains "$(<"$HOME_DIR/data/history/days/$previous.md")" '## Logbook' 'freezing yesterday did not refresh its readable page'
  assert_absent "$HOME_DIR/data/history/days/$today.logbook.json" 'a quiet current day wrote an empty Logbook'
  pass 'the first later local-day run freezes the preceding Logbook'
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
test_jev_receives_only_allowed_candidates_and_reuses_the_daily_choice
test_low_confidence_uses_deterministic_rule
test_quiet_day_does_not_write_a_zero_logbook
test_closed_day_requires_explicit_rebuild
test_first_later_day_closes_the_previous_logbook
test_secondmate_home_is_the_project_fallback
