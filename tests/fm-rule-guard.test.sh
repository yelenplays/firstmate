#!/usr/bin/env bash
# Behavior tests for bin/fm-rule-guard.sh.
#
# Feeds real reply text and Claude Stop payloads to the guard: the
# bang-interactive check's hits and quoted-rule passes, the block with its
# rewrite hint, the bounded block count that ends in a captain-facing halt and
# never in a successful violating stop, fail-open on a missing reply, the scope
# guards, and the registered settings.json entry.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-rule-guard)
GUARD="$ROOT/bin/fm-rule-guard.sh"
HOME_DIR="$TMP_ROOT/home"
FAKE_ROOT="$TMP_ROOT/primary"

run_env() {
  env -u FM_TASK_ID -u FM_SUPERVISION_ACTOR -u FM_MEMORY_CAPTURE_CHILD -u NO_MISTAKES_GATE \
    -u FM_STATE_OVERRIDE FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" "$@"
}

fresh_home() {
  rm -rf "$HOME_DIR" "$FAKE_ROOT"
  mkdir -p "$HOME_DIR/state" "$FAKE_ROOT/bin"
  : > "$FAKE_ROOT/AGENTS.md"
  git -C "$FAKE_ROOT" init -q
}

stop() {  # <reply> <stop_hook_active> [env assignments...] -> exit code; stdout in $HOME_DIR/out, stderr in $HOME_DIR/err
  local reply=$1 active=$2
  shift 2
  jq -nc --arg m "$reply" --argjson a "$active" --arg s "${SESSION:-s-1}" \
    '{session_id:$s,last_assistant_message:$m,stop_hook_active:$a}' \
    | run_env "$@" "$GUARD" --claude > "$HOME_DIR/out" 2> "$HOME_DIR/err"
}

# A stop that lets the turn end successfully: exit 0 without continue:false.
stop_succeeded() {  # <rc>
  [ "$1" -eq 0 ] && [ "$(jq -r 'if .continue == false then "halt" else "go" end' "$HOME_DIR/out" 2>/dev/null || echo go)" = go ]
}

test_scan_flags_handed_over_interactive_lines() {
  local text out rc
  # shellcheck disable=SC2016 # Backticks are literal reply markdown.
  for text in '! sudo darwin-rebuild switch --flake .' 'Run this:  `! gh auth login`' \
    'Then: ! ~/dotfiles/rebuild.sh' '(! security add-generic-password -s x)' '> ! op signin' \
    '! sudo -v' '- ! passwd' 'no worries, run ! sudo darwin-rebuild switch' \
    'No worries you can now run ! sudo darwin-rebuild switch' \
    'No worries now run ! sudo darwin-rebuild switch' 'no worries run ! sudo -v' \
    'Kein Problem: `! sudo -v`' 'No problem, run `! gh auth login`' \
    'Never use the old command; run `! sudo -v` instead.' 'keine Sorge einfach ! sudo -v' \
    'nicht vergessen ! sudo -v' "don't forget ! sudo -v" 'vergiss nicht ! sudo -v' \
    'No worries - run ! sudo -v' 'Not sure? run ! sudo -v'; do
    out=$(printf '%s\n' "$text" | "$GUARD" scan); rc=$?
    expect_code 1 "$rc" "scan missed: $text"
    assert_contains "$out" 'bang-interactive: ' "scan did not name the check for: $text"
  done
  # shellcheck disable=SC2016 # Backticks are literal reply markdown.
  for text in 'Never hand the captain a `! sudo` line.' 'Nie wieder `! gh auth login` schicken.' \
    'Done! sudo is no longer needed.' 'Wow! login works now.' '! git status' 'Use pbcopy, not ! sudo.' \
    'sudo darwin-rebuild switch (pasted into Terminal)' 'Never run ! sudo -v' \
    'Do not ever run ! sudo -v' 'Never hand the captain a "! <cmd>" line for sudo.' \
    'Statt ! sudo -v nimm pbcopy.' 'Use pbcopy instead of ! gh auth login.'; do
    out=$(printf '%s\n' "$text" | "$GUARD" scan) || fail "scan flagged: $text ($out)"
  done
  assert_contains "$("$GUARD" list)" 'bang-interactive' 'list did not print the check registry'
  pass 'bang-interactive flags handed-over sudo, rebuild, login, password, and keychain lines and passes quoted rules'
}

test_claude_stop_blocks_until_a_halt() {
  local rc log="$HOME_DIR/state/captain-rules/log.jsonl" reply i
  fresh_home
  reply=$'Bitte im Terminal:\n! sudo darwin-rebuild switch'
  stop "$reply" false; rc=$?
  expect_code 2 "$rc" 'a reply handing over ! sudo must block the stop'
  assert_grep 'CAPTAIN RULE BLOCK (bang-interactive)' "$HOME_DIR/err" 'the block did not name its check'
  assert_grep '! sudo darwin-rebuild switch' "$HOME_DIR/err" 'the block did not quote the offending line'
  assert_grep 'pbcopy' "$HOME_DIR/err" 'the block did not give the pbcopy rewrite'
  assert_grep 'block 1 of 3' "$HOME_DIR/err" 'the block did not count itself'
  assert_grep '"event":"guard-block"' "$log" 'the block was not logged'

  # The same reply on every forced continuation keeps blocking up to the cap,
  # then halts the turn; no violating stop ever ends as a success.
  for i in 2 3; do
    stop "$reply" true; rc=$?
    expect_code 2 "$rc" "repeat $i of the blocked reply must still block"
    assert_grep "block $i of 3" "$HOME_DIR/err" "repeat $i did not count up"
  done
  stop "$reply" true; rc=$?
  stop_succeeded "$rc" && fail 'a violating reply past the cap ended the turn as a success'
  expect_code 0 "$rc" 'the halt must reach Claude Code as Stop JSON on exit 0'
  assert_equals false "$(jq -r '.continue' "$HOME_DIR/out")" 'the halt did not set continue:false'
  assert_contains "$(jq -r '.stopReason' "$HOME_DIR/out")" 'Do not run that "!" line' 'the halt reason did not warn the captain'
  assert_contains "$(jq -r '.stopReason' "$HOME_DIR/out")" 'real Terminal window' 'the halt reason did not name the safe path'
  assert_equals 1 "$(grep -c '"event":"guard-halt"' "$log")" 'the halt was not logged once'
  assert_no_grep 'guard-release' "$log" 'the guard still released a violating reply'

  # After a halt, and after any clean stop, a new violation starts at block 1.
  stop "$reply" false; rc=$?
  expect_code 2 "$rc" 'a new turn after a halt must block again'
  assert_grep 'block 1 of 3' "$HOME_DIR/err" 'a new turn did not restart the count'
  stop "$reply" true; rc=$?
  expect_code 2 "$rc" 'the continuation must block'
  stop 'Kopiert per pbcopy; bitte im Terminal einfuegen.' true || fail 'a rewritten reply was blocked'
  stop $'Another try:\n! sudo -v' true; rc=$?
  expect_code 2 "$rc" 'a violation after a clean stop must block'
  assert_grep 'block 1 of 3' "$HOME_DIR/err" 'a clean stop did not reset the count'

  # Counts are per session, and the cap is configurable; 0 halts at once.
  SESSION=s-2 stop "$reply" true; rc=$?
  assert_grep 'block 1 of 3' "$HOME_DIR/err" 'another session inherited this session'"'"'s count'
  SESSION=s-3 stop "$reply" false FM_RULE_GUARD_BLOCK_CAP=0; rc=$?
  stop_succeeded "$rc" && fail 'a zero cap let a violating reply succeed'
  assert_equals false "$(jq -r '.continue' "$HOME_DIR/out")" 'a zero cap did not halt the first violation'

  stop 'All done, nothing for you to run.' false || fail 'a clean reply was blocked'
  printf '{}' | run_env "$GUARD" --claude || fail 'a payload without a reply did not fail open'
  printf '{"last_assistant_message":42}' | run_env "$GUARD" --claude || fail 'a non-string reply did not fail open'
  printf 'not json' | run_env "$GUARD" --claude || fail 'a malformed payload did not fail open'
  pass 'the Claude Stop guard blocks with a rewrite hint, halts at the cap instead of releasing, and fails open'
}

test_claude_stop_scope() {
  local guard reply=$'Run:\n! sudo darwin-rebuild switch'
  fresh_home
  for guard in FM_TASK_ID=t1 FM_SUPERVISION_ACTOR=branch FM_MEMORY_CAPTURE_CHILD=1 NO_MISTAKES_GATE=1; do
    stop "$reply" false env -u FM_GATE_REFUSE_BYPASS "$guard" || fail "the guard blocked under $guard"
  done
  stop "$reply" false env FM_ROOT_OVERRIDE="$TMP_ROOT/not-primary" || fail 'the guard blocked outside a primary root'
  assert_absent "$HOME_DIR/state/captain-rules" 'an out-of-scope stop wrote guard state'
  printf 'mate-a\n' > "$HOME_DIR/.fm-secondmate-home"
  stop "$reply" false && fail 'a secondmate seat, which talks to the captain too, was not guarded'
  pass 'the guard binds primary seats only, never workers, gates, or the supervision branch'
}

test_registered_stop_entry_reaches_the_guard() {
  local command rc
  fresh_home
  command=$(jq -r '.hooks.Stop[].hooks[].command | select(test("fm-rule-guard.sh --claude"))' "$ROOT/.claude/settings.json")
  [ -n "$command" ] || fail 'settings.json registers no fm-rule-guard.sh Stop hook'
  jq -nc '{last_assistant_message:"! sudo darwin-rebuild switch",stop_hook_active:false}' \
    | run_env env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$ROOT" bash -c "$command" 2>/dev/null; rc=$?
  expect_code 2 "$rc" 'the registered Stop entry did not block a violating reply'
  pass 'the registered Claude Stop entry reaches fm-rule-guard.sh'
}

test_scan_flags_handed_over_interactive_lines
test_claude_stop_blocks_until_a_halt
test_claude_stop_scope
test_registered_stop_entry_reaches_the_guard

echo "# fm-rule-guard.test.sh: all assertions passed"
