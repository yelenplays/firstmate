#!/usr/bin/env bash
# Regression coverage for the launch-time Megamind binding used by ordinary
# ship and scout workers.
#
# The helper is exercised through its public command surface with a synthetic
# Megamind executable. The spawn cases capture the real launch command sent to
# a fake tmux endpoint, proving the common preflight prefix is present for both
# task kinds without starting a vendor worker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-worker-preflight.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-preflight)

STUB="$TMP_ROOT/megamind-axi"
STUB_ARGS="$TMP_ROOT/megamind-args"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  printf 'megamind-axi 0.3.0\n'
  exit 0
fi
printf '%s\n' "$@" >> "${FM_TEST_STUB_ARGS:?}"
printf '%s\n' '{
  "schema_version": "megamind/preflight-result/v2",
  "request_hash": "worker-request-hash",
  "model_class": "cloud",
  "status": "no-match",
  "confidence": null,
  "thresholds": {"reliance_floor": 0.75, "offer_floor": 0.25, "ambiguity_band": 0.05},
  "preflight_id": "worker-preflight-1",
  "catalog_hash": "worker-catalog-1",
  "matches": [],
  "offers": [],
  "filtered": [],
  "redacted_count": 0
}'
SH
chmod +x "$STUB"

make_home() {
  local home=$1 name=$2
  mkdir -p "$home/config" "$home/state" "$home/estate-$name"
  printf '%s\n' "$STUB" > "$home/config/megamind-executable"
  printf '%s\n' "$home/estate-$name" > "$home/config/megamind-estate"
  printf 'cloud\n' > "$home/config/megamind-model-class"
}

run_helper() {
  local home=$1 request=$2
  FM_TEST_STUB_ARGS="$STUB_ARGS" "$HELPER" "$home" "$request"
}

test_primary_binding_and_proof_placement() {
  local primary project request out rc
  primary="$TMP_ROOT/primary"
  project="$TMP_ROOT/project-copy"
  request="$TMP_ROOT/request.md"
  make_home "$primary" primary
  mkdir -p "$project/state"
  printf 'substantive request can contain PRIVATE-REQUEST-CANARY\n' > "$request"
  : > "$STUB_ARGS"
  out=$(cd "$project" && unset FM_HOME && run_helper "$primary" "$request"); rc=$?
  expect_code 0 "$rc" "primary worker preflight from an isolated project copy"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = no-match ] || fail "helper did not print the typed no-match result"
  assert_grep "$primary/estate-primary" "$STUB_ARGS" "preflight did not use the primary binding"
  assert_grep "worker-request-hash" "$primary/state/megamind-preflight.jsonl" "primary proof was not written"
  [ ! -e "$project/state/megamind-preflight.jsonl" ] || fail "worker proof leaked into the isolated project copy"
  assert_no_grep "PRIVATE-REQUEST-CANARY" "$primary/state/megamind-preflight.jsonl" "proof log leaked request text"
  pass "worker preflight uses the owner binding and keeps proof in that home"
}

test_secondmate_binding_is_not_primary_binding() {
  local primary secondmate request out rc
  primary="$TMP_ROOT/primary-secondmate"
  secondmate="$TMP_ROOT/secondmate"
  request="$TMP_ROOT/secondmate-request.md"
  make_home "$primary" primary
  mkdir -p "$secondmate/config" "$secondmate/state"
  : > "$STUB_ARGS"
  out=$(FM_HOME="$secondmate" "$ROOT/bin/fm-megamind-preflight.sh" run --request "secondmate-shaped home is unbound"); rc=$?
  expect_code 1 "$rc" "unconfigured secondmate-shaped home"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = not_configured ] \
    || fail "an unconfigured secondmate-shaped home inherited a binding"
  make_home "$secondmate" secondmate
  printf 'secondmate worker request\n' > "$request"
  : > "$STUB_ARGS"
  out=$(run_helper "$secondmate" "$request"); rc=$?
  expect_code 0 "$rc" "secondmate worker preflight"
  assert_grep "$secondmate/estate-secondmate" "$STUB_ARGS" "secondmate worker used the primary binding"
  assert_no_grep "$primary/estate-primary" "$STUB_ARGS" "secondmate worker leaked the primary estate"
  [ -e "$secondmate/state/megamind-preflight.jsonl" ] || fail "secondmate proof was not written to its own state"
  [ ! -e "$primary/state/megamind-preflight.jsonl" ] || fail "secondmate proof leaked into the primary state"
  pass "secondmate workers remain bound to their own home"
}

test_missing_and_unsafe_bindings_block() {
  local missing unsafe symlink request out rc
  request="$TMP_ROOT/unsafe-request.md"
  printf 'request\n' > "$request"
  missing="$TMP_ROOT/missing-binding"
  mkdir -p "$missing"
  out=$(run_helper "$missing" "$request" 2>&1); rc=$?
  expect_code 1 "$rc" "missing binding"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = not_configured ] || fail "missing binding did not preserve typed failure: $out"

  unsafe="$TMP_ROOT/unsafe-binding"
  mkdir -p "$unsafe"
  out=$($HELPER "relative-home" "$request" 2>&1); rc=$?
  expect_code 1 "$rc" "relative binding"
  assert_contains "$out" "absolute path" "relative binding was not rejected"

  symlink="$TMP_ROOT/request-link"
  ln -s "$request" "$symlink"
  out=$($HELPER "$unsafe" "$symlink" 2>&1); rc=$?
  expect_code 1 "$rc" "symlink request"
  assert_contains "$out" "regular file" "symlink request was not rejected"
  pass "missing, relative, and symlinked inputs block before worker work"
}

make_spawn_fakebin() {
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
  list-windows|has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for arg in "$@"; do
        if [ "$prev" = -l ]; then printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"; fi
        prev=$arg
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 kind=$2 case_dir home project worktree fakebin launchlog id
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  launchlog="$case_dir/launch.log"
  id="worker-preflight-$name"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$project" "$worktree" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf 'Delivery contract: mode=no-mistakes\n# task\n' > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$project|$worktree|$fakebin|$launchlog|$id|$kind"
}

run_spawn_case() {
  local home=$1 worktree=$2 fakebin=$3 launchlog=$4 id=$5 kind=$6
  local args=("$id" "$HOME_PROJECT")
  if [ "$kind" = scout ]; then
    args=("$id" "$HOME_PROJECT" --scout)
  else
    args+=(--mode no-mistakes --yolo off)
  fi
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$worktree" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "${args[@]}" 2>&1
}

test_ship_and_scout_launch_families_receive_prefix() {
  local rec home project worktree fakebin launchlog id kind out rc launch brief_real
  for kind in ship scout; do
    rec=$(make_spawn_case "$kind" "$kind")
    IFS='|' read -r _ home project worktree fakebin launchlog id _ <<EOF
$rec
EOF
    HOME_PROJECT="$project" out=$(run_spawn_case "$home" "$worktree" "$fakebin" "$launchlog" "$id" "$kind"); rc=$?
    expect_code 0 "$rc" "$kind spawn"
    launch=$(cat "$launchlog")
    brief_real=$(cd "$(dirname "$home/data/$id/brief.md")" && pwd -P)/brief.md
    assert_contains "$launch" "'$ROOT/bin/fm-worker-preflight.sh' '$home' '$brief_real' &&" \
      "$kind launch omitted the owner-home preflight"
    assert_contains "$launch" "codex " "$kind launch omitted the selected worker family"
    assert_not_contains "$launch" "FM_HOME=$home codex" \
      "$kind launch exported the owner's FM_HOME into the worker"
  done
  pass "ship and scout launch families receive the deterministic preflight prefix"
}

test_primary_binding_and_proof_placement
test_secondmate_binding_is_not_primary_binding
test_missing_and_unsafe_bindings_block
test_ship_and_scout_launch_families_receive_prefix

echo "# all fm-worker-preflight tests passed"
