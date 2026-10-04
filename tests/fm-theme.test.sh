#!/usr/bin/env bash
# tests/fm-theme.test.sh - behavior tests for bin/fm-theme.sh, the theme pack
# resolver and renderer.
#
# Coverage:
#   - the built-in default (absent, empty, `nautical`, `default`) renders no
#     themed surface: canonical status words, an empty status map, no banner,
#     and no digest
#   - the tracked ny-trenches pack renders its banner, address, no-op reply,
#     names, display-only status words, and voice guidance; the banner appears
#     only when asked for, and never carries terminal escapes off a TTY
#   - an unknown or unsafe name falls back to the default with exactly one
#     warning line, and the digest carries that one line too
#   - `set` validates the name before writing config/theme, and `off` removes it
#   - config/theme is part of the inherited secondmate configuration
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

THEME="$ROOT/bin/fm-theme.sh"
TMP_ROOT=$(fm_test_tmproot fm-theme-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

new_config() {  # <name>: echoes a fresh, empty config directory
  local dir="$TMP_ROOT/$1/config"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

theme() {  # <config-dir> <args...>
  local config=$1
  shift
  env -u NO_COLOR FM_CONFIG_OVERRIDE="$config" bash "$THEME" "$@"
}

test_default_renders_nothing_themed() {
  local config value state
  for value in ABSENT '' nautical default; do
    config=$(new_config "default-$value")
    [ "$value" = ABSENT ] || printf '%s\n' "$value" > "$config/theme"
    assert_equals nautical "$(theme "$config" current 2>&1)" "default [$value] current"
    for state in working 'done' needs-decision blocked paused failed parked; do
      assert_equals "$state" "$(theme "$config" status "$state" 2>&1)" "default [$value] status $state"
    done
    assert_equals '{}' "$(theme "$config" status-map 2>&1)" "default [$value] status map"
    assert_equals '' "$(theme "$config" banner 2>&1)" "default [$value] banner"
    assert_equals '' "$(theme "$config" digest --banner 2>&1)" "default [$value] digest"
    assert_equals '' "$(theme "$config" show 2>&1)" "default [$value] show"
  done
  pass "the built-in default renders no themed surface"
}

test_ny_trenches_renders_banner_and_status_words() {
  local config out err map
  config=$(new_config ny)
  printf 'ny-trenches\n' > "$config/theme"
  err="$TMP_ROOT/ny/err"

  assert_equals ny-trenches "$(theme "$config" current 2>"$err")" "ny current"
  assert_equals '' "$(cat "$err")" "an existing pack must not warn"

  assert_equals 'on the block' "$(theme "$config" status working)" "ny working word"
  assert_equals 'dropped' "$(theme "$config" status 'done')" "ny done word"
  assert_equals 'need the OG' "$(theme "$config" status needs-decision)" "ny decision word"
  assert_equals 'parked' "$(theme "$config" status parked)" "an unmapped state keeps its canonical word"

  map=$(theme "$config" status-map)
  printf '%s\n' "$map" | jq -e '
    .working == "on the block" and .done == "dropped" and .["needs-decision"] == "need the OG"
  ' >/dev/null || fail "ny status map is wrong: $map"

  out=$(theme "$config" banner)
  assert_contains "$out" "N E W   Y O R K" "ny banner renders the skyline caption"
  assert_not_contains "$out" $'\033' "a banner off a TTY must carry no terminal escapes"

  out=$(theme "$config" digest --banner)
  assert_contains "$out" "Theme pack: ny-trenches" "digest names the pack"
  assert_contains "$out" "N E W   Y O R K" "digest with --banner carries the banner"
  assert_contains "$out" "Address word (replaces \"captain\" in chat): OG" "digest carries the address word"
  assert_contains "$out" "Exact no-op reply (replaces \"Captain, shipshape.\"): OG, we good." "digest carries the no-op reply"
  assert_contains "$out" "captain -> the OG" "digest maps the captain"
  assert_contains "$out" "first-mate -> the plug" "digest maps the first mate"
  assert_contains "$out" "workers -> the squad" "digest maps the workers"
  assert_contains "$out" "scout -> a lookout" "digest maps scouts"
  assert_contains "$out" "second-mate -> a lieutenant" "digest maps second mates"
  assert_contains "$out" "finished-pr -> a drop" "digest maps a finished PR"
  assert_contains "$out" "working -> on the block" "digest lists the working word"
  assert_contains "$out" "public replies, Slack posts, and non-chat artifacts keep the" "digest states the chat-only boundary"
  assert_contains "$out" "No slurs" "digest carries the voice floor"
  assert_not_contains "$out" $'\033' "the digest must carry no terminal escapes"

  out=$(theme "$config" digest)
  assert_contains "$out" "Theme pack: ny-trenches" "slim digest still names the pack"
  assert_contains "$out" "No slurs" "slim digest still carries the voice"
  assert_not_contains "$out" "N E W   Y O R K" "digest without --banner omits the banner"
  pass "ny-trenches renders its banner, names, status words, and voice"
}

test_unknown_theme_falls_back_with_one_warning() {
  local config value out err lines
  for value in bogus '../themes/ny-trenches' 'Ny-Trenches' 'ny trenches'; do
    config=$(new_config "unknown-$RANDOM")
    printf '%s\n' "$value" > "$config/theme"
    err="$config/err"

    out=$(theme "$config" status working 2>"$err") || fail "status must exit 0 on fallback [$value]"
    assert_equals working "$out" "unknown [$value] keeps the canonical word"
    lines=$(wc -l < "$err" | tr -d ' ')
    assert_equals 1 "$lines" "unknown [$value] warns exactly once"
    assert_contains "$(cat "$err")" "using the built-in nautical default" "unknown [$value] warning names the fallback"

    out=$(theme "$config" status-map 2>/dev/null)
    assert_equals '{}' "$out" "unknown [$value] status map is empty"

    out=$(theme "$config" digest --banner 2>/dev/null) || fail "digest must exit 0 on fallback [$value]"
    lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
    assert_equals 1 "$lines" "unknown [$value] digest is one warning line"
    assert_contains "$out" "fm-theme: unknown theme" "unknown [$value] digest carries the warning"
  done
  pass "an unknown theme falls back to the default with one warning line"
}

test_set_validates_and_off_removes() {
  local config rc
  config=$(new_config set)

  rc=0
  theme "$config" set nope >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "set refuses an unknown pack"
  [ ! -e "$config/theme" ] || fail "a refused set must not write config/theme"

  theme "$config" set ny-trenches >/dev/null || fail "set ny-trenches failed"
  assert_equals ny-trenches "$(cat "$config/theme")" "set writes the pack name"
  assert_equals 'dropped' "$(theme "$config" status 'done')" "set takes effect for the next render"

  theme "$config" set off >/dev/null || fail "set off failed"
  [ ! -e "$config/theme" ] || fail "set off must remove config/theme"
  assert_equals 'done' "$(theme "$config" status 'done')" "set off restores the default"

  assert_contains "$(theme "$config" list)" "ny-trenches" "list names the tracked pack"
  pass "set validates the pack name and off restores the default"
}

test_theme_is_inherited_by_secondmates() {
  local items
  items=$(bash -c '. "$1/bin/fm-config-inherit-lib.sh"; fm_config_inherit_items' _ "$ROOT")
  assert_contains "$items" "config/theme" "config/theme must be inherited by secondmate homes"
  pass "config/theme is inherited by secondmate homes"
}

test_default_renders_nothing_themed
test_ny_trenches_renders_banner_and_status_words
test_unknown_theme_falls_back_with_one_warning
test_set_validates_and_off_removes
test_theme_is_inherited_by_secondmates

echo "# fm-theme.test.sh: all assertions passed"
