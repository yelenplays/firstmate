#!/usr/bin/env bash
# Behavior tests for bin/fm-skill-path.sh.
#
# Every case builds a synthetic Claude configuration root and points
# CLAUDE_CONFIG_DIR at it, so the suite proves the resolver's contract on any
# machine and in CI without depending on a plugin actually being installed.
# The assertions are behavioral: exit status, stdout, and stderr of real runs.
#
# The load-bearing guarantee is that a refusal prints NO path, so an adapter can
# treat any stdout as resolved and any nonzero status as an honest unsupported
# state instead of improvising a path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOLVER="$ROOT/bin/fm-skill-path.sh"
TMP_ROOT=$(fm_test_tmproot fm-skill-path)

if ! command -v jq >/dev/null 2>&1; then
  echo "skip: jq not found (required to read the Claude plugin registry)"
  exit 0
fi

# --- fixtures ----------------------------------------------------------------

# fm_skill_fixture <config-root>: a complete, valid configuration with plugin
# "demo-skills" 2.3.1 from marketplace "demo-market", enabled at user scope, and
# declaring one skill "interviewing" that carries a support file.
fm_skill_fixture() {
  local config=$1 install
  install="$config/plugins/cache/demo-market/demo-skills/2.3.1"
  mkdir -p "$config/plugins" "$install/.claude-plugin" "$install/skills/productivity/interviewing"

  cat > "$config/plugins/installed_plugins.json" <<EOF
{
  "version": 1,
  "plugins": {
    "demo-skills@demo-market": [
      {
        "scope": "user",
        "installPath": "$install",
        "version": "2.3.1",
        "gitCommitSha": "abc123def456"
      }
    ]
  }
}
EOF

  cat > "$config/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "demo-skills@demo-market": true
  }
}
EOF

  cat > "$install/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "demo-skills",
  "version": "2.3.1",
  "skills": [
    "./skills/productivity/interviewing"
  ]
}
EOF

  cat > "$install/skills/productivity/interviewing/SKILL.md" <<'EOF'
---
name: interviewing
description: A fixture skill.
---

# Interviewing

Body text. See [FORMAT.md](./FORMAT.md).
EOF

  cat > "$install/skills/productivity/interviewing/FORMAT.md" <<'EOF'
# Format

Support file reached by a relative link from SKILL.md.
EOF

  # A skill present in the source tree but NOT declared by the manifest, the
  # shape of upstream in-progress/misc/personal/deprecated skills.
  mkdir -p "$install/skills/deprecated/retired"
  cat > "$install/skills/deprecated/retired/SKILL.md" <<'EOF'
---
name: retired
description: Present on disk, absent from the manifest.
---
EOF

  printf '%s\n' "$install"
}

# fm_skill_install_path <config-root>
fm_skill_install_path() {
  printf '%s\n' "$1/plugins/cache/demo-market/demo-skills/2.3.1"
}

# fm_skill_run <config-root> <args...>: run the resolver against a fixture
# config, capturing stdout and stderr separately. Sets RUN_OUT, RUN_ERR, RUN_RC.
fm_skill_run() {
  local config=$1
  shift
  RUN_OUT=$(CLAUDE_CONFIG_DIR="$config" "$RESOLVER" "$@" 2>"$TMP_ROOT/stderr.txt")
  RUN_RC=$?
  RUN_ERR=$(cat "$TMP_ROOT/stderr.txt")
}

# assert_refusal <code> <label>: the last run must have refused with <code> and
# printed nothing on stdout.
assert_refusal() {
  local want=$1 label=$2
  expect_code "$want" "$RUN_RC" "$label"
  [ -z "$RUN_OUT" ] || fail "$label: refusal printed a path on stdout: $RUN_OUT"
  [ -n "$RUN_ERR" ] || fail "$label: refusal printed no diagnostic on stderr"
}

# --- tests -------------------------------------------------------------------

test_resolves_declared_skill() {
  local config install
  config="$TMP_ROOT/resolve"
  install=$(fm_skill_fixture "$config")

  fm_skill_run "$config" demo-skills interviewing
  expect_code 0 "$RUN_RC" "resolving a declared skill should exit 0 (stderr: $RUN_ERR)"
  assert_contains "$RUN_OUT" "plugin=demo-skills" "resolved block lost the plugin name"
  assert_contains "$RUN_OUT" "marketplace=demo-market" "resolved block lost the marketplace"
  assert_contains "$RUN_OUT" "scope=user" "resolved block lost the install scope"
  assert_contains "$RUN_OUT" "version=2.3.1" "resolved block lost the plugin version"
  assert_contains "$RUN_OUT" "commit=abc123def456" "resolved block lost the source pin"
  assert_contains "$RUN_OUT" "skill=interviewing" "resolved block lost the skill name"
  assert_contains "$RUN_OUT" "skill_dir=$install/skills/productivity/interviewing" \
    "resolved block lost the skill directory"
  assert_contains "$RUN_OUT" "skill_file=$install/skills/productivity/interviewing/SKILL.md" \
    "resolved block lost the SKILL.md path"
  pass "fm-skill-path.sh: resolves a declared skill with its full identity"
}

test_resolved_paths_are_real_and_support_files_resolve() {
  local config dir out
  config="$TMP_ROOT/support"
  fm_skill_fixture "$config" >/dev/null

  fm_skill_run "$config" demo-skills interviewing --field skill_dir
  expect_code 0 "$RUN_RC" "--field skill_dir should exit 0 (stderr: $RUN_ERR)"
  dir=$RUN_OUT
  assert_present "$dir/SKILL.md" "resolved skill_dir does not contain SKILL.md"
  # The upstream convention links support files relatively from SKILL.md, so the
  # returned directory is what makes those links resolve.
  assert_present "$dir/FORMAT.md" "relative support file does not resolve under skill_dir"

  fm_skill_run "$config" demo-skills interviewing --list-files
  expect_code 0 "$RUN_RC" "--list-files should exit 0 (stderr: $RUN_ERR)"
  out=$RUN_OUT
  assert_contains "$out" "SKILL.md" "--list-files omitted SKILL.md"
  assert_contains "$out" "FORMAT.md" "--list-files omitted the support file"
  case "$out" in
    /*) fail "--list-files printed absolute paths, not paths relative to skill_dir" ;;
  esac
  pass "fm-skill-path.sh: resolved directory carries the skill's support tree"
}

test_default_config_root_is_claude_home() {
  local config out rc
  config="$TMP_ROOT/default-home/.claude"
  fm_skill_fixture "$config" >/dev/null
  out=$(env -u CLAUDE_CONFIG_DIR HOME="$TMP_ROOT/default-home" "$RESOLVER" \
    demo-skills interviewing --field version 2>&1)
  rc=$?
  expect_code 0 "$rc" "an unset CLAUDE_CONFIG_DIR should fall back to \$HOME/.claude (got: $out)"
  [ "$out" = "2.3.1" ] || fail "default config root resolved the wrong version: $out"
  pass "fm-skill-path.sh: an unset CLAUDE_CONFIG_DIR falls back to \$HOME/.claude"
}

test_custom_config_dir_with_spaces() {
  local config
  config="$TMP_ROOT/config root with spaces/.claude dir"
  fm_skill_fixture "$config" >/dev/null

  fm_skill_run "$config" demo-skills interviewing --field skill_file
  expect_code 0 "$RUN_RC" "a config path containing spaces should resolve (stderr: $RUN_ERR)"
  assert_contains "$RUN_OUT" "config root with spaces" "resolved path lost the spaces in the config root"
  assert_present "$RUN_OUT" "resolved skill_file does not exist under a path with spaces"

  fm_skill_run "$config" demo-skills interviewing --list-files
  expect_code 0 "$RUN_RC" "--list-files should survive a path containing spaces (stderr: $RUN_ERR)"
  assert_contains "$RUN_OUT" "FORMAT.md" "--list-files lost the support file under a path with spaces"
  pass "fm-skill-path.sh: resolves through a CLAUDE_CONFIG_DIR containing spaces"
}

test_missing_install_refuses() {
  local config install
  config="$TMP_ROOT/missing"
  install=$(fm_skill_fixture "$config")

  # No registry at all.
  rm -f "$config/plugins/installed_plugins.json"
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 3 "an absent plugin registry must refuse"

  # Registry present, plugin absent from it.
  fm_skill_fixture "$config" >/dev/null
  cat > "$config/plugins/installed_plugins.json" <<'EOF'
{ "version": 1, "plugins": {} }
EOF
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 3 "an unregistered plugin must refuse"

  # Registered but the install directory is gone.
  fm_skill_fixture "$config" >/dev/null
  rm -rf "$install"
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 3 "a registered plugin with no install directory must refuse"
  pass "fm-skill-path.sh: refuses a missing registry, plugin, or install directory"
}

test_disabled_plugin_refuses() {
  local config
  config="$TMP_ROOT/disabled"
  fm_skill_fixture "$config" >/dev/null

  cat > "$config/settings.json" <<'EOF'
{ "enabledPlugins": { "demo-skills@demo-market": false } }
EOF
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 4 "an explicitly disabled plugin must refuse"
  assert_contains "$RUN_ERR" "disabled" "disabled refusal did not say the plugin is disabled"

  # No decision recorded anywhere is treated as not enabled, not as enabled.
  cat > "$config/settings.json" <<'EOF'
{ "enabledPlugins": {} }
EOF
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 4 "a plugin with no enablement decision must refuse"

  rm -f "$config/settings.json"
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 4 "a missing settings file must refuse rather than assume enabled"
  pass "fm-skill-path.sh: refuses a disabled or unenabled plugin"
}

test_local_settings_decide_enablement() {
  local config
  config="$TMP_ROOT/local-settings"
  fm_skill_fixture "$config" >/dev/null

  cat > "$config/settings.local.json" <<'EOF'
{ "enabledPlugins": { "demo-skills@demo-market": false } }
EOF
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 4 "a local settings file disabling the plugin must win over the shared one"
  pass "fm-skill-path.sh: a local enablement decision wins over the shared one"
}

test_skill_not_in_this_version_refuses() {
  local config
  config="$TMP_ROOT/not-declared"
  fm_skill_fixture "$config" >/dev/null

  fm_skill_run "$config" demo-skills nonexistent
  assert_refusal 5 "an unknown skill must refuse with the not-declared status"

  # Present on disk but absent from the manifest: exactly the shape of upstream
  # deprecated, in-progress, misc, and personal skills that ship in the source
  # tree but are not part of the plugin.
  fm_skill_run "$config" demo-skills retired
  assert_refusal 5 "a skill on disk but absent from the manifest must refuse"
  pass "fm-skill-path.sh: refuses a skill this plugin version does not declare"
}

test_ambiguous_marketplace_refuses() {
  local config install
  config="$TMP_ROOT/ambiguous-market"
  install=$(fm_skill_fixture "$config")

  cat > "$config/plugins/installed_plugins.json" <<EOF
{
  "version": 1,
  "plugins": {
    "demo-skills@demo-market": [
      { "scope": "user", "installPath": "$install", "version": "2.3.1", "gitCommitSha": "abc123def456" }
    ],
    "demo-skills@other-market": [
      { "scope": "user", "installPath": "$install", "version": "2.3.1", "gitCommitSha": "abc123def456" }
    ]
  }
}
EOF
  cat > "$config/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "demo-skills@demo-market": true,
    "demo-skills@other-market": true
  }
}
EOF

  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 6 "a plugin name present in two marketplaces must refuse as ambiguous"
  assert_contains "$RUN_ERR" "ambiguous" "ambiguity refusal did not name the problem"

  # Naming the marketplace explicitly resolves the ambiguity.
  fm_skill_run "$config" demo-skills@demo-market interviewing --field marketplace
  expect_code 0 "$RUN_RC" "an explicit marketplace should resolve (stderr: $RUN_ERR)"
  [ "$RUN_OUT" = "demo-market" ] || fail "explicit marketplace resolved to '$RUN_OUT'"
  pass "fm-skill-path.sh: refuses an ambiguous marketplace and accepts an explicit one"
}

test_ambiguous_scope_refuses() {
  local config install
  config="$TMP_ROOT/ambiguous-scope"
  install=$(fm_skill_fixture "$config")

  cat > "$config/plugins/installed_plugins.json" <<EOF
{
  "version": 1,
  "plugins": {
    "demo-skills@demo-market": [
      { "scope": "user", "installPath": "$install", "version": "2.3.1", "gitCommitSha": "abc123def456" },
      { "scope": "project", "installPath": "$install", "version": "2.3.1", "gitCommitSha": "abc123def456" }
    ]
  }
}
EOF

  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 6 "a plugin installed in two scopes must refuse as ambiguous"

  fm_skill_run "$config" demo-skills interviewing --scope project --field scope
  expect_code 0 "$RUN_RC" "an explicit scope should resolve (stderr: $RUN_ERR)"
  [ "$RUN_OUT" = "project" ] || fail "explicit scope resolved to '$RUN_OUT'"

  fm_skill_run "$config" demo-skills interviewing --scope nowhere
  assert_refusal 3 "an unmatched scope must refuse"
  pass "fm-skill-path.sh: refuses an ambiguous scope and accepts an explicit one"
}

test_tampered_install_refuses() {
  local config install
  config="$TMP_ROOT/tampered"
  install=$(fm_skill_install_path "$config")

  # The manifest names a different plugin than the registry key.
  fm_skill_fixture "$config" >/dev/null
  cat > "$install/.claude-plugin/plugin.json" <<'EOF'
{ "name": "someone-elses-plugin", "version": "2.3.1", "skills": ["./skills/productivity/interviewing"] }
EOF
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 6 "a manifest naming another plugin must refuse"

  # The manifest version disagrees with the registry version.
  fm_skill_fixture "$config" >/dev/null
  cat > "$install/.claude-plugin/plugin.json" <<'EOF'
{ "name": "demo-skills", "version": "9.9.9", "skills": ["./skills/productivity/interviewing"] }
EOF
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 6 "a manifest version disagreeing with the registry must refuse"

  # No manifest at all.
  fm_skill_fixture "$config" >/dev/null
  rm -f "$install/.claude-plugin/plugin.json"
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 6 "an install with no manifest must refuse"

  # The declared directory has no SKILL.md.
  fm_skill_fixture "$config" >/dev/null
  rm -f "$install/skills/productivity/interviewing/SKILL.md"
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 6 "a declared skill with no SKILL.md must refuse"

  # SKILL.md front matter names a different skill than the directory.
  fm_skill_fixture "$config" >/dev/null
  cat > "$install/skills/productivity/interviewing/SKILL.md" <<'EOF'
---
name: something-else
description: Swapped content under the expected directory name.
---
EOF
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 6 "SKILL.md declaring another skill name must refuse"

  # A traversing manifest entry must never escape the install root.
  fm_skill_fixture "$config" >/dev/null
  cat > "$install/.claude-plugin/plugin.json" <<'EOF'
{ "name": "demo-skills", "version": "2.3.1", "skills": ["./skills/../../../interviewing"] }
EOF
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 6 "a traversing manifest path must refuse"
  pass "fm-skill-path.sh: refuses a tampered or inconsistent install"
}

test_symlinked_skill_refuses() {
  local config install outside
  config="$TMP_ROOT/symlink"
  install=$(fm_skill_install_path "$config")
  outside="$TMP_ROOT/symlink-outside"
  mkdir -p "$outside"
  cat > "$outside/SKILL.md" <<'EOF'
---
name: interviewing
description: Attacker-controlled content outside the plugin.
---
EOF

  # The skill directory itself is a symlink out of the plugin tree.
  fm_skill_fixture "$config" >/dev/null
  rm -rf "$install/skills/productivity/interviewing"
  ln -s "$outside" "$install/skills/productivity/interviewing"
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 6 "a symlinked skill directory must refuse"

  # A symlink inside an otherwise real support tree.
  fm_skill_fixture "$config" >/dev/null
  ln -s "$outside/SKILL.md" "$install/skills/productivity/interviewing/EXTRA.md"
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 6 "a symlink inside the support tree must refuse"
  pass "fm-skill-path.sh: refuses symlinked skills and support trees"
}

# The resolver reads the plugin registry only. A stale user-level copy of the
# same skill under ~/.agents/skills must never satisfy a request, because those
# copies drift from the pinned plugin and can carry a different invocation
# posture than the version they appear to be.
test_stale_user_level_copy_is_never_used() {
  local home config out rc
  home="$TMP_ROOT/stale-home"
  config="$home/.claude"
  mkdir -p "$home/.agents/skills/interviewing"
  cat > "$home/.agents/skills/interviewing/SKILL.md" <<'EOF'
---
name: interviewing
description: A stale user-level copy from an older revision.
---
EOF
  mkdir -p "$config/plugins"
  cat > "$config/plugins/installed_plugins.json" <<'EOF'
{ "version": 1, "plugins": {} }
EOF

  out=$(HOME="$home" CLAUDE_CONFIG_DIR="$config" "$RESOLVER" demo-skills interviewing 2>/dev/null)
  rc=$?
  expect_code 3 "$rc" "a stale user-level copy must not satisfy an unregistered plugin"
  [ -z "$out" ] || fail "a stale user-level copy was resolved: $out"
  pass "fm-skill-path.sh: never falls back to a stale user-level skill copy"
}

test_expected_version_and_commit_pins() {
  local config
  config="$TMP_ROOT/pins"
  fm_skill_fixture "$config" >/dev/null

  fm_skill_run "$config" demo-skills interviewing \
    --expect-version 2.3.1 --expect-commit abc123def456 --field version
  expect_code 0 "$RUN_RC" "matching pins should resolve (stderr: $RUN_ERR)"
  [ "$RUN_OUT" = "2.3.1" ] || fail "matching pins resolved '$RUN_OUT'"

  fm_skill_run "$config" demo-skills interviewing --expect-version 9.9.9
  assert_refusal 6 "a version pin mismatch must refuse"

  fm_skill_run "$config" demo-skills interviewing --expect-commit deadbeef
  assert_refusal 6 "a source-pin mismatch must refuse"
  pass "fm-skill-path.sh: honors expected version and source-commit pins"
}

# Valid JSON of the wrong shape must still produce a clean refusal. Without this
# the resolver aborts mid-read on a jq type error, which is a confusing failure
# rather than an honest unsupported state, and it can leave partial output.
test_malformed_config_shapes_refuse_cleanly() {
  local config install
  config="$TMP_ROOT/malformed"
  install=$(fm_skill_install_path "$config")

  fm_skill_fixture "$config" >/dev/null
  cat > "$config/settings.json" <<'EOF'
{ "enabledPlugins": "not-an-object" }
EOF
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 4 "settings with a non-object enabledPlugins must refuse as not enabled"

  fm_skill_fixture "$config" >/dev/null
  cat > "$config/plugins/installed_plugins.json" <<'EOF'
{ "version": 1, "plugins": { "demo-skills@demo-market": { "scope": "user" } } }
EOF
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 3 "a registry entry that is not an array must refuse"

  # Both lookup paths must survive it: bare name walks the key set, while an
  # explicit marketplace indexes the map directly.
  fm_skill_fixture "$config" >/dev/null
  cat > "$config/plugins/installed_plugins.json" <<'EOF'
{ "version": 1, "plugins": [] }
EOF
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 3 "a registry whose plugins is not an object must refuse on a bare plugin name"
  fm_skill_run "$config" demo-skills@demo-market interviewing
  assert_refusal 3 "a registry whose plugins is not an object must refuse on an explicit marketplace"

  fm_skill_fixture "$config" >/dev/null
  cat > "$install/.claude-plugin/plugin.json" <<'EOF'
{ "name": "demo-skills", "version": "2.3.1", "skills": "./skills/productivity/interviewing" }
EOF
  fm_skill_run "$config" demo-skills interviewing
  assert_refusal 5 "a manifest whose skills is not an array must refuse"
  pass "fm-skill-path.sh: malformed configuration shapes refuse cleanly"
}

test_usage_errors() {
  local config out rc
  config="$TMP_ROOT/usage"
  fm_skill_fixture "$config" >/dev/null

  fm_skill_run "$config"
  assert_refusal 2 "no arguments must be a usage error"

  fm_skill_run "$config" demo-skills
  assert_refusal 2 "a missing skill name must be a usage error"

  fm_skill_run "$config" demo-skills interviewing --nope
  assert_refusal 2 "an unknown option must be a usage error"

  fm_skill_run "$config" demo-skills ../escape
  assert_refusal 2 "a skill name containing a path separator must be a usage error"

  fm_skill_run "$config" demo-skills interviewing --field bogus
  assert_refusal 2 "an unknown field must be a usage error"

  # A usage error stays a usage error whatever the environment does, so a typo
  # never hides behind whichever resolution failure would have come first.
  fm_skill_run "$TMP_ROOT/no-such-config" demo-skills interviewing --field bogus
  assert_refusal 2 "an unknown field must be a usage error even with no registry present"

  fm_skill_run "$config" demo-skills interviewing --list-files --field skill_dir
  assert_refusal 2 "combining --list-files with --field must be a usage error"

  out=$("$RESOLVER" --help 2>&1); rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "Usage:" "--help did not print the usage header"
  assert_contains "$out" "Exit status:" "--help did not print the exit-status contract"
  pass "fm-skill-path.sh: usage errors are exact and --help works"
}

test_resolves_declared_skill
test_resolved_paths_are_real_and_support_files_resolve
test_default_config_root_is_claude_home
test_custom_config_dir_with_spaces
test_missing_install_refuses
test_disabled_plugin_refuses
test_local_settings_decide_enablement
test_skill_not_in_this_version_refuses
test_ambiguous_marketplace_refuses
test_ambiguous_scope_refuses
test_tampered_install_refuses
test_symlinked_skill_refuses
test_stale_user_level_copy_is_never_used
test_expected_version_and_commit_pins
test_malformed_config_shapes_refuse_cleanly
test_usage_errors
