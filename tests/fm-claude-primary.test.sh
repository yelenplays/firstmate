#!/usr/bin/env bash
# Portable regression for bin/fm-claude-primary.sh, the Claude primary launcher
# and its config/claude-remote-control opt-in. A fake claude records the argv and
# working directory it was started with; the real-harness counterpart is
# tests/fm-claude-remote-control-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAUNCHER="$ROOT/bin/fm-claude-primary.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-primary)
HOME_DIR="$TMP_ROOT/home"
RECORD="$TMP_ROOT/record"
FAKE="$TMP_ROOT/claude"
mkdir -p "$HOME_DIR/config"

cat > "$FAKE" <<SH
#!/usr/bin/env bash
{ printf 'cwd=%s\n' "\$(pwd -P)"; for a in "\$@"; do printf 'arg=%s\n' "\$a"; done; } > '$RECORD'
SH
chmod +x "$FAKE"

launch() {  # <args...>; runs the launcher against the fixture home
  rm -f "$RECORD"
  FM_HOME="$HOME_DIR" FM_CLAUDE_BIN="$FAKE" "$LAUNCHER" "$@"
}

set_config() {  # <content>
  printf '%s\n' "$1" > "$HOME_DIR/config/claude-remote-control"
}

expect_args() {  # <label> <expected arg lines...>
  local label=$1 want
  shift
  want=$(printf 'arg=%s\n' "$@")
  [ "$(grep '^arg=' "$RECORD" 2>/dev/null)" = "$want" ] \
    || fail "$label: launched with $(grep '^arg=' "$RECORD" 2>/dev/null | tr '\n' ' '), expected $(printf '%s' "$want" | tr '\n' ' ')"
}

# Absent file: plain claude, run from the checkout root, args passed through.
launch --continue || fail "absent config: launcher exited $?"
expect_args "absent config" --continue
[ "$(sed -n 's/^cwd=//p' "$RECORD")" = "$(cd "$ROOT" && pwd -P)" ] \
  || fail "the launch must run from the checkout root so the tracked Claude hooks load, got $(sed -n 's/^cwd=//p' "$RECORD")"
pass "absent config launches plain claude from the checkout root with arguments passed through"

set_config off
launch || fail "off: launcher exited $?"
[ -e "$RECORD" ] || fail "off must still launch claude"
if grep -q '^arg=' "$RECORD"; then
  fail "off must launch with no flag, got $(grep '^arg=' "$RECORD")"
fi
pass "off launches plain claude"

set_config on
launch --continue || fail "on: launcher exited $?"
expect_args "on" --remote-control firstmate --continue
pass "on adds --remote-control with the default session name before passed-through arguments"

set_config '# phone steering
on'
launch || fail "on after a comment: launcher exited $?"
expect_args "on after a comment" --remote-control firstmate
pass "on ignores comment lines and uses the fixed firstmate session name"

for bad in 'yes' 'on x' 'on two words' 'off name' 'ON'; do
  set_config "$bad"
  rm -f "$RECORD"
  RC=0
  ERR=$(FM_HOME="$HOME_DIR" FM_CLAUDE_BIN="$FAKE" "$LAUNCHER" 2>&1 >/dev/null) || RC=$?
  [ "$RC" = 2 ] || fail "config '$bad' must refuse with exit 2, got $RC"
  [ ! -e "$RECORD" ] || fail "config '$bad' must not launch claude"
  case "$ERR" in *"accepted values are"*) : ;; *) fail "config '$bad' refusal must name the accepted values, got: $ERR" ;; esac
done
pass "an unrecognized value refuses to launch and names the accepted values"

rm -f "$HOME_DIR/config/claude-remote-control"
mkdir "$HOME_DIR/config/claude-remote-control"
RC=0
FM_HOME="$HOME_DIR" FM_CLAUDE_BIN="$FAKE" "$LAUNCHER" >/dev/null 2>&1 || RC=$?
[ "$RC" = 2 ] || fail "a non-regular config path must refuse with exit 2, got $RC"
pass "an unreadable or non-regular config path refuses to launch"
