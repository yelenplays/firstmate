#!/usr/bin/env bash
# Behavior tests for bin/fm-memory-capture.sh and bin/fm-memory-capture.mjs.
#
# Drives the real capture against a scratch home whose journal is built by the
# real bin/fm-history.sh from a fixture transcript. The Claude CLI is a
# recording stand-in and curl a recording trap, so the tests pin the
# deterministic filter, that captain words reach only the Claude model and
# arrive whole, write-then-verify, the watermark, overlapping boundaries, the
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

# curl trap: any outbound HTTP call from the capture is recorded and refused.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" >> "$FAKE_REC/curl.calls"
exit 7
SH

# Claude CLI stand-in: records argv and stdin, then prints a canned result.
# While the FAKE_CLAUDE_HOLD file exists it marks itself started and waits.
cat > "$FAKEBIN/fake-claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_REC/claude.args"
cat >> "$FAKE_REC/claude.stdin"
printf 'x\n' >> "$FAKE_REC/claude.calls"
if [ -n "${FAKE_CLAUDE_HOLD:-}" ] && [ -e "$FAKE_CLAUDE_HOLD" ]; then
  : > "$FAKE_REC/claude.started"
  while [ -e "$FAKE_CLAUDE_HOLD" ]; do sleep 0.05; done
fi
[ "${FAKE_CLAUDE_FAIL:-}" = 1 ] && { echo 'not json'; exit 1; }
if [ -n "${FAKE_CLAUDE_RESULT:-}" ]; then
  cat "$FAKE_CLAUDE_RESULT"
  exit 0
fi
cat <<'JSON'
{"type":"result","is_error":false,"total_cost_usd":0.0012,
 "usage":{"input_tokens":5,"cache_creation_input_tokens":900,"cache_read_input_tokens":0,"output_tokens":120},
 "structured_output":{"memories":[
  {"topic":"Commit message dashes","category":"preferences","fact":"On 2026-09-24 the captain asked for plain dashes in commit messages.","sensitivity":"normal","now":false},
  {"topic":"Breakup and move","category":"events","fact":"On 2026-09-24 the captain said the relationship ended and they are moving out.","sensitivity":"private","now":true,"now_summary":"The captain is going through a breakup and a move.","expires":"2026-10-08"}
 ]}}
JSON
SH
chmod +x "$FAKEBIN/curl" "$FAKEBIN/fake-claude"

TRANSCRIPT="$TMP_ROOT/transcript.jsonl"

turn() {  # <id> <minute> <captain text> <reply text>
  jq -nc --arg id "$1" --arg t "2026-09-24T10:$2:00Z" --arg text "$3" \
    '{type:"user",origin:{kind:"human"},uuid:$id,timestamp:$t,message:{content:$text}}'
  jq -nc --arg id "$1-r" --arg t "2026-09-24T10:$2:30Z" --arg text "$4" \
    '{type:"assistant",uuid:$id,timestamp:$t,message:{content:[{type:"text",text:$text}],stop_reason:"end_turn"}}'
}

journal() {
  run_env "$ROOT/bin/fm-history.sh" capture --transcript "$TRANSCRIPT" >/dev/null \
    || fail 'fixture journal capture failed'
}

fresh_home() {
  rm -rf "$HOME_DIR" "$REC"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$REC"
  {
    turn c1 01 'Please always use plain dash in commit messages from now on.' 'Noted, plain dashes in every commit.'
    turn c2 02 'merge it' 'Merged.'
    turn c3 03 'My girlfriend and I broke up yesterday and I am moving out of the flat.' 'I am sorry, Captain. I will keep things light this week.'
    turn c4 04 ': Firstmate instruction waiting: list the inbox and act on it' 'Captain, shipshape.'
    turn c5 05 'The deploy script for the docs site fixes the lint issue now.' 'Good, the lint lane is green again.'
    turn c6 06 'My bank account was frozen; add a reminder to the backlog and fix the test config.' 'Added to the backlog.'
  } > "$TRANSCRIPT"
  journal
}

run_env() {
  env -u FM_TASK_ID -u FM_SUPERVISION_ACTOR -u FM_MEMORY_CAPTURE_CHILD -u FM_MEMORY_CAPTURE \
    PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_MEMORY_DIR="$HOME_DIR/data/memories" FM_CLAUDE_BIN="$FAKEBIN/fake-claude" \
    TYPESAFE_API_KEY=fixture-key JEV_ROUTE=typesafe JEV_URL=https://example.invalid/jev \
    FAKE_REC="$REC" "$@"
}

test_capture_filters_writes_and_verifies() {
  local out store="$HOME_DIR/data/memories"
  fresh_home
  out=$(run_env "$CAPTURE" run --trigger precompact) || fail "capture run failed: $out"
  assert_contains "$out" '"turns":6' 'the run did not read all six journaled turns'
  assert_contains "$out" '"dropped":2' 'the one-word answer and the wake prompt were not dropped'
  assert_contains "$out" '"units":4' 'every retained turn must reach the model'
  assert_contains "$out" '"model_calls":1' 'the model was not called exactly once'
  assert_absent "$REC/curl.calls" 'captain words left through an HTTP call'
  assert_contains "$(cat "$REC/claude.stdin")" 'broke up yesterday' 'the personal turn did not reach the model'
  assert_contains "$(cat "$REC/claude.stdin")" 'plain dash in commit messages' 'the preference turn did not reach the model'
  assert_contains "$(cat "$REC/claude.stdin")" 'docs site' 'a work turn did not reach the model'
  assert_contains "$(cat "$REC/claude.stdin")" 'bank account was frozen' 'a mixed work and personal turn did not reach the model'
  assert_not_contains "$(cat "$REC/claude.stdin")" 'merge it' 'a one-word answer reached the model'
  assert_not_contains "$(cat "$REC/claude.stdin")" 'instruction waiting' 'a wake prompt reached the model'
  assert_contains "$(cat "$REC/claude.args")" 'claude-haiku-5-5' 'the model was not pinned to Haiku'
  assert_contains "$(cat "$REC/claude.args")" '--no-session-persistence' 'the model call persisted a session'
  assert_grep 'plain dashes in commit messages' "$store/preferences/commit-message-dashes.md" 'the preference memory was not written'
  assert_grep 'sensitivity: private' "$store/events/breakup-and-move.md" 'the personal event was not marked private'
  assert_grep 'expires: 2026-10-08' "$store/now/breakup-and-move.md" 'the now entry lost its expiry'
  assert_grep 'going through a breakup' "$store/now/breakup-and-move.md" 'the now entry lost its summary'
  assert_contains "$(cat "$HOME_DIR/state/memory-capture/watermark.json")" '"id":"c6"' 'the watermark did not advance to the last turn'
  out=$(run_env "$CAPTURE" run --trigger sessionend) || fail "second run failed: $out"
  assert_contains "$out" '"turns":0' 'a second run re-read captured turns'
  [ "$(wc -l < "$REC/claude.calls" | tr -d ' ')" = 1 ] || fail 'a run with nothing new called the model'
  [ "$(wc -l < "$HOME_DIR/state/memory-capture/runs.jsonl" | tr -d ' ')" = 2 ] || fail 'each run must append one record'
  pass 'capture sends every retained turn only to the model, writes verified memories and a now entry, and advances once'
}

# The only durable fact sits past the old 2400-character clip in one message
# and past a 12000-character chunk boundary in another; both must reach the
# model before the watermark retires their turns.
test_long_messages_reach_the_model_whole() {
  local out filler long short
  fresh_home
  filler=$(printf 'The requirements walk through the release checklist in detail. %.0s' $(seq 1 200))
  short="${filler:0:2680} From now on always use tabs instead of spaces."
  long="${filler} From now on always sign release notes with the crew name."
  {
    turn c7 07 "$short" 'Understood.'
    turn c8 08 "$long" 'Understood.'
  } >> "$TRANSCRIPT"
  journal
  out=$(run_env "$CAPTURE" run --trigger precompact) || fail "capture run failed: $out"
  assert_contains "$(cat "$REC/claude.stdin")" 'always use tabs instead of spaces' 'a fact past 2400 characters never reached the model'
  assert_contains "$(cat "$REC/claude.stdin")" 'sign release notes with the crew name' 'a fact past the chunk boundary never reached the model'
  assert_contains "$(cat "$REC/claude.stdin")" '(message part 2/2)' 'a long message was not split into labeled parts'
  assert_not_contains "$(cat "$REC/claude.stdin")" '[...]' 'a captain message was clipped'
  assert_contains "$(cat "$HOME_DIR/state/memory-capture/watermark.json")" '"id":"c8"' 'the watermark did not advance past the long turns'
  pass 'long captain messages reach the model whole before the watermark retires them'
}

# A SessionEnd that fires while a PreCompact run is mid-extraction must be
# drained by that run, not left for a future boundary.
test_overlapping_boundary_is_drained() {
  local out bg i=0 runs
  fresh_home
  : > "$REC/hold"
  FAKE_CLAUDE_HOLD="$REC/hold" run_env "$CAPTURE" run --trigger precompact > "$REC/bg.out" 2>&1 &
  bg=$!
  while [ ! -e "$REC/claude.started" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$REC/claude.started" ] || { rm -f "$REC/hold"; wait "$bg"; fail 'the first run never reached the model'; }
  turn c9 09 'Remember that the release freeze starts on Friday.' 'Noted.' >> "$TRANSCRIPT"
  journal
  out=$(run_env "$CAPTURE" run --trigger sessionend) || fail "overlapping boundary failed: $out"
  assert_contains "$out" 'drain this boundary' 'the overlapping boundary did not report the hand-off'
  [ -e "$HOME_DIR/state/memory-capture/pending" ] || fail 'the overlapping boundary left no pending marker'
  rm -f "$REC/hold"
  wait "$bg" || fail "the first run failed: $(cat "$REC/bg.out")"
  runs="$HOME_DIR/state/memory-capture/runs.jsonl"
  [ "$(wc -l < "$runs" | tr -d ' ')" = 2 ] || fail "expected the first run and one drain run: $(cat "$runs")"
  assert_contains "$(tail -n 1 "$runs")" '"trigger":"sessionend"' 'the drain run did not carry the SessionEnd trigger'
  assert_contains "$(tail -n 1 "$runs")" '"turns":1' 'the drain run did not read exactly the newer turn'
  assert_contains "$(cat "$REC/claude.stdin")" 'release freeze starts on Friday' 'the SessionEnd turn never reached the model'
  assert_contains "$(cat "$HOME_DIR/state/memory-capture/watermark.json")" '"id":"c9"' 'the watermark stopped before the SessionEnd turn'
  assert_absent "$HOME_DIR/state/memory-capture/pending" 'the drained boundary left its marker behind'
  assert_absent "$HOME_DIR/state/memory-capture/lock" 'the run lock was left behind'
  pass 'a boundary that overlaps a running capture is drained before that run exits'
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
  assert_contains "$(cat "$HOME_DIR/state/memory-capture/watermark.json")" '"id":"c6"' 'recovery did not capture the queued turns'
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

test_now_hook_delivers_current_context_only_in_primary_scope() {
  local fake_root="$TMP_ROOT/now-primary" out guard source command
  fresh_home
  mkdir -p "$fake_root/bin"
  : > "$fake_root/AGENTS.md"
  git -C "$fake_root" init -q
  out=$(run_env env FM_ROOT_OVERRIDE="$fake_root" "$CAPTURE" now) || fail 'empty NOW hook failed'
  [ -z "$out" ] || fail 'empty store printed a NOW header'
  run_env "$ROOT/bin/fm-memory.sh" remember --category now --expires 2999-01-01 \
    --sensitivity private 'Current move' 'The captain is moving house this week.' >/dev/null || fail 'NOW fixture write failed'
  run_env "$ROOT/bin/fm-memory.sh" remember --category now --expires 2000-01-01 \
    'Expired focus' 'An old focus that must not be injected.' >/dev/null || fail 'expired fixture write failed'
  # Disabling extraction must not disable delivery of already-captured context.
  printf 'off\n' > "$HOME_DIR/config/memory-capture"
  out=$(run_env env FM_ROOT_OVERRIDE="$fake_root" FM_MEMORY_CAPTURE=off "$CAPTURE" now) || fail 'primary NOW hook failed'
  assert_contains "$out" 'NOW (current captain context' 'NOW hook omitted its header'
  assert_contains "$out" 'The captain is moving house this week.' 'NOW hook omitted private current context'
  assert_not_contains "$out" 'An old focus' 'NOW hook included expired context'
  for guard in FM_TASK_ID=t1 FM_SUPERVISION_ACTOR=branch FM_MEMORY_CAPTURE_CHILD=1; do
    out=$(run_env env "$guard" FM_ROOT_OVERRIDE="$fake_root" "$CAPTURE" now) || fail "NOW hook failed under $guard"
    [ -z "$out" ] || fail "NOW hook leaked context under $guard"
  done
  out=$(run_env env -u FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE=1 FM_ROOT_OVERRIDE="$fake_root" "$CAPTURE" now) || fail 'gate NOW hook failed'
  [ -z "$out" ] || fail 'NOW hook leaked context into a gate agent'
  printf 'secondmate\n' > "$HOME_DIR/.fm-secondmate-home"
  out=$(run_env env FM_ROOT_OVERRIDE="$fake_root" "$CAPTURE" now) || fail 'secondmate NOW hook failed'
  [ -z "$out" ] || fail 'NOW hook leaked primary context into a secondmate'
  rm "$HOME_DIR/.fm-secondmate-home"
  out=$(run_env env FM_ROOT_OVERRIDE="$TMP_ROOT/not-primary" "$CAPTURE" now) || fail 'out-of-scope NOW hook failed'
  [ -z "$out" ] || fail 'NOW hook leaked context outside primary scope'

  command=$(jq -r '.hooks.SessionStart[1].hooks[0].command' "$ROOT/.claude/settings.json")
  for source in startup resume compact clear; do
    out=$(printf '{"source":"%s"}' "$source" | run_env env FM_ROOT_OVERRIDE="$fake_root" \
      CLAUDE_PROJECT_DIR="$ROOT" bash -c "$command") || fail "registered NOW hook failed on $source"
    assert_contains "$out" 'The captain is moving house this week.' "registered NOW hook omitted context on $source"
    [ "${#out}" -lt 6500 ] || fail 'registered NOW hook exceeded its inline output budget'
  done
  assert_absent "$HOME_DIR/state/memory-capture" 'NOW delivery triggered extraction'
  pass 'separate NOW hook delivers current private context only in primary scope on every SessionStart'
}

# Replay the real extractor's privacy failure: a work-derived fact and NOW
# summary carried financial details but were labeled normal. The financial
# event was separately private; privacy must not depend on either label.
test_private_derivations_never_reach_public_now() {
  local out public owner labels result="$TMP_ROOT/private-derivation.json" store
  for labels in mixed all-normal unlabeled; do
    fresh_home
    store="$HOME_DIR/data/memories"
    jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{type:"user",origin:{kind:"human"},uuid:"privacy-human",timestamp:$at,message:{content:"My bank account was frozen; remember that deploy reviews need to happen in the mornings while I resolve it. This is synthetic lab validation data."}}' > "$TRANSCRIPT"
    journal
    # Updating a previously public topic must not retain its public visibility.
    run_env "$ROOT/bin/fm-memory.sh" remember --category preferences \
      'Deploy review schedule' 'Deploy reviews used to happen in the afternoons.' >/dev/null || fail 'existing topic fixture failed'
    run_env "$ROOT/bin/fm-memory.sh" remember --category now \
      'Deploy review schedule' 'Deploy reviews are in the afternoons.' >/dev/null || fail 'existing NOW fixture failed'
    run_env "$ROOT/bin/fm-memory.sh" remember --category now \
      'Public release focus' 'PUBLIC-RELEASE-FOCUS' >/dev/null || fail 'public NOW fixture failed'
    jq -nc --arg labels "$labels" '{type:"result",is_error:false,structured_output:{memories:([
      {topic:"Deploy review schedule",category:"preferences",fact:"The captain asked that deploy reviews be held in the mornings while they deal with the frozen bank account.",sensitivity:"normal",now:true,now_summary:"Deploy reviews should be scheduled in the mornings while the captain resolves the bank account freeze.",expires:"2999-01-01"}
    ] + (if $labels == "mixed" then [
      {topic:"Bank account freeze",category:"events",fact:"The captain said their bank account was frozen.",sensitivity:"private",now:true,now_summary:"The captain is resolving a bank account freeze.",expires:"2999-01-01"}
    ] else [] end))}} | if $labels == "unlabeled" then del(.structured_output.memories[].sensitivity) else . end' > "$result"
    out=$(FAKE_CLAUDE_RESULT="$result" run_env "$CAPTURE" run --trigger sessionend) || fail "privacy capture failed: $out"
    public=$(run_env "$ROOT/bin/fm-memory.sh" now --exclude-private) || fail 'public NOW failed'
    assert_contains "$public" 'PUBLIC-RELEASE-FOCUS' 'public NOW no longer returns explicitly public context'
    assert_not_contains "$public" 'bank account' "financial context leaked through a derived work summary ($labels labels)"
    assert_not_contains "$public" 'frozen' "financial context leaked through public NOW ($labels labels)"
    owner=$(run_env "$ROOT/bin/fm-memory.sh" now) || fail 'owner NOW failed'
    assert_contains "$owner" 'Deploy reviews should be scheduled in the mornings' 'privacy fix discarded useful current context'
    assert_contains "$owner" 'bank account freeze' 'private context was lost rather than protected'
    assert_grep 'sensitivity: private' "$store/preferences/deploy-review-schedule.md" 'derived durable memory was not protected'
    assert_grep 'sensitivity: private' "$store/now/deploy-review-schedule.md" 'derived NOW entry was not protected'
    assert_contains "$(cat "$HOME_DIR/state/memory-capture/watermark.json")" 'privacy-human' 'verified private capture did not advance the watermark'
  done
  pass 'private derivations remain available to Claude but never reach public NOW, regardless of model labels'
}

if [ "${1:-}" = --private-derivation-only ]; then
  test_private_derivations_never_reach_public_now
  exit 0
fi

test_private_derivations_never_reach_public_now
test_now_hook_delivers_current_context_only_in_primary_scope
test_capture_filters_writes_and_verifies
test_long_messages_reach_the_model_whole
test_overlapping_boundary_is_drained
test_non_anthropic_model_is_refused
test_two_failures_alert_once_and_recovery_resolves
test_hook_stands_down_outside_the_primary_main_session
