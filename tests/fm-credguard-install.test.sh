#!/usr/bin/env bash
# shellcheck disable=SC2016
# Behavior tests for the credential read guard installer (docs/credguard.md).
#
# Every case runs bin/fm-credguard-install.mjs against a throwaway HOME with
# stub harness executables on PATH, so no real harness config is touched.
# Asserts: --check changes nothing, install keeps every other hook, backs up
# each changed file, is idempotent, writes through a symlinked config, refuses
# malformed JSON, reports absent and uncovered harnesses, and refuses to wire
# a hook that lives in a linked git worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL="$ROOT/bin/fm-credguard-install.mjs"
command -v node >/dev/null 2>&1 || { pass "node not installed, skipping"; exit 0; }
command -v git >/dev/null 2>&1 || { pass "git not installed, skipping"; exit 0; }

T=$(fm_test_tmproot fm-credguard-install) || fail "could not create a temp root"
HARNESSES=(claude codex devin kimi grok pi omp)

# A PATH with exactly the tools the installer needs plus one stub per harness.
TOOLS="$T/tools"
mkdir -p "$TOOLS"
ln -s "$(command -v node)" "$TOOLS/node"
ln -s "$(command -v git)" "$TOOLS/git"
TOML_PY=""
for py in python3 python3.14 python3.13 python3.12 python3.11; do
  if command -v "$py" >/dev/null 2>&1 && "$py" -c 'import tomllib' 2>/dev/null; then
    TOML_PY=$(command -v "$py")
    ln -s "$TOML_PY" "$TOOLS/python3"
    break
  fi
done

new_home() {  # <name> [harness...] -> echoes a HOME whose fakebin holds stubs for the named harnesses
  local h="$T/$1" fakebin name
  shift
  mkdir -p "$h"
  fakebin=$(fm_fakebin "$h")
  for name in "$@"; do
    printf '#!/bin/sh\nexit 0\n' > "$fakebin/$name"
    chmod +x "$fakebin/$name"
  done
  printf '%s\n' "$h"
}

install_in() {  # <home> [args...] -> sets RC OUT
  local h=$1
  shift
  OUT=$(env -i HOME="$h" PATH="$h/fakebin:$TOOLS:/usr/bin:/bin" "$INSTALL" --hook "$T/hook/fm-credguard-read.mjs" "$@" 2>&1)
  RC=$?
}

json_eval() {  # <file> <js expression over `s`> -> prints the result
  node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(eval(process.argv[2]))' "$1" "$2"
}

toml_eval() {  # <file> <python expression over `s`> -> prints the result
  "$TOML_PY" -c 'import sys, tomllib; s = tomllib.load(open(sys.argv[1], "rb")); print(eval(sys.argv[2]))' "$1" "$2"
}

fingerprint() {  # <home> -> one line per regular file: path and checksum
  (cd "$1" && find . -type f ! -path './fakebin/*' -print0 | sort -z | xargs -0 cksum)
}

seed_configs() {  # <home>: configs that already hold other hooks
  local h=$1
  mkdir -p "$h/.claude" "$h/.codex" "$h/.config/devin" "$h/.kimi-code"
  cat > "$h/.claude/settings.json" <<'EOF'
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "other-hook" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "stop-hook" }] }]
  }
}
EOF
  cat > "$h/.codex/config.toml" <<'EOF'
model = "gpt-test"

[features]
hooks = true

# an existing group the guard must not displace
[[hooks.PreToolUse]]
matcher = "Bash"

[[hooks.PreToolUse.hooks]]
type = "command"
command = "keep-me"
EOF
  printf '{"permissions":{"deny":["Read(**/.env)"]},"hooks":{"PreToolUse":[{"matcher":"exec","hooks":[{"type":"command","command":"devin-other"}]}]}}\n' > "$h/.config/devin/config.json"
  printf 'default_model = "k2"\n\n[[hooks]]\nevent = "Stop"\ncommand = "kimi-stop"\n' > "$h/.kimi-code/config.toml"
}

mkdir -p "$T/hook"
printf '#!/bin/sh\nexit 0\n' > "$T/hook/fm-credguard-read.mjs"
chmod +x "$T/hook/fm-credguard-read.mjs"

# --- cases -------------------------------------------------------------------

test_check_changes_nothing() {
  local h before
  h=$(new_home check "${HARNESSES[@]}")
  seed_configs "$h"
  before=$(fingerprint "$h")
  install_in "$h" --check
  expect_code 1 "$RC" "--check on a home without the guard"
  assert_contains "$OUT" "-- claude: guard missing" "--check reports claude missing"
  assert_equals "$before" "$(fingerprint "$h")" "--check left every file unchanged"
  pass "--check reports what is missing and changes nothing"
}

test_install_keeps_other_hooks() {
  local h
  [ -n "$TOML_PY" ] || { pass "no Python with tomllib, skipping the TOML install case"; return; }
  h=$(new_home install "${HARNESSES[@]}")
  seed_configs "$h"
  install_in "$h"
  expect_code 0 "$RC" "install exit"$'\n'"$OUT"
  assert_not_contains "$OUT" $'\n-- ' "install reports no failure"

  assert_equals "opus" "$(json_eval "$h/.claude/settings.json" 's.model')" "claude keeps its settings"
  assert_equals "other-hook" "$(json_eval "$h/.claude/settings.json" 's.hooks.PreToolUse[0].hooks[0].command')" "claude keeps the other PreToolUse hook"
  assert_equals "stop-hook" "$(json_eval "$h/.claude/settings.json" 's.hooks.Stop[0].hooks[0].command')" "claude keeps the Stop hook"
  assert_equals "Bash|Read|Grep" "$(json_eval "$h/.claude/settings.json" 's.hooks.PreToolUse[1].matcher')" "claude guard matcher"
  assert_contains "$(json_eval "$h/.claude/settings.json" 's.hooks.PreToolUse[1].hooks[0].command')" "--runtime claude" "claude guard command"

  assert_equals "devin-other" "$(json_eval "$h/.config/devin/config.json" 's.hooks.PreToolUse[0].hooks[0].command')" "devin keeps the other hook"
  assert_equals "Read(**/.env)" "$(json_eval "$h/.config/devin/config.json" 's.permissions.deny[0]')" "devin keeps its permissions"
  assert_equals "exec|read|grep" "$(json_eval "$h/.config/devin/config.json" 's.hooks.PreToolUse[1].matcher')" "devin guard matcher"

  assert_equals "keep-me" "$(toml_eval "$h/.codex/config.toml" 's["hooks"]["PreToolUse"][0]["hooks"][0]["command"]')" "codex keeps the other group first"
  assert_equals "Bash" "$(toml_eval "$h/.codex/config.toml" 's["hooks"]["PreToolUse"][1]["matcher"]')" "codex guard sits at group 1"
  assert_contains "$(toml_eval "$h/.codex/config.toml" 'list(s["hooks"]["state"].keys())[0]')" ":pre_tool_use:1:0" "codex trust key names group 1"
  assert_contains "$(toml_eval "$h/.codex/config.toml" 'list(s["hooks"]["state"].values())[0]["trusted_hash"]')" "sha256:" "codex trust hash recorded"
  assert_equals "gpt-test" "$(toml_eval "$h/.codex/config.toml" 's["model"]')" "codex keeps its settings"

  assert_equals "kimi-stop" "$(toml_eval "$h/.kimi-code/config.toml" 's["hooks"][0]["command"]')" "kimi keeps the Stop hook"
  assert_equals "PreToolUse" "$(toml_eval "$h/.kimi-code/config.toml" 's["hooks"][1]["event"]')" "kimi guard event"

  assert_contains "$(json_eval "$h/.grok/hooks/fm-credguard-read.json" 's.hooks.PreToolUse[0].hooks[0].command')" "--runtime grok" "grok hook file"
  assert_grep "$T/hook/fm-credguard-read.mjs" "$h/.pi/agent/extensions/fm-credguard-read.ts" "pi extension names the hook"
  assert_grep '"omp"' "$h/.omp/agent/extensions/fm-credguard-read.ts" "omp extension names its runtime"

  for f in .claude/settings.json .codex/config.toml .config/devin/config.json .kimi-code/config.toml; do
    compgen -G "$h/$f.bak-credguard-*" >/dev/null || fail "no backup for $f"
  done
  pass "install wires every harness, keeps every other hook, and backs up each changed file"
}

test_install_is_idempotent() {
  local h before backups
  [ -n "$TOML_PY" ] || { pass "no Python with tomllib, skipping the idempotency case"; return; }
  h=$(new_home idem "${HARNESSES[@]}")
  seed_configs "$h"
  install_in "$h"
  expect_code 0 "$RC" "first install"
  before=$(fingerprint "$h")
  backups=$(find "$h" -name '*.bak-credguard-*' | wc -l)
  install_in "$h"
  expect_code 0 "$RC" "second install"
  assert_equals "$before" "$(fingerprint "$h")" "a second install changes no file"
  assert_equals "$backups" "$(find "$h" -name '*.bak-credguard-*' | wc -l)" "a second install makes no backup"
  install_in "$h" --check
  expect_code 0 "$RC" "--check after install"
  pass "install is idempotent and --check then passes"
}

test_new_hook_path_replaces_old_handler() {
  local h
  h=$(new_home moved claude)
  install_in "$h"
  expect_code 0 "$RC" "first install"
  mkdir -p "$T/hook2"
  cp "$T/hook/fm-credguard-read.mjs" "$T/hook2/fm-credguard-read.mjs"
  OUT=$(env -i HOME="$h" PATH="$h/fakebin:$TOOLS:/usr/bin:/bin" "$INSTALL" --hook "$T/hook2/fm-credguard-read.mjs" 2>&1)
  RC=$?
  expect_code 0 "$RC" "install with a moved hook"
  assert_equals "1" "$(json_eval "$h/.claude/settings.json" 's.hooks.PreToolUse.length')" "one guard group remains"
  assert_contains "$(json_eval "$h/.claude/settings.json" 's.hooks.PreToolUse[0].hooks[0].command')" "/hook2/" "the guard points at the new hook"
  pass "a moved hook replaces the old guard handler instead of adding a second"
}

test_symlinked_config_written_through() {
  local h target
  h=$(new_home link claude)
  mkdir -p "$h/dotfiles" "$h/.claude"
  printf '{"model":"opus"}\n' > "$h/dotfiles/settings.json"
  ln -s "$h/dotfiles/settings.json" "$h/.claude/settings.json"
  install_in "$h" --harness claude
  expect_code 0 "$RC" "install over a symlink"
  [ -L "$h/.claude/settings.json" ] || fail "the symlink was replaced by a file"
  target="$h/dotfiles/settings.json"
  assert_equals "Bash|Read|Grep" "$(json_eval "$target" 's.hooks.PreToolUse[0].matcher')" "the link target holds the guard"
  compgen -G "$target.bak-credguard-*" >/dev/null || fail "no backup beside the link target"
  pass "a symlinked config is written through and stays a link"
}

test_malformed_json_refused() {
  local h
  h=$(new_home broken claude)
  mkdir -p "$h/.claude"
  printf '{"model": "opus",\n' > "$h/.claude/settings.json"
  install_in "$h" --harness claude
  expect_code 1 "$RC" "install over malformed JSON"
  assert_contains "$OUT" "-- claude:" "malformed JSON is reported"
  assert_equals '{"model": "opus",' "$(cat "$h/.claude/settings.json")" "malformed JSON left unchanged"
  pass "malformed settings JSON is reported and never overwritten"
}

test_absent_and_uncovered_reported() {
  local h name
  h=$(new_home bare)
  install_in "$h"
  expect_code 0 "$RC" "install with no harness installed"
  for name in "${HARNESSES[@]}"; do
    assert_contains "$OUT" "absent $name: not installed" "$name reported absent"
  done
  for name in "codex crewmate and scout launches" muse agy rovo opencode cursor gemini; do
    assert_contains "$OUT" "uncovered $name:" "$name reported uncovered"
  done
  [ ! -e "$h/.claude" ] && [ ! -e "$h/.grok" ] && [ ! -e "$h/.pi" ] || fail "an absent harness got a config"
  pass "absent harnesses are reported and untouched; uncovered harnesses are always listed"
}

test_linked_worktree_refused() {
  local repo="$T/repo" wt="$T/repo-wt" rc=0 out
  fm_git_worktree "$repo" "$wt" fm/test
  for d in "$repo" "$wt"; do
    mkdir -p "$d/bin"
    cp "$INSTALL" "$d/bin/fm-credguard-install.mjs"
    cp "$T/hook/fm-credguard-read.mjs" "$d/bin/fm-credguard-read.mjs"
  done
  out=$(env -i HOME="$T/wt-home" PATH="$TOOLS:/usr/bin:/bin" "$wt/bin/fm-credguard-install.mjs" --check 2>&1) || rc=$?
  expect_code 2 "$rc" "default hook from a linked worktree"
  assert_contains "$out" "linked git worktree" "the refusal names the reason"
  rc=0
  out=$(env -i HOME="$T/wt-home" PATH="$TOOLS:/usr/bin:/bin" "$repo/bin/fm-credguard-install.mjs" --check 2>&1) || rc=$?
  expect_code 0 "$rc" "default hook from the primary checkout"
  assert_contains "$out" "ok guard hook at $repo/bin/fm-credguard-read.mjs" "the primary checkout's hook is used"
  pass "a linked worktree's hook is refused; the primary checkout's is used"
}

test_check_changes_nothing
test_install_keeps_other_hooks
test_install_is_idempotent
test_new_hook_path_replaces_old_handler
test_symlinked_config_written_through
test_malformed_json_refused
test_absent_and_uncovered_reported
test_linked_worktree_refused
