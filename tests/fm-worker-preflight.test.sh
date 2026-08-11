#!/usr/bin/env bash
# Regression coverage for the mandatory launch-time Megamind binding every
# ordinary ship and scout worker must clear.
#
# Two layers are exercised. bin/fm-worker-preflight.sh is driven directly with a
# synthetic Megamind executable for the binding, routing-request, outcome, and
# proof-placement matrix. bin/fm-spawn.sh is then driven end to end against a
# fake tmux endpoint so the refusal boundary (no endpoint, no worktree, no task
# record), the private per-task result delivery, the secondmate omission, and the
# isolated-copy behavior are proven where they actually happen.
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
  "status": "'"${FM_TEST_STUB_STATUS:-no-match}"'",
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

file_mode() {  # <path>
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

make_home() {
  local home=$1 name=$2
  mkdir -p "$home/config" "$home/state" "$home/estate-$name"
  printf '%s\n' "$STUB" > "$home/config/megamind-executable"
  printf '%s\n' "$home/estate-$name" > "$home/config/megamind-estate"
  printf 'cloud\n' > "$home/config/megamind-model-class"
}

write_request() {  # <path> <text>
  printf '%s\n' "$2" > "$1"
}

run_helper() {  # <home> <request-file> <result-file> [extra helper args...]
  FM_TEST_STUB_ARGS="$STUB_ARGS" "$HELPER" "$@"
}

test_owner_binding_proof_and_private_result() {
  local primary project request result out rc
  primary="$TMP_ROOT/primary"
  project="$TMP_ROOT/project-copy"
  request="$TMP_ROOT/request.md"
  result="$primary/state/owner.megamind-preflight.json"
  make_home "$primary" primary
  mkdir -p "$project/state"
  write_request "$request" 'routing summary with PRIVATE-REQUEST-CANARY'
  : > "$STUB_ARGS"
  out=$(cd "$project" && unset FM_HOME && run_helper "$primary" "$request" "$result"); rc=$?
  expect_code 0 "$rc" "authorized worker preflight from an isolated project copy"
  [ -z "$out" ] || fail "an authorized preflight printed the typed result instead of filing it: $out"
  assert_present "$result" "the authorized typed result was not filed for the task"
  [ "$(jq -r '.outcome' < "$result")" = no-match ] || fail "the filed result is not the typed document"
  [ "$(file_mode "$result")" = 600 ] || fail "the task's preflight result is not private (mode $(file_mode "$result"))"
  assert_grep "$primary/estate-primary" "$STUB_ARGS" "preflight did not use the primary binding"
  assert_grep "worker-request-hash" "$primary/state/megamind-preflight.jsonl" "primary proof was not written"
  assert_absent "$project/state/megamind-preflight.jsonl" "worker proof leaked into the isolated project copy"
  assert_no_grep "PRIVATE-REQUEST-CANARY" "$primary/state/megamind-preflight.jsonl" "proof log leaked request text"
  pass "an authorized preflight binds the owner home and files a private task result"
}

test_ambient_overrides_cannot_redirect_the_binding() {
  local owner foreign request result rc
  owner="$TMP_ROOT/override-owner"
  foreign="$TMP_ROOT/override-foreign"
  request="$TMP_ROOT/override-request.md"
  result="$owner/state/override.megamind-preflight.json"
  make_home "$owner" owner
  make_home "$foreign" foreign
  write_request "$request" 'routing summary for the override case'
  : > "$STUB_ARGS"
  # The tmux/herdr server a worker pane lives in can be a child of firstmate, so
  # these documented overrides are reachable in the launching environment. An
  # ambient value must not repoint the binding's config or drop its proof in
  # another home.
  FM_CONFIG_OVERRIDE="$foreign/config" FM_STATE_OVERRIDE="$foreign/state" \
    run_helper "$owner" "$request" "$result"; rc=$?
  expect_code 0 "$rc" "owner-bound preflight under ambient overrides"
  assert_grep "$owner/estate-owner" "$STUB_ARGS" "an ambient FM_CONFIG_OVERRIDE redirected the binding"
  assert_no_grep "$foreign/estate-foreign" "$STUB_ARGS" "the binding leaked into the foreign home's estate"
  assert_present "$owner/state/megamind-preflight.jsonl" "proof was not written to the binding owner's state"
  assert_absent "$foreign/state/megamind-preflight.jsonl" "an ambient FM_STATE_OVERRIDE misplaced the proof record"
  pass "ambient FM_CONFIG_OVERRIDE and FM_STATE_OVERRIDE cannot move the owner binding"
}

test_relocated_home_binds_its_own_resolved_directories() {
  local home config state foreign request result rc
  home="$TMP_ROOT/relocated-home"
  config="$TMP_ROOT/relocated-config"
  state="$TMP_ROOT/relocated-state"
  foreign="$TMP_ROOT/relocated-foreign"
  request="$TMP_ROOT/relocated-request.md"
  result="$state/relocated.megamind-preflight.json"
  mkdir -p "$home" "$state"
  make_home "$foreign" foreign
  mkdir -p "$config" "$TMP_ROOT/relocated-estate"
  printf '%s\n' "$STUB" > "$config/megamind-executable"
  printf '%s\n' "$TMP_ROOT/relocated-estate" > "$config/megamind-estate"
  write_request "$request" 'routing summary for a relocated home'
  : > "$STUB_ARGS"
  # A home whose operational directories are relocated (docs/configuration.md
  # "FM_HOME") still reads its OWN binding and files its OWN proof, which is what
  # the owner passes explicitly rather than leaving to the ambient environment.
  FM_CONFIG_OVERRIDE="$foreign/config" FM_STATE_OVERRIDE="$foreign/state" \
    run_helper "$home" "$request" "$result" --config "$config" --state "$state"; rc=$?
  expect_code 0 "$rc" "relocated home preflight"
  assert_grep "$TMP_ROOT/relocated-estate" "$STUB_ARGS" "the relocated home did not read its own binding"
  assert_present "$state/megamind-preflight.jsonl" "the relocated home's proof was misplaced"
  assert_absent "$foreign/state/megamind-preflight.jsonl" "the relocated home's proof leaked into another home"
  assert_present "$result" "the relocated home filed no task result"
  pass "an explicitly pinned config and state bind a relocated home to its own directories"
}

test_secondmate_binding_is_not_primary_binding() {
  local primary secondmate request result out rc
  primary="$TMP_ROOT/primary-secondmate"
  secondmate="$TMP_ROOT/secondmate"
  request="$TMP_ROOT/secondmate-request.md"
  result="$TMP_ROOT/secondmate/state/sm-worker.megamind-preflight.json"
  make_home "$primary" primary
  mkdir -p "$secondmate/config" "$secondmate/state"
  : > "$STUB_ARGS"
  out=$(FM_HOME="$secondmate" "$ROOT/bin/fm-megamind-preflight.sh" run --request "secondmate-shaped home is unbound"); rc=$?
  expect_code 1 "$rc" "unconfigured secondmate-shaped home"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = not_configured ] \
    || fail "an unconfigured secondmate-shaped home inherited a binding"
  make_home "$secondmate" secondmate
  write_request "$request" 'secondmate worker routing summary'
  : > "$STUB_ARGS"
  run_helper "$secondmate" "$request" "$result"; rc=$?
  expect_code 0 "$rc" "secondmate worker preflight"
  assert_grep "$secondmate/estate-secondmate" "$STUB_ARGS" "secondmate worker used the primary binding"
  assert_no_grep "$primary/estate-primary" "$STUB_ARGS" "secondmate worker leaked the primary estate"
  assert_present "$secondmate/state/megamind-preflight.jsonl" "secondmate proof was not written to its own state"
  assert_absent "$primary/state/megamind-preflight.jsonl" "secondmate proof leaked into the primary state"
  assert_present "$result" "the secondmate's worker result was not filed in its own home"
  pass "secondmate workers remain bound to their own home"
}

# <label> <request-file> <expected-failure-code>
assert_request_blocks() {
  local label=$1 request=$2 code=$3 home result out rc
  home="$TMP_ROOT/request-guard"
  result="$TMP_ROOT/request-guard/state/guard.megamind-preflight.json"
  [ -d "$home" ] || make_home "$home" guard
  printf 'stale authorization\n' > "$result"
  : > "$STUB_ARGS"
  out=$(run_helper "$home" "$request" "$result" 2>/dev/null); rc=$?
  expect_code 1 "$rc" "$label"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = "$code" ] \
    || fail "$label did not report failure code $code: $out"
  assert_absent "$result" "$label left a stale authorization behind"
  [ ! -s "$STUB_ARGS" ] || fail "$label reached Megamind instead of failing closed"
}

test_routing_request_guard_blocks_before_any_call() {
  local dir
  dir="$TMP_ROOT/requests"
  mkdir -p "$dir"
  assert_request_blocks "a missing routing request" "$dir/absent.md" routing_request_missing

  : > "$dir/empty.md"
  assert_request_blocks "an empty routing request" "$dir/empty.md" routing_request_empty

  write_request "$dir/placeholder.md" '{ROUTING}'
  assert_request_blocks "an unresolved routing placeholder" "$dir/placeholder.md" routing_request_unresolved

  write_request "$dir/task-placeholder.md" 'route the {TASK} for this worker'
  assert_request_blocks "an unresolved task placeholder" "$dir/task-placeholder.md" routing_request_unresolved

  awk 'BEGIN { for (i = 0; i < 80; i++) printf "routing words that never end " }' > "$dir/huge.md"
  assert_request_blocks "an oversized routing request" "$dir/huge.md" routing_request_too_large

  printf 'one\ntwo\nthree\nfour\n' > "$dir/multiline.md"
  assert_request_blocks "a multi-paragraph routing request" "$dir/multiline.md" routing_request_too_large

  write_request "$dir/real.md" 'routing summary'
  ln -sf "$dir/real.md" "$dir/link.md"
  assert_request_blocks "a symlinked routing request" "$dir/link.md" routing_request_invalid
  pass "an unauthored, oversized, or unsafe routing request blocks before Megamind is called"
}

test_unauthorized_outcomes_block_and_clear_the_result() {
  local home request result out rc status
  home="$TMP_ROOT/outcomes"
  request="$TMP_ROOT/outcome-request.md"
  result="$home/state/outcome.megamind-preflight.json"
  make_home "$home" outcomes
  write_request "$request" 'routing summary for the outcome matrix'
  for status in ambiguous unavailable; do
    printf 'stale authorization\n' > "$result"
    : > "$STUB_ARGS"
    out=$(FM_TEST_STUB_STATUS="$status" run_helper "$home" "$request" "$result" 2>/dev/null); rc=$?
    expect_code 1 "$rc" "$status outcome"
    [ "$(printf '%s' "$out" | jq -r '.outcome')" = "$status" ] \
      || fail "the $status outcome did not surface its typed document: $out"
    assert_absent "$result" "the $status outcome left an authorization behind"
  done

  printf 'stale authorization\n' > "$result"
  : > "$STUB_ARGS"
  rm -f "$home/config/megamind-estate"
  out=$(run_helper "$home" "$request" "$result" 2>/dev/null); rc=$?
  expect_code 1 "$rc" "unconfigured binding"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = not_configured ] \
    || fail "an unconfigured binding did not preserve its typed failure: $out"
  assert_absent "$result" "an unconfigured binding left an authorization behind"
  pass "ambiguous, unavailable, and failed bindings block and clear the task authorization"
}

test_binding_home_must_be_a_real_absolute_home() {
  local request result out rc
  request="$TMP_ROOT/home-guard-request.md"
  result="$TMP_ROOT/primary/state/home-guard.megamind-preflight.json"
  write_request "$request" 'routing summary'
  out=$("$HELPER" relative-home "$request" "$result" 2>/dev/null); rc=$?
  expect_code 1 "$rc" "relative binding home"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = binding_home_invalid \
    ] || fail "a relative binding home was not typed: $out"
  out=$("$HELPER" "$TMP_ROOT/primary" "$request" relative-result 2>/dev/null); rc=$?
  expect_code 1 "$rc" "relative result path"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = result_path_invalid ] \
    || fail "a relative result path was not typed: $out"
  pass "a relative binding home or result path blocks with a typed failure"
}

# --- spawn boundary ---------------------------------------------------------

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

# make_spawn_case <name> <bound|unbound> -> case_dir|home|project|worktree|fakebin|launchlog|id
make_spawn_case() {
  local name=$1 binding=$2 case_dir home project worktree fakebin launchlog id
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
  printf 'Delivery contract: mode=no-mistakes\n# Task\nBRIEF-ONLY-CANARY\n' \
    > "$home/data/$id/brief.md"
  if [ "$binding" = bound ]; then
    make_home "$home" "$name"
    write_request "$home/data/$id/megamind-request.md" 'ROUTING-ONLY-CANARY worker routing summary'
  fi
  : > "$launchlog"
  printf '%s\n' "$case_dir|$home|$project|$worktree|$fakebin|$launchlog|$id"
}

run_spawn_case() {  # <home> <project> <worktree> <fakebin> <launchlog> <id> <kind>
  local home=$1 project=$2 worktree=$3 fakebin=$4 launchlog=$5 id=$6 kind=$7
  local args=("$id" "$project")
  if [ "$kind" = scout ]; then
    args+=(--scout)
  else
    args+=(--mode no-mistakes --yolo off)
  fi
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$worktree" TMUX="fake,1,0" \
    FM_TEST_STUB_ARGS="$STUB_ARGS" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "${args[@]}" 2>&1
}

test_ship_and_scout_spawns_authorize_before_launch() {
  local rec home project worktree fakebin launchlog id kind out rc launch result
  for kind in ship scout; do
    rec=$(make_spawn_case "$kind" bound)
    IFS='|' read -r _ home project worktree fakebin launchlog id <<EOF
$rec
EOF
    : > "$STUB_ARGS"
    out=$(run_spawn_case "$home" "$project" "$worktree" "$fakebin" "$launchlog" "$id" "$kind"); rc=$?
    expect_code 0 "$rc" "$kind spawn with an authorized binding: $out"
    result="$home/state/$id.megamind-preflight.json"
    assert_present "$result" "$kind spawn filed no private preflight result"
    [ "$(jq -r '.outcome' < "$result")" = no-match ] || fail "$kind result is not the typed document"
    assert_present "$home/state/$id.meta" "$kind spawn published no task record"
    launch=$(cat "$launchlog")
    assert_contains "$launch" "codex " "$kind launch omitted the selected worker family"
    assert_not_contains "$launch" "fm-worker-preflight.sh" \
      "$kind launch still routed the preflight through the worker's terminal"
    assert_not_contains "$launch" "ROUTING-ONLY-CANARY" "$kind launch leaked the routing request text"
    assert_grep "ROUTING-ONLY-CANARY" "$STUB_ARGS" "$kind spawn did not route the authored request"
    assert_no_grep "BRIEF-ONLY-CANARY" "$STUB_ARGS" "$kind spawn submitted the full task brief to Megamind"
    assert_grep "worker-request-hash" "$home/state/megamind-preflight.jsonl" \
      "$kind spawn left no proof record in the binding owner's home"
  done
  pass "authorized ship and scout spawns route only the authored request and file a private result"
}

test_blocked_binding_refuses_before_any_task_exists() {
  local rec home project worktree fakebin launchlog id out rc
  rec=$(make_spawn_case unbound unbound)
  IFS='|' read -r _ home project worktree fakebin launchlog id <<EOF
$rec
EOF
  : > "$STUB_ARGS"
  out=$(run_spawn_case "$home" "$project" "$worktree" "$fakebin" "$launchlog" "$id" ship); rc=$?
  expect_code 1 "$rc" "spawn with no owner binding"
  assert_contains "$out" "was not authorized by the owning home's Megamind preflight" \
    "the refusal did not name the blocked binding"
  assert_contains "$out" '"code":"routing_request_missing"' \
    "the refusal did not carry the typed failure document"
  assert_absent "$home/state/$id.meta" "a blocked binding still published a task record"
  assert_absent "$home/state/$id.megamind-preflight.json" "a blocked binding still filed an authorization"
  [ ! -s "$launchlog" ] || fail "a blocked binding still sent a launch command to an endpoint"
  pass "a blocked binding refuses the spawn before any endpoint or task record exists"
}

test_unresolved_routing_placeholder_refuses_spawn() {
  local rec home project worktree fakebin launchlog id out rc
  rec=$(make_spawn_case placeholder bound)
  IFS='|' read -r _ home project worktree fakebin launchlog id <<EOF
$rec
EOF
  printf '{ROUTING}\n' > "$home/data/$id/megamind-request.md"
  : > "$STUB_ARGS"
  out=$(run_spawn_case "$home" "$project" "$worktree" "$fakebin" "$launchlog" "$id" ship); rc=$?
  expect_code 1 "$rc" "spawn with an unfilled routing request"
  assert_contains "$out" '"code":"routing_request_unresolved"' \
    "an unfilled routing request was not typed at the spawn boundary"
  assert_absent "$home/state/$id.meta" "an unfilled routing request still published a task record"
  [ ! -s "$STUB_ARGS" ] || fail "an unfilled routing request still reached Megamind"
  pass "an unfilled routing request refuses the spawn"
}

test_isolated_copy_carries_no_binding_material() {
  local rec home project worktree fakebin launchlog id out rc launch
  rec=$(make_spawn_case isolated bound)
  IFS='|' read -r _ home project worktree fakebin launchlog id <<EOF
$rec
EOF
  : > "$STUB_ARGS"
  out=$(run_spawn_case "$home" "$project" "$worktree" "$fakebin" "$launchlog" "$id" ship); rc=$?
  expect_code 0 "$rc" "isolated-copy spawn: $out"
  assert_absent "$worktree/config" "the isolated copy received the owner's config directory"
  assert_absent "$worktree/megamind-estate" "the isolated copy received the owner's estate"
  assert_absent "$worktree/$id.megamind-preflight.json" "the preflight result was copied into the isolated copy"
  assert_absent "$worktree/state" "the isolated copy received the owner's state directory"
  launch=$(cat "$launchlog")
  assert_not_contains "$launch" "megamind" "the worker launch carries Megamind configuration"
  assert_not_contains "$launch" "FM_HOME=" "the worker launch overrode the worker's ordinary FM_HOME"
  pass "the worker's isolated copy receives no binding, credential, or request material"
}

test_secondmate_launch_omits_the_worker_preflight() {
  local case_dir home sm id launchlog fakebin out rc launch
  case_dir="$TMP_ROOT/spawn-secondmate"
  home="$case_dir/home"
  sm="$case_dir/sm-home"
  id='sm-preflight-omitted'
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects" "$sm/bin" "$sm/data"
  printf 'claude\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  printf 'charter brief\n' > "$home/data/$id/brief.md"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  : > "$launchlog"
  : > "$STUB_ARGS"
  # The home carries NO Megamind binding on purpose: a secondmate is a firstmate
  # home rather than an ordinary worker, so the worker gate must not reach it.
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SKIP_SECONDMATE_INHERIT=1 FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$sm" --secondmate 2>&1); rc=$?
  expect_code 0 "$rc" "secondmate spawn from a home with no Megamind binding: $out"
  launch=$(cat "$launchlog")
  assert_not_contains "$launch" "fm-worker-preflight.sh" "a secondmate launch ran the ordinary worker preflight"
  assert_absent "$home/state/$id.megamind-preflight.json" "a secondmate launch filed a worker preflight result"
  assert_absent "$sm/state/megamind-preflight.jsonl" "a secondmate launch wrote a worker proof record"
  [ ! -s "$STUB_ARGS" ] || fail "a secondmate launch consulted the primary's Megamind binding"
  pass "secondmate launches stay outside the ordinary worker preflight"
}

test_owner_binding_proof_and_private_result
test_ambient_overrides_cannot_redirect_the_binding
test_relocated_home_binds_its_own_resolved_directories
test_secondmate_binding_is_not_primary_binding
test_routing_request_guard_blocks_before_any_call
test_unauthorized_outcomes_block_and_clear_the_result
test_binding_home_must_be_a_real_absolute_home
test_ship_and_scout_spawns_authorize_before_launch
test_blocked_binding_refuses_before_any_task_exists
test_unresolved_routing_placeholder_refuses_spawn
test_isolated_copy_carries_no_binding_material
test_secondmate_launch_omits_the_worker_preflight

echo "# all fm-worker-preflight tests passed"
