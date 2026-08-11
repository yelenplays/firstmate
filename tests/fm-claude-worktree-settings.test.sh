#!/usr/bin/env bash
# Regression test for the Claude crewmate turn-end hook's edit to a worktree's
# .claude/settings.local.json (bin/fm-claude-worktree-hook.sh, driven by
# bin/fm-spawn.sh and bin/fm-teardown.sh).
#
# fm-spawn used to `cat >` that path, so a project that keeps its own
# settings.local.json - permissions the captain pre-approved, hooks the project
# already had - lost the whole file to a single hooks object the moment a
# crewmate spawned there. The file is tracked in some repos, so the deletion
# could be committed and would read as ordinary agent configuration in the diff.
#
# These tests drive the real fm-spawn.sh against a real git worktree with a fake
# tmux/treehouse (the tests/fm-spawn-worktree-settle.test.sh pattern) and assert
# the captain's keys survive, and that teardown's removal path puts the file
# back the way it found it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HOOK="$ROOT/bin/fm-claude-worktree-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-worktree-settings)

command -v python3 >/dev/null 2>&1 || { echo "1..0 # SKIP python3 required"; exit 0; }

# --- fixtures ---------------------------------------------------------------

# make_fakebin <dir>: a tmux stub that reports the settled worktree path for
# every pane_current_path read, plus an exit-0 treehouse.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> <id>: a firstmate home pinned to the claude crew harness, a
# project with a real worktree, and a brief. Echoes "home|proj|wt|fakebin".
make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_test_megamind_task "$home" "$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

settings_of() { printf '%s/.claude/settings.local.json' "$1"; }

# Read the worktree's own info/exclude, not `git check-ignore`: a host-level
# core.excludesFile commonly ignores .claude/settings.local.json already, which
# would mask whether fm-spawn added the entry itself.
excluded_in_worktree() {
  local excl
  excl=$(git -C "$1" rev-parse --git-path info/exclude) || return 1
  [ -f "$excl" ] || return 1
  grep -qxF '.claude/settings.local.json' "$excl"
}

json_query() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))'"$2"')' "$1"
}

# --- spawn preserves the captain's file -------------------------------------

test_spawn_preserves_existing_keys_and_hooks() {
  local rec id out status file permissions stop_commands
  id=claude-settings-merge-z1
  rec=$(make_case merge "$id")
  read_case "$rec"

  file=$(settings_of "$WT_DIR")
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<'JSON'
{
  "permissions": {
    "allow": ["Bash(npm run test:*)", "Read(//srv/captain-notes/**)", "WebFetch"]
  },
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "echo project-stop"}]}
    ],
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "echo project-pretooluse"}]}
    ]
  },
  "env": {"PROJECT_FLAG": "1"}
}
JSON

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file" \
    || fail "settings.local.json is not valid JSON after the spawn"

  permissions=$(json_query "$file" '["permissions"]["allow"]')
  assert_contains "$permissions" 'Bash(npm run test:*)' "the captain's pre-approved permissions were dropped"
  assert_contains "$permissions" 'Read(//srv/captain-notes/**)' "the captain's pre-approved permissions were dropped"
  assert_contains "$permissions" 'WebFetch' "the captain's pre-approved permissions were dropped"

  assert_grep 'PROJECT_FLAG' "$file" "an unrelated top-level key was dropped"
  assert_grep 'project-pretooluse' "$file" "a pre-existing non-Stop hook was dropped"

  stop_commands=$(json_query "$file" '["hooks"]["Stop"]')
  assert_contains "$stop_commands" 'echo project-stop' "the project's own Stop hook was dropped"
  assert_contains "$stop_commands" "$id.turn-ended" "firstmate's turn-end Stop hook was not installed"

  ! excluded_in_worktree "$WT_DIR" \
    || fail "firstmate hid the project's own settings file from git"

  pass "spawn merges the turn-end hook and preserves existing permissions and hooks"
}

# All four Claude lifecycle hooks (bin/fm-busy-lib.sh) arrive through the merging
# installer, so a project's own hook on one of those same events survives and the
# original bytes still come back when they are removed.
test_spawn_installs_every_lifecycle_hook_without_displacing_the_project() {
  local rec id out status file before
  id=claude-settings-lifecycle-z12
  rec=$(make_case lifecycle "$id")
  read_case "$rec"

  file=$(settings_of "$WT_DIR")
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<'JSON'
{
  "permissions": {
    "allow": ["Bash(npm run build:*)"]
  },
  "hooks": {
    "SessionEnd": [
      {"hooks": [{"type": "command", "command": "echo project-sessionend"}]}
    ]
  }
}
JSON
  before=$(cat "$file")

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed:"$'\n'"$out"

  assert_contains "$(json_query "$file" '["hooks"]["UserPromptSubmit"]')" \
    '--event user-prompt-submit' "the UserPromptSubmit lifecycle hook was not installed"
  assert_contains "$(json_query "$file" '["hooks"]["Stop"]')" \
    "$id.turn-ended" "the Stop hook lost the turn-end notification"
  assert_contains "$(json_query "$file" '["hooks"]["Stop"]')" \
    '--event stop' "the Stop lifecycle hook was not installed"
  assert_contains "$(json_query "$file" '["hooks"]["StopFailure"]')" \
    '--event stop-failure' "the StopFailure lifecycle hook was not installed"
  assert_contains "$(json_query "$file" '["hooks"]["SessionEnd"]')" \
    '--event session-end' "the SessionEnd lifecycle hook was not installed"
  assert_contains "$(json_query "$file" '["hooks"]["SessionEnd"]')" \
    'echo project-sessionend' "the project's own hook on a firstmate event was displaced"
  assert_grep 'npm run build' "$file" "the project's pre-approved permissions were dropped"

  # A refused teardown reinstalls without naming a hook set, so the install
  # record - not the legacy default - decides what a still-running crewmate keeps.
  "$ROOT/bin/fm-claude-worktree-hook.sh" remove "$WT_DIR" \
    "$HOME_DIR/state/$id.turn-ended" "$HOME_DIR/state/$id.claude-settings-backup" \
    >/dev/null || fail "removal was refused after a lifecycle install"
  "$ROOT/bin/fm-claude-worktree-hook.sh" install "$WT_DIR" \
    "$HOME_DIR/state/$id.turn-ended" "$HOME_DIR/state/$id.claude-settings-backup" \
    >/dev/null || fail "the refused-teardown restore was refused"
  assert_contains "$(json_query "$file" '["hooks"]["StopFailure"]')" \
    '--event stop-failure' "the restore downgraded the crewmate to the legacy turn-end hook"

  "$ROOT/bin/fm-claude-worktree-hook.sh" remove "$WT_DIR" \
    "$HOME_DIR/state/$id.turn-ended" "$HOME_DIR/state/$id.claude-settings-backup" \
    >/dev/null || fail "removal was refused after a restore"
  [ "$(cat "$file")" = "$before" ] \
    || fail "removing the lifecycle hooks did not restore the original bytes:"$'\n'"$(cat "$file")"

  pass "spawn installs every lifecycle hook and removal restores the project's file"
}

test_spawn_creates_file_when_absent() {
  local rec id out status file
  id=claude-settings-absent-z2
  rec=$(make_case absent "$id")
  read_case "$rec"
  file=$(settings_of "$WT_DIR")

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed with no pre-existing settings file"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_present "$file" "no settings.local.json was created"
  assert_grep "$id.turn-ended" "$file" "turn-end hook missing from the created file"
  excluded_in_worktree "$WT_DIR" \
    || fail "a settings file firstmate created was left in git's view"
  pass "spawn creates the settings file when the project has none"
}

test_spawn_handles_empty_file() {
  local rec id status file
  id=claude-settings-empty-z3
  rec=$(make_case empty "$id")
  read_case "$rec"
  file=$(settings_of "$WT_DIR")
  mkdir -p "$(dirname "$file")"
  : > "$file"

  run_spawn "$id" >/dev/null
  status=$?
  expect_code 0 "$status" "spawn should succeed over an empty settings file"
  assert_grep "$id.turn-ended" "$file" "turn-end hook missing after spawning over an empty file"
  pass "spawn treats an empty settings file as having nothing to preserve"
}

test_spawn_refuses_malformed_file_without_clobbering() {
  local rec id out status file before after
  id=claude-settings-malformed-z4
  rec=$(make_case malformed "$id")
  read_case "$rec"
  file=$(settings_of "$WT_DIR")
  mkdir -p "$(dirname "$file")"
  printf '{"permissions": {"allow": ["Bash(ls)"]},\n' > "$file"
  before=$(cat "$file")

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when settings.local.json is malformed JSON"
  assert_contains "$out" "settings.local.json" "refusal did not name the offending file"
  after=$(cat "$file")
  [ "$before" = "$after" ] || fail "malformed settings.local.json was overwritten: $after"
  pass "spawn refuses a malformed settings file instead of overwriting it"
}

test_spawn_refuses_symlinked_settings() {
  local rec id out status file target
  id=claude-settings-symlink-z5
  rec=$(make_case symlink "$id")
  read_case "$rec"
  file=$(settings_of "$WT_DIR")
  target="$TMP_ROOT/symlink-target.json"
  printf '{"permissions": {"allow": ["Bash(ls)"]}}\n' > "$target"
  mkdir -p "$(dirname "$file")"
  ln -s "$target" "$file"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse a symlinked settings.local.json"
  assert_contains "$out" "settings.local.json" "refusal did not name the offending file"
  assert_no_grep 'turn-ended' "$target" "wrote through a symlink and out of the worktree"
  pass "spawn refuses a symlinked settings file rather than writing through it"
}

# --- removal restores what was there ----------------------------------------

run_remove() {
  local id=$1
  "$HOOK" remove "$WT_DIR" "$HOME_DIR/state/$id.turn-ended" "$HOME_DIR/state/$id.claude-settings-backup"
}

test_remove_restores_pre_existing_file_byte_for_byte() {
  local rec id file before after status
  id=claude-settings-restore-z6
  rec=$(make_case restore "$id")
  read_case "$rec"
  file=$(settings_of "$WT_DIR")
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<'JSON'
{
  "permissions": {
    "allow": ["Bash(npm run test:*)"]
  },
  "env": {"PROJECT_FLAG": "1"}
}
JSON
  before=$(cat "$file")

  run_spawn "$id" >/dev/null || fail "spawn failed"
  assert_grep "$id.turn-ended" "$file" "turn-end hook was not installed"

  run_remove "$id" >/dev/null
  status=$?
  expect_code 0 "$status" "hook removal should succeed"
  after=$(cat "$file")
  [ "$before" = "$after" ] || fail "removal did not restore the original bytes:"$'\n'"$after"
  pass "removal restores a pre-existing settings file byte for byte"
}

test_remove_keeps_crewmate_additions_and_drops_only_our_hook() {
  local rec id file status permissions
  id=claude-settings-crewadd-z7
  rec=$(make_case crewadd "$id")
  read_case "$rec"
  file=$(settings_of "$WT_DIR")
  mkdir -p "$(dirname "$file")"
  printf '%s\n' '{"permissions": {"allow": ["Bash(ls)"]}}' > "$file"

  run_spawn "$id" >/dev/null || fail "spawn failed"
  # The crewmate approves another permission mid-task, as Claude Code does.
  python3 - "$file" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as stream:
    doc = json.load(stream)
doc["permissions"]["allow"].append("Bash(git status)")
with open(path, "w") as stream:
    json.dump(doc, stream, indent=2)
    stream.write("\n")
PY

  run_remove "$id" >/dev/null
  status=$?
  expect_code 0 "$status" "hook removal should succeed"
  permissions=$(json_query "$file" '["permissions"]["allow"]')
  assert_contains "$permissions" 'Bash(ls)' "removal dropped a pre-existing permission"
  assert_contains "$permissions" 'Bash(git status)' "removal dropped a permission added during the task"
  assert_no_grep 'turn-ended' "$file" "removal left firstmate's turn-end hook behind"
  pass "removal drops only firstmate's hook and keeps everything the task added"
}

test_remove_deletes_file_firstmate_created() {
  local rec id file status
  id=claude-settings-created-z8
  rec=$(make_case created "$id")
  read_case "$rec"
  file=$(settings_of "$WT_DIR")

  run_spawn "$id" >/dev/null || fail "spawn failed"
  assert_present "$file" "spawn did not create the settings file"

  run_remove "$id" >/dev/null
  status=$?
  expect_code 0 "$status" "hook removal should succeed"
  assert_absent "$file" "removal left behind a settings file firstmate created"
  assert_absent "$WT_DIR/.claude" "removal left behind a .claude directory firstmate created"
  pass "removal deletes a settings file (and directory) firstmate created"
}

test_remove_is_idempotent_and_quiet_when_absent() {
  local rec id status
  id=claude-settings-noop-z9
  rec=$(make_case noop "$id")
  read_case "$rec"

  run_remove "$id" >/dev/null
  status=$?
  expect_code 0 "$status" "removal with nothing installed should succeed"
  pass "removal is a no-op when there is no settings file"
}

test_remove_refuses_malformed_without_deleting() {
  local rec id file before after out status
  id=claude-settings-removemal-z10
  rec=$(make_case removemal "$id")
  read_case "$rec"
  file=$(settings_of "$WT_DIR")

  run_spawn "$id" >/dev/null || fail "spawn failed"
  printf '{"permissions": ["broken"\n' > "$file"
  before=$(cat "$file")

  out=$(run_remove "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "removal should refuse a malformed settings file"
  assert_contains "$out" "refused" "refusal was not reported"
  after=$(cat "$file")
  [ "$before" = "$after" ] || fail "removal rewrote a malformed settings file"
  pass "removal refuses a malformed settings file instead of deleting it"
}

# --- the whole spawn-to-teardown round trip ---------------------------------

# A project that TRACKS .claude/settings.local.json is the shape that made this
# dangerous: the merged hook shows up as an uncommitted change to a tracked file,
# so teardown has to put the file back before it inspects the worktree for the
# crewmate's unlanded work - otherwise a clean task is refused on firstmate's own
# edit.
test_spawn_and_teardown_round_trip_on_a_tracked_settings_file() {
  local id case_dir home proj wt fakebin file before after out status
  id=claude-settings-roundtrip-z11
  case_dir="$TMP_ROOT/roundtrip"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_test_megamind_task "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  fm_git_init_commit "$proj"
  mkdir -p "$proj/.claude"
  cat > "$proj/.claude/settings.local.json" <<'JSON'
{
  "permissions": {
    "allow": ["Bash(pytest:*)", "Read(//srv/captain-notes/**)"]
  }
}
JSON
  git -C "$proj" add -f .claude/settings.local.json
  git -C "$proj" -c user.email=t@t -c user.name=t commit -qm "track claude settings"
  fm_git_add_origin "$proj" "$case_dir/origin.git"
  git -C "$proj" push -q origin HEAD:main
  git -C "$proj" fetch -q origin
  git -C "$proj" worktree add -q -b "wt-roundtrip" "$wt"

  HOME_DIR=$home PROJ_DIR=$proj WT_DIR=$wt FAKEBIN_DIR=$fakebin
  file=$(settings_of "$wt")
  before=$(cat "$file")

  run_spawn "$id" >/dev/null || fail "spawn failed"
  assert_grep "$id.turn-ended" "$file" "turn-end hook was not installed"
  [ -n "$(git -C "$wt" status --porcelain)" ] \
    || fail "fixture is wrong: the merged hook should show as a change to a tracked file"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "teardown was refused on firstmate's own settings edit:"$'\n'"$out"
  after=$(cat "$file")
  [ "$before" = "$after" ] || fail "teardown did not restore the tracked settings file:"$'\n'"$after"
  [ -z "$(git -C "$wt" status --porcelain)" ] \
    || fail "teardown left the worktree dirty: $(git -C "$wt" status --porcelain)"
  assert_absent "$home/state/$id.claude-settings-backup" "teardown left its install record behind"
  pass "a tracked settings file survives the whole spawn-to-teardown round trip"
}

test_spawn_preserves_existing_keys_and_hooks
test_spawn_installs_every_lifecycle_hook_without_displacing_the_project
test_spawn_creates_file_when_absent
test_spawn_handles_empty_file
test_spawn_refuses_malformed_file_without_clobbering
test_spawn_refuses_symlinked_settings
test_remove_restores_pre_existing_file_byte_for_byte
test_remove_keeps_crewmate_additions_and_drops_only_our_hook
test_remove_deletes_file_firstmate_created
test_remove_is_idempotent_and_quiet_when_absent
test_remove_refuses_malformed_without_deleting
test_spawn_and_teardown_round_trip_on_a_tracked_settings_file

echo "# all fm-claude-worktree-settings tests passed"
