#!/usr/bin/env bash
# Ephemeral verification driver (not committed): drives a REAL fm-spawn.sh
# --relaunch against the hermetic tmux stub and asserts the watcher turn
# anchors and window markers of the predecessor incarnation are retired by the
# spawn path. Deleted after the run.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-verify-spawn-retire)
mkdir -p "$TMP_ROOT"
SPAWN="$ROOT/bin/fm-spawn.sh"

make_tmux_stub() {
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) cat "$D/becomes" > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

add_ship_task() {
  local dir=$1 id=$2 harness=${3:-claude}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise spawn retirement for $id.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
}

run_spawn() {
  local dir=$1; shift
  mkdir -p "$dir/user-home"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    "$SPAWN" "$@" 2>&1
}

test_relaunch_retires_predecessor_turn_anchors() {
  local dir out rc key
  dir=$(new_case spawn-retire rl99)
  add_ship_task "$dir" rl99 claude
  printf 'zsh' > "$dir/fake/command"
  key="fmses_fm-rl99"
  # Predecessor incarnation's stale anchors and supervision markers, exactly
  # as an interrupted teardown / long-idle prior incarnation leaves them.
  touch -t 200001010000 "$dir/home/state/rl99.turn-ended"
  touch -t 200001010000 "$dir/home/state/rl99.progress"
  printf '2\n' > "$dir/home/state/.wedge-escalations-$key"
  printf '1\n' > "$dir/home/state/.count-$key"
  printf 'old-worker' > "$dir/home/state/.window-owner-$key"
  : > "$dir/home/state/.paused-$key"

  out=$(run_spawn "$dir" rl99 --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "spawn --relaunch should succeed"$'\n'"$out"

  [ ! -e "$dir/home/state/rl99.turn-ended" ] \
    || fail "relaunch kept the predecessor's stale turn-ended anchor"
  [ ! -e "$dir/home/state/rl99.progress" ] \
    || fail "relaunch kept the predecessor's stale progress anchor"
  [ ! -e "$dir/home/state/.wedge-escalations-$key" ] \
    || fail "relaunch kept the predecessor's wedge-escalation count"
  [ ! -e "$dir/home/state/.count-$key" ] \
    || fail "relaunch kept the predecessor's hash count"
  [ ! -e "$dir/home/state/.paused-$key" ] \
    || fail "relaunch kept the predecessor's pause marker"
  [ "$(cat "$dir/home/state/.window-owner-$key" 2>/dev/null)" = rl99 ] \
    || fail "relaunch did not claim the endpoint for the new incarnation"
  pass "a relaunch retires the predecessor's turn anchors and window markers before publishing"
}

test_relaunch_leaves_colliding_sibling_task_markers() {
  local dir out rc
  dir=$(new_case task-collision rl88)
  add_ship_task "$dir" v2.ship claude
  # A second live task whose id flattens to the same key, with its own worktree.
  fm_git_worktree "$dir/proj2" "$dir/wt2" "task-v2_ship"
  mkdir -p "$dir/home/data/v2_ship"
  printf '# Task\n## Captain\047s intent\ncollide\n' > "$dir/home/data/v2_ship/brief.md"
  {
    echo "window=fmses:fm-v2_ship"
    echo "endpoint_task_id=v2_ship"
    echo "worktree=$dir/wt2"
    echo "project=$dir/proj2"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-v2_ship"
    echo "model=default"
    echo "effort=default"
  } > "$dir/home/state/v2_ship.meta"
  printf 'zsh' > "$dir/fake/command"
  # v2.ship and v2_ship flatten to the same task key; the live sibling's shared
  # episode markers must survive the acting task's relaunch retirement.
  : > "$dir/home/state/.subsuper-stale-v2_ship"
  : > "$dir/home/state/.subsuper-paused-v2_ship"
  : > "$dir/home/state/.subsuper-pause-until-due-v2_ship"
  : > "$dir/home/state/.seen-v2_ship_turn-ended"
  : > "$dir/home/state/.count-fmses_fm-v2_ship"
  touch -t 200001010000 "$dir/home/state/v2.ship.turn-ended"
  touch -t 200001010000 "$dir/home/state/v2.ship.progress"

  out=$(run_spawn "$dir" v2.ship --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "relaunch under a task-key collision should succeed"$'\n'"$out"
  for m in .subsuper-stale-v2_ship .subsuper-paused-v2_ship .subsuper-pause-until-due-v2_ship .seen-v2_ship_turn-ended; do
    [ -e "$dir/home/state/$m" ] || fail "relaunch deleted the colliding sibling's shared $m"
  done
  [ ! -e "$dir/home/state/v2.ship.turn-ended" ] || fail "relaunch kept the acting task's own turn-ended"
  [ ! -e "$dir/home/state/v2.ship.progress" ] || fail "relaunch kept the acting task's own progress"
  pass "a relaunch under a task-key collision retires its own anchors and spares the live sibling's shared markers"
}

test_relaunch_retires_predecessor_turn_anchors
test_relaunch_leaves_colliding_sibling_task_markers
