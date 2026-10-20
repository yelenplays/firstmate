#!/usr/bin/env bash
# Behavior tests for bin/fm-rule-guard.sh.
#
# Feeds real reply text and Claude Stop payloads to the guard: the
# bang-interactive check's hits and quoted-rule passes, the block with its
# rewrite hint, the release on a repeated forced continuation, fail-open on a
# missing reply, the scope guards, and the registered settings.json entry.
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

stop() {  # <reply> <stop_hook_active> [env assignments...] -> exit code; stderr in $HOME_DIR/err
  local reply=$1 active=$2
  shift 2
  jq -nc --arg m "$reply" --argjson a "$active" '{last_assistant_message:$m,stop_hook_active:$a}' \
    | run_env "$@" "$GUARD" --claude 2> "$HOME_DIR/err"
}

test_scan_flags_handed_over_interactive_lines() {
  local text out rc
  # shellcheck disable=SC2016 # Backticks are literal reply markdown.
  for text in '! sudo darwin-rebuild switch --flake .' 'Run this:  `! gh auth login`' \
    'Then: ! ~/dotfiles/rebuild.sh' '(! security add-generic-password -s x)' '> ! op signin' \
    '! sudo -v' '- ! passwd' 'no worries, run ! sudo darwin-rebuild switch'; do
    out=$(printf '%s\n' "$text" | "$GUARD" scan); rc=$?
    expect_code 1 "$rc" "scan missed: $text"
    assert_contains "$out" 'bang-interactive: ' "scan did not name the check for: $text"
  done
  # shellcheck disable=SC2016 # Backticks are literal reply markdown.
  for text in 'Never hand the captain a `! sudo` line.' 'Nie wieder `! gh auth login` schicken.' \
    'Done! sudo is no longer needed.' 'Wow! login works now.' '! git status' 'Use pbcopy, not ! sudo.' \
    'sudo darwin-rebuild switch (pasted into Terminal)'; do
    out=$(printf '%s\n' "$text" | "$GUARD" scan) || fail "scan flagged: $text ($out)"
  done
  assert_contains "$("$GUARD" list)" 'bang-interactive' 'list did not print the check registry'
  pass 'bang-interactive flags handed-over sudo, rebuild, login, password, and keychain lines and passes quoted rules'
}

test_claude_stop_blocks_and_releases() {
  local rc log="$HOME_DIR/state/captain-rules/log.jsonl" reply
  fresh_home
  reply=$'Bitte im Terminal:\n! sudo darwin-rebuild switch'
  stop "$reply" false; rc=$?
  expect_code 2 "$rc" 'a reply handing over ! sudo must block the stop'
  assert_grep 'CAPTAIN RULE BLOCK (bang-interactive)' "$HOME_DIR/err" 'the block did not name its check'
  assert_grep '! sudo darwin-rebuild switch' "$HOME_DIR/err" 'the block did not quote the offending line'
  assert_grep 'pbcopy' "$HOME_DIR/err" 'the block did not give the pbcopy rewrite'
  assert_grep '"event":"guard-block"' "$log" 'the block was not logged'

  stop "$reply" true; rc=$?
  expect_code 0 "$rc" 'the same reply on the forced continuation must be released'
  assert_grep '"event":"guard-release"' "$log" 'the release was not logged'
  stop $'Another try:\n! sudo -v' true; rc=$?
  expect_code 2 "$rc" 'a different violating reply on a continuation must still block'

  stop 'All done, nothing for you to run.' false || fail 'a clean reply was blocked'
  printf '{}' | run_env "$GUARD" --claude || fail 'a payload without a reply did not fail open'
  printf '{"last_assistant_message":42}' | run_env "$GUARD" --claude || fail 'a non-string reply did not fail open'
  printf 'not json' | run_env "$GUARD" --claude || fail 'a malformed payload did not fail open'
  pass 'the Claude Stop guard blocks with a rewrite hint, releases a repeated continuation, and fails open'
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
test_claude_stop_blocks_and_releases
test_claude_stop_scope
test_registered_stop_entry_reaches_the_guard

echo "# fm-rule-guard.test.sh: all assertions passed"
