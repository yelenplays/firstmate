#!/usr/bin/env bash
# End-to-end tests for the private conversation journal, task cards, and search.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-history)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
BASE_PATH=$PATH
HELPER="$ROOT/bin/fm-history.sh"
TZ=Europe/Berlin
export TZ

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

run_history() {
  PATH="$FAKEBIN:$BASE_PATH" TZ=Europe/Berlin FM_HOME="$HOME_DIR" \
    FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" "$HELPER" "$@"
}

run_test_axi() {
  FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$ROOT/bin/fm-tasks-axi.sh" "$@"
}

run_test_captain() {
  FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}

mode_of() {
  if [ "$(uname -s)" = Darwin ]; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}

test_capture_is_idempotent_and_uses_the_captains_local_day() {
  local transcript old_transcript page recent output old_line new_line
  fresh_home
  transcript="$TMP_ROOT/transcript.jsonl"
  jq -nc --arg id 'captain-msg-1' --arg text $'The captain\x27s exact phrase survives compaction.\nKeep this line too.' \
    '{type:"user",origin:"human",uuid:$id,timestamp:"2026-09-22T22:30:00Z",message:{content:$text}}' > "$transcript"
  jq -nc --arg id 'firstmate-msg-1' --arg text 'The final firstmate reply is also captured.' \
    '{type:"assistant",uuid:$id,timestamp:"2026-09-22T22:30:05Z",message:{content:$text,stop_reason:"end_turn"}}' >> "$transcript"

  output=$(run_history capture --transcript "$transcript")
  assert_contains "$output" 'captured 1 captain message(s) and 1 final reply/replies' 'the first capture did not consume both turns'
  page="$HOME_DIR/data/history/days/2026-09-23.md"
  assert_present "$page" '22:30Z was not assigned to the next Europe/Berlin day'
  assert_absent "$HOME_DIR/data/history/days/2026-09-22.md" 'the UTC date was incorrectly used as the page key'
  run_history capture --transcript "$transcript" >/dev/null
  [ "$(grep -c 'fm-history:captain id=captain-msg-1' "$page")" = 1 ] \
    || fail 'a repeated capture appended the captain turn twice'
  [ "$(grep -c 'fm-history:firstmate id=firstmate-msg-1' "$page")" = 1 ] \
    || fail 'a repeated capture appended the final reply twice'
  old_transcript="$TMP_ROOT/old-transcript.jsonl"
  jq -nc '{type:"user",origin:"human",uuid:"captain-msg-old",timestamp:"2026-09-20T10:00:00Z",message:{content:"An earlier captain turn."}}' > "$old_transcript"
  jq -nc '{type:"assistant",uuid:"firstmate-msg-old",timestamp:"2026-09-20T10:00:05Z",message:{content:"The earlier reply.",stop_reason:"end_turn"}}' >> "$old_transcript"
  run_history capture --transcript "$old_transcript" >/dev/null

  recent=$(run_history recent --n 5)
  old_line=$(printf '%s\n' "$recent" | grep -nF 'An earlier captain turn.' | cut -d: -f1)
  new_line=$(printf '%s\n' "$recent" | grep -nF "The captain's exact phrase survives compaction." | cut -d: -f1)
  [ -n "$old_line" ] && [ -n "$new_line" ] && [ "$old_line" -lt "$new_line" ] \
    || fail 'recent conversations are not in chronological order across local-day pages'
  assert_contains "$recent" "The captain's exact phrase survives compaction." 'recent did not print the exact captain words'
  assert_contains "$recent" 'Keep this line too.' 'recent dropped a line from the captain message'
  assert_contains "$recent" 'The final firstmate reply is also captured.' 'recent dropped the final reply'
  output=$(run_history find 'captain exact phrase survives compaction')
  assert_contains "$output" '2026-09-23.md' 'local history search did not return the matching day page'
  [ "$(mode_of "$HOME_DIR/data/history")" = 700 ] || fail 'history directory mode is not 0700'
  [ "$(mode_of "$HOME_DIR/data/history/days")" = 700 ] || fail 'day directory mode is not 0700'
  pass 'capture is idempotent, local-day keyed, and recoverable through recent and BM25 search'
}

test_pi_transcript_capture_keeps_captain_words_and_final_reply_only() {
  local transcript output recent
  fresh_home
  transcript="$TMP_ROOT/pi-transcript.jsonl"
  jq -nc '{type:"session",id:"session-1",timestamp:"2026-09-23T10:00:00.000Z",version:3}' > "$transcript"
  {
    jq -nc --arg text "The captain's exact Pi request." '{type:"message",id:"captain-1",timestamp:"2026-09-23T10:01:00.000Z",message:{role:"user",timestamp:"2026-09-23T10:01:00.000Z",content:[{type:"text",text:$text}]}}'
    jq -nc '{type:"message",id:"assistant-tool",timestamp:"2026-09-23T10:01:10.000Z",message:{role:"assistant",stopReason:"toolUse",timestamp:"2026-09-23T10:01:10.000Z",content:[{type:"thinking",thinking:"Private model reasoning."},{type:"toolCall",name:"bash",arguments:{command:"echo hidden"}}]}}'
    jq -nc '{type:"message",id:"tool-result",timestamp:"2026-09-23T10:01:11.000Z",message:{role:"toolResult",content:[{type:"text",text:"Private tool output."}]}}'
    jq -nc '{type:"message",id:"assistant-final",timestamp:"2026-09-23T10:01:20.000Z",message:{role:"assistant",stopReason:"stop",timestamp:"2026-09-23T10:01:20.000Z",content:[{type:"thinking",thinking:"Another private thought."},{type:"text",text:"The final Pi answer."}]}}'
    jq -nc '{type:"message",id:"internal",timestamp:"2026-09-23T10:02:00.000Z",message:{role:"user",content:[{type:"text",text:"\u2063FIRSTMATE_OP: hidden supervisor injection"}]}}'
  } >> "$transcript"
  output=$(run_history capture --transcript "$transcript")
  assert_contains "$output" 'captured 1 captain message(s) and 1 final reply/replies' 'Pi transcript capture did not pair the captain turn with its final answer'
  recent=$(run_history recent --n 5)
  assert_contains "$recent" "The captain's exact Pi request." 'Pi transcript capture lost the captain message'
  assert_contains "$recent" 'The final Pi answer.' 'Pi transcript capture lost the final assistant answer'
  assert_not_contains "$recent" 'Private model reasoning.' 'Pi transcript capture exposed thinking blocks'
  assert_not_contains "$recent" 'Private tool output.' 'Pi transcript capture exposed tool results'
  assert_not_contains "$recent" 'hidden supervisor injection' 'Pi transcript capture journaled internal operational input'
  pass 'Pi transcript capture stores captain input and final replies without tool or thinking content'
}

test_claude_compaction_and_session_end_hooks_capture_once() {
  local transcript payload compact_hook end_hook recent today
  fresh_home
  transcript="$TMP_ROOT/claude-transcript.jsonl"
  jq -nc '{type:"user",origin:"human",uuid:"claude-captain",timestamp:"2026-09-23T10:00:00Z",message:{content:"Exact Claude captain words."}}' > "$transcript"
  {
    jq -nc '{type:"assistant",uuid:"claude-reply",timestamp:"2026-09-23T10:00:05Z",message:{content:"Claude final answer." ,stop_reason:"end_turn"}}'
    jq -nc '{type:"user",origin:"human",uuid:"claude-operational",timestamp:"2026-09-23T10:00:06Z",message:{content:"\u2063FIRSTMATE_OP: hidden supervisor injection"}}'
    jq -nc '{type:"assistant",uuid:"claude-operational-reply",timestamp:"2026-09-23T10:00:07Z",message:{content:"Reply to the internal injection.",stop_reason:"end_turn"}}'
    jq -nc '{type:"user",origin:"human",uuid:"claude-captain-2",timestamp:"2026-09-23T10:00:08Z",message:{content:"Second Claude captain words."}}'
    jq -nc '{type:"assistant",uuid:"claude-reply-2",timestamp:"2026-09-23T10:00:09Z",message:{content:"Second Claude final answer.",stop_reason:"end_turn",usage:{input_tokens:30,output_tokens:6,cache_creation_input_tokens:4,cache_read_input_tokens:8}}}'
  } >> "$transcript"
  compact_hook=$(jq -r '.hooks.PreCompact[0].hooks[0].command' "$ROOT/.claude/settings.json")
  end_hook=$(jq -r '.hooks.SessionEnd[0].hooks[0].command' "$ROOT/.claude/settings.json")
  payload=$(jq -nc --arg transcript "$transcript" '{transcript_path:$transcript,trigger:"auto"}')
  printf '%s' "$payload" | env -u GROK_AGENT -u GROK_HOOK_EVENT FM_TASK_ID=claude-worker \
    CLAUDE_PROJECT_DIR="$ROOT" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    PATH="$FAKEBIN:$BASE_PATH" bash -c "$compact_hook" \
    || fail 'the Claude worker capture hook failed to exit cleanly'
  assert_absent "$HOME_DIR/data/history/days/2026-09-23.md" \
    'the primary history hook captured a Claude task worker transcript'
  printf '%s' "$payload" | env -u GROK_AGENT -u GROK_HOOK_EVENT FM_TASK_ID=claude-worker \
    CLAUDE_PROJECT_DIR="$ROOT" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    PATH="$FAKEBIN:$BASE_PATH" bash -c "$end_hook" \
    || fail 'the Claude worker session-end hook failed to exit cleanly'
  assert_absent "$HOME_DIR/data/history/days/2026-09-23.md" \
    'the primary session-end hook captured a Claude task worker transcript'
  printf '%s' "$payload" | env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$ROOT" \
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" PATH="$FAKEBIN:$BASE_PATH" bash -c "$compact_hook" \
    || fail 'the Claude pre-compaction capture hook failed'
  printf '%s' "$payload" | env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$ROOT" \
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" PATH="$FAKEBIN:$BASE_PATH" bash -c "$end_hook" \
    || fail 'the Claude session-end capture hook failed'
  [ "$(grep -c 'fm-history:captain id=claude-captain trailing-newline' "$HOME_DIR/data/history/days/2026-09-23.md")" = 1 ] \
    || fail 'the two Claude lifecycle hooks duplicated the same captain turn'
  recent=$(run_history recent --n 5)
  assert_contains "$recent" 'Exact Claude captain words.' \
    'Claude lifecycle hooks did not preserve the captain words'
  assert_contains "$recent" 'Second Claude captain words.' \
    'Claude lifecycle hooks did not preserve a later captain turn'
  assert_contains "$recent" 'Second Claude final answer.' \
    'the session-end hook did not capture the final reply after compaction'
  assert_not_contains "$recent" 'FIRSTMATE_OP' 'Claude capture journaled an internal operational input'
  assert_not_contains "$recent" 'Reply to the internal injection.' 'Claude capture journaled an internal response'
  today=$(date +%Y-%m-%d)
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" 'context_input_tokens' \
    'the compaction hook did not record a local token-count entry'
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" '"context_input_tokens": 42' \
    'the compaction record did not include cached and uncached context tokens'
  assert_contains "$(<"$HOME_DIR/data/history/days/$today.md")" '"output_tokens": 6' \
    'the compaction record did not retain available output-token usage'
  pass 'Claude pre-compaction records local token usage and shares an idempotent capture cursor'
}

test_task_cards_are_written_once_and_indexed() {
  local card index meta_line encoded metadata
  fresh_home
  mkdir -p "$HOME_DIR/data/task-card"
  run_history_axi() {
    FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$ROOT/bin/fm-tasks-axi.sh" "$@"
  }
  run_history_axi add task-card 'A completed project task' --kind ship --repo sample-project --start >/dev/null
  run_history_axi "done" task-card --pr 'https://github.com/acme/sample-project/pull/22' >/dev/null
  cat > "$HOME_DIR/data/task-card/brief.md" <<'EOF'
# Task

## Captain's intent

Preserve the captain's exact task ask.

## Firstmate spec

This section is not the captain's intent.
EOF
  printf 'mode=no-mistakes\nkind=ship\npr=https://github.com/acme/sample-project/pull/22\n' \
    > "$HOME_DIR/state/task-card.meta"
  printf 'done: PR https://github.com/acme/sample-project/pull/22 checks green\n' \
    > "$HOME_DIR/state/task-card.status"

  run_history task task-card >/dev/null
  card="$HOME_DIR/data/history/tasks/task-card.md"
  index="$HOME_DIR/data/history/index.md"
  assert_present "$card" 'task cleanup did not produce a history card'
  assert_contains "$(<"$card")" "Preserve the captain's exact task ask." 'task card lost the captain intent'
  assert_not_contains "$(<"$card")" "This section is not the captain's intent." 'task card misattributed the Firstmate spec'
  assert_contains "$(<"$card")" 'done: PR https://github.com/acme/sample-project/pull/22 checks green' 'task card omitted its ready outcome'
  assert_contains "$(<"$card")" 'fm-history:task:v1' 'task card omitted its structured local record'
  assert_contains "$(<"$index")" 'tasks/task-card.md - task - A completed project task' 'the generated index omitted the task card'
  meta_line=$(grep 'fm-history:task:v1' "$card")
  encoded=${meta_line#*fm-history:task:v1 }
  encoded=${encoded% -->}
  if [ "$(uname -s)" = Darwin ]; then metadata=$(printf '%s' "$encoded" | base64 -D); else metadata=$(printf '%s' "$encoded" | base64 -d); fi
  assert_contains "$metadata" '"via":"pull_request"' 'task card metadata did not retain its structured landing source'
  assert_contains "$metadata" '"pr_url":"https://github.com/acme/sample-project/pull/22"' 'task card metadata lost its PR URL'
  cp "$card" "$TMP_ROOT/card-before-retry.md"
  run_history task task-card >/dev/null
  cmp -s "$TMP_ROOT/card-before-retry.md" "$card" || fail 'a repeated task cleanup rewrote its card'
  assert_contains "$meta_line" 'fm-history:task:v1' 'the task card metadata was not discoverable'
  [ "$(mode_of "$HOME_DIR/data/history/tasks")" = 700 ] || fail 'task-card directory mode is not 0700'
  [ "$(mode_of "$card")" = 600 ] || fail 'task card mode is not 0600'
  pass 'cleanup writes one private task card and updates the generated history index'
}

test_task_cards_use_terminal_events_without_filing_open_work() {
  local card meta_line encoded metadata output
  fresh_home
  run_test_axi add stale-open-row 'Completed according to its status event' --kind ship --repo sample-project --start >/dev/null
  printf 'done: completed through the status stream\n' > "$HOME_DIR/state/stale-open-row.status"
  run_history task stale-open-row >/dev/null
  card="$HOME_DIR/data/history/tasks/stale-open-row.md"
  assert_present "$card" 'the terminal done event did not produce a task card'
  meta_line=$(grep 'fm-history:task:v1' "$card")
  encoded=${meta_line#*fm-history:task:v1 }
  encoded=${encoded% -->}
  if [ "$(uname -s)" = Darwin ]; then metadata=$(printf '%s' "$encoded" | base64 -D); else metadata=$(printf '%s' "$encoded" | base64 -d); fi
  jq -e '.completion.verb == "done"' <<< "$metadata" >/dev/null \
    || fail 'status-event completion was not recorded in the task card'

  run_test_axi add still-running 'Work that is not complete' --kind ship --repo sample-project --start >/dev/null
  output=$(run_history task still-running)
  assert_contains "$output" 'no terminal completion evidence' 'an in-flight task was not retained'
  assert_absent "$HOME_DIR/data/history/tasks/still-running.md" 'an in-flight task was filed as a completed card'

  run_test_axi add captain-held 'A question is waiting for the captain' --kind captain --repo sample-project --start >/dev/null
  run_test_captain hold captain-held --reason 'Needs a decision' >/dev/null
  printf 'done: deliverable exists, but the captain decision is still open\n' > "$HOME_DIR/state/captain-held.status"
  run_history task captain-held >/dev/null
  assert_absent "$HOME_DIR/data/history/tasks/captain-held.md" 'a captain-held task was filed as complete'
  pass 'task cards use independent terminal evidence and leave unfinished work intact'
}

test_wake_batches_and_acknowledgements_are_journaled() {
  local today page stderr ack_through generation marker history_backup queue_before queue_after
  fresh_home
  today=$(TZ=Europe/Berlin date +%Y-%m-%d)
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    bash -c '. "$1"; fm_wake_append check test-key "check: exact wake reason"' _ "$ROOT/bin/fm-wake-lib.sh" \
    || fail 'the wake fixture could not append a durable row'
  : > "$HOME_DIR/data/history"
  if FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    TZ=Europe/Berlin "$ROOT/bin/fm-wake-drain.sh" > "$TMP_ROOT/drain-failed.out" 2> "$TMP_ROOT/drain-failed.err"; then
    fail 'the wake was presented despite a failed journal write'
  fi
  assert_present "$HOME_DIR/state/.wake-queue" 'a journal failure discarded the durable wake'
  assert_not_contains "$(<"$TMP_ROOT/drain-failed.out")" 'exact wake reason' 'an unjournaled wake was presented'
  rm -f "$HOME_DIR/data/history"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    TZ=Europe/Berlin "$ROOT/bin/fm-wake-drain.sh" > "$TMP_ROOT/drain.out" 2> "$TMP_ROOT/drain.err" \
    || fail 'the wake drain did not present the fixture row after journal recovery'
  stderr=$(<"$TMP_ROOT/drain.err")
  ack_through=$(printf '%s\n' "$stderr" | sed -n 's/.*--ack-through \([0-9][0-9]*\) --recovery-generation.*/\1/p')
  generation=$(printf '%s\n' "$stderr" | sed -n 's/.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._:-]*\).*/\1/p')
  [ -n "$ack_through" ] && [ -n "$generation" ] || fail 'the drain omitted its acknowledgement command'
  page="$HOME_DIR/data/history/days/$today.md"
  assert_contains "$(<"$page")" 'exact wake reason' 'the presented wake row was not journaled'
  assert_contains "$(<"$page")" 'test-key' 'the wake journal omitted its key'
  marker=$(grep -c 'fm-history:wake-batch id=' "$page")
  [ "$marker" = 1 ] || fail 'the initial wake batch was not recorded exactly once'
  assert_contains "$(<"$page")" "\"acknowledgement_number\": $ack_through" 'the wake batch omitted its acknowledgement number'
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    TZ=Europe/Berlin "$ROOT/bin/fm-wake-drain.sh" > "$TMP_ROOT/drain-retry.out" 2> "$TMP_ROOT/drain-retry.err" \
    || fail 'a repeated unacknowledged wake presentation failed'
  [ "$(grep -c 'fm-history:wake-batch id=' "$page")" = 1 ] || fail 'a repeated presentation duplicated the wake batch'
  history_backup="$HOME_DIR/data/history-backup"
  mv "$HOME_DIR/data/history" "$history_backup"
  : > "$HOME_DIR/data/history"
  queue_before=$(wc -l < "$HOME_DIR/state/.wake-queue" | tr -d ' ')
  if FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    TZ=Europe/Berlin "$ROOT/bin/fm-wake-drain.sh" --ack-through "$ack_through" \
      --recovery-generation "$generation" > "$TMP_ROOT/ack-failed.out" 2> "$TMP_ROOT/ack-failed.err"; then
    fail 'the wake was acknowledged despite a failed acknowledgement journal write'
  fi
  queue_after=$(wc -l < "$HOME_DIR/state/.wake-queue" | tr -d ' ')
  [ "$queue_after" = "$queue_before" ] || fail 'an unjournaled acknowledgement consumed its wake'
  rm -f "$HOME_DIR/data/history"
  mv "$history_backup" "$HOME_DIR/data/history"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    TZ=Europe/Berlin "$ROOT/bin/fm-wake-drain.sh" --ack-through "$ack_through" \
      --recovery-generation "$generation" > "$TMP_ROOT/ack.out" 2> "$TMP_ROOT/ack.err" \
    || fail 'the wake acknowledgement did not complete after journal recovery'
  assert_contains "$(<"$page")" 'wake-ack' 'the acknowledgement was not journaled'
  assert_contains "$(<"$page")" 'rows_acknowledged' 'the acknowledgement row count was not recorded'
  pass 'wake presentations are retry-safe and their acknowledgements are journaled'
}

test_capture_is_idempotent_and_uses_the_captains_local_day
test_pi_transcript_capture_keeps_captain_words_and_final_reply_only
test_claude_compaction_and_session_end_hooks_capture_once
test_task_cards_are_written_once_and_indexed
test_task_cards_use_terminal_events_without_filing_open_work
test_wake_batches_and_acknowledgements_are_journaled
