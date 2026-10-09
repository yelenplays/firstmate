#!/usr/bin/env bash
# tests/fm-qos.test.sh - worker launches and test-suite runs execute at utility QoS.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-qos)
unset FM_QOS_APPLIED FM_QOS_UNAME FM_QOS_TASKPOLICY
export FM_TEST_SLOT_DIR="$TMP_ROOT/slots"

make_fake_taskpolicy() {
  cat > "$1" <<SH
#!/bin/sh
printf '%s %s\n' "\$1" "\$2" >> '$2'
shift 2
exec "\$@"
SH
  chmod +x "$1"
}

lib_eval() {
  bash -c '. "$1/bin/fm-qos-lib.sh"; eval "$2"' _ "$ROOT" "$1"
}

test_prefix_follows_the_host() {
  local fake="$TMP_ROOT/prefix-taskpolicy"
  make_fake_taskpolicy "$fake" "$TMP_ROOT/prefix.log"
  assert_equals "" "$(FM_QOS_UNAME=Linux FM_QOS_TASKPOLICY=$fake lib_eval fm_qos_command_prefix)" \
    "a non-macOS host should get no prefix"
  assert_equals "" "$(FM_QOS_UNAME=Darwin FM_QOS_TASKPOLICY=$TMP_ROOT/missing lib_eval fm_qos_command_prefix)" \
    "a macOS host without taskpolicy should get no prefix"
  assert_equals "$fake -c utility" "$(FM_QOS_UNAME=Darwin FM_QOS_TASKPOLICY=$fake lib_eval fm_qos_command_prefix)" \
    "a macOS host should get the utility clamp"
  pass "the launch prefix clamps at utility only on macOS with taskpolicy present"
}

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

install_probe() {
  printf '#!/bin/sh\n%s\n' "$2" > "$1/codex"
  chmod +x "$1/codex"
}

run_emitted_launch() {
  local shell=${1:-/bin/sh}
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm TMUX=synthetic-pane SHELL="$shell" \
    "$shell" -c "$(cat "$LAUNCH_LOG")"
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
    out=$(FM_QOS_UNAME=Darwin FM_QOS_TASKPOLICY="$fake" \
      run_case_spawn "wrap-$setting-a1" "$PROJ_DIR" --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "allowlist=$setting spawn should succeed: $out"
    install_probe "$FAKEBIN_DIR" 'printenv FM_QOS_APPLIED'
    seen=$(run_emitted_launch) || fail "allowlist=$setting: the emitted launch failed to run"
    assert_equals "-c utility" "$(cat "$log" 2>/dev/null)" \
      "allowlist=$setting: the launch should run exactly once through the utility clamp"
    assert_equals utility "$seen" "allowlist=$setting: the agent should inherit the applied marker"
  done
  pass "every launch runs through the utility clamp, with and without an allowlist"
}

test_spawn_on_a_host_without_the_clamp_is_unchanged() {
  local rec out status seen fake log
  rec=$(make_case linux linux-a1)
  read_case "$rec"
  fake="$TMP_ROOT/linux-taskpolicy"
  log="$TMP_ROOT/linux-taskpolicy.log"
  make_fake_taskpolicy "$fake" "$log"
  out=$(FM_QOS_UNAME=Linux FM_QOS_TASKPOLICY="$fake" \
    run_case_spawn linux-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a non-macOS spawn should succeed: $out"
  install_probe "$FAKEBIN_DIR" 'printenv FM_QOS_APPLIED || echo unset'
  seen=$(run_emitted_launch) || fail "non-macOS: the emitted launch failed to run"
  [ ! -s "$log" ] || fail "a non-macOS launch must not run through the clamp, got: $(cat "$log")"
  assert_equals unset "$seen" "a non-macOS launch should carry no CPU class at all"
  pass "a host without the clamp launches exactly as before"
}

test_real_taskpolicy_clamps_the_agent() {
  local rec out status seen
  if [ "$(uname -s)" != Darwin ] || [ ! -x /usr/sbin/taskpolicy ] || ! command -v python3 >/dev/null 2>&1; then
    pass "skip: real taskpolicy clamp needs macOS with taskpolicy and python3"
    return 0
  fi
  rec=$(make_case real real-a1)
  read_case "$rec"
  out=$(run_case_spawn real-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a real-clamp spawn should succeed: $out"
  install_probe "$FAKEBIN_DIR" "exec $(command -v python3) -I -c 'import ctypes; print(hex(ctypes.CDLL(None).qos_class_self()))'"
  seen=$(/usr/sbin/taskpolicy -c background env -i HOME="$TMP_ROOT/pane-home" \
    PATH="$FAKEBIN_DIR:$PATH" TERM=xterm TMUX=synthetic-pane SHELL=/bin/sh /bin/sh -c "$(cat "$LAUNCH_LOG")") \
    || fail "real clamp: the emitted launch failed to run"
  assert_equals 0x11 "$seen" "the agent should run at utility QoS even from a background parent"
  pass "on macOS the real taskpolicy gives the launched agent utility QoS"
}

test_runner_applies_the_class_once() {
  local repo="$TMP_ROOT/runner" fake log out
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-qos-lib.sh" "$repo/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$ROOT/tests/environment.sh" "$repo/tests/"
  cat > "$repo/tests/fm-qos-probe.test.sh" <<'SH'
#!/usr/bin/env bash
printenv FM_QOS_APPLIED
SH
  chmod +x "$repo/tests/fm-qos-probe.test.sh"
  fake="$TMP_ROOT/runner-taskpolicy"
  log="$TMP_ROOT/runner-taskpolicy.log"
  make_fake_taskpolicy "$fake" "$log"
  out=$(cd "$repo" && FM_QOS_UNAME=Darwin FM_QOS_TASKPOLICY="$fake" \
    bin/fm-test-run.sh tests/fm-qos-probe.test.sh 2>&1) \
    || fail "the clamped runner failed: $out"
  assert_equals "-c utility" "$(cat "$log")" "the runner should re-exec exactly once at utility"
  assert_contains "$out" utility "selected scripts should run inside the clamped runner"

  : > "$log"
  out=$(cd "$repo" && FM_QOS_APPLIED=utility FM_QOS_UNAME=Darwin \
    FM_QOS_TASKPOLICY="$fake" bin/fm-test-run.sh tests/fm-qos-probe.test.sh 2>&1) \
    || fail "the already-clamped runner failed: $out"
  [ ! -s "$log" ] || fail "a runner already clamped must not re-exec: $(cat "$log")"
  pass "the runner clamps itself at utility exactly once"
}

test_spawn_preserves_zsh_raw_command_syntax() {
  local shell rec fake log out seen status
  shell=$(command -v zsh) || {
    pass "skip: zsh raw-command syntax needs zsh"
    return 0
  }
  rec=$(make_case zsh zsh-a1)
  read_case "$rec"
  fake="$TMP_ROOT/zsh-taskpolicy"
  log="$TMP_ROOT/zsh-taskpolicy.log"
  make_fake_taskpolicy "$fake" "$log"
  cat >"$FAKEBIN_DIR/custom-agent" <<'SH'
#!/bin/sh
cat "$1"
printenv FM_QOS_APPLIED
SH
  chmod +x "$FAKEBIN_DIR/custom-agent"
  out=$(FM_QOS_UNAME=Darwin FM_QOS_TASKPOLICY="$fake" \
    run_case_spawn zsh-a1 "$PROJ_DIR" --mode no-mistakes --yolo off \
      "\"$FAKEBIN_DIR/custom-agent\" =(printf '%s\\n' zsh-process-substitution)")
  status=$?
  expect_code 0 "$status" "raw zsh spawn should succeed: $out"
  seen=$(run_emitted_launch "$shell") || fail "the clamped zsh raw command did not run"
  assert_equals $'zsh-process-substitution\nutility' "$seen" "zsh should interpret the raw command inside the clamp"
  assert_equals '-c utility' "$(cat "$log")" "the raw zsh command must retain utility QoS"
  pass "a real spawn preserves zsh-only raw-command syntax under utility QoS"
}

test_prefix_follows_the_host
test_spawn_wraps_every_launch
test_spawn_preserves_zsh_raw_command_syntax
test_spawn_on_a_host_without_the_clamp_is_unchanged
test_real_taskpolicy_clamps_the_agent
test_runner_applies_the_class_once
