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

REAL_VERSION=1.3.1
REAL_COMMIT=49dd158d1076134a641b33efb035946536778336
MARKET=mattpocock
KEY="mattpocock-skills@$MARKET"
# The identity a pointer generated from the default fixture passes to the loader.
PINS=(--validated-plugin "$KEY" --validated-version "$REAL_VERSION" --validated-commit "$REAL_COMMIT")

# --- fixture ----------------------------------------------------------------
#
# build_plugin <root> [version] [commit] [enabled] [manifest-name]
# Creates a Claude configuration root with one installed plugin from marketplace
# $MARKET, and echoes nothing. Its manifest declares three skills; its source
# tree also carries an in-progress skill outside the declared set, the shape of
# upstream's non-promoted buckets, and a deprecated one that must never be
# offered. Callers export CLAUDE_CONFIG_DIR="<root>/config".

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
    "$KEY": [
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
{ "enabledPlugins": { "$KEY": $enabled } }
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
  write_skill "$install/skills/in-progress/loop-me" loop-me \
    'Grill me about specs for the workflows I want to build.' 'true'
  write_skill "$install/skills/deprecated/old-way" old-way \
    'A retired skill upstream no longer uses.' ''
}

# pointer_command <pointer-file>: the Step 1 command block, exactly as written.
pointer_command() {
  awk '/^```bash$/ { inside = 1; next } /^```$/ { inside = 0 } inside' "$1"
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

  out=$(CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd "${PINS[@]}") \
    || fail "loader refused a healthy install"

  assert_contains "$out" 'UNIQUE-UPSTREAM-PROCEDURE-tdd' \
    "loader did not print the original skill bytes"
  assert_contains "$out" 'author=Matt Pocock' "loader dropped author attribution"
  assert_contains "$out" 'license=MIT' "loader dropped the licence"
  assert_contains "$out" 'upstream=https://github.com/mattpocock/skills' \
    "loader dropped the upstream repository"
  assert_contains "$out" "plugin=$KEY" "loader did not name the plugin it resolved"
  assert_contains "$out" "resolved_version=$REAL_VERSION" "loader dropped the resolved version"
  assert_contains "$out" 'pin=validated' "loader did not report a matching pin as validated"
  assert_contains "$out" 'reference.md' "loader did not list the skill's support files"
  assert_not_contains "$out" 'PLUGIN CHANGED' \
    "loader warned about drift while resolving the validated pin"

  # With no validated identity to compare, there is nothing to call drift.
  out=$(CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd --check) \
    || fail "loader refused a healthy install without a validated identity"
  assert_contains "$out" 'pin=unpinned' "loader invented a pin nobody passed"
  assert_not_contains "$out" 'PLUGIN CHANGED' "loader reported drift with no validated identity"
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
  refuses "unknown skill" 5 env CLAUDE_CONFIG_DIR="$root/config" "$LOADER" not-a-skill
  refuses "deprecated skill" 5 env CLAUDE_CONFIG_DIR="$root/config" "$LOADER" old-way

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
  root="$TMP_ROOT/loader-version-drift"
  build_plugin "$root" 9.9.9 "$REAL_COMMIT"

  # An upstream bump must keep working, or every release becomes an outage and
  # the sync chore the pointer pattern removes comes straight back.
  out=$(CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd "${PINS[@]}") \
    || fail "loader refused a newer plugin version by default"
  assert_contains "$out" 'PLUGIN CHANGED' "loader stayed silent about a changed plugin"
  assert_contains "$out" 'pin=changed' "loader reported a changed pin as validated"
  assert_contains "$out" 'UNIQUE-UPSTREAM-PROCEDURE-tdd' \
    "loader withheld the installed original while reporting drift"

  CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd "${PINS[@]}" --require-validated-pin \
    >/dev/null 2>&1
  rc=$?
  expect_code 6 "$rc" "--require-validated-pin accepted a changed plugin"
  pass "version drift is reported loudly, and refused outright on request"
}

test_loader_reports_commit_drift_without_hiding_the_original() {
  local root out rc
  root="$TMP_ROOT/loader-commit-drift"
  build_plugin "$root" "$REAL_VERSION" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

  out=$(CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd "${PINS[@]}") \
    || fail "loader refused an install with a changed source commit"
  assert_contains "$out" 'PLUGIN CHANGED' \
    "loader stayed silent about a changed source commit"
  assert_contains "$out" 'pin=changed' \
    "loader reported a changed source commit as validated"
  assert_contains "$out" 'UNIQUE-UPSTREAM-PROCEDURE-tdd' \
    "loader withheld the installed original during commit drift"

  CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd "${PINS[@]}" --require-validated-pin \
    >/dev/null 2>&1
  rc=$?
  expect_code 6 "$rc" "--require-validated-pin accepted a changed source commit"

  # Strict mode with nothing to compare against is a usage error, not a pass.
  CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd --require-validated-pin >/dev/null 2>&1
  expect_code 2 $? "--require-validated-pin without a validated identity was accepted"
  pass "commit drift is reported loudly, and refused outright on request"
}

# add_install <root> <marketplace> <version> <commit>: register a second install
# of the plugin from another marketplace, carrying the same skills.
add_install() {
  local root=$1 market=$2 version=$3 commit=$4 other registry
  other="$root/install-$market"
  mkdir -p "$other"
  cp -R "$root/install/." "$other/"
  jq --arg v "$version" '.version = $v' "$other/.claude-plugin/plugin.json" \
    >"$other/plugin.json.new"
  mv "$other/plugin.json.new" "$other/.claude-plugin/plugin.json"
  printf '\nUNIQUE-%s-INSTALL\n' "$market" >>"$other/skills/engineering/tdd/SKILL.md"
  registry="$root/config/plugins/installed_plugins.json"
  jq --arg k "mattpocock-skills@$market" --arg p "$other" --arg v "$version" --arg c "$commit" \
    '.plugins[$k] = [{ scope: "user", installPath: $p, version: $v, gitCommitSha: $c }]' \
    "$registry" >"$registry.new"
  mv "$registry.new" "$registry"
}

# set_enabled <root> <marketplace>=<true|false>...
set_enabled() {
  local root=$1 pair settings
  shift
  settings="$root/config/settings.json"
  for pair in "$@"; do
    jq --arg k "mattpocock-skills@${pair%%=*}" --argjson v "${pair#*=}" \
      '.enabledPlugins[$k] = $v' "$settings" >"$settings.new"
    mv "$settings.new" "$settings"
  done
}

# The suite moved marketplaces once already: the old install stays registered
# but disabled, and the loader has to follow the enabled one, wherever it is.
test_loader_follows_the_one_enabled_marketplace() {
  local root out
  root="$TMP_ROOT/loader-market"
  build_plugin "$root"
  add_install "$root" claude-plugins-official 1.2.3 2ab958093e83e0ec752e6c1c5932da465bf23e0c
  set_enabled "$root" claude-plugins-official=false

  out=$(CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd) \
    || fail "loader refused while exactly one marketplace was enabled"
  assert_contains "$out" "plugin=$KEY" "loader did not follow the enabled marketplace"
  assert_contains "$out" "resolved_version=$REAL_VERSION" "loader read the disabled install's version"
  assert_not_contains "$out" 'UNIQUE-claude-plugins-official-INSTALL' \
    "loader printed bytes from the disabled install"

  set_enabled "$root" claude-plugins-official=true "$MARKET=false"
  out=$(CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd) \
    || fail "loader refused after the enabled marketplace switched"
  assert_contains "$out" 'plugin=mattpocock-skills@claude-plugins-official' \
    "loader kept a marketplace that is now disabled"
  assert_contains "$out" 'UNIQUE-claude-plugins-official-INSTALL' \
    "loader did not print the newly enabled install's bytes"

  set_enabled "$root" claude-plugins-official=false "$MARKET=false"
  out=$(CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd 2>"$root/err")
  expect_code 4 $? "loader resolved while no marketplace was enabled"
  [ -z "$out" ] || fail "loader printed on stdout with no marketplace enabled: $out"
  assert_grep 'none of them is enabled' "$root/err" "the refusal did not say why"

  set_enabled "$root" claude-plugins-official=true "$MARKET=true"
  out=$(CLAUDE_CONFIG_DIR="$root/config" "$LOADER" tdd 2>"$root/err")
  expect_code 6 $? "loader picked one of two enabled marketplaces"
  [ -z "$out" ] || fail "loader printed on stdout with two marketplaces enabled: $out"
  assert_grep 'ambiguous' "$root/err" "the refusal did not name the ambiguity"
  pass "the loader follows the one enabled marketplace and refuses none or several"
}

# Captain's ask: every upstream skill, not only the declared set. Skills upstream
# keeps outside the manifest load like any other.
test_loader_offers_every_live_upstream_skill() {
  local root out
  root="$TMP_ROOT/loader-undeclared-offer"
  build_plugin "$root"
  write_skill "$root/install/skills/misc/setup-pre-commit" setup-pre-commit \
    'Set up pre-commit hooks.' ''

  out=$(CLAUDE_CONFIG_DIR="$root/config" "$LOADER" --list) || fail "--list refused a healthy install"
  [ "$out" = "$(printf 'grilling\nloop-me\nsetup-pre-commit\ntdd\nwayfinder')" ] \
    || fail "--list did not offer exactly the declared and non-deprecated skills: $out"

  out=$(CLAUDE_CONFIG_DIR="$root/config" "$LOADER" loop-me) \
    || fail "loader refused an in-progress skill"
  assert_contains "$out" 'UNIQUE-UPSTREAM-PROCEDURE-loop-me' \
    "loader did not print the in-progress skill's original bytes"
  pass "the loader offers every non-deprecated upstream skill"
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
printf 'plugin=mattpocock-skills\n'
printf 'marketplace=stub-market\n'
printf 'scope=user\n'
printf 'version=7.7.7\n'
printf 'commit=stubcommit\n'
printf 'skill=tdd\n'
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
  assert_contains "$out" 'plugin=mattpocock-skills@stub-market' \
    "loader did not take the plugin identity from the shared resolver"
  assert_contains "$out" 'resolved_version=7.7.7' \
    "loader did not take the version from the shared resolver"
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
  assert_grep "upstream-plugin: \"$KEY\"" "$file" \
    "pointer does not name the plugin it resolves"
  assert_no_grep 'claude-plugins-official' "$file" \
    "pointer names a marketplace that is not the enabled one"
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
  rm -rf "$root/install/skills/productivity/grilling"

  run_pointers "$root/config" --prune --dest "$dest" >/dev/null
  assert_absent "$dest/matt-grilling" "prune left a pointer to a retired skill"
  assert_present "$dest/matt-tdd/SKILL.md" "prune removed a still-declared pointer"
  pass "retired pointers are pruned and repeat installs change nothing"
}

# A skill upstream still ships but that stops resolving is not retired: --prune
# keeps its pointer and says why, and --check reports it as unresolved.
test_prune_keeps_pointers_of_unresolved_skills() {
  local root dest out rc
  root="$TMP_ROOT/prune-unresolved"
  build_plugin "$root"
  dest="$root/skills"
  run_pointers "$root/config" --dest "$dest" --date 2026-07-30 >/dev/null \
    || fail "pointer install failed against a healthy plugin"

  sed 's/^name: loop-me$/name: loop-you/' "$root/install/skills/in-progress/loop-me/SKILL.md" \
    >"$root/loop-me.md"
  mv "$root/loop-me.md" "$root/install/skills/in-progress/loop-me/SKILL.md"
  jq '.skills -= ["./skills/productivity/grilling"]' "$root/install/.claude-plugin/plugin.json" \
    >"$root/plugin.json"
  mv "$root/plugin.json" "$root/install/.claude-plugin/plugin.json"
  rm -rf "$root/install/skills/productivity/grilling"

  out=$(run_pointers "$root/config" --check --dest "$dest" 2>&1)
  rc=$?
  expect_code 1 "$rc" "--check passed with an offered skill that does not resolve"
  assert_contains "$out" "UNRESOLVED: $dest/matt-loop-me" "--check did not report the unresolved pointer"
  assert_not_contains "$out" "RETIRED: $dest/matt-loop-me" "--check called an unresolved skill retired"
  assert_contains "$out" "RETIRED: $dest/matt-grilling" "--check did not report the retired pointer"

  out=$(run_pointers "$root/config" --prune --dest "$dest" 2>&1)
  rc=$?
  expect_code 1 "$rc" "--prune passed while keeping a pointer whose skill does not resolve"
  assert_present "$dest/matt-loop-me/SKILL.md" "prune deleted the pointer of a skill that still ships"
  assert_contains "$out" "UNRESOLVED: kept $dest/matt-loop-me" "prune did not name the kept pointer"
  assert_absent "$dest/matt-grilling" "prune left a pointer to a retired skill"
  assert_present "$dest/matt-tdd/SKILL.md" "prune removed a pointer whose skill resolves"
  pass "--prune keeps, and --check flags, pointers of offered skills that do not resolve"
}

# Symlinked entry files still identify offered skills, even if their targets
# disappear; they must be unresolved, not silently omitted or pruned as retired.
test_symlinked_undeclared_skill_stays_unresolved() {
  local root dest out kind
  for kind in linked dangling; do
    root="$TMP_ROOT/symlinked-entry-$kind"
    build_plugin "$root"
    dest="$root/skills"
    run_pointers "$root/config" --dest "$dest" --date 2026-07-30 >/dev/null \
      || fail "pointer install failed against a healthy plugin"

    mv "$root/install/skills/in-progress/loop-me/SKILL.md" "$root/loop-me.md"
    ln -s "$root/loop-me.md" "$root/install/skills/in-progress/loop-me/SKILL.md"
    [ "$kind" != dangling ] || rm "$root/loop-me.md"

    out=$(run_pointers "$root/config" --check --dest "$dest" 2>&1)
    expect_code 1 $? "--check passed with a $kind symlinked undeclared SKILL.md"
    assert_contains "$out" "UNRESOLVED: $dest/matt-loop-me" \
      "--check did not flag the $kind symlinked skill's pointer"
    assert_not_contains "$out" "RETIRED: $dest/matt-loop-me" \
      "--check called a $kind symlinked skill retired"
    assert_not_contains "$out" 'ok - ' "--check reported an incomplete set as healthy"

    out=$(CLAUDE_CONFIG_DIR="$root/config" "$LOADER" loop-me --check 2>"$root/err")
    expect_code 6 $? "loader did not reject the $kind symlink as an integrity failure"
    [ -z "$out" ] || fail "loader printed output for a symlinked skill"
    assert_grep 'symlink' "$root/err" "loader did not diagnose the symlink"

    out=$(CLAUDE_CONFIG_DIR="$root/config" "$LOADER" --list 2>"$root/err")
    expect_code 7 $? "--list silently omitted a $kind symlinked undeclared SKILL.md"
    [ "$out" = "$(printf 'grilling\ntdd\nwayfinder')" ] \
      || fail "--list did not retain exactly the resolvable skills: $out"
    assert_grep 'leaves out loop-me' "$root/err" "--list did not name the unresolved skill"

    out=$(run_pointers "$root/config" --dest "$root/fresh-skills" --date 2026-07-30 2>&1)
    expect_code 1 $? "install passed with a $kind symlinked undeclared SKILL.md"
    assert_contains "$out" 'UNRESOLVED: upstream skill loop-me is offered' \
      "install did not name the unresolved upstream skill"
    assert_absent "$root/fresh-skills/matt-loop-me" "install generated an unsafe pointer"
    assert_present "$root/fresh-skills/matt-tdd/SKILL.md" "install omitted a healthy skill"

    out=$(run_pointers "$root/config" --check --dest "$root/fresh-skills" 2>&1)
    expect_code 1 $? "--check passed a fresh incomplete pointer set"
    assert_contains "$out" 'UNRESOLVED: upstream skill loop-me is offered' \
      "fresh audit did not name the unresolved upstream skill"
    assert_not_contains "$out" 'ok - ' "fresh audit reported an incomplete set as healthy"

    cp "$dest/matt-loop-me/SKILL.md" "$root/pointer-before.md"
    out=$(run_pointers "$root/config" --prune --dest "$dest" 2>&1)
    expect_code 1 $? "--prune passed with a $kind symlinked undeclared SKILL.md"
    assert_contains "$out" "UNRESOLVED: kept $dest/matt-loop-me" \
      "prune did not name the unresolved pointer it kept"
    assert_present "$dest/matt-loop-me/.firstmate-pointer" "prune removed the pointer marker"
    cmp -s "$root/pointer-before.md" "$dest/matt-loop-me/SKILL.md" \
      || fail "prune removed or changed the unresolved pointer"
  done
  pass "symlinked undeclared entry files are unresolved and their pointers survive pruning"
}

# --- the bridge must be internally coherent ---------------------------------
#
# The outage these guard: every installed pointer named bin/fm-matt-skill.sh as
# its Step 1 while the repo shipped no such file. Each pointer's own contract
# then told the worker to stop rather than improvise, so a dependent review
# parked. Every case above still passed, because each one built the loader path
# from $ROOT and so assumed the very file that was missing. These two close that
# gap from the other direction: from a generated pointer inward.

test_generated_pointer_loads_through_the_shipped_loader() {
  local root dest recorded upstream out
  root="$TMP_ROOT/coherent"
  build_plugin "$root"
  dest="$root/skills"

  # Deliberately no --loader: this is the path a real install bakes in, and the
  # one every pointer on disk will invoke.
  run_pointers "$root/config" --dest "$dest" --date 2026-07-30 >/dev/null \
    || fail "pointer install failed with the default loader"

  recorded=$(sed -n 's/^loader=//p' "$dest/matt-tdd/.firstmate-pointer" | head -n 1)
  upstream=$(sed -n 's/^upstream_skill=//p' "$dest/matt-tdd/.firstmate-pointer" | head -n 1)
  [ -n "$recorded" ] || fail "generated pointer records no loader to invoke"
  [ -x "$recorded" ] \
    || fail "generated pointer names a loader this repo does not ship: $recorded"

  # The agent reads SKILL.md, not the marker, so the Step 1 command it will copy
  # has to name that same executable.
  assert_grep "$recorded $upstream" "$dest/matt-tdd/SKILL.md" \
    "pointer body does not name the loader recorded in its marker"

  # Run the pointer's Step 1 exactly as written and require original bytes.
  out=$(CLAUDE_CONFIG_DIR="$root/config" "$recorded" "$upstream") \
    || fail "the pointer's own Step 1 command failed against a healthy install"
  assert_contains "$out" 'FIRSTMATE POINTER: ORIGINAL SKILL LOADED' \
    "the pointer's Step 1 printed no identity header"
  assert_contains "$out" "UNIQUE-UPSTREAM-PROCEDURE-$upstream" \
    "the pointer's Step 1 did not reach the installed original bytes"
  pass "a generated pointer's Step 1 runs against the loader this repo ships"
}

# An audit has to diagnose the live failure: pointers generated while the loader
# existed, then left behind when that checkout no longer carries it. --check
# must read each pointer's RECORDED loader rather than its own, or it would
# report the set healthy from a checkout that still has one.
test_check_reports_a_recorded_loader_that_later_vanished() {
  local root dest mirror out
  root="$TMP_ROOT/vanished"
  build_plugin "$root"
  dest="$root/skills"

  mkdir -p "$root/mirror/bin"
  # The generator records the loader beside it as an absolute resolved path, so
  # the expectation has to be resolved too: on macOS $TMPDIR reaches the same
  # directory through a symlink and an unresolved path would never match.
  mirror=$(CDPATH='' cd -- "$root/mirror/bin" && pwd -P)
  cp "$LOADER" "$POINTERS" "$ROOT/bin/fm-skill-path.sh" "$mirror/"

  CLAUDE_CONFIG_DIR="$root/config" "$mirror/fm-matt-pointers.sh" \
    --dest "$dest" --date 2026-07-30 >/dev/null \
    || fail "pointer install from the mirrored checkout failed"
  assert_grep "$mirror/fm-matt-skill.sh" "$dest/matt-tdd/.firstmate-pointer" \
    "pointer did not record the loader that generated it"

  # That checkout loses its loader, exactly as the shipped tree had.
  rm -f "$mirror/fm-matt-skill.sh"

  out=$(run_pointers "$root/config" --check --dest "$dest" 2>&1)
  expect_code 1 $? "--check passed pointers whose recorded loader had vanished"
  assert_contains "$out" 'BROKEN' "--check did not report the vanished loader"
  assert_contains "$out" "$mirror/fm-matt-skill.sh" \
    "--check audited its own loader instead of the one each pointer records"
  pass "--check names pointers whose recorded loader no longer exists"
}

test_check_reports_retired_pointers_and_their_recorded_loaders() {
  local root dest mirror manifest retired_loader out
  root="$TMP_ROOT/retired-check"
  build_plugin "$root"
  dest="$root/skills"

  mkdir -p "$root/mirror/bin"
  mirror=$(CDPATH='' cd -- "$root/mirror/bin" && pwd -P)
  cp "$LOADER" "$POINTERS" "$ROOT/bin/fm-skill-path.sh" "$mirror/"

  CLAUDE_CONFIG_DIR="$root/config" "$mirror/fm-matt-pointers.sh" \
    --dest "$dest" --date 2026-07-30 >/dev/null \
    || fail "pointer install from the mirrored checkout failed"

  manifest="$root/install/.claude-plugin/plugin.json"
  jq '.skills |= map(select(. != "./skills/productivity/grilling"))' "$manifest" \
    >"$manifest.new"
  mv "$manifest.new" "$manifest"
  rm -rf "$root/install/skills/productivity/grilling"

  retired_loader="$root/retired-loader.sh"
  cp "$mirror/fm-matt-skill.sh" "$retired_loader"
  sed "s|^loader=.*|loader=$retired_loader|" \
    "$dest/matt-grilling/.firstmate-pointer" \
    >"$dest/matt-grilling/.firstmate-pointer.new"
  mv "$dest/matt-grilling/.firstmate-pointer.new" \
    "$dest/matt-grilling/.firstmate-pointer"

  out=$(run_pointers "$root/config" --check --dest "$dest" 2>&1)
  expect_code 1 $? "--check passed a retired pointer"
  assert_contains "$out" 'RETIRED' "--check did not identify the retired pointer"
  assert_contains "$out" 'matt-grilling' "--check did not name the retired pointer"
  assert_not_contains "$out" 'BROKEN' \
    "--check reported a healthy retired pointer as broken"
  assert_not_contains "$out" 'matt-tdd' \
    "--check reported a declared pointer while only the retired pointer drifted"
  assert_not_contains "$out" 'matt-wayfinder' \
    "--check reported a declared pointer while only the retired pointer drifted"

  chmod -x "$retired_loader"
  out=$(run_pointers "$root/config" --check --dest "$dest" 2>&1)
  expect_code 1 $? "--check passed a retired pointer with a dead loader"
  assert_contains "$out" 'RETIRED' "--check hid the retired pointer with a dead loader"
  assert_contains "$out" "BROKEN: $dest/matt-grilling/SKILL.md" \
    "--check did not identify the retired pointer with a dead loader"
  assert_contains "$out" "$retired_loader" \
    "--check did not name the retired pointer's recorded loader"
  assert_not_contains "$out" 'matt-tdd' \
    "--check reported a declared pointer while only the retired loader was dead"
  assert_not_contains "$out" 'matt-wayfinder' \
    "--check reported a declared pointer while only the retired loader was dead"
  pass "--check audits retired pointers and their recorded loaders"
}

test_check_audits_all_retired_pointers_without_an_identity_skill() {
  local root dest mirror manifest retired_loader out
  root="$TMP_ROOT/all-retired-check"
  build_plugin "$root"
  dest="$root/skills"

  mkdir -p "$root/mirror/bin"
  mirror=$(CDPATH='' cd -- "$root/mirror/bin" && pwd -P)
  cp "$LOADER" "$POINTERS" "$ROOT/bin/fm-skill-path.sh" "$mirror/"

  CLAUDE_CONFIG_DIR="$root/config" "$mirror/fm-matt-pointers.sh" \
    --dest "$dest" --date 2026-07-30 >/dev/null \
    || fail "pointer install from the mirrored checkout failed"

  retired_loader="$root/all-retired-loader.sh"
  cp "$mirror/fm-matt-skill.sh" "$retired_loader"
  sed "s|^loader=.*|loader=$retired_loader|" \
    "$dest/matt-tdd/.firstmate-pointer" \
    >"$dest/matt-tdd/.firstmate-pointer.new"
  mv "$dest/matt-tdd/.firstmate-pointer.new" \
    "$dest/matt-tdd/.firstmate-pointer"
  chmod -x "$retired_loader"

  manifest="$root/install/.claude-plugin/plugin.json"
  jq '.skills = []' "$manifest" >"$manifest.new"
  mv "$manifest.new" "$manifest"
  rm -rf "$root/install/skills"
  mkdir -p "$dest/foreign-skill"
  printf 'foreign skill remains untouched\n' >"$dest/foreign-skill/SKILL.md"

  out=$(run_pointers "$root/config" --check --dest "$dest" 2>&1)
  expect_code 1 $? "--check did not report an all-retired pointer set as drift"
  assert_contains "$out" "RETIRED: $dest/matt-tdd" \
    "--check did not report the retired tdd pointer"
  assert_contains "$out" "RETIRED: $dest/matt-wayfinder" \
    "--check did not report the retired wayfinder pointer"
  assert_contains "$out" "RETIRED: $dest/matt-grilling" \
    "--check did not report the retired grilling pointer"
  assert_contains "$out" "RETIRED: $dest/matt-loop-me" \
    "--check did not report the retired undeclared pointer"
  assert_contains "$out" "BROKEN: $dest/matt-tdd/SKILL.md" \
    "--check did not report the dead all-retired loader"
  assert_contains "$out" "$retired_loader" \
    "--check did not name the dead all-retired loader"
  assert_not_contains "$out" "BROKEN: $dest/matt-wayfinder/SKILL.md" \
    "--check reported an executable all-retired loader as broken"
  assert_not_contains "$out" "BROKEN: $dest/matt-grilling/SKILL.md" \
    "--check reported an executable all-retired loader as broken"
  assert_not_contains "$out" "$dest/foreign-skill" \
    "--check reported an unmarked foreign directory as a pointer"
  assert_grep 'foreign skill remains untouched' "$dest/foreign-skill/SKILL.md" \
    "--check changed an unmarked foreign directory"
  pass "--check audits all retired pointers without an identity skill"
}

test_check_reports_combined_pointer_faults_once_each() {
  local root dest drift_loader missing_loader out
  root="$TMP_ROOT/combined-check"
  build_plugin "$root"
  dest="$root/skills"
  run_pointers "$root/config" --dest "$dest" --date 2026-07-30 >/dev/null

  drift_loader="$root/drift-loader.sh"
  missing_loader="$root/missing-loader.sh"
  cp "$LOADER" "$drift_loader"
  cp "$LOADER" "$missing_loader"
  sed "s|^loader=.*|loader=$drift_loader|" \
    "$dest/matt-tdd/.firstmate-pointer" \
    >"$dest/matt-tdd/.firstmate-pointer.new"
  mv "$dest/matt-tdd/.firstmate-pointer.new" \
    "$dest/matt-tdd/.firstmate-pointer"
  sed "s|^loader=.*|loader=$missing_loader|" \
    "$dest/matt-wayfinder/.firstmate-pointer" \
    >"$dest/matt-wayfinder/.firstmate-pointer.new"
  mv "$dest/matt-wayfinder/.firstmate-pointer.new" \
    "$dest/matt-wayfinder/.firstmate-pointer"
  chmod -x "$drift_loader" "$missing_loader"
  printf 'drifted content\n' >>"$dest/matt-tdd/SKILL.md"
  rm -f "$dest/matt-wayfinder/SKILL.md"

  out=$(run_pointers "$root/config" --check --dest "$dest" 2>&1)
  expect_code 1 $? "--check passed pointers with combined faults"
  assert_contains "$out" "DRIFTED: $dest/matt-tdd/SKILL.md" \
    "--check did not report the drifted pointer"
  assert_contains "$out" "BROKEN: $dest/matt-tdd/SKILL.md" \
    "--check did not report the drifted pointer's dead loader"
  assert_contains "$out" "$drift_loader" \
    "--check did not name the drifted pointer's recorded loader"
  assert_contains "$out" "MISSING: $dest/matt-wayfinder/SKILL.md" \
    "--check did not report the missing pointer body"
  assert_contains "$out" "BROKEN: $dest/matt-wayfinder/SKILL.md" \
    "--check did not report the missing pointer body's dead loader"
  assert_contains "$out" "$missing_loader" \
    "--check did not name the missing pointer's recorded loader"
  assert_contains "$out" 'drift=2 foreign=0' \
    "--check counted combined diagnostics instead of unhealthy pointers"
  assert_not_contains "$out" 'matt-grilling' \
    "--check reported a pointer whose loader remained executable"
  pass "--check reports combined pointer faults without double-counting"
}

# Every skill upstream offers gets a pointer, including the ones outside the
# declared set, without changing its invocation. An uncurated bucket skill that
# would not resolve is left out instead of aborting the run partway, and both
# install and --check fail naming it rather than passing an incomplete set.
test_pointers_cover_undeclared_skills() {
  local root dest out err rc
  root="$TMP_ROOT/undeclared-pointers"
  build_plugin "$root"
  write_skill "$root/install/skills/misc/setup-pre-commit" setup-pre-commit \
    'Set up pre-commit hooks.' ''
  write_skill "$root/install/skills/in-progress/writing-beats" beats \
    'Front matter names another skill.' ''
  write_skill "$root/install/skills/in-progress/drafting" drafting 'One copy.' ''
  write_skill "$root/install/skills/misc/drafting" drafting 'Another copy.' ''
  dest="$root/skills"
  err="$root/install.err"
  run_pointers "$root/config" --dest "$dest" --date 2026-07-30 >/dev/null 2>"$err"
  expect_code 1 $? "install passed while offered skills did not resolve"

  assert_absent "$dest/matt-writing-beats" "a skill whose front matter names another skill got a pointer"
  assert_absent "$dest/matt-drafting" "a skill present twice in the source tree got a pointer"
  assert_grep 'UNRESOLVED: upstream skill writing-beats is offered' "$err" \
    "install did not name the misnamed skill in its own summary"
  assert_grep 'UNRESOLVED: upstream skill drafting is offered' "$err" \
    "install did not name the duplicated skill in its own summary"

  out=$(run_pointers "$root/config" --check --dest "$dest" 2>&1)
  rc=$?
  expect_code 1 "$rc" "--check passed a pointer set missing offered skills that do not resolve"
  assert_contains "$out" 'UNRESOLVED: upstream skill writing-beats is offered' \
    "--check did not name the misnamed skill in its own summary"
  assert_contains "$out" 'UNRESOLVED: upstream skill drafting is offered' \
    "--check did not name the duplicated skill in its own summary"
  assert_not_contains "$out" 'ok - ' "--check reported ok for an incomplete pointer set"

  assert_grep 'disable-model-invocation: true' "$dest/matt-loop-me/SKILL.md" \
    "an undeclared user-invoked skill was promoted to model invocation"
  assert_grep 'disable-model-invocation: false' "$dest/matt-setup-pre-commit/SKILL.md" \
    "an undeclared model-invocable skill lost model invocation"
  assert_no_grep 'UNIQUE-UPSTREAM-PROCEDURE' "$dest/matt-loop-me/SKILL.md" \
    "an undeclared pointer copied part of the upstream skill body"
  assert_absent "$dest/matt-old-way" "a deprecated upstream skill got a pointer"

  out=$(run_pointers "$root/config" --list 2>/dev/null)
  [ "$out" = "$(printf 'matt-grilling\tgrilling\tmodel-invocable\nmatt-loop-me\tloop-me\tuser-invoked-only\nmatt-setup-pre-commit\tsetup-pre-commit\tmodel-invocable\nmatt-tdd\ttdd\tmodel-invocable\nmatt-wayfinder\twayfinder\tuser-invoked-only')" ] \
    || fail "--list did not offer exactly the resolvable skills: $out"
  pass "pointers cover every resolvable non-deprecated upstream skill"
}

# A pointer's Step 1 carries the identity it was generated from, so the loader
# can tell a worker when the enabled plugin has moved on. A marketplace switch
# is the case that bit: pointers kept naming an install that was disabled.
test_pointer_step1_flags_a_plugin_switch() {
  local root dest cmd out
  root="$TMP_ROOT/switch"
  build_plugin "$root"
  dest="$root/skills"
  run_pointers "$root/config" --dest "$dest" --date 2026-07-30 >/dev/null \
    || fail "pointer install failed against a healthy plugin"

  cmd=$(pointer_command "$dest/matt-tdd/SKILL.md")
  assert_contains "$cmd" "--validated-plugin $KEY" "Step 1 does not pass the plugin it was generated from"
  out=$(CLAUDE_CONFIG_DIR="$root/config" bash -c "$cmd") \
    || fail "the pointer's Step 1 failed against the plugin it was generated from"
  assert_contains "$out" 'pin=validated' "Step 1 did not validate against its own identity"
  assert_not_contains "$out" 'PLUGIN CHANGED' "Step 1 reported drift with nothing changed"

  add_install "$root" newmarket 2.0.0 cafecafecafecafecafecafecafecafecafecafe
  set_enabled "$root" "$MARKET=false" newmarket=true

  out=$(CLAUDE_CONFIG_DIR="$root/config" bash -c "$cmd") \
    || fail "the pointer's Step 1 refused after the plugin switched marketplaces"
  assert_contains "$out" 'PLUGIN CHANGED' "Step 1 stayed silent about a marketplace switch"
  assert_contains "$out" 'plugin=mattpocock-skills@newmarket' "Step 1 did not load the enabled install"
  assert_contains "$out" 'UNIQUE-newmarket-INSTALL' "Step 1 did not print the enabled install's bytes"

  out=$(run_pointers "$root/config" --check --dest "$dest" 2>&1)
  expect_code 1 $? "--check passed pointers generated from a disabled install"
  assert_contains "$out" "DRIFTED: $dest/matt-tdd/SKILL.md" "--check did not flag the switched plugin"

  run_pointers "$root/config" --dest "$dest" --date 2026-07-30 >/dev/null \
    || fail "regenerating after the switch failed"
  assert_grep 'upstream-plugin: "mattpocock-skills@newmarket"' "$dest/matt-tdd/SKILL.md" \
    "regenerated pointer does not name the newly enabled plugin"
  assert_grep 'validated-version: "2.0.0"' "$dest/matt-tdd/SKILL.md" \
    "regenerated pointer does not record the new version"
  run_pointers "$root/config" --check --dest "$dest" >/dev/null 2>&1
  expect_code 0 $? "--check still reported drift after regenerating"
  pass "a pointer's Step 1 flags a plugin switch and regenerating clears it"
}

test_generator_refuses_without_an_enabled_plugin() {
  local root dest out
  root="$TMP_ROOT/none-enabled"
  build_plugin "$root" "$REAL_VERSION" "$REAL_COMMIT" false
  dest="$root/skills"

  out=$(run_pointers "$root/config" --dest "$dest" 2>&1)
  expect_code 4 $? "the generator ran with no enabled plugin"
  assert_contains "$out" 'disabled' "the generator's refusal did not say the plugin is disabled"
  assert_absent "$dest" "the generator created pointers with no enabled plugin"
  pass "the generator refuses, and writes nothing, without an enabled plugin"
}

test_loader_prints_original_bytes_and_identity
test_loader_refuses_without_printing_anything
test_loader_reports_drift_without_hiding_the_original
test_loader_reports_commit_drift_without_hiding_the_original
test_loader_follows_the_one_enabled_marketplace
test_loader_offers_every_live_upstream_skill
test_loader_delegates_to_the_shared_resolver_when_present
test_loader_refuses_without_the_shared_resolver
test_pointers_carry_attribution_and_no_procedure
test_pointers_mirror_upstream_invocation_flags
test_pointers_cover_undeclared_skills
test_pointer_step1_flags_a_plugin_switch
test_generator_refuses_without_an_enabled_plugin
test_pointer_instructs_a_hard_stop_on_failure
test_check_detects_drift_absence_and_a_dead_loader
test_foreign_directories_are_never_written_or_removed
test_retired_skills_are_pruned_and_reinstalls_are_idempotent
test_prune_keeps_pointers_of_unresolved_skills
test_symlinked_undeclared_skill_stays_unresolved
test_generated_pointer_loads_through_the_shipped_loader
test_check_reports_a_recorded_loader_that_later_vanished
test_check_reports_retired_pointers_and_their_recorded_loaders
test_check_audits_all_retired_pointers_without_an_identity_skill
test_check_reports_combined_pointer_faults_once_each
