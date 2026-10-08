#!/usr/bin/env bash
# tests/fm-qos.test.sh - worker launches and test-suite runs execute at the
# background CPU class bin/fm-qos-lib.sh resolves (FM_WORKER_QOS).
#
# The spawn assertions never read bin/fm-spawn.sh's source. They drive the real
# spawn against a fake pane, then EXECUTE the launch command the pane received.
# Portable cases stand a recording taskpolicy in for the macOS one, so the
# wrapping is proven on every host; on macOS a further case runs the real
# taskpolicy and has the agent report the QoS class the kernel actually gave it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-qos)
# tests/lib.sh pins FM_WORKER_QOS=off for host-independent launch shapes; every
# case here chooses its own class explicitly.
unset FM_WORKER_QOS FM_QOS_APPLIED FM_QOS_UNAME FM_QOS_TASKPOLICY

# A stand-in taskpolicy that records its clamp and execs the program, which is
# what the real one does.
make_fake_taskpolicy() {  # <path> <log>
  cat > "$1" <<SH
#!/bin/sh
printf '%s %s\n' "\$1" "\$2" >> '$2'
shift 2
exec "\$@"
SH
  chmod +x "$1"
}

lib_eval() {  # <shell snippet> - run under bash with the library sourced
  bash -c '. "$1/bin/fm-qos-lib.sh"; eval "$2"' _ "$ROOT" "$1"
}

test_class_resolution() {
  local out rc
  assert_equals utility "$(lib_eval fm_qos_class)" "the default class should be utility"
  assert_equals background "$(FM_WORKER_QOS=background lib_eval fm_qos_class)" "background should be accepted"
  assert_equals maintenance "$(FM_WORKER_QOS=maintenance lib_eval fm_qos_class)" "maintenance should be accepted"
  assert_equals "" "$(FM_WORKER_QOS=off lib_eval fm_qos_class)" "off should disable the clamp"
  rc=0
  out=$(FM_WORKER_QOS=turbo lib_eval fm_qos_class 2>&1) || rc=$?
  expect_code 2 "$rc" "an unknown class should refuse"
  assert_contains "$out" "FM_WORKER_QOS must be utility, background, maintenance, or off" \
    "the refusal should name the accepted values"
  pass "FM_WORKER_QOS resolves utility by default, accepts the three classes and off, and refuses anything else"
}

test_prefix_follows_the_host() {
  local fake="$TMP_ROOT/prefix-taskpolicy"
  make_fake_taskpolicy "$fake" "$TMP_ROOT/prefix.log"
  assert_equals "" "$(FM_QOS_UNAME=Linux FM_QOS_TASKPOLICY=$fake lib_eval fm_qos_command_prefix)" \
    "a non-macOS host should get no prefix"
  assert_equals "" "$(FM_QOS_UNAME=Darwin FM_QOS_TASKPOLICY=$TMP_ROOT/missing lib_eval fm_qos_command_prefix)" \
    "a macOS host without taskpolicy should get no prefix"
  assert_equals "$fake -c utility" "$(FM_QOS_UNAME=Darwin FM_QOS_TASKPOLICY=$fake lib_eval fm_qos_command_prefix)" \
    "a macOS host should get the taskpolicy clamp"
  assert_equals "" "$(FM_WORKER_QOS=off FM_QOS_UNAME=Darwin FM_QOS_TASKPOLICY=$fake lib_eval fm_qos_command_prefix)" \
    "off should give no prefix even where the clamp is available"
  pass "the launch prefix clamps only on macOS with taskpolicy present, and never when off"
}

# make_case <name> <id> -> "<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>"
make_case() {
  local name=$1 id=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  fm_test_spawn_home "$case_dir/home" codex
  fm_git_worktree "$case_dir/project" "$case_dir/wt" "wt-$name"
  fm_test_spawn_brief "$case_dir/home" "$id"
  printf '%s\n' "$case_dir/home|$case_dir/project|$case_dir/wt|$(fm_test_make_spawn_fakebin "$case_dir/fake")|$case_dir/launch.log|$case_dir/pane.log"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# The agent probe reports what a real agent would have been started with.
install_probe() {  # <fakebin> <body>
  printf '#!/bin/sh\n%s\n' "$2" > "$1/codex"
  chmod +x "$1/codex"
}

run_emitted_launch() {
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm TMUX=synthetic-pane \
    /bin/sh -c "$(cat "$LAUNCH_LOG")"
}

test_spawn_wraps_every_launch() {
  local setting rec out status seen fake log
  for setting in absent enabled; do
    rec=$(make_case "wrap-$setting" "wrap-$setting-a1")
    read_case "$rec"
    [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    fake="$TMP_ROOT/wrap-$setting-taskpolicy"
    log="$TMP_ROOT/wrap-$setting-taskpolicy.log"
    make_fake_taskpolicy "$fake" "$log"
    out=$(FM_WORKER_QOS=background FM_QOS_UNAME=Darwin FM_QOS_TASKPOLICY="$fake" \
      run_case_spawn "wrap-$setting-a1" "$PROJ_DIR" --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "allowlist=$setting spawn should succeed: $out"
    # shellcheck disable=SC2016 # expanded by the probe, not here
    # shellcheck disable=SC2016 # expanded by the probe, not here
  install_probe "$FAKEBIN_DIR" 'printf "%s %s\n" "${FM_WORKER_QOS-unset}" "${FM_QOS_APPLIED-unset}"'
    seen=$(run_emitted_launch) || fail "allowlist=$setting: the emitted launch failed to run"
    assert_equals "-c background" "$(cat "$log" 2>/dev/null)" \
      "allowlist=$setting: the launch should run exactly once through the clamp at the chosen class"
    assert_equals "background background" "$seen" \
      "allowlist=$setting: the agent should inherit the class it was launched at, marked as applied"
  done
  pass "every launch runs through the clamp at the chosen class, with and without an allowlist"
}

test_spawn_off_leaves_the_launch_unclamped() {
  local rec out status seen fake log
  rec=$(make_case off off-a1)
  read_case "$rec"
  fake="$TMP_ROOT/off-taskpolicy"
  log="$TMP_ROOT/off-taskpolicy.log"
  make_fake_taskpolicy "$fake" "$log"
  out=$(FM_WORKER_QOS=off FM_QOS_UNAME=Darwin FM_QOS_TASKPOLICY="$fake" \
    run_case_spawn off-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an off spawn should succeed: $out"
  # shellcheck disable=SC2016 # expanded by the probe, not here
  install_probe "$FAKEBIN_DIR" 'printf "%s %s\n" "${FM_WORKER_QOS-unset}" "${FM_QOS_APPLIED-unset}"'
  seen=$(run_emitted_launch) || fail "off: the emitted launch failed to run"
  [ ! -s "$log" ] || fail "an off launch must not run through the clamp, got: $(cat "$log")"
  assert_equals "off unset" "$seen" \
    "an off launch should tell the agent's own suites to stay unclamped too"
  pass "FM_WORKER_QOS=off launches unclamped and carries off to the worker's own suites"
}

test_spawn_refuses_an_unknown_class() {
  local rec out status
  rec=$(make_case refuse refuse-a1)
  read_case "$rec"
  out=$(FM_WORKER_QOS=turbo run_case_spawn refuse-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "an unknown FM_WORKER_QOS should refuse the spawn: $out"
  assert_contains "$out" "FM_WORKER_QOS must be" "the refusal should name the variable"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused spawn must not send a launch: $(cat "$LAUNCH_LOG")"
  [ ! -e "$HOME_DIR/state/refuse-a1.meta" ] || fail "a refused spawn must not publish a task record"
  pass "an unknown FM_WORKER_QOS refuses the spawn before anything is launched"
}

# Real macOS proof: the kernel reports the clamp to the agent process itself.
# background is used because the suite already runs at utility under the runner,
# so only a different class proves this launch applied its own.
test_real_taskpolicy_clamps_the_agent() {
  local rec out status seen
  if [ "$(uname -s)" != Darwin ] || [ ! -x /usr/sbin/taskpolicy ] || ! command -v python3 >/dev/null 2>&1; then
    pass "skip: real taskpolicy clamp needs macOS with taskpolicy and python3"
    return 0
  fi
  rec=$(make_case real real-a1)
  read_case "$rec"
  out=$(FM_WORKER_QOS=background run_case_spawn real-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a real-clamp spawn should succeed: $out"
  install_probe "$FAKEBIN_DIR" "exec $(command -v python3) -I -c 'import ctypes; print(hex(ctypes.CDLL(None).qos_class_self()))'"
  seen=$(run_emitted_launch) || fail "real clamp: the emitted launch failed to run"
  # QOS_CLASS_BACKGROUND from <sys/qos.h>.
  assert_equals 0x9 "$seen" "the agent should run at the background QoS class"
  pass "on macOS the real taskpolicy gives the launched agent the chosen QoS class"
}

# The runner applies the class to itself before any script starts, so a suite
# a pipeline or a person starts is clamped too, and it does so only once.
test_runner_applies_the_class_once() {
  local repo="$TMP_ROOT/runner" fake log out
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-qos-lib.sh" "$repo/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$ROOT/tests/environment.sh" "$repo/tests/"
  cat > "$repo/tests/fm-qos-probe.test.sh" <<'SH'
#!/usr/bin/env bash
echo "probe class=${FM_QOS_APPLIED-unset}"
SH
  chmod +x "$repo/tests/fm-qos-probe.test.sh"
  fake="$TMP_ROOT/runner-taskpolicy"
  log="$TMP_ROOT/runner-taskpolicy.log"
  make_fake_taskpolicy "$fake" "$log"
  out=$(cd "$repo" && FM_WORKER_QOS=maintenance FM_QOS_UNAME=Darwin FM_QOS_TASKPOLICY="$fake" \
    bin/fm-test-run.sh tests/fm-qos-probe.test.sh 2>&1) \
    || fail "the clamped runner failed: $out"
  assert_equals "-c maintenance" "$(cat "$log")" "the runner should re-exec exactly once under the chosen class"
  assert_contains "$out" "probe class=maintenance" "selected scripts should run inside the clamped runner"

  : > "$log"
  out=$(cd "$repo" && FM_WORKER_QOS=maintenance FM_QOS_APPLIED=maintenance FM_QOS_UNAME=Darwin \
    FM_QOS_TASKPOLICY="$fake" bin/fm-test-run.sh tests/fm-qos-probe.test.sh 2>&1) \
    || fail "the already-clamped runner failed: $out"
  [ ! -s "$log" ] || fail "a runner already at its class must not re-exec: $(cat "$log")"

  local rc=0
  out=$(cd "$repo" && FM_WORKER_QOS=turbo bin/fm-test-run.sh tests/fm-qos-probe.test.sh 2>&1) || rc=$?
  expect_code 2 "$rc" "an unknown class should refuse the runner"
  case "$out" in
    *"probe class="*) fail "a refused runner still ran a script: $out" ;;
  esac
  pass "the runner clamps itself once at the chosen class and refuses an unknown one"
}

test_class_resolution
test_prefix_follows_the_host
test_spawn_wraps_every_launch
test_spawn_off_leaves_the_launch_unclamped
test_spawn_refuses_an_unknown_class
test_real_taskpolicy_clamps_the_agent
test_runner_applies_the_class_once
