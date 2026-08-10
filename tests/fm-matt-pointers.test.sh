#!/usr/bin/env bash
# fm-matt-pointers.test.sh - behavior coverage for the pointer bridge that lets
# runtimes which do not read the Claude plugin cache reach the installed Matt
# Pocock skills without a copy existing anywhere.
#
# Every case runs against a fake plugin under a private CLAUDE_CONFIG_DIR, so the
# suite never depends on, and never touches, the real install.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOADER="$ROOT/bin/fm-matt-skill.sh"
POINTERS="$ROOT/bin/fm-matt-pointers.sh"
TMP_ROOT=$(fm_test_tmproot fm-matt-pointers)

REAL_VERSION=1.2.0
REAL_COMMIT=2ab958093e83e0ec752e6c1c5932da465bf23e0c

# --- fixture ----------------------------------------------------------------
#
# build_plugin <root> [version] [commit] [enabled] [manifest-name]
# Creates a Claude configuration root with one installed plugin carrying three
# skills, and echoes nothing. Callers export CLAUDE_CONFIG_DIR="<root>/config".

build_plugin() {
  local root=$1
  local version=${2:-$REAL_VERSION}
  local commit=${3:-$REAL_COMMIT}
  local enabled=${4:-true}
  local mname=${5:-mattpocock-skills}
  local install="$root/install"

  mkdir -p "$root/config/plugins" "$install/.claude-plugin"
  cat >"$root/config/plugins/installed_plugins.json" <<EOF
{
  "plugins": {
    "mattpocock-skills@claude-plugins-official": [
      {
        "scope": "user",
        "installPath": "$install",
        "version": "$version",
        "gitCommitSha": "$commit"
      }
    ]
  }
}
EOF
  cat >"$root/config/settings.json" <<EOF
{ "enabledPlugins": { "mattpocock-skills@claude-plugins-official": $enabled } }
EOF
  cat >"$install/.claude-plugin/plugin.json" <<EOF
{
  "name": "$mname",
  "version": "$version",
  "skills": [
    "./skills/engineering/tdd",
    "./skills/engineering/wayfinder",
    "./skills/productivity/grilling"
  ]
}
EOF

  write_skill "$install/skills/engineering/tdd" tdd \
    'Test-driven development. Use when the user wants to build features test-first.' ''
  write_skill "$install/skills/engineering/wayfinder" wayfinder \
    'Plan a huge chunk of work as a shared map of decision tickets.' 'true'
  write_skill "$install/skills/productivity/grilling" grilling \
    'Grill the user relentlessly about a plan, decision, or idea.' ''
}

# write_skill <dir> <name> <description> <disable-model-invocation>
write_skill() {
  local dir=$1 name=$2 desc=$3 dmi=$4
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'name: %s\n' "$name"
    printf 'description: %s\n' "$desc"
    [ -z "$dmi" ] || printf 'disable-model-invocation: %s\n' "$dmi"
    printf -- '---\n\n'
    printf '# %s\n\nUNIQUE-UPSTREAM-PROCEDURE-%s: do the real work here.\n' "$name" "$name"
  } >"$dir/SKILL.md"
  printf 'support detail for %s\n' "$name" >"$dir/reference.md"
}

# --- loader: resolution and honest refusal ----------------------------------

test_loader_prints_original_bytes_and_identity() {
  local root out
  root="$TMP_ROOT/loader-ok"
  build_plugin "$root"

  out=$(CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd) \
    || fail "loader refused a healthy install"

  assert_contains "$out" 'UNIQUE-UPSTREAM-PROCEDURE-tdd' \
    "loader did not print the original skill bytes"
  assert_contains "$out" 'author=Matt Pocock' "loader dropped author attribution"
  assert_contains "$out" 'license=MIT' "loader dropped the licence"
  assert_contains "$out" 'upstream=https://github.com/mattpocock/skills' \
    "loader dropped the upstream repository"
  assert_contains "$out" "resolved_version=$REAL_VERSION" "loader dropped the resolved version"
  assert_contains "$out" 'pin=validated' "loader did not report a matching pin as validated"
  assert_contains "$out" 'reference.md' "loader did not list the skill's support files"
  assert_not_contains "$out" 'PLUGIN CHANGED' \
    "loader warned about drift while resolving the validated pin"
  pass "loader prints the installed original with full attribution and identity"
}

test_loader_refuses_without_printing_anything() {
  local root out rc stdout
  root="$TMP_ROOT/loader-refuse"
  build_plugin "$root"

  # A refusal must never leave a caller with half a procedure on stdout, so each
  # case asserts both the exit code and that stdout stayed empty.
  refuses() {  # <label> <expected-code> <env-assignments...> -- <args...>
    local label=$1 want=$2
    shift 2
    stdout=$("$@" 2>/dev/null)
    rc=$?
    expect_code "$want" "$rc" "$label"
    [ -z "$stdout" ] || fail "$label printed on stdout during a refusal: $stdout"
  }

  mv "$root/install" "$root/install-moved"
  refuses "moved install" 3 env CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd
  mv "$root/install-moved" "$root/install"

  refuses "absent configuration" 3 env CLAUDE_CONFIG_DIR="$TMP_ROOT/nowhere" "$LOADER" tdd

  root="$TMP_ROOT/loader-disabled"
  build_plugin "$root" "$REAL_VERSION" "$REAL_COMMIT" false
  refuses "disabled plugin" 4 env CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd

  root="$TMP_ROOT/loader-undeclared"
  build_plugin "$root"
  refuses "undeclared skill" 5 env CLAUDE_CONFIG_DIR="$root/config" "$LOADER" not-a-skill

  root="$TMP_ROOT/loader-swapped"
  build_plugin "$root" "$REAL_VERSION" "$REAL_COMMIT" true some-other-plugin
  refuses "swapped manifest identity" 6 env CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd

  root="$TMP_ROOT/loader-symlink"
  build_plugin "$root"
  rm -rf "$root/install/skills/engineering/tdd"
  mkdir -p "$root/elsewhere/tdd"
  write_skill "$root/elsewhere/tdd" tdd 'x' ''
  ln -s "$root/elsewhere/tdd" "$root/install/skills/engineering/tdd"
  refuses "symlinked skill directory" 6 env CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd

  root="$TMP_ROOT/loader-renamed"
  build_plugin "$root"
  sed -i.bak 's/^name: tdd$/name: something-else/' "$root/install/skills/engineering/tdd/SKILL.md"
  rm -f "$root/install/skills/engineering/tdd/SKILL.md.bak"
  refuses "front matter naming a different skill" 6 env CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd

  pass "loader refuses every unsafe install state and prints nothing on stdout"
}

test_loader_reports_drift_without_hiding_the_original() {
  local root out rc
  root="$TMP_ROOT/loader-drift"
  build_plugin "$root" 9.9.9 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

  # An upstream bump must keep working, or every release becomes an outage and
  # the sync chore the pointer pattern removes comes straight back.
  out=$(CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd) \
    || fail "loader refused a newer plugin version by default"
  assert_contains "$out" 'PLUGIN CHANGED' "loader stayed silent about a changed plugin"
  assert_contains "$out" 'pin=changed' "loader reported a changed pin as validated"
  assert_contains "$out" 'UNIQUE-UPSTREAM-PROCEDURE-tdd' \
    "loader withheld the installed original while reporting drift"

  CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd --require-validated-pin >/dev/null 2>&1
  rc=$?
  expect_code 6 "$rc" "--require-validated-pin accepted a changed plugin"
  pass "version drift is reported loudly, and refused outright on request"
}

test_loader_delegates_to_the_shared_resolver_when_present() {
  local bin out
  bin="$TMP_ROOT/delegate/bin"
  mkdir -p "$bin"
  cp "$LOADER" "$bin/"
  # A stand-in for bin/fm-skill-path.sh: the delegation contract is that the
  # loader trusts the shared resolver's block and its refusals verbatim.
  cat >"$bin/fm-skill-path.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "${2:-}" = tdd ] || { printf 'fm-skill-path.sh: refused %s\n' "${2:-}" >&2; exit 5; }
printf 'skill_dir=%s\n' "$FM_TEST_SKILL_DIR"
printf 'skill_file=%s/SKILL.md\n' "$FM_TEST_SKILL_DIR"
EOF
  chmod +x "$bin/fm-skill-path.sh"

  local root
  root="$TMP_ROOT/delegate"
  build_plugin "$root"

  out=$(CLAUDE_CONFIG_DIR="$root/config" \
        FM_TEST_SKILL_DIR="$root/install/skills/engineering/tdd" \
        "$bin/fm-matt-skill.sh" tdd) \
    || fail "loader did not delegate successfully to the shared resolver"
  assert_contains "$out" 'resolved_by=bin/fm-skill-path.sh' \
    "loader did not record that the shared resolver resolved the skill"
  assert_contains "$out" 'UNIQUE-UPSTREAM-PROCEDURE-tdd' \
    "delegated resolution did not reach the original bytes"

  CLAUDE_CONFIG_DIR="$root/config" FM_TEST_SKILL_DIR="$root/install/skills/engineering/tdd" \
    "$bin/fm-matt-skill.sh" grilling >/dev/null 2>&1
  expect_code 5 $? "loader did not pass through the shared resolver's exit status"
  pass "the loader delegates to the shared resolver and inherits its refusals"
}

# There is no second resolver. Without bin/fm-skill-path.sh beside it the loader
# must refuse loudly and print nothing, never resolve a path of its own.
test_loader_refuses_without_the_shared_resolver() {
  local lone root out
  lone="$TMP_ROOT/lone/bin"
  mkdir -p "$lone"
  cp "$LOADER" "$lone/"

  root="$TMP_ROOT/lone"
  build_plugin "$root"

  out=$(CLAUDE_CONFIG_DIR="$root/config" "$lone/fm-matt-skill.sh" tdd 2>/dev/null)
  expect_code 127 $? "loader resolved a skill with no shared resolver installed"
  [ -z "$out" ] || fail "loader printed skill bytes without the shared resolver: $out"
  pass "the loader refuses when the shared resolver is not installed beside it"
}

# --- pointers ----------------------------------------------------------------

run_pointers() {  # <config-root> <args...>
  local config=$1
  shift
  CLAUDE_CONFIG_DIR="$config" "$POINTERS" "$@"
}

test_pointers_carry_attribution_and_no_procedure() {
  local root dest file
  root="$TMP_ROOT/gen"
  build_plugin "$root"
  dest="$root/skills"

  run_pointers "$root/config" --dest "$dest" --date 2026-07-30 >/dev/null \
    || fail "pointer install failed against a healthy plugin"

  file="$dest/matt-tdd/SKILL.md"
  assert_present "$file" "no pointer was written for a declared skill"
  assert_grep 'Matt Pocock' "$file" "pointer does not credit the author"
  assert_grep 'license: MIT' "$file" "pointer does not carry the licence"
  assert_grep 'https://github.com/mattpocock/skills' "$file" \
    "pointer does not name the upstream repository"
  assert_grep 'mattpocock-skills@claude-plugins-official' "$file" \
    "pointer does not name the plugin it resolves"
  assert_grep "validated-version: \"$REAL_VERSION\"" "$file" \
    "pointer does not record the validated version"

  # The whole design rests on this: a pointer must contain no part of the
  # procedure, so there is nothing that can drift from the original.
  assert_no_grep 'UNIQUE-UPSTREAM-PROCEDURE' "$file" \
    "pointer copied part of the upstream skill body"

  assert_grep 'firstmate-pointer: "true"' "$file" \
    "pointer is not identifiable as firstmate-owned"
  assert_grep 'generated: "2026-07-30"' "$file" "pointer is not dated"
  assert_present "$dest/matt-tdd/.firstmate-pointer" "pointer directory carries no marker"
  pass "each pointer credits the original, dates itself, and copies no procedure"
}

test_pointers_mirror_upstream_invocation_flags() {
  local root dest out
  root="$TMP_ROOT/flags"
  build_plugin "$root"
  dest="$root/skills"
  run_pointers "$root/config" --dest "$dest" --date 2026-07-30 >/dev/null

  # wayfinder is user-invoked upstream; a pointer must not quietly promote it to
  # something the model can start on its own.
  assert_grep 'disable-model-invocation: true' "$dest/matt-wayfinder/SKILL.md" \
    "pointer promoted a user-invoked skill to model invocation"
  assert_grep 'disable-model-invocation: false' "$dest/matt-tdd/SKILL.md" \
    "pointer blocked model invocation for a model-invocable skill"
  assert_grep 'user-invocable: true' "$dest/matt-wayfinder/SKILL.md" \
    "pointer is not reachable as a slash command"

  out=$(run_pointers "$root/config" --list)
  assert_contains "$out" 'matt-wayfinder	wayfinder	user-invoked-only' \
    "--list misreports a user-invoked skill"
  assert_contains "$out" 'matt-tdd	tdd	model-invocable' \
    "--list misreports a model-invocable skill"
  pass "pointers mirror each upstream skill's invocation policy"
}

test_pointer_instructs_a_hard_stop_on_failure() {
  local root dest file
  root="$TMP_ROOT/stop"
  build_plugin "$root"
  dest="$root/skills"
  run_pointers "$root/config" --dest "$dest" --date 2026-07-30 >/dev/null
  file="$dest/matt-tdd/SKILL.md"

  assert_grep 'Do not reconstruct, paraphrase, or improvise the procedure' "$file" \
    "pointer does not forbid improvising the procedure when the load fails"
  assert_grep 'Never report this skill as used' "$file" \
    "pointer does not forbid reporting an unloaded skill as used"
  assert_grep "$LOADER tdd" "$file" "pointer does not name the exact load command"
  pass "a pointer whose load fails instructs a hard stop, not a fallback"
}

test_check_detects_drift_absence_and_a_dead_loader() {
  local root dest out
  root="$TMP_ROOT/check"
  build_plugin "$root"
  dest="$root/skills"
  run_pointers "$root/config" --dest "$dest" --date 2026-07-30 >/dev/null

  run_pointers "$root/config" --check --dest "$dest" >/dev/null 2>&1
  expect_code 0 $? "--check reported drift on a freshly installed set"

  printf 'edited\n' >>"$dest/matt-tdd/SKILL.md"
  out=$(run_pointers "$root/config" --check --dest "$dest" 2>&1)
  expect_code 1 $? "--check passed an edited pointer"
  assert_contains "$out" 'DRIFTED' "--check did not name the drifted pointer"

  rm -rf "$dest/matt-grilling"
  out=$(run_pointers "$root/config" --check --dest "$dest" 2>&1)
  assert_contains "$out" 'MISSING' "--check did not report a missing pointer"

  # A pointer whose loader has gone is inert, so an audit has to say so.
  root="$TMP_ROOT/check-loader"
  build_plugin "$root"
  dest="$root/skills"
  run_pointers "$root/config" --dest "$dest" --date 2026-07-30 \
    --loader "$TMP_ROOT/gone/fm-matt-skill.sh" >/dev/null
  out=$(run_pointers "$root/config" --check --dest "$dest" 2>&1)
  expect_code 1 $? "--check passed pointers naming a loader that does not exist"
  assert_contains "$out" 'BROKEN' "--check did not report an unusable loader"
  pass "--check catches edited, missing, and inert pointers"
}

test_foreign_directories_are_never_written_or_removed() {
  local root dest out
  root="$TMP_ROOT/foreign"
  build_plugin "$root"
  dest="$root/skills"
  mkdir -p "$dest/matt-tdd"
  printf 'hand written, not a pointer\n' >"$dest/matt-tdd/SKILL.md"

  out=$(run_pointers "$root/config" --dest "$dest" --date 2026-07-30 2>&1)
  expect_code 1 $? "install did not report the blocked foreign directory"
  assert_contains "$out" 'FOREIGN' "install did not name the foreign directory"
  assert_grep 'hand written, not a pointer' "$dest/matt-tdd/SKILL.md" \
    "install overwrote a directory it did not generate"
  assert_present "$dest/matt-wayfinder/SKILL.md" \
    "one foreign directory stopped the other pointers from installing"

  run_pointers "$root/config" --uninstall --dest "$dest" >/dev/null
  assert_grep 'hand written, not a pointer' "$dest/matt-tdd/SKILL.md" \
    "uninstall removed a directory it did not generate"
  assert_absent "$dest/matt-wayfinder" "uninstall left a generated pointer behind"
  pass "unmarked directories survive install and uninstall untouched"
}

test_retired_skills_are_pruned_and_reinstalls_are_idempotent() {
  local root dest out
  root="$TMP_ROOT/prune"
  build_plugin "$root"
  dest="$root/skills"
  run_pointers "$root/config" --dest "$dest" --date 2026-07-30 >/dev/null

  out=$(run_pointers "$root/config" --dest "$dest" --date 2026-07-30)
  assert_contains "$out" '0 written' "a repeat install rewrote unchanged pointers"

  # Upstream drops a skill: its pointer must not linger and keep advertising a
  # workflow that can no longer be loaded.
  local manifest
  manifest="$root/install/.claude-plugin/plugin.json"
  jq '.skills |= map(select(. != "./skills/productivity/grilling"))' "$manifest" >"$manifest.new"
  mv "$manifest.new" "$manifest"

  run_pointers "$root/config" --prune --dest "$dest" >/dev/null
  assert_absent "$dest/matt-grilling" "prune left a pointer to a retired skill"
  assert_present "$dest/matt-tdd/SKILL.md" "prune removed a still-declared pointer"
  pass "retired pointers are pruned and repeat installs change nothing"
}

test_loader_prints_original_bytes_and_identity
test_loader_refuses_without_printing_anything
test_loader_reports_drift_without_hiding_the_original
test_loader_delegates_to_the_shared_resolver_when_present
test_loader_refuses_without_the_shared_resolver
test_pointers_carry_attribution_and_no_procedure
test_pointers_mirror_upstream_invocation_flags
test_pointer_instructs_a_hard_stop_on_failure
test_check_detects_drift_absence_and_a_dead_loader
test_foreign_directories_are_never_written_or_removed
test_retired_skills_are_pruned_and_reinstalls_are_idempotent
