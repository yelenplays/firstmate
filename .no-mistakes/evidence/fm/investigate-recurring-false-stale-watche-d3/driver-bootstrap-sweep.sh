#!/usr/bin/env bash
# Ephemeral verification driver (not committed): drives the REAL
# bin/fm-bootstrap.sh local session-start phase with the hermetic fake
# toolchain and asserts the locked orphan watcher-state sweep runs and retires
# only residue no live record owns. Deleted after the run.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-verify-bootstrap-sweep)
export FM_BACKEND_CMUX_BUNDLE_BIN="$TMP_ROOT/no-bundled-cmux"
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true

make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_GH_AXI_VERSION:-0.1.29}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  if [ "${FM_FAKE_TREEHOUSE_LEASE_HELP:-}" = 1 ]; then
    printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  else
    printf '%s\n' 'Usage: treehouse get'
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_NO_MISTAKES_VERSION:-no-mistakes version v1.46.0 (fake) 2026-06-27T00:02:18Z}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  add_tasks_axi "$fakebin" "0.2.4"
  add_quota_axi "$fakebin"
  printf '%s\n' "$fakebin"
}

add_quota_axi() {
  local fakebin=$1
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_QUOTA_AXI_VERSION:-0.1.29}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/quota-axi"
}

add_tasks_axi() {
  local fakebin=$1 version=$2 archive_body=${3:-yes} multi_id=${4:-yes} archive_line mv_usage
  archive_line=""
  [ "$archive_body" = yes ] && archive_line='  --archive-body'
  mv_usage='usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  [ "$multi_id" = yes ] || mv_usage='usage: tasks-axi mv <id> --to <path-or-dir>'
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' '$version'
  exit 0
fi
if [ "\${1:-}" = update ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --body-file <path>'
  [ -z '$archive_line' ] || printf '%s\n' '$archive_line'
  exit 0
fi
if [ "\${1:-}" = mv ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' '$mv_usage'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

test_bootstrap_retires_orphan_watcher_state() {
  local dir home fakebin out rc live_key ghost_key
  dir="$TMP_ROOT/sweep"; home="$dir/home"; mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  fakebin=$(make_fake_toolchain "$dir")
  live_key="test_fm-live"; ghost_key="test_fm-ghost"
  printf 'window=test:fm-live\nkind=ship\n' > "$home/state/live.meta"
  touch "$home/state/live.turn-ended"
  : > "$home/state/.hash-$live_key"
  : > "$home/state/.window-owner-$live_key"
  # orphaned residue: dead window key + dead task signal files
  : > "$home/state/.hash-$ghost_key"
  : > "$home/state/.wedge-escalations-$ghost_key"
  : > "$home/state/.window-owner-$ghost_key"
  touch "$home/state/dead.turn-ended" "$home/state/dead.progress"

  set +e
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$dir/fake-root" \
    FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_VERBOSE_FACTS=1 \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "bootstrap local phase should succeed"$'\n'"$out"
  assert_contains "$out" "BOOTSTRAP_INFO: retired" "bootstrap should report the orphan watcher sweep"$'\n'"$out"
  [ ! -e "$home/state/.hash-$ghost_key" ] || fail "bootstrap left the orphan window marker"
  [ ! -e "$home/state/.wedge-escalations-$ghost_key" ] || fail "bootstrap left the orphan escalation count"
  [ ! -e "$home/state/dead.turn-ended" ] || fail "bootstrap left a dead task's turn-ended signal"
  [ ! -e "$home/state/dead.progress" ] || fail "bootstrap left a dead task's progress signal"
  [ -e "$home/state/.hash-$live_key" ] || fail "bootstrap removed a live endpoint's marker"
  [ -e "$home/state/live.turn-ended" ] || fail "bootstrap removed a live task's turn-ended"
  [ -e "$home/state/live.meta" ] || fail "bootstrap removed a live task record"
  pass "bootstrap's local session-start phase retires orphan watcher state and keeps live state"
}

test_bootstrap_retires_orphan_watcher_state
