#!/usr/bin/env bash
# Behavior tests for the Claude Stop-owned watcher auto-arm
# (bin/fm-claude-stop-autoarm.sh, docs/watcher-continuity.md).
#
# The hook fires as a Claude asyncRewake Stop hook. These tests run it hermetically
# as a child of a fake harness (a bash symlink named "claude") whose pid is
# written into the fixture home's state/.lock for ordinary owned-lock cases.
# Stale-owner cases instead leave a dead recorded pid for the hook to reclaim
# through the real fm-lock.sh path. The arm wrapper is a per-test fixture, so no
# real watcher, model, or fleet state is touched.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child, and grep needles are literal strings
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-stop-autoarm)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"

# Copy the hook and its sourced dependencies into a fixture checkout.
install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-autoarm-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree: the shape every crewmate/scout task worktree
# has (git-dir != git-common-dir), which must keep the hook inert.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/autoarm-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

# Run the hook as a child of the fake harness holding the fixture home's
# session lock. $1 = fixture dir. Any extra env assignments must be exported
# before invocation. Captures stdout+stderr; exit code on stdout of the caller.
run_autoarm() {
  local dir=$1 rc=0
  printf '%s\n' '{"session_id":"sess-autoarm","stop_hook_active":false}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1 || rc=$?
  printf 'RC=%s\n' "$rc" >&2
  return "$rc"
}

# Run <command> inside a session -> helper -> command process tree where BOTH
# the session and the helper carry a harness command name, the shape a harness
# creates whenever it interposes one of its own processes between the session
# that owns the home and a hook or tool call that session fires.
# The session records its own pid in state/.lock, and both pids are published so
# a caller can prove the helper level really exists instead of trusting that
# bash did not collapse it away.
# $1 = fixture dir, remaining args = command line to run at the innermost level.
run_behind_harness_helper() {
  local dir=$1 rc=0
  shift
  cat > "$dir/helper.sh" <<'SH'
printf '%s\n' "$$" > "$FM_HOME/state/helper-pid"
"$@"
SH
  cat > "$dir/session.sh" <<'SH'
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_TEST_HELPER_HARNESS" "$FM_HOME/helper.sh" "$@"
SH
  printf '%s\n' '{"session_id":"sess-nested","stop_hook_active":false}' \
    | FM_HOME="$dir" FM_TEST_HELPER_HARNESS="$FAKE_CLAUDE" \
      "$FAKE_CLAUDE" "$dir/session.sh" "$@" 2>&1 || rc=$?
  return "$rc"
}

# Run <command> below a shared-daemon -> pty-host -> session process tree where
# ALL THREE levels carry a harness command name, the shape Claude Code 2.1.220
# actually creates: a `claude daemon run` at ppid 1 and a `claude bg-pty-host`
# below it, both SHARED by every Claude session on the machine, and a
# `claude bg-spare` that IS the session holding the home. No lock is written, so
# a caller can observe which pid a first acquisition mints. Every level publishes
# its pid so a caller can prove the tree really has three distinct processes.
# $1 = fixture dir, remaining args = command line to run below the session.
run_below_shared_harness_ancestors() {
  local dir=$1 rc=0
  shift
  cat > "$dir/spare.sh" <<'SH'
printf '%s\n' "$$" > "$FM_HOME/state/spare-pid"
"$@"
inner=$?
exit "$inner"
SH
  cat > "$dir/pty-host.sh" <<'SH'
printf '%s\n' "$$" > "$FM_HOME/state/pty-host-pid"
"$FM_TEST_HELPER_HARNESS" "$FM_HOME/spare.sh" "$@"
inner=$?
exit "$inner"
SH
  cat > "$dir/daemon.sh" <<'SH'
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_TEST_HELPER_HARNESS" "$FM_HOME/pty-host.sh" "$@"
inner=$?
exit "$inner"
SH
  FM_HOME="$dir" FM_TEST_HELPER_HARNESS="$FAKE_CLAUDE" \
    "$FAKE_CLAUDE" "$dir/daemon.sh" "$@" 2>&1 || rc=$?
  return "$rc"
}

# Fail unless run_below_shared_harness_ancestors really produced three distinct
# harness levels; without that the fixture cannot see the minting boundary.
assert_shared_ancestor_levels_exist() {
  local dir=$1 daemon pty spare
  daemon=$(cat "$dir/state/daemon-pid" 2>/dev/null || true)
  pty=$(cat "$dir/state/pty-host-pid" 2>/dev/null || true)
  spare=$(cat "$dir/state/spare-pid" 2>/dev/null || true)
  { [ -n "$daemon" ] && [ -n "$pty" ] && [ -n "$spare" ]; } \
    || fail "shared-ancestor fixture did not publish all three pids (daemon=$daemon pty-host=$pty spare=$spare)"
  { [ "$daemon" != "$pty" ] && [ "$pty" != "$spare" ] && [ "$daemon" != "$spare" ]; } \
    || fail "shared-ancestor fixture collapsed: expected three distinct processes, got daemon=$daemon pty-host=$pty spare=$spare"
}

# Fail unless run_behind_harness_helper really produced a distinct helper level.
assert_helper_level_exists() {
  local dir=$1 session helper
  session=$(cat "$dir/state/session-pid" 2>/dev/null || true)
  helper=$(cat "$dir/state/helper-pid" 2>/dev/null || true)
  { [ -n "$session" ] && [ -n "$helper" ]; } \
    || fail "nested fixture did not publish both pids (session=$session helper=$helper)"
  [ "$session" != "$helper" ] \
    || fail "nested fixture collapsed: the helper level must be its own process, got $helper for both"
}

# Arm fixture variants, installed per test as <dir>/bin/fm-watch-arm.sh.
write_arm_fixture() {
  local dir=$1 kind=$2
  case "$kind" in
    actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    failed)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
      ;;
    clean)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
SH
      ;;
    slow-actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
sleep 2
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: task.status done: slow fixture\n'
exit 0
SH
      ;;
    meta-vanishes)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
rm -f "$FM_HOME/state/task.meta"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: task.status done: fixture\n'
exit 0
SH
      ;;
    afk-appears)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.afk"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    *)
      echo "unknown arm fixture: $kind" >&2
      return 2
      ;;
  esac
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

# --- registration contract ----------------------------------------------------

test_settings_registers_autoarm_with_multi_hour_timeout() {
  local settings
  settings="$ROOT/.claude/settings.json"
  jq -e '
    [.hooks.Stop[].hooks[] | select(.command | contains("fm-claude-stop-autoarm.sh"))]
      | length == 1
  ' "$settings" >/dev/null || fail "settings must register exactly one Stop auto-arm hook"
  jq -e '
    [.hooks.Stop[].hooks[] | select(.command | contains("fm-claude-stop-autoarm.sh"))][0]
      | .asyncRewake == true and .type == "command" and (.timeout | type == "number" and . >= 28800)
  ' "$settings" >/dev/null || fail "auto-arm must be asyncRewake with an explicit timeout of at least 28800s (the 600s default is forbidden)"
  jq -e '
    [.hooks.Stop[].hooks[] | select(.command | contains("fm-claude-stop-autoarm.sh"))][0].command
      | contains("&") | not
  ' "$settings" >/dev/null || fail "auto-arm registration must not use shell fire-and-forget"
  grep -q '"$SCRIPT_DIR/fm-watch-arm.sh" >"$OUT" 2>&1' "$ROOT/bin/fm-claude-stop-autoarm.sh" \
    || fail "auto-arm must foreground the arm wrapper inside the hook-owned process tree"
  grep -q 'asyncRewake' "$ROOT/bin/fm-claude-stop-autoarm.sh" \
    || fail "auto-arm header must document its asyncRewake registration contract"
  pass "settings.json registers the asyncRewake auto-arm with timeout >= 28800 and a foreground arm"
}

# --- scope and gates ----------------------------------------------------------

test_inert_in_child_worktree() {
  local base dir out status
  base="$TMP_ROOT/crew-base"
  dir="$TMP_ROOT/crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must stay inert in a child task worktree"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed inside a child worktree"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "hook wrote an epoch inside a child worktree"
  pass "auto-arm: inert in a linked child worktree even when in-flight"
}

test_inert_without_session_lock() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/no-lock")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # No state/.lock: run the hook directly (no fake harness, no lock file).
  out=$(printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" bash "$dir/bin/fm-claude-stop-autoarm.sh" 2>&1); status=$?
  expect_code 0 "$status" "hook must stay inert when no session holds the home lock"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed without a session lock"
  pass "auto-arm: inert with no session lock"
}

test_reclaims_stale_session_lock_before_arming() {
  local dir out status expected_owner actual_owner
  dir=$(make_primary_dir "$TMP_ROOT/stale-lock")
  : > "$dir/state/task.meta"
  printf '9999999\n' > "$dir/state/.lock"
  write_arm_fixture "$dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale"}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/expected-owner"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1); status=$?
  expect_code 2 "$status" "a dead recorded session owner must be reclaimed before the actionable rewake"
  expected_owner=$(cat "$dir/state/expected-owner")
  actual_owner=$(cat "$dir/state/.lock")
  [ "$actual_owner" = "$expected_owner" ] || fail "stale session lock was not claimed by the current harness: expected $expected_owner, got $actual_owner"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm after reclaiming the stale session lock"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "stale-lock recovery must record outcome=rewake"
  pass "auto-arm: a demonstrably dead recorded session owner is reclaimed through fm-lock.sh before arming"
}

test_inert_when_lock_held_by_other_harness() {
  local dir other out status owner_after
  dir=$(make_primary_dir "$TMP_ROOT/other-lock")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # The trailing no-op keeps the fake harness process alive instead of allowing
  # bash to exec the final sleep into a non-harness process.
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  printf '%s\n' "$other" > "$dir/state/.lock"
  out=$(printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  owner_after=$(cat "$dir/state/.lock")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$status" "hook must stay inert when another live harness holds the session lock"
  [ "$owner_after" = "$other" ] || fail "hook replaced another live harness owner: expected $other, got $owner_after"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed while another session owned the lock"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "hook wrote an epoch while another session owned the lock"
  pass "auto-arm: inert without arm, rewake, or lock replacement when another live harness owns the home"
}

# --- session identity across the harness's own helper processes ---------------
#
# The lock records an identity ("this session owns this home"), so the question
# is whether the recorded pid is in this process's ancestry - not whether it is
# the NEAREST harness-named ancestor. Asking the nearest-ancestor question makes
# the hook go inert for its own session the moment the harness interposes a
# same-named helper below the session.
#
# Minting is the mirror question and stays narrow: the pid written into the lock
# is the nearest harness ancestor, because the harness-named processes ABOVE a
# session are shared by every session on the machine.

test_claims_own_home_behind_nested_same_harness_helper() {
  local dir status=0
  dir=$(make_primary_dir "$TMP_ROOT/nested-owned")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  run_behind_harness_helper "$dir" "$dir/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>&1 || status=$?
  assert_helper_level_exists "$dir"
  expect_code 2 "$status" "the hook must claim its own home from behind a same-harness helper"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm from behind a same-harness helper"
  [ "$(epoch_outcome "$dir")" = rewake ] \
    || fail "nested-helper claim must record outcome=rewake, got: $(epoch_outcome "$dir")"
  pass "auto-arm: claims its own home when the session sits above the harness's own helper process"
}

test_inert_behind_nested_helper_when_another_harness_owns_lock() {
  local dir other status=0 owner_after
  dir=$(make_primary_dir "$TMP_ROOT/nested-other")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  # session.sh writes its own pid to .lock first; overwrite it from the arm
  # fixture's vantage point instead by pointing the lock at the unrelated owner
  # after the tree is built but before the hook reads it.
  cat > "$dir/bin/pre-hook.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "$other" > "\$FM_HOME/state/.lock"
exec "\$FM_HOME/bin/fm-claude-stop-autoarm.sh"
SH
  chmod +x "$dir/bin/pre-hook.sh"
  run_behind_harness_helper "$dir" "$dir/bin/pre-hook.sh" >/dev/null 2>&1 || status=$?
  owner_after=$(cat "$dir/state/.lock")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  assert_helper_level_exists "$dir"
  expect_code 0 "$status" "a nested helper must not widen ownership to another live session's home"
  [ "$owner_after" = "$other" ] || fail "nested hook replaced an unrelated live owner: expected $other, got $owner_after"
  [ ! -e "$dir/state/arm-ran" ] || fail "nested hook armed a home owned by an unrelated live session"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "nested hook wrote an epoch for an unrelated live session's home"
  pass "auto-arm: a same-harness helper never extends ownership to an unrelated live session's home"
}

test_fm_lock_never_refuses_its_own_session_behind_helper() {
  local dir out status=0
  dir=$(make_primary_dir "$TMP_ROOT/nested-relock")
  # session.sh acquires the lock as a direct child, exactly as an early-session
  # tool call does; the helper level then re-acquires it later in the session.
  # Which harness pid the re-acquisition records is not asserted: a deeper
  # acquisition legitimately mints the nearer harness ancestor, and stale-owner
  # recovery covers that pid dying. The contract under test is only that the
  # session is never refused a home it already holds.
  cat > "$dir/bin/relock.sh" <<'SH'
#!/usr/bin/env bash
"$FM_HOME/bin/fm-lock.sh"
SH
  chmod +x "$dir/bin/relock.sh"
  out=$(run_behind_harness_helper "$dir" "$dir/bin/relock.sh" 2>&1) || status=$?
  assert_helper_level_exists "$dir"
  expect_code 0 "$status" "a session must never be refused a home it already holds: $out"
  assert_contains "$out" "lock acquired" "re-acquisition from behind a helper must succeed"
  pass "fm-lock: a session behind its harness's own helper is never refused its own home"
}

# Minting must stop at the session. Claude Code 2.1.220 puts a `bg-pty-host` and
# a `daemon run` ABOVE the session, both harness-named and both SHARED by every
# Claude session on the machine, and the daemon's ppid is 1. A walk that widened
# past the nearest harness ancestor would run to that shared daemon and record
# one pid for every session at once, so each of them would satisfy the ownership
# predicate for the others' homes and no session could ever be refused.
test_fm_lock_mints_the_session_not_a_shared_harness_ancestor() {
  local dir daemon_pid spare_pid minted status=0
  dir=$(make_primary_dir "$TMP_ROOT/shared-ancestors")
  cat > "$dir/bin/mint.sh" <<'SH'
#!/usr/bin/env bash
"$FM_HOME/bin/fm-lock.sh"
SH
  chmod +x "$dir/bin/mint.sh"
  run_below_shared_harness_ancestors "$dir" "$dir/bin/mint.sh" >/dev/null 2>&1 || status=$?
  assert_shared_ancestor_levels_exist "$dir"
  daemon_pid=$(cat "$dir/state/daemon-pid")
  spare_pid=$(cat "$dir/state/spare-pid")
  expect_code 0 "$status" "a first acquisition below the session must succeed"
  minted=$(cat "$dir/state/.lock")
  [ "$minted" != "$daemon_pid" ] \
    || fail "lock recorded the shared harness daemon pid $daemon_pid; every session under it would own this home"
  [ "$minted" != "$(cat "$dir/state/pty-host-pid")" ] \
    || fail "lock recorded the shared pty-host pid; every session under it would own this home"
  [ "$minted" = "$spare_pid" ] \
    || fail "lock must record the session pid $spare_pid, got $minted"
  pass "fm-lock: minting stops at the session and never widens to a shared harness ancestor above it"
}

test_inert_when_afk() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/afk")
  : > "$dir/state/task.meta"
  : > "$dir/state/.afk"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must never arm or rewake while away mode owns triage"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed while state/.afk existed"
  pass "auto-arm: inert while AFK owns supervision"
}

test_stale_lock_recovery_preserves_afk_and_need_gates() {
  local afk_dir idle_dir out status
  afk_dir=$(make_primary_dir "$TMP_ROOT/stale-afk")
  : > "$afk_dir/state/task.meta"
  : > "$afk_dir/state/.afk"
  printf '9999999\n' > "$afk_dir/state/.lock"
  write_arm_fixture "$afk_dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale-afk"}' | FM_HOME="$afk_dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  expect_code 0 "$status" "a stale owner must not widen the AFK gate"
  [ "$(cat "$afk_dir/state/.lock")" = 9999999 ] || fail "AFK stale lock was reclaimed despite away ownership"
  [ ! -e "$afk_dir/state/arm-ran" ] || fail "stale AFK home armed"

  idle_dir=$(make_primary_dir "$TMP_ROOT/stale-idle")
  printf '9999999\n' > "$idle_dir/state/.lock"
  write_arm_fixture "$idle_dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale-idle"}' | FM_HOME="$idle_dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  expect_code 0 "$status" "a stale owner must not widen the supervision-need gate"
  [ "$(cat "$idle_dir/state/.lock")" = 9999999 ] || fail "idle stale lock was reclaimed without supervision need"
  [ ! -e "$idle_dir/state/arm-ran" ] || fail "stale idle home armed"
  pass "auto-arm: stale-owner recovery leaves the AFK and supervision-need gates unchanged"
}

test_inert_when_fleet_idle() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/idle")
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must exit 0 in an idle home with no X-mode poll"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed an idle home"
  pass "auto-arm: inert with nothing in flight and no X-mode need"
}

# --- the armed cycle ----------------------------------------------------------

test_actionable_close_rewakes_with_reason() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/actionable")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an actionable arm close must exit 2 so Claude rewakes"
  assert_contains "$out" "firstmate watcher wake" "rewake must carry the wake banner"
  assert_contains "$out" "stale: fixture-win actionable" "rewake must carry the arm's reason line"
  assert_contains "$out" "bin/fm-wake-drain.sh" "rewake must direct the drain-first protocol"
  assert_contains "$out" "do NOT run bin/fm-watch-arm.sh" "rewake must forbid a duplicate model re-arm"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "epoch must record outcome=rewake, got: $(epoch_outcome "$dir")"
  [ ! -e "$dir/state/.claude-autoarm.lock" ] || fail "owner lock must be released after the cycle"
  [ -e "$dir/state/arm-ran" ] || fail "hook never foregrounded the arm wrapper"
  pass "auto-arm: actionable close translates to exactly one exit-2 rewake with reason"
}

test_failed_close_rewakes_with_failure_banner() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/failed")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" failed
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a typed watcher failure must rewake as an alarm"
  assert_contains "$out" "watcher cycle FAILED" "failure rewake must carry the failure banner"
  assert_contains "$out" "watcher: FAILED" "failure rewake must carry the arm's typed failure"
  assert_contains "$out" "repair supervision" "failure rewake must direct the manual repair"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "epoch must record outcome=rewake, got: $(epoch_outcome "$dir")"
  pass "auto-arm: watcher: FAILED translates to an exit-2 alarm rewake"
}

test_clean_close_exits_silently() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/clean")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" clean
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "a clean arm close with no actionable reason must not rewake"
  [ -z "$out" ] || fail "clean close produced output: $out"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "epoch must record outcome=clean, got: $(epoch_outcome "$dir")"
  pass "auto-arm: clean close exits silently with a clean epoch"
}

test_arms_for_x_mode_poll_need_without_inflight() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/x-need")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/state/x-watch.check.sh"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an X-mode relay poll need must keep the auto-arm active with zero tasks in flight"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm for the X-mode poll need"
  pass "auto-arm: X-mode poll need arms the cycle even with no tasks in flight"
}

test_single_flight_admits_exactly_one_owner() {
  local dir rc1 rc2 count
  dir=$(make_primary_dir "$TMP_ROOT/single-flight")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" slow-actionable
  FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    printf "%s\n" "{\"session_id\":\"s\"}" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>"$FM_HOME/state/err1" &
    p1=$!
    printf "%s\n" "{\"session_id\":\"s\"}" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>"$FM_HOME/state/err2" &
    p2=$!
    wait "$p1"; echo $? > "$FM_HOME/state/rc1"
    wait "$p2"; echo $? > "$FM_HOME/state/rc2"
  '
  rc1=$(cat "$dir/state/rc1")
  rc2=$(cat "$dir/state/rc2")
  count=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "concurrent firings must foreground exactly one arm, saw $count"
  { [ "$rc1" = 2 ] && [ "$rc2" = 0 ]; } || { [ "$rc1" = 0 ] && [ "$rc2" = 2 ]; } \
    || fail "exactly one firing must translate the close (rc 2) and the other must no-op (rc 0), got rc1=$rc1 rc2=$rc2"
  pass "auto-arm: concurrent firings admit one owner and one rewake translation"
}

test_need_vanished_mid_cycle_closes_quietly() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/vanished")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" meta-vanishes
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "an actionable close after the fleet went idle must not rewake"
  [ -z "$out" ] || fail "vanished-need close produced output: $out"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "epoch must record outcome=clean, got: $(epoch_outcome "$dir")"
  pass "auto-arm: need vanishing mid-cycle closes without a rewake"
}

test_afk_mid_cycle_suppresses_rewake() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/afk-mid")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" afk-appears
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "AFK appearing mid-cycle must suppress the primary rewake"
  [ -z "$out" ] || fail "AFK-suppressed close produced output: $out"
  [ "$(epoch_outcome "$dir")" = afk ] || fail "epoch must record outcome=afk, got: $(epoch_outcome "$dir")"
  pass "auto-arm: mid-cycle AFK hands triage to the daemon with no rewake"
}

test_active_in_marked_secondmate_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/secondmate")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a marked secondmate home must get the same active auto-arm as the main primary"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm in a marked secondmate home"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "secondmate epoch must record outcome=rewake"
  pass "auto-arm: active in a marked secondmate home"
}

test_fm_lock_status_still_works_with_shared_lib() {
  local out
  out=$(FM_HOME="$TMP_ROOT/lock-status-home" bash "$ROOT/bin/fm-lock.sh" status 2>&1)
  assert_contains "$out" "lock: free" "fm-lock.sh status must keep working after the session-lock lib extraction"
  pass "fm-lock: shared session-lock lib preserves the status path"
}

test_settings_registers_autoarm_with_multi_hour_timeout
test_inert_in_child_worktree
test_inert_without_session_lock
test_reclaims_stale_session_lock_before_arming
test_inert_when_lock_held_by_other_harness
test_claims_own_home_behind_nested_same_harness_helper
test_inert_behind_nested_helper_when_another_harness_owns_lock
test_fm_lock_never_refuses_its_own_session_behind_helper
test_fm_lock_mints_the_session_not_a_shared_harness_ancestor
test_inert_when_afk
test_stale_lock_recovery_preserves_afk_and_need_gates
test_inert_when_fleet_idle
test_actionable_close_rewakes_with_reason
test_failed_close_rewakes_with_failure_banner
test_clean_close_exits_silently
test_arms_for_x_mode_poll_need_without_inflight
test_single_flight_admits_exactly_one_owner
test_need_vanished_mid_cycle_closes_quietly
test_afk_mid_cycle_suppresses_rewake
test_active_in_marked_secondmate_home
test_fm_lock_status_still_works_with_shared_lib
