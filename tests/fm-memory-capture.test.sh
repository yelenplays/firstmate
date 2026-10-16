#!/usr/bin/env bash
# Behavior tests for bin/fm-memory-capture.sh and bin/fm-memory-capture.mjs.
#
# Drives the real capture against a scratch home whose journal is built by the
# real bin/fm-history.sh from a fixture transcript. Jev and the Claude CLI are
# recording stand-ins, so the tests pin the deterministic filter, the privacy
# split between Jev and the model, write-then-verify, the watermark, the
# failure alert, and the hook scope guards without network or tokens.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-memory-capture)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HOME_DIR="$TMP_ROOT/home"
REC="$TMP_ROOT/rec"
CAPTURE="$ROOT/bin/fm-memory-capture.sh"
TZ=Europe/Berlin
export TZ

# Jev stand-in: records each request and answers by keyword, or fails when
# FAKE_JEV_FAIL=1.
cat > "$FAKEBIN/fake-jev" <<'SH'
#!/usr/bin/env bash
input=$(cat)
printf '%s\n' "$input" >> "$FAKE_REC/jev.stdin"
[ "${FAKE_JEV_FAIL:-}" = 1 ] && { echo 'jev: no key' >&2; exit 1; }
printf '%s' "$input" | jq -r '.questions[].id' | while read -r id; do
  line=$(printf '%s' "$input" | jq -r '.state' | grep -o "$id: [^|]*" | head -n 1)
  case "$line" in
    *"plain dash"*) printf '%s: preference p=0.9 conf=0.9\n' "$id" ;;
    *) printf '%s: none p=0.9 conf=0.9\n' "$id" ;;
  esac
done
SH

# Claude CLI stand-in: records argv and stdin, then prints a canned result.
cat > "$FAKEBIN/fake-claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_REC/claude.args"
cat >> "$FAKE_REC/claude.stdin"
printf 'x\n' >> "$FAKE_REC/claude.calls"
[ "${FAKE_CLAUDE_FAIL:-}" = 1 ] && { echo 'not json'; exit 1; }
cat <<'JSON'
{"type":"result","is_error":false,"total_cost_usd":0.0012,
 "usage":{"input_tokens":5,"cache_creation_input_tokens":900,"cache_read_input_tokens":0,"output_tokens":120},
 "structured_output":{"memories":[
  {"topic":"Commit message dashes","category":"preferences","fact":"On 2026-09-24 the captain asked for plain dashes in commit messages.","sensitivity":"normal","now":false},
  {"topic":"Breakup and move","category":"events","fact":"On 2026-09-24 the captain said the relationship ended and they are moving out.","sensitivity":"private","now":true,"now_summary":"The captain is going through a breakup and a move.","expires":"2026-10-08"}
 ]}}
JSON
SH
chmod +x "$FAKEBIN/fake-jev" "$FAKEBIN/fake-claude"

fresh_home() {
  rm -rf "$HOME_DIR" "$REC"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$REC"
  local transcript="$TMP_ROOT/transcript.jsonl"
  {
    turn() {  # <id> <minute> <captain text> <reply text>
      jq -nc --arg id "$1" --arg t "2026-09-24T10:$2:00Z" --arg text "$3" \
        '{type:"user",origin:{kind:"human"},uuid:$id,timestamp:$t,message:{content:$text}}'
      jq -nc --arg id "$1-r" --arg t "2026-09-24T10:$2:30Z" --arg text "$4" \
        '{type:"assistant",uuid:$id,timestamp:$t,message:{content:[{type:"text",text:$text}],stop_reason:"end_turn"}}'
    }
    turn c1 01 'Please always use plain dash in commit messages from now on.' 'Noted, plain dashes in every commit.'
    turn c2 02 'merge it' 'Merged.'
    turn c3 03 'My girlfriend and I broke up yesterday and I am moving out of the flat.' 'I am sorry, Captain. I will keep things light this week.'
    turn c4 04 ': Firstmate instruction waiting: list the inbox and act on it' 'Captain, shipshape.'
    turn c5 05 'The deploy script for the docs site fixes the lint issue now.' 'Good, the lint lane is green again.'
  } > "$transcript"
  run_env "$ROOT/bin/fm-history.sh" capture --transcript "$transcript" >/dev/null \
    || fail 'fixture journal capture failed'
}

run_env() {
  env -u FM_TASK_ID -u FM_SUPERVISION_ACTOR -u FM_MEMORY_CAPTURE_CHILD -u FM_MEMORY_CAPTURE \
    PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_MEMORY_DIR="$HOME_DIR/data/memories" FM_CLAUDE_BIN="$FAKEBIN/fake-claude" \
    FM_MEMORY_CAPTURE_JEV_BIN="$FAKEBIN/fake-jev" FAKE_REC="$REC" "$@"
}

test_capture_splits_privacy_writes_and_verifies() {
  local out store="$HOME_DIR/data/memories"
  fresh_home
  out=$(run_env "$CAPTURE" run --trigger precompact) || fail "capture run failed: $out"
  assert_contains "$out" '"turns":5' 'the run did not read all five journaled turns'
  assert_contains "$out" '"dropped":2' 'the one-word answer and the wake prompt were not dropped'
  assert_contains "$out" '"jev_units":2' 'only the two work-shaped turns should reach Jev'
  assert_contains "$out" '"jev_none":1' 'Jev did not skip the turn without a durable fact'
  assert_contains "$out" '"model_calls":1' 'the model was not called exactly once'
  assert_not_contains "$(cat "$REC/jev.stdin")" 'girlfriend' 'a personal turn reached Jev'
  assert_not_contains "$(cat "$REC/jev.stdin")" 'moving out' 'a personal turn reached Jev'
  assert_contains "$(cat "$REC/claude.stdin")" 'broke up yesterday' 'the personal turn did not reach the model'
  assert_contains "$(cat "$REC/claude.stdin")" 'plain dash in commit messages' 'the Jev-selected turn did not reach the model'
  assert_contains "$(cat "$REC/claude.stdin")" '(triage: preference)' 'the Jev category hint was not passed on'
  assert_not_contains "$(cat "$REC/claude.stdin")" 'docs site' 'a turn Jev ruled out still reached the model'
  assert_not_contains "$(cat "$REC/claude.stdin")" 'merge it' 'a one-word answer reached the model'
  assert_not_contains "$(cat "$REC/claude.stdin")" 'instruction waiting' 'a wake prompt reached the model'
  assert_contains "$(cat "$REC/claude.args")" 'claude-haiku-5-5' 'the model was not pinned to Haiku'
  assert_contains "$(cat "$REC/claude.args")" '--no-session-persistence' 'the model call persisted a session'
  assert_grep 'plain dashes in commit messages' "$store/preferences/commit-message-dashes.md" 'the preference memory was not written'
  assert_grep 'sensitivity: private' "$store/events/breakup-and-move.md" 'the personal event was not marked private'
  assert_grep 'expires: 2026-10-08' "$store/now/breakup-and-move.md" 'the now entry lost its expiry'
  assert_grep 'going through a breakup' "$store/now/breakup-and-move.md" 'the now entry lost its summary'
  assert_contains "$(cat "$HOME_DIR/state/memory-capture/watermark.json")" '"id":"c5"' 'the watermark did not advance to the last turn'
  out=$(run_env "$CAPTURE" run --trigger sessionend) || fail "second run failed: $out"
  assert_contains "$out" '"turns":0' 'a second run re-read captured turns'
  [ "$(wc -l < "$REC/claude.calls" | tr -d ' ')" = 1 ] || fail 'a run with nothing new called the model'
  [ "$(wc -l < "$HOME_DIR/state/memory-capture/runs.jsonl" | tr -d ' ')" = 2 ] || fail 'each run must append one record'
  pass 'capture keeps personal turns from Jev, writes verified memories and a now entry, and advances once'
}

test_jev_failure_falls_back_to_the_model() {
  local out
  fresh_home
  out=$(FAKE_JEV_FAIL=1 run_env "$CAPTURE" run) || fail "capture with Jev down failed: $out"
  assert_contains "$out" '"jev_escalated":2' 'Jev failures were not counted as undecided'
  assert_contains "$(cat "$REC/claude.stdin")" 'docs site' 'an undecided turn did not fall back to the model'
  pass 'a Jev failure sends the undecided turns to the model instead of dropping them'
}

test_non_anthropic_model_is_refused() {
  local rc=0
  fresh_home
  FM_MEMORY_CAPTURE_MODEL=deepseek-v4 run_env "$CAPTURE" run >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail 'a non-Anthropic capture model was accepted'
  assert_absent "$REC/claude.stdin" 'a refused model still received captain words'
  assert_absent "$HOME_DIR/state/memory-capture/watermark.json" 'a refused run advanced the watermark'
  pass 'captain words never go to a non-Anthropic capture model'
}

test_two_failures_alert_once_and_recovery_resolves() {
  local status="$HOME_DIR/state/memory-capture.status"
  fresh_home
  FAKE_CLAUDE_FAIL=1 run_env "$CAPTURE" run >/dev/null 2>&1 && fail 'a failed model call reported success'
  assert_absent "$status" 'one failure must not alert yet'
  FAKE_CLAUDE_FAIL=1 run_env "$CAPTURE" run >/dev/null 2>&1
  FAKE_CLAUDE_FAIL=1 run_env "$CAPTURE" run >/dev/null 2>&1
  [ "$(grep -c '^failed \[at=[0-9]*\]: memory capture failed twice in a row' "$status")" = 1 ] \
    || fail 'two failures in a row must append exactly one failed line'
  assert_absent "$HOME_DIR/state/memory-capture/watermark.json" 'a failed run advanced the watermark'
  run_env "$CAPTURE" run >/dev/null || fail 'the recovery run failed'
  grep -Eq '^resolved \[at=[0-9]+\]: memory capture recovered' "$status" || fail 'recovery did not resolve the alert'
  assert_contains "$(cat "$HOME_DIR/state/memory-capture/watermark.json")" '"id":"c5"' 'recovery did not capture the queued turns'
  pass 'two failed runs alert once, keep turns queued, and the next good run resolves'
}

test_hook_stands_down_outside_the_primary_main_session() {
  local fake_root="$TMP_ROOT/primary"
  fresh_home
  rm -rf "$fake_root"
  mkdir -p "$fake_root/bin"
  : > "$fake_root/AGENTS.md"
  git -C "$fake_root" init -q
  for guard in FM_TASK_ID=t1 FM_SUPERVISION_ACTOR=branch FM_MEMORY_CAPTURE_CHILD=1 FM_MEMORY_CAPTURE=off; do
    printf '{}' | run_env env "$guard" FM_ROOT_OVERRIDE="$fake_root" "$CAPTURE" hook precompact \
      || fail "hook exited non-zero under $guard"
    assert_absent "$HOME_DIR/state/memory-capture" "hook started a capture under $guard"
  done
  printf 'off\n' > "$HOME_DIR/config/memory-capture"
  printf '{}' | run_env env FM_ROOT_OVERRIDE="$fake_root" "$CAPTURE" hook sessionend || fail 'hook failed with config off'
  assert_absent "$HOME_DIR/state/memory-capture" 'hook started a capture with config/memory-capture off'
  rm "$HOME_DIR/config/memory-capture"
  printf '{}' | run_env env FM_ROOT_OVERRIDE="$ROOT" "$CAPTURE" hook precompact || fail 'hook failed in a linked worktree'
  if [ "$(git -C "$ROOT" rev-parse --git-dir)" != "$(git -C "$ROOT" rev-parse --git-common-dir)" ]; then
    assert_absent "$HOME_DIR/state/memory-capture" 'hook started a capture from a linked worktree'
  fi
  rm -rf "$HOME_DIR/state/memory-capture"
  printf '{}' | run_env env FM_ROOT_OVERRIDE="$fake_root" "$CAPTURE" hook precompact || fail 'in-scope hook failed'
  local i=0
  while [ ! -s "$HOME_DIR/state/memory-capture/runs.jsonl" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  assert_contains "$(cat "$HOME_DIR/state/memory-capture/runs.jsonl" 2>/dev/null)" '"trigger":"precompact"' \
    'the in-scope hook did not start a detached capture run'
  pass 'the hook runs only for the primary home main session and returns before the capture'
}

test_capture_splits_privacy_writes_and_verifies
test_jev_failure_falls_back_to_the_model
test_non_anthropic_model_is_refused
test_two_failures_alert_once_and_recovery_resolves
test_hook_stands_down_outside_the_primary_main_session
