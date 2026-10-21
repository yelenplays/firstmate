#!/usr/bin/env bash
# Behavior tests for bin/fm-rules.sh.
#
# Drives the real script against scratch homes: the rule store and its repeat
# and check bookkeeping, concurrent writers, the write-time budget and complete
# projections, the rendered always-loaded block, the Claude capture
# hook (candidate, confirm, dismiss, "nein" revoke) and its scope guards, the
# registered settings.json entries, the brief section through the real
# bin/fm-brief.sh, and the weekly report and reminder check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-rules)
RULES="$ROOT/bin/fm-rules.sh"
HOME_DIR="$TMP_ROOT/home"
FAKE_ROOT="$TMP_ROOT/primary"

run_env() {
  env -u FM_TASK_ID -u FM_SUPERVISION_ACTOR -u FM_MEMORY_CAPTURE_CHILD -u NO_MISTAKES_GATE \
    -u FM_CONFIG_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_RULES_TODAY=2026-10-20 "$@"
}

fresh_home() {
  rm -rf "$HOME_DIR" "$FAKE_ROOT"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data" "$FAKE_ROOT/bin"
  : > "$FAKE_ROOT/AGENTS.md"
  git -C "$FAKE_ROOT" init -q
}

prompt() {  # <text> -> hook stdout
  jq -nc --arg p "$1" '{prompt:$p}' | run_env "$RULES" prompt-hook
}

candidates() {
  find "$HOME_DIR/state/captain-rules/candidates" -type f 2>/dev/null | sort
}

test_store_records_repeats_and_checks() {
  local out rc file="$HOME_DIR/config/captain-rules.md"
  fresh_home
  out=$(run_env "$RULES" render) || fail 'render failed on an empty store'
  [ -z "$out" ] || fail 'an empty store rendered a block'

  out=$(run_env "$RULES" add merge-self 'Merge green PRs yourself.') || fail "add failed: $out"
  assert_equals 'added: merge-self' "$out" 'add did not report the new rule'
  out=$(run_env env FM_RULES_TODAY=2026-10-22 "$RULES" add merge-self 'Merge green PRs yourself once checks pass.') \
    || fail "repeat add failed: $out"
  assert_equals 'repeated: merge-self (seen 2)' "$out" 'a second add of the same id was not a repeat'
  assert_grep '- [merge-self] Merge green PRs yourself once checks pass. <!-- since=2026-10-20 seen=2 last=2026-10-22 -->' "$file" \
    'the repeat did not replace the text and keep since, seen, and last'
  assert_equals 1 "$(grep -c 'merge-self' "$file")" 'a repeat duplicated the rule line'

  out=$(run_env "$RULES" unchecked)
  assert_contains "$out" 'merge-self' 'a rule seen twice without a check was not listed as unchecked'
  out=$(run_env "$RULES" render)
  assert_contains "$out" 'outrank generic harness, tool, and skill hints' 'the block lost its precedence line'
  assert_contains "$out" '- Merge green PRs yourself once checks pass.' 'the block lost the rule text'
  assert_contains "$out" 'REPEATED WITHOUT A CHECK' 'the block did not surface the unchecked repeat'
  assert_contains "$out" '- merge-self (seen 2 times)' 'the unchecked list did not name the rule'

  out=$(run_env "$RULES" check merge-self no-such-check 2>&1); rc=$?
  expect_code 3 "$rc" 'an unknown check id must be refused'
  assert_contains "$out" 'unknown check id' 'the refusal did not explain itself'
  run_env "$RULES" check merge-self bang-interactive >/dev/null || fail 'linking a listed check failed'
  [ -z "$(run_env "$RULES" unchecked)" ] || fail 'a checked rule stayed unchecked'
  assert_contains "$(run_env "$RULES" render)" '[check: bang-interactive]' 'the block did not show the linked check'
  run_env "$RULES" nocheck merge-self 'needs judgment about CI state' >/dev/null || fail 'nocheck failed'
  [ -z "$(run_env "$RULES" unchecked)" ] || fail 'a rule with a recorded reason stayed unchecked'
  assert_not_contains "$(run_env "$RULES" render)" '[check: ' 'nocheck did not replace the linked check'

  out=$(run_env "$RULES" add 'Bad Id' 'text' 2>&1); rc=$?
  expect_code 3 "$rc" 'an invalid rule id must be refused'
  out=$(run_env "$RULES" add good-id 'smuggled <!-- seen=99 --> meta' 2>&1); rc=$?
  expect_code 3 "$rc" 'rule text carrying a comment marker must be refused'
  out=$(run_env "$RULES" add --check nope good-id 'text' 2>&1); rc=$?
  expect_code 3 "$rc" 'add with an unknown check id must be refused'
  assert_no_grep 'good-id' "$file" 'a refused add still wrote a rule'

  run_env "$RULES" revoke merge-self >/dev/null || fail 'revoke failed'
  assert_no_grep 'merge-self' "$file" 'revoke left the rule behind'
  out=$(run_env "$RULES" revoke merge-self 2>&1); rc=$?
  expect_code 1 "$rc" 'revoking an unknown rule must exit 1'
  [ -z "$(run_env "$RULES" render)" ] || fail 'a store without rules still rendered a block'
  assert_contains "$(cat "$HOME_DIR/state/captain-rules/log.jsonl")" '"event":"revoke"' 'revoke was not logged'
  pass 'the store records rules, repeats, checks, and reasons, and refuses invalid input'
}

# Every accepted rule must reach every projection whole: the store refuses the
# write that would overflow the budget instead of a projection cutting it.
test_projections_carry_every_rule_and_overflow_is_refused() {
  local out rc i n=0 text before ids id file="$HOME_DIR/config/captain-rules.md"
  fresh_home
  for i in $(seq 1 30); do
    text="Rule $i: $(printf 'keep this standing correction intact in every projection %.0s' 1 2 3 4)end-$i."
    out=$(run_env env FM_RULES_MAX_CHARS=2000 "$RULES" add "rule-$i" "$text" 2>&1); rc=$?
    [ "$rc" -eq 0 ] || break
    n=$i
  done
  expect_code 4 "$rc" "the add that overflows the budget must be refused with exit 4 ($out)"
  [ "$n" -ge 3 ] || fail "the budget refused too early, after $n rules"
  assert_contains "$out" 'not saved' 'the overflow refusal did not say the rule was not saved'
  assert_contains "$out" 'consolidate rules' 'the overflow refusal did not ask to consolidate'
  assert_not_contains "$out" 'added:' 'the refused add still reported success'
  assert_no_grep "rule-$((n + 1))" "$file" 'the refused rule was written'
  assert_no_grep "\"rule\":\"rule-$((n + 1))\"" "$HOME_DIR/state/captain-rules/log.jsonl" 'the refused rule was logged as saved'

  ids=$(run_env "$RULES" list | cut -f1)
  assert_equals "$n" "$(printf '%s\n' "$ids" | grep -c .)" 'list lost a rule'
  local render session brief
  render=$(run_env env FM_RULES_MAX_CHARS=2000 "$RULES" render)
  session=$(run_env env FM_RULES_MAX_CHARS=2000 "$RULES" session </dev/null)
  brief=$(run_env "$RULES" brief-section)
  for id in $ids; do
    text=$(run_env "$RULES" list | awk -F'\t' -v id="$id" '$1 == id { print $3 }')
    assert_contains "$render" "- $text" "render dropped or cut $id"
    assert_contains "$session" "- $text" "the session hook dropped or cut $id"
    assert_contains "$brief" "- $text" "the brief section dropped or cut $id"
  done
  assert_equals "$render" "$session" 'the session block differs from render'

  # Consolidation always lands, even over budget; growth over budget never does.
  before=$(cat "$file")
  run_env env FM_RULES_MAX_CHARS=200 "$RULES" add rule-1 'Rule 1, consolidated.' >/dev/null \
    || fail 'restating a rule with a shorter text was refused over budget'
  assert_grep '- [rule-1] Rule 1, consolidated.' "$file" 'the consolidation did not land'
  out=$(run_env env FM_RULES_MAX_CHARS=200 "$RULES" add rule-2 "$(run_env "$RULES" list | awk -F'\t' '$1 == "rule-2" { print $3 }') More." 2>&1); rc=$?
  expect_code 4 "$rc" 'growing a rule over budget must be refused'
  run_env env FM_RULES_MAX_CHARS=200 "$RULES" revoke rule-3 >/dev/null || fail 'revoke was refused over budget'
  [ "$before" != "$(cat "$file")" ] || fail 'the store did not change'

  # A hand-edited store past the budget still renders whole.
  for i in $(seq 40 49); do
    printf -- '- [hand-%s] Hand edited rule %s with enough words to pass a tiny budget. <!-- since=2026-10-20 seen=1 -->\n' "$i" "$i" >> "$file"
  done
  out=$(run_env env FM_RULES_MAX_CHARS=200 "$RULES" render)
  for i in $(seq 40 49); do
    assert_contains "$out" "- Hand edited rule $i with enough words to pass a tiny budget." "render cut hand-edited rule $i"
  done
  assert_not_contains "$out" 'cut at' 'render still announced a cut'
  out=$(run_env env FM_RULES_MAX_CHARS=abc "$RULES" add x-rule 'X.' 2>&1); rc=$?
  expect_code 2 "$rc" 'an invalid budget must be a usage error'
  pass 'render, session, and brief-section carry every rule whole, and an overflowing write is refused before it is saved'
}

# Parallel writers each read, change, and rename the store; the store lock must
# make every successful write survive.
test_concurrent_writes_keep_every_rule() {
  local i dir="$TMP_ROOT/concurrent" cid seen ok=0
  fresh_home
  rm -rf "$dir"; mkdir -p "$dir"
  run_env "$RULES" add shared 'Shared rule.' >/dev/null || fail 'seeding the shared rule failed'
  for i in $(seq 1 10); do
    ( run_env "$RULES" add "rule-$i" "Rule $i." >/dev/null; printf '%s\n' "$?" > "$dir/add-$i" ) &
  done
  for i in $(seq 1 5); do
    ( run_env "$RULES" add shared 'Shared rule.' >/dev/null; printf '%s\n' "$?" > "$dir/repeat-$i" ) &
  done
  wait
  for i in "$dir"/*; do assert_equals 0 "$(cat "$i")" "concurrent write $(basename "$i") failed"; done
  for i in $(seq 1 10); do
    run_env "$RULES" list | grep -q "^rule-$i	" || fail "concurrent add rule-$i was lost"
  done
  seen=$(run_env "$RULES" list | awk -F'\t' '$1 == "shared" { print $2 }')
  assert_equals seen=6 "$seen" 'concurrent repeats lost a count'
  assert_equals 11 "$(run_env "$RULES" list | grep -c .)" 'concurrent writes lost or duplicated a rule'

  prompt 'from now on, never do that again' >/dev/null
  cid=$(basename "$(candidates)")
  for i in 1 2 3; do
    ( run_env "$RULES" confirm "$cid" "from-cand-$i" "Candidate rule $i." >/dev/null 2>&1; printf '%s\n' "$?" > "$dir/confirm-$i" ) &
  done
  wait
  for i in 1 2 3; do [ "$(cat "$dir/confirm-$i")" = 0 ] && ok=$((ok + 1)); done
  assert_equals 1 "$ok" 'one candidate was confirmed more than once, or never'
  assert_equals 1 "$(run_env "$RULES" list | grep -c '^from-cand-')" 'a single candidate produced several rules'
  pass 'concurrent adds, repeats, and confirms all survive with correct counts under the store lock'
}

# A tab is ordinary copied whitespace: it is stored as a space so no projection
# splits the rule, while other control characters are refused unsaved.
test_tabs_survive_and_control_characters_are_refused() {
  local out rc file="$HOME_DIR/config/captain-rules.md" view
  fresh_home
  out=$(run_env "$RULES" add tabbed $'Use\tthe clipboard\t\tfor sudo.') || fail "a tabbed rule was refused: $out"
  assert_equals 'added: tabbed' "$out" 'the tabbed add did not report success'
  for view in list render session brief-section; do
    out=$(run_env "$RULES" "$view" </dev/null)
    assert_contains "$out" 'Use the clipboard  for sudo.' "$view lost or split the tabbed rule"
    assert_not_contains "$out" 'seen 2026' "$view read the date as the repeat count"
  done
  assert_equals $'tabbed\tseen=1\tUse the clipboard  for sudo.' "$(run_env "$RULES" list)" 'list split the tabbed rule'
  printf -- '- [hand-tab] Hand\tedited rule. <!-- since=2026-10-20 seen=1 -->\n' >> "$file"
  assert_contains "$(run_env "$RULES" render)" '- Hand edited rule.' 'a hand-edited tab split the rendered rule'

  local before
  before=$(cat "$file")
  for text in $'Carriage\rreturn' $'Bell\arule' $'Two\nlines'; do
    out=$(run_env "$RULES" add ctrl-rule "$text" 2>&1); rc=$?
    expect_code 3 "$rc" 'a rule with a control character must be refused'
    assert_contains "$out" 'control characters' 'the refusal did not name control characters'
  done
  assert_equals "$before" "$(cat "$file")" 'a refused control-character rule changed the store'
  assert_no_grep '"rule":"ctrl-rule"' "$HOME_DIR/state/captain-rules/log.jsonl" 'a refused rule was logged as saved'
  pass 'tabs are stored as spaces so every projection keeps the rule whole, and control characters are refused unsaved'
}

# Stub tmux for fm-send's inbox doorbell, as tests/fm-send-inbox.test.sh does.
make_tmux_stub() {  # <dir> -> fakebin
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done; printf 'fakepane\n' ;;
  capture-pane) printf '\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 \xe2\x94\x82\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n' ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/tmux" "$fb/sleep"
  printf '%s\n' "$fb"
}

inbox_bodies() {  # <state-dir> <task-id> -> every record body, oldest first
  local rec
  for rec in "$1/$2.inbox"/*.msg "$1/$2.inbox/handled"/*.msg; do
    [ -f "$rec" ] || continue
    printf '%s\t%s\n' "$(basename "$rec")" "$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$rec" | tr '\n' ' ')"
  done | sort | cut -f2-
}

# Consumers that already loaded the rules - a running worker of this home, a
# secondmate home, and that secondmate's running worker - get every saved
# change without a restart or a manual push, and a consumer that cannot be
# reached is reported instead of claimed.
test_saved_changes_reach_running_consumers() {
  local fb sm="$TMP_ROOT/sm-home" out rc brief last
  fresh_home
  rm -rf "$sm"
  mkdir -p "$sm/state" "$sm/config" "$sm/data" "$sm/bin"
  printf 'sm\n' > "$sm/.fm-secondmate-home"
  : > "$sm/AGENTS.md"
  fb=$(make_tmux_stub "$TMP_ROOT")
  deliver_env() { run_env env PATH="$fb:$PATH" FM_SEND_SETTLE=0 "$@"; }

  deliver_env "$RULES" add first-rule 'First standing rule.' >/dev/null || fail 'seeding the first rule failed'
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" live-worker some-proj --scout >/dev/null || fail 'scaffolding the worker failed'
  brief="$HOME_DIR/data/live-worker/brief.md"
  assert_grep '- First standing rule.' "$brief" 'the existing worker brief lacks the first rule'
  fm_write_meta "$HOME_DIR/state/live-worker.meta" 'window=sess:fm-live-worker' 'kind=scout' 'harness=claude'
  fm_write_meta "$HOME_DIR/state/sm.meta" 'window=sess:fm-sm' 'kind=secondmate' 'harness=claude' "home=$sm"
  fm_write_meta "$sm/state/sm-worker.meta" 'window=sess:fm-sm-worker' 'kind=ship' 'harness=claude'

  out=$(deliver_env "$RULES" add new-rule 'Apply this new correction in every running worker now.' 2>&1) \
    || fail "saving a correction with live consumers failed: $out"
  assert_contains "$out" 'added: new-rule' 'the save did not report success'
  assert_contains "$out" '2 running worker(s), 1 secondmate home(s), 0 not reached' 'the save did not report its delivery'
  assert_grep '[new-rule] Apply this new correction' "$sm/config/captain-rules.md" 'the secondmate home did not receive the new rule'
  for last in "$(inbox_bodies "$HOME_DIR/state" live-worker | tail -n 1)" "$(inbox_bodies "$sm/state" sm-worker | tail -n 1)"; do
    assert_contains "$last" 'CAPTAIN RULES UPDATE' 'a running worker got no rules update'
    assert_contains "$last" '- Apply this new correction in every running worker now.' 'the update lacks the new rule'
    assert_contains "$last" '- First standing rule.' 'the update is not the complete set'
  done

  deliver_env "$RULES" add new-rule 'Apply the restated correction everywhere.' >/dev/null || fail 'restating the rule failed'
  last=$(inbox_bodies "$HOME_DIR/state" live-worker | tail -n 1)
  assert_contains "$last" '- Apply the restated correction everywhere.' 'a changed text did not reach the worker'
  assert_not_contains "$last" 'every running worker now' 'the worker still got the old text'
  deliver_env "$RULES" revoke new-rule >/dev/null || fail 'revoking the rule failed'
  last=$(inbox_bodies "$sm/state" sm-worker | tail -n 1)
  assert_not_contains "$last" 'restated correction' 'a revocation did not reach the secondmate worker'
  assert_no_grep '[new-rule]' "$sm/config/captain-rules.md" 'the revocation did not reach the secondmate home'
  local count
  count=$(inbox_bodies "$HOME_DIR/state" live-worker | grep -c 'CAPTAIN RULES UPDATE')
  deliver_env "$RULES" add first-rule 'First standing rule.' >/dev/null || fail 'repeating the unchanged rule failed'
  assert_equals "$count" "$(inbox_bodies "$HOME_DIR/state" live-worker | grep -c 'CAPTAIN RULES UPDATE')" \
    'an unchanged repeat sent a redundant update'

  printf 'not a directory\n' > "$HOME_DIR/state/stuck.inbox"
  fm_write_meta "$HOME_DIR/state/stuck.meta" 'window=sess:fm-stuck' 'kind=ship' 'harness=claude'
  out=$(deliver_env "$RULES" add late-rule 'A rule one worker cannot receive.' 2>&1); rc=$?
  expect_code 5 "$rc" 'an unreached consumer must exit 5'
  assert_contains "$out" 'added: late-rule' 'the save itself was not reported'
  assert_contains "$out" 'not delivered: worker stuck' 'the unreached worker was not named'
  assert_contains "$out" 'fm-rules.sh deliver' 'the failure did not name the retry'
  assert_grep '[late-rule]' "$HOME_DIR/config/captain-rules.md" 'the rule was not saved'
  rm -f "$HOME_DIR/state/stuck.inbox" "$HOME_DIR/state/stuck.meta"
  out=$(deliver_env "$RULES" deliver 2>&1) || fail "the retry failed: $out"
  assert_contains "$(inbox_bodies "$HOME_DIR/state" live-worker | tail -n 1)" '- A rule one worker cannot receive.' 'the retry did not deliver'
  pass 'saved additions, restatements, and revocations reach running workers and secondmate homes, and an unreached consumer is reported'
}

# A fixture bin/ whose scripts are the real ones, except the SSH transport
# (fm-on.sh runs the command in a local stand-in for the remote home, or fails
# with ssh's 255 while $FM_FAKE_REMOTE_DOWN exists) and the config push (copies
# the rule file into that home unless $FM_FAKE_PUSH_STALE exists).
make_remote_fixture_bin() {  # <dir> -> fixture bin
  local fx="$1/fixbin" f
  rm -rf "$fx"
  mkdir -p "$fx"
  for f in "$ROOT"/bin/*; do ln -s "$f" "$fx/${f##*/}"; done
  rm -f "$fx/fm-on.sh" "$fx/fm-config-push.sh"
  cat > "$fx/fm-on.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --stdin ] || shift
shift
cmd=$1
shift
[ ! -e "$FM_FAKE_REMOTE_DOWN" ] || exit 255
exec env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
  FM_HOME="$FM_FAKE_REMOTE_HOME" "$FM_FAKE_REAL_BIN/$cmd" "$@"
SH
  cat > "$fx/fm-config-push.sh" <<'SH'
#!/usr/bin/env bash
[ ! -e "$FM_FAKE_PUSH_STALE" ] || exit 0
mkdir -p "$FM_FAKE_REMOTE_HOME/config"
if [ -f "$FM_HOME/config/captain-rules.md" ]; then
  cp "$FM_HOME/config/captain-rules.md" "$FM_FAKE_REMOTE_HOME/config/captain-rules.md"
else
  rm -f "$FM_FAKE_REMOTE_HOME/config/captain-rules.md"
fi
SH
  chmod +x "$fx/fm-on.sh" "$fx/fm-config-push.sh"
  printf '%s\n' "$fx"
}

test_registry_and_remote_secondmates_reach_their_workers() {
  local fb sm="$TMP_ROOT/sm-home" rm_home="$TMP_ROOT/remote-home" fx out rc
  fresh_home
  rm -rf "$sm" "$rm_home"
  mkdir -p "$sm/state" "$sm/config" "$sm/data" "$sm/bin" "$rm_home/state" "$rm_home/config" "$rm_home/data"
  printf 'sm\n' > "$sm/.fm-secondmate-home"
  printf 'rm\n' > "$rm_home/.fm-secondmate-home"
  : > "$sm/AGENTS.md"
  : > "$rm_home/AGENTS.md"
  fb=$(make_tmux_stub "$TMP_ROOT")
  deliver_env() { run_env env PATH="$fb:$PATH" FM_SEND_SETTLE=0 "$@"; }

  # A live secondmate meta without home=, whose home only the registry records.
  printf -- '- sm - fixture mate (home: %s; scope: fixture; projects: -; added 2026-10-20)\n' "$sm" \
    > "$HOME_DIR/data/secondmates.md"
  fm_write_meta "$HOME_DIR/state/sm.meta" 'window=sess:fm-sm' 'kind=secondmate' 'harness=claude'
  fm_write_meta "$sm/state/sm-worker.meta" 'window=sess:fm-sm-worker' 'kind=ship' 'harness=claude'
  out=$(deliver_env "$RULES" add correction 'Apply the new correction immediately.' 2>&1) \
    || fail "a registry-only secondmate home was not reached: $out"
  assert_contains "$out" '1 running worker(s), 1 secondmate home(s), 0 not reached' 'the registry-only home did not count its worker'
  assert_contains "$(inbox_bodies "$sm/state" sm-worker | tail -n 1)" '- Apply the new correction immediately.' \
    'the worker of a registry-only secondmate home got no update'

  # A live secondmate with neither home= nor a registry home is reported, never skipped.
  fm_write_meta "$HOME_DIR/state/lost.meta" 'window=sess:fm-lost' 'kind=secondmate' 'harness=claude'
  out=$(deliver_env "$RULES" deliver 2>&1); rc=$?
  expect_code 5 "$rc" 'a secondmate without a resolvable home must count as not reached'
  assert_contains "$out" 'secondmate lost has no home= and no registry home' 'the unresolved home was not named'
  rm -f "$HOME_DIR/state/lost.meta" "$HOME_DIR/state/sm.meta"

  # A remote secondmate delivers to its own running workers through its route.
  fx=$(make_remote_fixture_bin "$TMP_ROOT")
  remote_env() {
    deliver_env env FM_FAKE_REMOTE_HOME="$rm_home" FM_FAKE_REAL_BIN="$ROOT/bin" \
      FM_FAKE_REMOTE_DOWN="$TMP_ROOT/remote-down" FM_FAKE_PUSH_STALE="$TMP_ROOT/push-stale" "$@"
  }
  rm -f "$TMP_ROOT/remote-down" "$TMP_ROOT/push-stale"
  printf -- '- rm - remote mate (host: fixture-host; root: %s; home: %s; scope: fixture; projects: -; added 2026-10-20)\n' \
    "$ROOT" "$rm_home" > "$HOME_DIR/data/secondmates.md"
  fm_write_meta "$HOME_DIR/state/rm.meta" 'window=sess:fm-rm' 'kind=secondmate' 'harness=claude' \
    "home=$rm_home" 'remote_host=fixture-host'
  fm_write_meta "$rm_home/state/rm-worker.meta" 'window=sess:fm-rm-worker' 'kind=ship' 'harness=claude'
  out=$(remote_env "$fx/fm-rules.sh" add remote-rule 'Reach the remote workers too.' 2>&1) \
    || fail "a remote secondmate's workers were not reached: $out"
  assert_contains "$out" '1 running worker(s), 1 secondmate home(s), 0 not reached' 'the remote worker was not counted'
  assert_contains "$(inbox_bodies "$rm_home/state" rm-worker | tail -n 1)" '- Reach the remote workers too.' \
    'the remote secondmate did not hand the update to its worker'

  # A transport failure is reported, and the printed retry recovers it.
  : > "$TMP_ROOT/remote-down"
  out=$(remote_env "$fx/fm-rules.sh" add outage-rule 'Survive a remote outage.' 2>&1); rc=$?
  expect_code 5 "$rc" 'an unreachable remote secondmate must exit 5'
  assert_contains "$out" 'not delivered: the running workers of secondmate rm' 'the unreachable remote was not named'
  assert_not_contains "$(inbox_bodies "$rm_home/state" rm-worker | tail -n 1)" 'Survive a remote outage.' \
    'the remote worker got an update across a failed route'
  rm -f "$TMP_ROOT/remote-down"
  out=$(remote_env "$fx/fm-rules.sh" deliver 2>&1) || fail "the retry after the outage failed: $out"
  assert_contains "$(inbox_bodies "$rm_home/state" rm-worker | tail -n 1)" '- Survive a remote outage.' \
    'the retry did not reach the remote worker'

  # A home whose copy did not arrive is reported instead of re-sending its old set.
  : > "$TMP_ROOT/push-stale"
  out=$(remote_env "$fx/fm-rules.sh" add stale-rule 'Never resend an old set.' 2>&1); rc=$?
  expect_code 5 "$rc" 'a secondmate with a stale copy must exit 5'
  assert_contains "$out" 'secondmate rm still has rule set' 'the stale copy was not named'
  assert_not_contains "$(inbox_bodies "$rm_home/state" rm-worker | tail -n 1)" 'Never resend an old set.' \
    'the remote worker got a set its home does not have'
  rm -f "$TMP_ROOT/push-stale"
  out=$(remote_env "$fx/fm-rules.sh" deliver 2>&1) || fail "the retry after the stale push failed: $out"
  assert_contains "$(inbox_bodies "$rm_home/state" rm-worker | tail -n 1)" '- Never resend an old set.' \
    'the retry did not deliver the current set'
  pass 'registry-only and remote secondmate homes hand each saved change to their own running workers, and failures are retried'
}

test_unsafe_secondmate_homes_are_never_entered() {
  local fb dir state out rc case
  fresh_home
  fb=$(make_tmux_stub "$TMP_ROOT")
  # Each case: a live secondmate record whose home= fails the shared home
  # validation, with a running worker recorded under the state it would read.
  for case in unseeded mismatched forbidden escaping; do
    dir="$TMP_ROOT/unsafe-$case"
    [ "$case" != forbidden ] || dir="$HOME_DIR/nested-mate"
    rm -rf "$dir" "$TMP_ROOT/escaped-state"
    mkdir -p "$dir/bin" "$dir/config" "$dir/data"
    : > "$dir/AGENTS.md"
    case "$case" in
      unseeded) ;;
      mismatched) printf 'other\n' > "$dir/.fm-secondmate-home" ;;
      *) printf 'bad\n' > "$dir/.fm-secondmate-home" ;;
    esac
    state="$dir/state"
    if [ "$case" = escaping ]; then
      mkdir -p "$TMP_ROOT/escaped-state"
      ln -s "$TMP_ROOT/escaped-state" "$state"
      state="$TMP_ROOT/escaped-state"
    else
      mkdir -p "$state"
    fi
    fm_write_meta "$state/foreign.meta" 'window=sess:fm-foreign' 'kind=ship' 'harness=claude'
    fm_write_meta "$HOME_DIR/state/bad.meta" 'window=sess:fm-bad' 'kind=secondmate' 'harness=claude' "home=$dir"
    out=$(run_env env PATH="$fb:$PATH" FM_SEND_SETTLE=0 "$RULES" deliver 2>&1); rc=$?
    expect_code 5 "$rc" "a $case secondmate home must count as not reached"
    assert_contains "$out" 'not delivered: secondmate bad home' "the $case home was not named as unsafe"
    assert_absent "$state/foreign.inbox" "delivery entered the $case home and wrote to its worker"
    rm -rf "$dir"
  done
  pass 'secondmate homes that fail the shared home validation are reported and never entered'
}

test_writes_refuse_in_a_secondmate_home() {
  local out rc
  fresh_home
  printf 'mate-a\n' > "$HOME_DIR/.fm-secondmate-home"
  out=$(run_env "$RULES" add some-rule 'Some rule.' 2>&1); rc=$?
  expect_code 2 "$rc" 'a secondmate home must refuse to record a rule'
  assert_contains "$out" 'primary home only' 'the secondmate refusal did not explain itself'
  assert_absent "$HOME_DIR/config/captain-rules.md" 'a secondmate home wrote a rule file'
  pass 'rule writes refuse in a secondmate home, whose config is a primary copy'
}

test_prompt_hook_captures_and_confirms() {
  local out cid file="$HOME_DIR/config/captain-rules.md" context
  fresh_home
  for text in 'merge it' 'looks good, ship the wiki page' 'FIRSTMATE SUPERVISION WAKE ab jetzt nie wieder' \
    '<task-notification>ab jetzt</task-notification>' \
    'see this <pasted_content id="x">ab jetzt nie wieder falsch</pasted_content> and summarize it'; do
    out=$(prompt "$text") || fail "hook failed on: $text"
    [ -z "$out" ] || fail "hook raised a candidate for: $text"
  done
  [ -z "$(candidates)" ] || fail 'non-corrections left candidates behind'

  out=$(prompt 'hab ich dir schon gesagt: kein ! fuer sudo, nimm pbcopy') || fail 'hook failed on a correction'
  context=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext') || fail "hook output is not JSON: $out"
  assert_equals UserPromptSubmit "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" 'hook named the wrong event'
  cid=$(basename "$(candidates)")
  assert_contains "$context" "CAPTAIN RULE CANDIDATE $cid" 'the injected instruction did not name its candidate'
  assert_contains "$context" "fm-rules.sh confirm $cid" 'the instruction did not give the confirm command'
  assert_contains "$context" '"nein" nimmt sie zurueck' 'the instruction did not carry the one-line confirmation'
  assert_absent "$file" 'the hook wrote a rule by itself'

  run_env "$RULES" confirm --check bang-interactive "$cid" no-bang-sudo 'Never hand the captain a "! <cmd>" line for sudo.' >/dev/null \
    || fail 'confirm failed'
  assert_grep '- [no-bang-sudo] Never hand the captain a "! <cmd>" line for sudo. <!-- since=2026-10-20 seen=1 check=bang-interactive -->' "$file" \
    'confirm did not record the rule with its check'
  [ -z "$(candidates)" ] || fail 'confirm left its candidate open'

  out=$(prompt 'Nein.')
  assert_contains "$out" 'fm-rules.sh revoke no-bang-sudo' 'a bare nein right after a confirm did not inject the revoke'
  printf '%s no-bang-sudo\n' "$(( $(date +%s) - 4000 ))" > "$HOME_DIR/state/captain-rules/last-confirmed"
  [ -z "$(prompt 'nein')" ] || fail 'a nein long after the confirm still injected a revoke'

  prompt 'that is wrong, never do that again' >/dev/null
  cid=$(basename "$(candidates)")
  run_env "$RULES" dismiss "$cid" >/dev/null || fail 'dismiss failed'
  [ -z "$(candidates)" ] || fail 'dismiss left its candidate open'
  assert_equals 1 "$(run_env "$RULES" list | grep -c .)" 'dismiss changed the rule set'
  pass 'the capture hook raises candidates only for corrections, never writes rules, and supports confirm, dismiss, and nein'
}

test_hooks_stand_down_outside_their_scope() {
  local guard out
  fresh_home
  run_env "$RULES" add some-rule 'Some rule.' >/dev/null || fail 'seeding a rule failed'
  for guard in FM_TASK_ID=t1 FM_SUPERVISION_ACTOR=branch FM_MEMORY_CAPTURE_CHILD=1 NO_MISTAKES_GATE=1; do
    out=$(jq -nc '{prompt:"ab jetzt nie wieder"}' | run_env env -u FM_GATE_REFUSE_BYPASS "$guard" "$RULES" prompt-hook) \
      || fail "prompt hook failed under $guard"
    [ -z "$out" ] || fail "prompt hook raised a candidate under $guard"
    out=$(run_env env -u FM_GATE_REFUSE_BYPASS "$guard" "$RULES" session </dev/null) || fail "session hook failed under $guard"
    [ -z "$out" ] || fail "session hook loaded rules under $guard"
  done
  out=$(jq -nc '{prompt:"ab jetzt nie wieder"}' | run_env env FM_ROOT_OVERRIDE="$TMP_ROOT/not-primary" "$RULES" prompt-hook)
  [ -z "$out" ] || fail 'prompt hook ran outside a primary root'
  [ -z "$(candidates)" ] || fail 'an out-of-scope hook left a candidate'

  printf 'mate-a\n' > "$HOME_DIR/.fm-secondmate-home"
  out=$(jq -nc '{prompt:"ab jetzt nie wieder"}' | run_env "$RULES" prompt-hook)
  [ -z "$out" ] || fail 'a secondmate home raised a candidate'
  out=$(run_env "$RULES" session </dev/null)
  assert_contains "$out" '- Some rule.' 'a secondmate seat did not load the inherited rules'
  pass 'capture runs only in the primary main session and the session block reaches main and secondmate seats only'
}

test_registered_claude_entries_reach_the_script() {
  local command out
  fresh_home
  run_env "$RULES" add some-rule 'Some rule.' >/dev/null || fail 'seeding a rule failed'
  command=$(jq -r '.hooks.SessionStart[].hooks[].command | select(test("fm-rules.sh session"))' "$ROOT/.claude/settings.json")
  [ -n "$command" ] || fail 'settings.json registers no fm-rules.sh session hook'
  for source in startup resume compact clear; do
    out=$(printf '{"source":"%s"}' "$source" | run_env env CLAUDE_PROJECT_DIR="$ROOT" bash -c "$command") \
      || fail "registered session hook failed on $source"
    assert_contains "$out" '- Some rule.' "registered session hook dropped the rules on $source"
  done
  command=$(jq -r '.hooks.UserPromptSubmit[].hooks[].command | select(test("fm-rules.sh prompt-hook"))' "$ROOT/.claude/settings.json")
  [ -n "$command" ] || fail 'settings.json registers no fm-rules.sh prompt-hook'
  out=$(jq -nc '{prompt:"from now on, never use that tool"}' | run_env env CLAUDE_PROJECT_DIR="$ROOT" bash -c "$command")
  assert_contains "$out" 'CAPTAIN RULE CANDIDATE' 'the registered prompt hook did not raise a candidate'
  pass 'the registered Claude SessionStart and UserPromptSubmit entries reach fm-rules.sh'
}

test_briefs_carry_the_rules() {
  local home="$TMP_ROOT/brief-home" brief kind
  rm -rf "$home"
  mkdir -p "$home/config"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" rules-absent some-proj --scout >/dev/null || fail 'scout scaffold failed without rules'
  assert_no_grep '# Captain rules' "$home/data/rules-absent/brief.md" 'a home without rules still added a section'

  FM_HOME="$home" FM_ROOT_OVERRIDE="$FAKE_ROOT" "$RULES" add pbcopy-for-sudo 'Hand sudo steps over through pbcopy.' >/dev/null \
    || fail 'seeding a rule failed'
  for kind in ship scout; do
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "rules-$kind" some-proj --scout >/dev/null || fail 'scout scaffold failed'
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "rules-$kind" some-proj --mode no-mistakes >/dev/null || fail 'ship scaffold failed'
    fi
    brief="$home/data/rules-$kind/brief.md"
    assert_grep '# Captain rules' "$brief" "$kind brief lost the captain rules section"
    assert_grep '- Hand sudo steps over through pbcopy.' "$brief" "$kind brief lost the rule"
    assert_grep "this brief's task scope and safety rules still win" "$brief" "$kind brief lost the precedence wording"
  done
  FM_HOME="$home" FM_SECONDMATE_CHARTER='Supervise assigned work.' \
    "$ROOT/bin/fm-brief.sh" rules-mate --secondmate --no-projects >/dev/null || fail 'secondmate scaffold failed'
  assert_no_grep '# Captain rules' "$home/data/rules-mate/brief.md" 'a secondmate charter took the rules section'
  pass 'ship and scout briefs carry the captain rules; charters and rule-free homes carry none'
}

test_report_and_weekly_check() {
  local tdir="$TMP_ROOT/transcripts" now out shim
  fresh_home
  now=$(date +%s)
  mkdir -p "$tdir"
  {
    jq -nc --arg t "$(date -u -r $((now - 3600)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((now - 3600))" +%Y-%m-%dT%H:%M:%SZ)" \
      '{type:"user",timestamp:$t,message:{content:"wie oft noch, mach es selbst"}}'
    jq -nc --arg t "$(date -u -r $((now - 3500)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((now - 3500))" +%Y-%m-%dT%H:%M:%SZ)" \
      '{type:"user",timestamp:$t,message:{content:"FIRSTMATE SUPERVISION WAKE ab jetzt"}}'
    jq -nc --arg t "$(date -u -r $((now - 3400)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((now - 3400))" +%Y-%m-%dT%H:%M:%SZ)" \
      '{type:"user",timestamp:$t,message:{content:"thanks, ship it"}}'
    jq -nc '{type:"user",timestamp:"2020-01-01T00:00:00Z",message:{content:"schon wieder, from an old week"}}'
  } > "$tdir/session.jsonl"
  run_env "$RULES" add a-rule 'A rule.' >/dev/null
  run_env "$RULES" add a-rule 'A rule, restated.' >/dev/null
  printf '%s\n' '{"schema":"fm-rules-event.v1","at":"2999-01-01T00:00:00Z","event":"guard-block","check":"bang-interactive","hash":"x"}' \
    >> "$HOME_DIR/state/captain-rules/log.jsonl"

  out=$(run_env "$RULES" weekly-check) || fail 'weekly-check failed'
  assert_contains "$out" 'weekly report due' 'a home that never ran a report was not reminded'
  [ -z "$(run_env "$RULES" weekly-check)" ] || fail 'the reminder repeated within the same due week'

  out=$(run_env "$RULES" report --transcripts "$tdir" --now "$now") || fail "report failed: $out"
  assert_contains "$out" 'Rules: 1 total, 1 added, 1 repeated.' 'report miscounted rules'
  assert_contains "$out" '- a-rule: recorded again 1 time(s) this period, seen 2 in total, no check' 'report missed the repeat'
  assert_contains "$out" '- bang-interactive: 1' 'report missed the guard block'
  assert_contains "$out" '- a-rule (seen 2 times): A rule, restated.' 'report missed the unchecked repeat'
  assert_contains "$out" 'correction-like captain prompts in' 'report skipped the transcripts'
  assert_contains "$out" 'wie oft noch, mach es selbst' 'report missed a correction in the transcript'
  assert_not_contains "$out" 'SUPERVISION WAKE' 'report counted a wake as a captain correction'
  assert_not_contains "$out" 'from an old week' 'report counted a prompt from outside the window'
  assert_not_contains "$out" 'ship it' 'report counted a plain prompt'
  [ -z "$(run_env "$RULES" weekly-check)" ] || fail 'a fresh report did not quiet the weekly reminder'

  run_env "$RULES" weekly-arm >/dev/null || fail 'weekly-arm failed'
  shim="$HOME_DIR/state/captain-rules-weekly.check.sh"
  assert_present "$shim" 'weekly-arm wrote no check shim'
  [ "$(stat -c %a "$shim" 2>/dev/null || stat -f %Lp "$shim")" = 700 ] || fail 'the check shim is not mode 700'
  assert_present "$HOME_DIR/state/captain-rules-weekly.check-trust" 'weekly-arm did not register the check'
  out=$(env -u FM_HOME "$shim") || fail 'the armed shim failed'
  [ -z "$out" ] || fail 'the armed shim reminded right after a report'
  run_env "$RULES" weekly-disarm >/dev/null || fail 'weekly-disarm failed'
  assert_absent "$shim" 'weekly-disarm left the shim'
  assert_absent "$HOME_DIR/state/captain-rules-weekly.check-trust" 'weekly-disarm left the registration'
  pass 'the weekly report counts repeats, blocks, unchecked rules, and transcript corrections, and the check reminds once per due week'
}

test_store_records_repeats_and_checks
test_projections_carry_every_rule_and_overflow_is_refused
test_concurrent_writes_keep_every_rule
test_tabs_survive_and_control_characters_are_refused
test_saved_changes_reach_running_consumers
test_registry_and_remote_secondmates_reach_their_workers
test_unsafe_secondmate_homes_are_never_entered
test_writes_refuse_in_a_secondmate_home
test_prompt_hook_captures_and_confirms
test_hooks_stand_down_outside_their_scope
test_registered_claude_entries_reach_the_script
test_briefs_carry_the_rules
test_report_and_weekly_check

echo "# fm-rules.test.sh: all assertions passed"
