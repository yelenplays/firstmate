#!/usr/bin/env bash
# End-to-end tests for bounded best-effort Logbook and Deck refresh wiring.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-logbook-refresh)
HOME_DIR="$TMP_ROOT/home"
DECK_DIR="$TMP_ROOT/deck"
TODAY=$(TZ=Europe/Berlin date +%Y-%m-%d)

fail() { echo "not ok: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

fresh_home() {
  rm -rf "$TMP_ROOT"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
  cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
  cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
}

run_refresh() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    "$ROOT/bin/fm-logbook-refresh.sh"
}

test_generates_logbook_and_calls_configured_deck() {
  fresh_home
  mkdir -p "$DECK_DIR/deploy"
  cat > "$DECK_DIR/deploy/refresh.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = work-landed ] || exit 9
[ -n "${FM_DECK_FIRSTMATE_ROOT:-}" ] || exit 2
printf '%s %s %s\n' "$1" "$FM_DECK_FIRSTMATE_ROOT" "$FM_DECK_ROOT" >> "$FM_TEST_REFRESH_LOG"
EOF
  chmod +x "$DECK_DIR/deploy/refresh.sh"
  printf '%s\n' "$DECK_DIR" > "$HOME_DIR/config/deck-path"
  FM_TEST_REFRESH_LOG="$TMP_ROOT/refresh.log" run_refresh \
    || fail 'best-effort helper returned failure'
  [ -f "$HOME_DIR/data/history/days/$TODAY.logbook.json" ] \
    || fail "helper did not generate today's Logbook"
  [ "$(cat "$TMP_ROOT/refresh.log" 2>/dev/null)" = "work-landed $HOME_DIR $DECK_DIR" ] \
    || fail 'configured Deck refresh hook did not run with work-landed and its roots'
  pass 'generation precedes a configured Deck refresh hook'
}

test_missing_deck_configuration_is_silent() {
  fresh_home
  output=$(run_refresh 2>&1) || fail 'missing optional Deck config changed the caller result'
  [ -z "$output" ] || fail "missing optional Deck config was not silent: $output"
  [ -f "$HOME_DIR/data/history/days/$TODAY.logbook.json" ] \
    || fail 'missing Deck config also skipped local Logbook generation'
  pass 'missing Deck configuration skips only the publish refresh'
}

test_deck_failure_is_best_effort() {
  fresh_home
  mkdir -p "$DECK_DIR/deploy"
  cat > "$DECK_DIR/deploy/refresh.sh" <<'EOF'
#!/usr/bin/env bash
exit 19
EOF
  chmod +x "$DECK_DIR/deploy/refresh.sh"
  printf '%s\n' "$DECK_DIR" > "$HOME_DIR/config/deck-path"
  run_refresh >/dev/null 2>&1 || fail 'Deck refresh failure escaped the best-effort helper'
  pass 'Deck refresh failure does not fail the caller'
}

test_kickstarts_configured_launchd_job() {
  fresh_home
  mkdir -p "$DECK_DIR/deploy" "$TMP_ROOT/bin"
  cat > "$DECK_DIR/deploy/refresh.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s %s %s\n' "$1" "$FM_DECK_FIRSTMATE_ROOT" "$FM_DECK_ROOT" >> "$FM_TEST_REFRESH_LOG"
EOF
  chmod +x "$DECK_DIR/deploy/refresh.sh"
  cat > "$TMP_ROOT/bin/launchctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FM_TEST_LAUNCHCTL_LOG"
exit "${FM_TEST_LAUNCHCTL_STATUS:-0}"
EOF
  chmod +x "$TMP_ROOT/bin/launchctl"
  printf '%s\n' "$DECK_DIR" > "$HOME_DIR/config/deck-path"
  printf '%s\n' example.fm-deck > "$HOME_DIR/config/deck-launchd-label"
  PATH="$TMP_ROOT/bin:$PATH" FM_TEST_LAUNCHCTL_LOG="$TMP_ROOT/launchctl.log" \
    FM_TEST_REFRESH_LOG="$TMP_ROOT/refresh.log" run_refresh \
    || fail 'kickstart path returned failure'
  [ "$(cat "$TMP_ROOT/launchctl.log" 2>/dev/null)" = "kickstart gui/$(id -u)/example.fm-deck" ] \
    || fail 'configured Deck launchd job was not kickstarted'
  [ ! -e "$TMP_ROOT/refresh.log" ] \
    || fail 'successful kickstart also started a concurrent direct refresh'

  FM_TEST_LAUNCHCTL_STATUS=9 PATH="$TMP_ROOT/bin:$PATH" \
    FM_TEST_LAUNCHCTL_LOG="$TMP_ROOT/launchctl.log" \
    FM_TEST_REFRESH_LOG="$TMP_ROOT/refresh.log" run_refresh \
    || fail 'failed-kickstart fallback returned failure'
  [ "$(cat "$TMP_ROOT/refresh.log" 2>/dev/null)" = "work-landed $HOME_DIR $DECK_DIR" ] \
    || fail 'failed kickstart did not fall back to direct refresh'

  : > "$TMP_ROOT/launchctl.log"
  : > "$TMP_ROOT/refresh.log"
  printf '%s\n%s\n' example.fm-deck other.fm-deck > "$HOME_DIR/config/deck-launchd-label"
  PATH="$TMP_ROOT/bin:$PATH" FM_TEST_LAUNCHCTL_LOG="$TMP_ROOT/launchctl.log" \
    FM_TEST_REFRESH_LOG="$TMP_ROOT/refresh.log" run_refresh \
    || fail 'multi-line-label fallback returned failure'
  [ ! -s "$TMP_ROOT/launchctl.log" ] \
    || fail 'multi-line label kickstarted a job'
  [ "$(cat "$TMP_ROOT/refresh.log" 2>/dev/null)" = "work-landed $HOME_DIR $DECK_DIR" ] \
    || fail 'multi-line label did not fall back to direct refresh'
  pass 'successful kickstart avoids direct refresh; invalid labels fall back'
}

test_generates_logbook_and_calls_configured_deck
test_kickstarts_configured_launchd_job
test_missing_deck_configuration_is_silent
test_deck_failure_is_best_effort
