#!/usr/bin/env bash
# Regression test for fm-spawn.sh's truth-path check: a fleet clone under
# projects/ whose origin is a plain local path to a non-bare repository that
# has no remote of its own shares one Treehouse worktree pool with that
# repository, because Treehouse keys a pool by the origin URL, or by the
# repository path when there is no origin. A slot that repository created is
# then handed to the clone's spawn, is a worktree of the other repository,
# and the launch used to die late on "is not a worktree of project". The
# spawn now refuses before any pane or pool slot exists, with one line naming
# the path to pass, and never silently changes which repository work lands in.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-truth-path)

# make_truth_case <name> <id> [origin-mode]
# Builds a home, a live repository at <case>/live/<name>, a fleet clone of it at
# <home>/projects/<name>, and a Treehouse-shaped pool whose slot is a linked
# worktree of the LIVE repository (the 2026-09-22 shape). origin-mode:
#   path     the clone's origin is the live repository's plain path (default)
#   file     the clone's origin is a file:// URL, which Treehouse keys apart
#   remote   the live repository has an origin of its own, so its pool is apart
#   bare     the clone's origin is a bare repository
#   noslot   the live repository has no pool slot, so the pool is the clone's
make_truth_case() {
  local name=$1 id=$2 mode=${3:-path} case_dir home live clone pool slot fakebin
  case_dir="$TMP_ROOT/$id"
  home="$case_dir/home"
  live="$case_dir/live/$name"
  clone="$home/projects/$name"
  pool="$case_dir/treehouse/$name-abc123"
  slot="$pool/2/$name"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_init_commit "$live"
  case "$mode" in
  bare)
    git clone --quiet --bare "$live" "$case_dir/live/$name.git"
    git clone --quiet "$case_dir/live/$name.git" "$clone"
    ;;
  file)
    git clone --quiet "file://$live" "$clone"
    ;;
  *)
    git clone --quiet "$live" "$clone"
    ;;
  esac
  if [ "$mode" = remote ]; then
    git clone --quiet --bare "$live" "$case_dir/live/upstream.git"
    git -C "$live" remote add origin "file://$case_dir/live/upstream.git"
  fi
  mkdir -p "$pool"
  printf '{"worktrees":[]}\n' > "$pool/treehouse-state.json"
  if [ "$mode" != noslot ]; then
    git -C "$live" worktree add --quiet -b "slot-$id" "$slot"
  else
    git -C "$clone" worktree add --quiet -b "slot-$id" "$slot"
  fi
  fm_test_spawn_brief "$home" "$id" "Exercise the truth-path check for $id."
  printf '%s\n' "$home|$live|$clone|$slot|$fakebin"
}

read_truth_record() {
  IFS='|' read -r HOME_DIR LIVE_DIR CLONE_DIR SLOT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_truth_spawn() {
  local id=$1 project=$2
  FM_TEST_CLAUDE_CONFIG_DIR="$HOME_DIR/claude-config" \
    fm_test_run_spawn "$HOME_DIR" "$SLOT_DIR" "$FAKEBIN_DIR" \
    "$id" "$project" --mode no-mistakes --yolo off
}

# The exact incident: projects/Wikis cloned from the live ~/Documents/Wikis,
# which has no remote, so both share one pool and the slot handed out belongs
# to the live repository. The spawn must refuse before creating a window or
# claiming a slot, and the one-line refusal must name the path to pass.
test_shared_pool_clone_refuses_early_naming_the_live_path() {
  local rec id out status live_real
  id=truth-shared-pool-z1
  rec=$(make_truth_case Wikis "$id")
  read_truth_record "$rec"
  live_real=$(cd "$LIVE_DIR" && pwd -P)

  out=$(run_truth_spawn "$id" projects/Wikis)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a clone whose pool slots belong to its origin"$'\n'"$out"
  assert_not_contains "$out" "is not a worktree of project" \
    "spawn still died late on the trust-registration refusal"
  assert_contains "$out" "project '$CLONE_DIR' shares its Treehouse worktree pool" \
    "the refusal did not name the clone it refused"$'\n'"$out"
  assert_contains "$out" "pass '$live_real'" \
    "the refusal did not name the exact path to pass"$'\n'"$out"
  [ "$(printf '%s\n' "$out" | grep -c '^error:')" -eq 1 ] \
    || fail "the refusal was not exactly one error line"$'\n'"$out"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  [ ! -e "$(dirname "$SLOT_DIR")/.fm-slot-owner" ] || fail "refused spawn claimed the pool slot"
  pass "a clone sharing its origin's Treehouse pool refuses early and names the path to pass"
}

# Passing the live repository itself is the resolution the refusal names; the
# check must not fire for it, so the spawn proceeds into its own pool slot.
test_live_path_itself_spawns() {
  local rec id out status
  id=truth-live-path-z2
  rec=$(make_truth_case Wikis "$id")
  read_truth_record "$rec"

  out=$(run_truth_spawn "$id" "$LIVE_DIR")
  status=$?
  expect_code 0 "$status" "spawn from the live repository should succeed"$'\n'"$out"
  assert_grep "worktree=$SLOT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the live repository's slot"
  pass "the path the refusal names spawns cleanly"
}

# Clones whose pool Treehouse keys apart from the origin repository, or whose
# pool holds no slot of it, must keep spawning from the clone unchanged.
test_unshared_pools_are_not_refused() {
  local mode rec id out
  for mode in file remote bare noslot; do
    id="truth-unshared-$mode-z3"
    rec=$(make_truth_case "Proj$mode" "$id" "$mode")
    read_truth_record "$rec"
    out=$(run_truth_spawn "$id" "projects/Proj$mode")
    assert_not_contains "$out" "shares its Treehouse worktree pool" \
      "origin mode $mode was wrongly refused by the truth-path check"
  done
  pass "clones with a separately keyed or clone-rooted pool are not refused"
}

sha256_hex() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

# Two Firstmate homes clone one remote into projects/<name> on one machine, so
# both resolve Treehouse's default pool <user-home>/.treehouse/<name>-<hash>,
# where <hash> is six hex digits of the SHA-256 of the origin URL. Home A made
# that pool first, so its one slot is a worktree of A's clone. B's per-clone
# pool is <user-home>/.treehouse/fm-clones/<twelve hex digits of the SHA-256 of
# B's physical clone path>/.treehouse/<name>-<hash>. An optional <pool-base>
# relative to the user home stands in for a configured Treehouse root.
make_two_home_case() {
  local id=$1 name=${2:-Proj} pool_base=${3:-} case_dir user url hash pool pinned slot_a slot_b
  case_dir="$TMP_ROOT/$id"
  user="$case_dir/user-home"
  mkdir -p "$user"
  fm_git_init_commit "$case_dir/seed/$name"
  git clone --quiet --bare "$case_dir/seed/$name" "$case_dir/remote/$name.git"
  url="file://$case_dir/remote/$name.git"
  fm_test_spawn_home "$case_dir/homeA" claude
  fm_test_spawn_home "$case_dir/homeB" claude
  git clone --quiet "$url" "$case_dir/homeA/projects/$name"
  git clone --quiet "$url" "$case_dir/homeB/projects/$name"
  hash=$(sha256_hex "$url")
  pool="$user${pool_base:+/$pool_base}/.treehouse/$name-${hash:0:6}"
  slot_a="$pool/1/$name"
  mkdir -p "$pool"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$slot_a" > "$pool/treehouse-state.json"
  git -C "$case_dir/homeA/projects/$name" worktree add --quiet --detach "$slot_a"
  pinned="$user/.treehouse/fm-clones/$(sha256_hex "$(cd "$case_dir/homeB/projects/$name" && pwd -P)" | cut -c1-12)/.treehouse/$name-${hash:0:6}"
  slot_b="$pinned/1/$name"
  fm_test_spawn_brief "$case_dir/homeA" "$id-a" "Spawn from home A."
  fm_test_spawn_brief "$case_dir/homeB" "$id-b" "Spawn from home B."
  printf '%s\n' "$case_dir|$user|$pool|$slot_a|$pinned|$slot_b"
}

read_two_home_record() {
  IFS='|' read -r CASE_DIR USER_HOME POOL_DIR SLOT_A PINNED_POOL SLOT_B <<EOF
$1
EOF
}

run_home_spawn() {
  local home=$1 slot=$2 id=$3 project=$4 fakebin
  fakebin=$(make_spawn_fakebin "$home/fake")
  HOME_DIR=$home
  FM_TEST_SPAWN_USER_HOME=$USER_HOME FM_TEST_CLAUDE_CONFIG_DIR="$home/claude-config" \
    fm_test_run_spawn "$home" "$slot" "$fakebin" "$id" "$project" --mode no-mistakes --yolo off
}

test_second_home_clone_of_one_remote_gets_its_own_pool() {
  local rec id out status head_a state_before clone_b
  id='pool-two-homes-z4'
  rec=$(make_two_home_case "$id")
  read_two_home_record "$rec"
  clone_b="$CASE_DIR/homeB/projects/Proj"
  head_a=$(git -C "$SLOT_A" rev-parse HEAD)
  state_before=$(cat "$POOL_DIR/treehouse-state.json")
  # Where Treehouse lands once B is pinned: a worktree of B's own clone.
  mkdir -p "$PINNED_POOL"
  printf '{"worktrees":[]}\n' > "$PINNED_POOL/treehouse-state.json"
  git -C "$clone_b" worktree add --quiet --detach "$SLOT_B"

  out=$(run_home_spawn "$CASE_DIR/homeB" "$SLOT_B" "$id-b" projects/Proj)
  status=$?
  expect_code 0 "$status" "home B's spawn of its own clone should succeed"$'\n'"$out"
  assert_not_contains "$out" "is not a worktree of project" \
    "home B was still handed home A's slot"
  assert_grep "worktree=$SLOT_B" "$CASE_DIR/homeB/state/$id-b.meta" \
    "home B's meta did not record a worktree of its own clone"
  assert_grep "root = \"$(dirname "$(dirname "$PINNED_POOL")")\"" "$clone_b/treehouse.toml" \
    "home B's clone was not pinned to its per-clone pool root"
  [ -z "$(git -C "$clone_b" status --porcelain)" ] \
    || fail "pinning left home B's clone dirty"$'\n'"$(git -C "$clone_b" status --porcelain)"
  [ "$(git -C "$SLOT_A" rev-parse HEAD)" = "$head_a" ] || fail "home A's slot HEAD moved"
  [ "$(cat "$POOL_DIR/treehouse-state.json")" = "$state_before" ] || fail "the shared pool's state changed"
  [ ! -e "$(dirname "$SLOT_A")/.fm-slot-owner" ] || fail "home B claimed home A's slot"
  [ ! -e "$CASE_DIR/homeA/projects/Proj/treehouse.toml" ] || fail "home A's clone was pinned"

  out=$(run_home_spawn "$CASE_DIR/homeA" "$SLOT_A" "$id-a" projects/Proj)
  status=$?
  expect_code 0 "$status" "home A's spawn should still use its existing pool"$'\n'"$out"
  assert_grep "worktree=$SLOT_A" "$CASE_DIR/homeA/state/$id-a.meta" \
    "home A's meta did not record its existing slot"
  [ ! -e "$CASE_DIR/homeA/projects/Proj/treehouse.toml" ] || fail "home A's own spawn pinned its clone"
  pass "a second home's clone of one remote is pinned to its own pool and the first home's pool is untouched"
}

test_foreign_pool_outside_projects_refuses_without_pinning() {
  local rec id out status project
  id='pool-outside-projects-z5'
  rec=$(make_two_home_case "$id")
  read_two_home_record "$rec"
  project="$CASE_DIR/elsewhere/Proj"
  mkdir -p "$CASE_DIR/elsewhere"
  mv "$CASE_DIR/homeB/projects/Proj" "$project"
  out=$(run_home_spawn "$CASE_DIR/homeB" "$SLOT_A" "$id-b" "$project")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a project whose pool holds a foreign slot"$'\n'"$out"
  assert_contains "$out" "holds '$SLOT_A', a worktree of another repository" \
    "the refusal did not name the foreign slot"$'\n'"$out"
  [ ! -e "$project/treehouse.toml" ] || fail "a project outside projects/ was pinned"
  [ ! -e "$(dirname "$SLOT_A")/.fm-slot-owner" ] || fail "refused spawn claimed the foreign slot"
  pass "a project outside projects/ whose pool holds a foreign slot refuses before allocation"
}

test_repository_owned_treehouse_config_is_not_overwritten() {
  local rec id out status clone_b
  id='pool-own-config-z6'
  rec=$(make_two_home_case "$id")
  read_two_home_record "$rec"
  clone_b="$CASE_DIR/homeB/projects/Proj"
  printf 'max_trees = 4\n' > "$clone_b/treehouse.toml"
  out=$(run_home_spawn "$CASE_DIR/homeB" "$SLOT_A" "$id-b" projects/Proj)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a foreign slot it could not pin away from"$'\n'"$out"
  assert_contains "$out" "could not be pinned to a pool of its own" \
    "the refusal did not explain the pin failure"$'\n'"$out"
  [ "$(cat "$clone_b/treehouse.toml")" = "max_trees = 4" ] || fail "the clone's own treehouse.toml was overwritten"
  pass "a clone carrying its own treehouse.toml refuses instead of being overwritten"
}

toml_value() {  # <file> <key>
  python3 -I -c 'import sys, tomllib; print(tomllib.load(open(sys.argv[1], "rb"))[sys.argv[2]])' "$1" "$2"
}

# Treehouse expands a configured root from the environment and reads its
# config as TOML, so a user config of `root = "$HOME/worktrees"` with a quoted
# key and a signed max_trees still resolves the shared pool, and the pin keeps
# that max_trees. A clone whose info/exclude lacks a final newline stays clean.
test_configured_root_resolves_and_pins_like_treehouse() {
  local rec id out status clone_b
  id='pool-configured-root-z8'
  rec=$(make_two_home_case "$id" Proj worktrees)
  read_two_home_record "$rec"
  clone_b="$CASE_DIR/homeB/projects/Proj"
  mkdir -p "$USER_HOME/.config/treehouse"
  # shellcheck disable=SC2016
  printf '"max_trees" = +4\nroot = "$HOME/worktrees" # the configured pool root\n' \
    > "$USER_HOME/.config/treehouse/config.toml"
  printf 'build/' > "$(git -C "$clone_b" rev-parse --path-format=absolute --git-path info/exclude)"
  mkdir -p "$clone_b/build"
  : > "$clone_b/build/artifact"
  mkdir -p "$PINNED_POOL"
  printf '{"worktrees":[]}\n' > "$PINNED_POOL/treehouse-state.json"
  git -C "$clone_b" worktree add --quiet --detach "$SLOT_B"

  out=$(run_home_spawn "$CASE_DIR/homeB" "$SLOT_B" "$id-b" projects/Proj)
  status=$?
  expect_code 0 "$status" "home B's spawn under a configured root should pin and succeed"$'\n'"$out"
  assert_contains "$out" "pinned project" "home B's clone was not pinned away from the configured shared pool"$'\n'"$out"
  assert_grep "worktree=$SLOT_B" "$CASE_DIR/homeB/state/$id-b.meta" \
    "home B's meta did not record a worktree of its own clone"
  [ "$(toml_value "$clone_b/treehouse.toml" max_trees)" = 4 ] || fail "the pin did not keep the configured max_trees"
  [ "$(toml_value "$clone_b/treehouse.toml" root)" = "$(dirname "$(dirname "$PINNED_POOL")")" ] \
    || fail "the pin did not name the per-clone pool root"
  [ -z "$(git -C "$clone_b" status --porcelain)" ] \
    || fail "pinning left home B's clone dirty"$'\n'"$(git -C "$clone_b" status --porcelain)"
  [ ! -e "$(dirname "$SLOT_A")/.fm-slot-owner" ] || fail "home B claimed home A's slot"
  pass "a configured \$HOME root with a quoted key and signed max_trees resolves and pins like Treehouse"
}

test_unreadable_treehouse_config_refuses_before_allocation() {
  local rec id out status clone_b
  id='pool-unreadable-config-z9'
  rec=$(make_two_home_case "$id")
  read_two_home_record "$rec"
  clone_b="$CASE_DIR/homeB/projects/Proj"
  mkdir -p "$USER_HOME/.config/treehouse"
  printf 'root = \n' > "$USER_HOME/.config/treehouse/config.toml"
  out=$(run_home_spawn "$CASE_DIR/homeB" "$SLOT_A" "$id-b" projects/Proj)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn allocated from a pool it could not resolve"$'\n'"$out"
  assert_contains "$out" "could not resolve the Treehouse worktree pool" \
    "the refusal did not explain the unresolved pool"$'\n'"$out"
  [ ! -e "$clone_b/treehouse.toml" ] || fail "an unresolved pool was pinned"
  [ ! -e "$(dirname "$SLOT_A")/.fm-slot-owner" ] || fail "refused spawn claimed the foreign slot"
  pass "a Treehouse config that cannot be read refuses before allocation"
}

# The pin must hold against the real Treehouse binary, not only the fake pane:
# unpinned, B is handed A's slot (the defect); pinned, B is handed its own.
test_real_treehouse_hands_second_home_its_own_worktree() {
  local rec id out clone_b got common_b got_common
  if ! command -v treehouse >/dev/null 2>&1; then
    echo "skip: treehouse not installed; the real-Treehouse pin check did not run"
    return 0
  fi
  id='pool-real-treehouse-z7'
  rec=$(make_two_home_case "$id")
  read_two_home_record "$rec"
  clone_b="$CASE_DIR/homeB/projects/Proj"
  common_b=$(cd "$(git -C "$clone_b" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)

  got=$(cd "$clone_b" && HOME=$USER_HOME TREEHOUSE_NO_UPDATE_CHECK=1 treehouse get --lease --lease-holder "$id" 2>/dev/null)
  [ "$got" = "$SLOT_A" ] || fail "unpinned Treehouse did not reproduce the shared-pool defect (got '$got')"
  (cd "$clone_b" && HOME=$USER_HOME TREEHOUSE_NO_UPDATE_CHECK=1 treehouse return --force "$got" >/dev/null 2>&1) \
    || fail "could not return the reproduction lease"

  out=$(run_home_spawn "$CASE_DIR/homeB" "$SLOT_A" "$id-b" projects/Proj)
  assert_contains "$out" "pinned project" "home B's spawn did not pin its clone"$'\n'"$out"
  got=$(cd "$clone_b" && HOME=$USER_HOME TREEHOUSE_NO_UPDATE_CHECK=1 treehouse get --lease --lease-holder "$id" 2>/dev/null)
  [ -n "$got" ] || fail "pinned Treehouse handed out no worktree"
  got_common=$(cd "$(git -C "$got" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)
  [ "$got_common" = "$common_b" ] || fail "pinned Treehouse handed home B '$got', not a worktree of its clone"
  [ "$got" = "$SLOT_B" ] || fail "pinned Treehouse used '$got', not the per-clone pool slot '$SLOT_B'"
  (cd "$clone_b" && HOME=$USER_HOME TREEHOUSE_NO_UPDATE_CHECK=1 treehouse return --force "$got" >/dev/null 2>&1) || true
  pass "real Treehouse hands a pinned second-home clone a worktree of its own clone ($(treehouse --version 2>/dev/null))"
}

test_shared_pool_clone_refuses_early_naming_the_live_path
test_live_path_itself_spawns
test_unshared_pools_are_not_refused
test_second_home_clone_of_one_remote_gets_its_own_pool
test_foreign_pool_outside_projects_refuses_without_pinning
test_repository_owned_treehouse_config_is_not_overwritten
test_configured_root_resolves_and_pins_like_treehouse
test_unreadable_treehouse_config_refuses_before_allocation
test_real_treehouse_hands_second_home_its_own_worktree

echo "# all fm-spawn-truth-path tests passed"
