#!/usr/bin/env bash
# tests/fm-quota-guard.test.sh - the runtime quota floor guard.
#
# The failure this covers: one unattended task drove a full pipeline overnight
# and consumed a provider's entire seven-day allowance by morning. Nothing was
# watching between dispatch and daylight, because quota-axi was consulted once at
# intake and never again.
#
# Every test drives bin/fm-quota-guard.sh, bin/fm-spawn.sh, or bin/fm-watch.sh as
# real executables against fixture snapshots and a stub quota-axi on PATH, so no
# assertion depends on the developer's own provider allowances. tests/lib.sh
# exports FM_QUOTA_GUARD=off for the rest of the suite; every case here turns it
# back on explicitly.
#
# The contract under test, in the order the cases appear:
#   1. a provider under its floor refuses a NEW spawn, before any endpoint,
#      worktree, or task record exists;
#   2. an unmeasurable window is a disclosed unknown that still launches;
#   3. a failed read degrades to that same disclosed uncertainty - never to
#      "healthy" and never to "exhausted";
#   4. the guard issues no control or teardown action against running work;
#   5. the heartbeat path stays bounded when the read is slow or fails;
#   6. stale windows are diagnostic data, not headroom, and a prepaid credits
#      balance is not exhaustion;
#   7. granularity follows the vendor: a provider-level window bounds every
#      model, a named-model window bounds only that model;
#   8. escalation is by transition, and it reaches the wake queue as a check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || {
  echo "skip: jq not found (the quota guard parses quota-axi output with it)"
  exit 0
}

GUARD="$ROOT/bin/fm-quota-guard.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-guard)
fm_git_identity fmtest fmtest@example.invalid

RESET_AT='2026-08-20T03:32:29.000Z'

# --- fixture builders --------------------------------------------------------
#
# Fixtures are written as literal JSON rather than generated, so a reader can see
# exactly which quota-axi shape each case pins. The shapes mirror the real
# `quota-axi --json` schemaVersion 3 document.

# provider_block <name> <availStatus> <remaining|-> <stale> <scope|-> <window|-> [credits|-]
provider_block() {
  local name=$1 avail=$2 remaining=$3 stale=$4 scope=$5 window=$6 credits=${7:-}
  local windows='[]' availability='[]' creditblock='' remblock=''
  [ "$window" = "-" ] || windows="[{\"id\":\"$window\",\"label\":\"$window\",\"kind\":\"weekly\",\"resetsAt\":\"$RESET_AT\"}]"
  [ "$remaining" = "-" ] || remblock=",\"effectivePercentRemaining\":$remaining"
  if [ "$scope" != "-" ]; then
    availability="[{\"scope\":\"$scope\",\"status\":\"$avail\",\"boundedBy\":[\"$window\"],\"limitingWindowIds\":[\"$window\"]$remblock}]"
  fi
  [ -z "$credits" ] || [ "$credits" = "-" ] || \
    creditblock=",\"credits\":{\"remaining\":$credits,\"unlimited\":false,\"unit\":\"credits\"}"
  printf '{"provider":"%s","label":"%s","source":"oauth","windows":%s,"state":{"status":"%s","stale":%s}%s,"quotaSemantics":{"status":"%s","effectiveAvailability":%s}}' \
    "$name" "$name" "$windows" \
    "$( [ "$stale" = true ] && printf 'stale' || printf 'fresh' )" "$stale" \
    "$creditblock" "$avail" "$availability"
}

# write_snapshot <file> <provider-block>...
write_snapshot() {
  local file=$1 first=1 block
  shift
  {
    printf '{"generatedAt":"2026-08-14T00:00:00.000Z","schemaVersion":3,"providers":['
    for block in "$@"; do
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '%s' "$block"
    done
    printf ']}\n'
  } > "$file"
  jq -e . "$file" >/dev/null || fail "fixture snapshot $file is not valid JSON"
}

# model_block <id> <provider> <effStatus|-> <remaining|-> <scope|-> <window|->
model_block() {
  local id=$1 provider=$2 status=$3 remaining=$4 scope=$5 window=$6 effective='' remblock=''
  if [ "$status" != "-" ]; then
    [ "$remaining" = "-" ] || remblock=",\"effectivePercentRemaining\":$remaining"
    effective=",\"effective\":{\"scope\":\"$scope\",\"status\":\"$status\",\"boundedBy\":[\"$window\"],\"limitingWindowIds\":[\"$window\"]$remblock}"
  fi
  printf '{"provider":"%s","id":"%s","label":"%s","intelligence":"high","quotaScopes":["%s"]%s,"state":{"status":"fresh","stale":false}}' \
    "$provider" "$id" "$id" "$scope" "$effective"
}

# write_catalog <file> <model-block>...
write_catalog() {
  local file=$1 first=1 block
  shift
  {
    printf '{"generatedAt":"2026-08-14T00:00:00.000Z","schemaVersion":1,"catalog":{"version":"2026-08-05"},"models":['
    for block in "$@"; do
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '%s' "$block"
    done
    printf ']}\n'
  } > "$file"
  jq -e . "$file" >/dev/null || fail "fixture catalog $file is not valid JSON"
}

# make_home <name> -> a home dir with state/ and config/, echoed
make_home() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config" "$dir/data" "$dir/projects"
  printf '%s\n' "$dir"
}

# A quota-axi stub whose behavior is driven by files the case writes:
#   $dir/axi-json     served for `quota-axi --json`
#   $dir/axi-models   served for `quota-axi models --json`
#   $dir/axi-mode     one of: ok (default), fail, hang
# It records every invocation in $dir/axi-calls.
make_quota_axi_stub() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
d=${FM_TEST_AXI_DIR:?}
printf '%s\n' "$*" >> "$d/axi-calls"
if [ "${1:-}" = --version ] || [ "${1:-}" = -v ]; then
  printf '%s\n' "${FM_TEST_AXI_VERSION:-0.1.20}"
  exit 0
fi
mode=$(cat "$d/axi-mode" 2>/dev/null || printf 'ok')
case "$mode" in
  fail) printf 'quota-axi: exploded\n' >&2; exit 3 ;;
  hang) sleep 600; exit 0 ;;
esac
case "${1:-}" in
  models) cat "$d/axi-models" 2>/dev/null || exit 3 ;;
  *)      cat "$d/axi-json" 2>/dev/null || exit 3 ;;
esac
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

# run_guard <home> <fakebin> <args...>: the guard bound to that home only, with
# the quota-axi stub first on PATH and the floor guard explicitly ON.
run_guard() {
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" FM_TEST_AXI_DIR="$home" FM_QUOTA_GUARD=on \
    "$GUARD" "$@" --state "$home/state" --config "$home/config" 2>&1
}

# prime <home> <fakebin>: take the reading up front. A heartbeat only ever reads
# the cached snapshot and leaves the refresh to a detached child, so a test that
# asserts on a verdict must supply the reading rather than race that child. This
# is also the real steady state: by the second heartbeat a reading exists.
prime() {
  run_guard "$1" "$2" refresh --catalog >/dev/null 2>&1 || true
  [ -s "$1/state/.quota-snapshot.json" ] || fail "fixture reading was not published for $1"
}

# --- 1. a provider under its floor refuses a NEW spawn ----------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(make_quota_axi_stub "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_TMUX_LOG:-/dev/null}"
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

# make_spawn_case <name> <task-id> -> "home|project|worktree|fakebin"
make_spawn_case() {
  local name=$1 id=$2 home proj wt fakebin
  home=$(make_home "$name")
  proj="$TMP_ROOT/$name-project"
  wt="$TMP_ROOT/$name-wt"
  fakebin=$(make_spawn_fakebin "$home")
  printf '%s\n' claude > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\nDelivery contract: mode=local-only\n' "$id" > "$home/data/$id/brief.md"
  fm_test_megamind_task "$home" "$id"
  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' GROK_HOME="$home/grok-home" \
    FM_TEST_AXI_DIR="$home" FM_QUOTA_GUARD=on \
    FM_TEST_TMUX_LOG="$home/tmux-calls" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_spawn_refuses_a_provider_under_its_floor() {
  local home proj wt fakebin id out status
  id=quota-below-a1
  IFS='|' read -r home proj wt fakebin <<< "$(make_spawn_case quota-below "$id")"
  write_snapshot "$home/axi-json" "$(provider_block codex known 3 false all_models weekly)"
  write_catalog "$home/axi-models" "$(model_block gpt-5.1-codex codex known 3 all_models weekly)"

  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
    --harness codex --model gpt-5.6-luna --mode local-only --yolo off)
  status=$?

  expect_code 1 "$status" "a spawn onto a provider under its floor must be refused"
  assert_contains "$out" "refusing to launch onto codex" "the refusal did not name the provider"
  assert_contains "$out" "3% of its allowance is left" "the refusal did not report the measured remaining percentage"
  assert_contains "$out" "under the 10% floor" "the refusal did not name the floor"
  assert_contains "$out" "weekly window" "the refusal did not name the bounding window"
  assert_contains "$out" "Nothing already running is affected" \
    "the refusal did not state that running work is untouched"
  # Refused BEFORE anything exists to clean up.
  assert_absent "$home/state/$id.meta" "a refused spawn still published a task record"
  assert_absent "$home/state/$id.status" "a refused spawn still created a status log"
  if [ -e "$home/tmux-calls" ]; then
    assert_no_grep 'new-window' "$home/tmux-calls" "a refused spawn still created a backend endpoint"
  fi
  pass "a spawn onto a provider under its floor is refused before any endpoint, worktree, or task record exists"
}

# --- 2. an unmeasurable window still launches -------------------------------

test_spawn_launches_on_an_unmeasurable_window() {
  local home proj wt fakebin id out status
  id=quota-unmeasurable-b1
  IFS='|' read -r home proj wt fakebin <<< "$(make_spawn_case quota-unmeasurable "$id")"
  # A stale provider: quota-axi still reports a window, but its availability is
  # unknown. This is the shape a real expired credential produces.
  write_snapshot "$home/axi-json" "$(provider_block codex unknown - true all_models weekly)"
  write_catalog "$home/axi-models" "$(model_block gpt-5.1-codex codex - - all_models weekly)"

  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
    --harness codex --mode local-only --yolo off)
  status=$?

  expect_code 0 "$status" "an unmeasurable window must not refuse a launch"
  assert_contains "$out" "spawned $id" "the spawn did not complete"
  assert_contains "$out" "unknown rather than exhausted" \
    "the unmeasurable window was not disclosed as uncertainty"
  assert_present "$home/state/$id.meta" "the launched task recorded no metadata"
  pass "an unmeasurable window is a disclosed unknown that still launches"
}

test_unbound_harness_has_no_floor_and_launches() {
  local home fakebin out
  home=$(make_home unbound-harness)
  fakebin=$(make_quota_axi_stub "$home")
  # Every provider is exhausted, so only the missing binding can allow this.
  write_snapshot "$home/axi-json" \
    "$(provider_block codex known 0 false all_models weekly)" \
    "$(provider_block claude known 0 false all_models weekly)"

  out=$(run_guard "$home" "$fakebin" preflight --harness pi --model grok-4)
  expect_code 0 "$?" "a harness with no verified provider binding must not be refused"
  assert_contains "$out" "no measurable provider is bound to the pi harness" \
    "the unbound harness was not disclosed"
  assert_not_contains "$out" "refusing to launch" "an unbound harness produced a refusal"

  out=$(run_guard "$home" "$fakebin" preflight --harness codex --provider none)
  expect_code 0 "$?" "--provider none must state 'no measurable provider', not refuse"
  pass "a harness with no verified provider binding resolves to unknown and launches"
}

# --- 3. a failed read is uncertainty, not a verdict -------------------------

test_failed_read_is_uncertainty_not_a_verdict() {
  local home fakebin out report
  home=$(make_home failed-read)
  fakebin=$(make_quota_axi_stub "$home")
  printf 'fail\n' > "$home/axi-mode"

  out=$(run_guard "$home" "$fakebin" preflight --harness codex)
  expect_code 0 "$?" "a failed quota read must not be treated as exhausted"
  assert_contains "$out" "unknown rather than exhausted" \
    "a failed read was not disclosed as uncertainty"

  # And it is equally not "healthy": the report says unmeasurable rather than
  # silently omitting the provider or claiming a verdict for it.
  report=$(run_guard "$home" "$fakebin" report)
  assert_contains "$report" "unmeasurable" "a failed read was reported as measured"
  assert_not_contains "$report" "	ok	" "a failed read produced an ok verdict"
  assert_not_contains "$report" "	below	" "a failed read produced a below verdict"
  assert_grep 'status=failed' "$home/state/.quota-snapshot.meta" \
    "the failed read was not recorded as failed"
  pass "a failed quota read degrades to disclosed uncertainty rather than to either verdict"
}

test_missing_quota_axi_is_uncertainty_not_a_verdict() {
  local home dir out
  home=$(make_home no-quota-axi)
  # An empty fakebin plus a PATH that contains nothing else: quota-axi is absent.
  dir="$home/emptybin"
  mkdir -p "$dir"
  out=$(PATH="$dir:/usr/bin:/bin" FM_QUOTA_GUARD=on "$GUARD" preflight --harness codex \
    --state "$home/state" --config "$home/config" 2>&1)
  expect_code 0 "$?" "a missing quota-axi must not refuse a launch"
  assert_contains "$out" "unknown rather than exhausted" \
    "a missing quota-axi was not disclosed as uncertainty"
  pass "a missing quota-axi is disclosed uncertainty, never a verdict either way"
}

# --- 4. the guard never touches running work --------------------------------

test_guard_issues_no_control_or_teardown_against_running_work() {
  local home fakebin worker_pid meta_before status_before out recorder tool
  home=$(make_home no-lifecycle-action)
  fakebin=$(make_quota_axi_stub "$home")
  recorder="$home/lifecycle-calls"

  # Every provider exhausted: the strongest possible temptation to intervene.
  # Taken before the recorders go in, so they only ever observe the guard.
  write_snapshot "$home/axi-json" "$(provider_block codex known 0 false all_models weekly)"
  prime "$home" "$fakebin"

  # Anything that could stop a worker is shadowed by a recorder, including the
  # fleet's own control plane by name.
  for tool in kill pkill killall tmux herdr zellij cmux orca \
              fm-control.sh fm-teardown.sh fm-spawn.sh treehouse; do
    cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >> "$recorder"
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
  : > "$recorder"

  # A real live process standing in for a running worker, plus its task records.
  sleep 120 &
  worker_pid=$!
  fm_write_meta "$home/state/live-task-c1.meta" \
    "window=firstmate:fm-live-task-c1" \
    "endpoint_task_id=live-task-c1" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "pid=$worker_pid"
  printf 'working: validating\n' > "$home/state/live-task-c1.status"
  meta_before=$(cksum < "$home/state/live-task-c1.meta")
  status_before=$(cksum < "$home/state/live-task-c1.status")

  out=$(run_guard "$home" "$fakebin" heartbeat)
  assert_contains "$out" "under the 10% floor" "the heartbeat did not escalate the crossed floor"
  assert_contains "$out" "nothing already running is affected" \
    "the escalation did not state that running work is untouched"
  run_guard "$home" "$fakebin" preflight --harness codex >/dev/null 2>&1 || true

  kill -0 "$worker_pid" 2>/dev/null || fail "the guard killed a running worker process"
  [ ! -s "$recorder" ] || \
    fail "the guard invoked a lifecycle tool against running work:"$'\n'"$(cat "$recorder")"
  [ "$(cksum < "$home/state/live-task-c1.meta")" = "$meta_before" ] \
    || fail "the guard modified a running task's record"
  [ "$(cksum < "$home/state/live-task-c1.status")" = "$status_before" ] \
    || fail "the guard wrote to a running task's status log"
  assert_present "$home/state/live-task-c1.meta" "the guard removed a running task's record"

  kill "$worker_pid" 2>/dev/null || true
  wait "$worker_pid" 2>/dev/null || true
  pass "an exhausted provider stops new dispatch and escalates, and never acts on running work"
}

# --- 5. the heartbeat path stays bounded ------------------------------------

test_heartbeat_stays_bounded_when_the_read_hangs() {
  local home fakebin start elapsed out
  home=$(make_home bounded-hang)
  fakebin=$(make_quota_axi_stub "$home")
  printf 'hang\n' > "$home/axi-mode"

  # No snapshot at all: the worst case, where the heartbeat has nothing cached
  # and the only available read never returns.
  start=$(date +%s)
  out=$(PATH="$fakebin:$PATH" FM_TEST_AXI_DIR="$home" FM_QUOTA_GUARD=on \
    FM_QUOTA_REFRESH_TIMEOUT=3 "$GUARD" heartbeat \
    --state "$home/state" --config "$home/config" 2>&1)
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -le 5 ] || fail "the heartbeat blocked for ${elapsed}s on a hanging quota-axi"
  # A brand new home is a bootstrap transient, not a condition worth a wake.
  [ -z "$out" ] || fail "the first heartbeat of a fresh home woke firstmate: $out"

  # The read it handed off is itself bounded: it gives up on its own and records
  # why. Waiting for that record, rather than for the lock to appear, avoids
  # racing the child's own startup.
  local waited=0
  while [ ! -f "$home/state/.quota-snapshot.meta" ] && [ "$waited" -lt 30 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  assert_present "$home/state/.quota-snapshot.meta" \
    "the detached read never finished, so its bound did not hold"
  assert_grep 'status=failed' "$home/state/.quota-snapshot.meta" \
    "the bounded read did not record its expiry"
  assert_grep 'did not finish within' "$home/state/.quota-snapshot.meta" \
    "the expiry was not recorded as a timeout"
  [ ! -d "$home/state/.quota-refresh.lock" ] || \
    fail "the detached refresh did not release its single-flight lock"

  # With that recorded condition in place, the next heartbeat says so once.
  start=$(date +%s)
  out=$(PATH="$fakebin:$PATH" FM_TEST_AXI_DIR="$home" FM_QUOTA_GUARD=on \
    FM_QUOTA_REFRESH_TIMEOUT=3 "$GUARD" heartbeat \
    --state "$home/state" --config "$home/config" 2>&1)
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -le 5 ] || fail "the second heartbeat blocked for ${elapsed}s on a hanging quota-axi"
  assert_contains "$out" "cannot be measured right now" \
    "a persistently failing read was not disclosed"
  assert_contains "$out" "no floor is being enforced" \
    "the disclosure did not say the floor is unenforced"
  pass "the heartbeat stays bounded when the quota read hangs, and discloses the result"
}

test_heartbeat_stays_bounded_when_the_read_fails() {
  local home fakebin start elapsed
  home=$(make_home bounded-fail)
  fakebin=$(make_quota_axi_stub "$home")
  printf 'fail\n' > "$home/axi-mode"
  start=$(date +%s)
  run_guard "$home" "$fakebin" heartbeat >/dev/null 2>&1 || true
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -le 5 ] || fail "the heartbeat blocked for ${elapsed}s on a failing quota-axi"
  pass "the heartbeat stays bounded when the quota read fails outright"
}

# --- 6. stale windows and prepaid credits -----------------------------------

test_stale_windows_are_not_headroom() {
  local home fakebin report out
  home=$(make_home stale-not-headroom)
  fakebin=$(make_quota_axi_stub "$home")
  # A full-looking window that is stale. Reading the percentage would say 100%
  # remaining; the vendor's own availability status says it cannot be known.
  write_snapshot "$home/axi-json" "$(provider_block codex unknown 100 true all_models weekly)"
  prime "$home" "$fakebin"

  report=$(run_guard "$home" "$fakebin" report)
  assert_contains "$report" "codex	unknown" "a stale window was not reported as unknown"
  assert_not_contains "$report" "codex	ok" "a stale window was treated as headroom"

  out=$(run_guard "$home" "$fakebin" preflight --harness codex)
  expect_code 0 "$?" "a stale window must not refuse a launch"
  assert_contains "$out" "not measurable right now" "a stale window was not disclosed as uncertainty"
  pass "a stale window is diagnostic data, reported as unknown rather than as headroom"
}

test_prepaid_credits_balance_is_not_exhaustion() {
  local home fakebin report
  home=$(make_home credits-not-exhaustion)
  fakebin=$(make_quota_axi_stub "$home")
  # A zero prepaid balance alongside a healthy measured window. Reading
  # credits.remaining would call this exhausted; only the availability entry
  # describes the consumption window this guard governs.
  write_snapshot "$home/axi-json" "$(provider_block grok known 90 false all_products credits 0)"
  prime "$home" "$fakebin"

  report=$(run_guard "$home" "$fakebin" report)
  assert_contains "$report" "grok	ok" "a zero prepaid credits balance was read as exhaustion"
  run_guard "$home" "$fakebin" preflight --harness grok >/dev/null
  expect_code 0 "$?" "a zero prepaid credits balance refused a launch"
  pass "a prepaid credits balance is not exhaustion of the window the guard governs"
}

# --- 7. vendor-supplied granularity -----------------------------------------

test_named_model_window_bounds_only_that_model() {
  local home fakebin out
  home=$(make_home model-granularity)
  fakebin=$(make_quota_axi_stub "$home")
  # The provider-wide allowance is healthy; one named model has its own,
  # nearly-spent window. Only that model may be refused.
  write_snapshot "$home/axi-json" "$(provider_block codex known 90 false all_models weekly)"
  write_catalog "$home/axi-models" \
    "$(model_block spent-model codex known 2 model:spent modelweek)" \
    "$(model_block plain-model codex known 90 all_models weekly)"

  out=$(run_guard "$home" "$fakebin" preflight --harness codex --model spent-model)
  expect_code 1 "$?" "a named model under its own window must be refused"
  assert_contains "$out" "2% of its allowance is left" "the model-scoped bound was not applied"
  assert_contains "$out" "scope model:spent" "the refusal did not name the model-scoped window"

  out=$(run_guard "$home" "$fakebin" preflight --harness codex --model plain-model)
  expect_code 0 "$?" "a model bounded only by the healthy provider window must launch"

  out=$(run_guard "$home" "$fakebin" preflight --harness codex)
  expect_code 0 "$?" "the provider-wide allowance is healthy, so an unnamed model must launch"
  pass "a named-model window bounds only that model, and leaves its siblings alone"
}

test_provider_level_window_bounds_every_model() {
  local home fakebin out
  home=$(make_home provider-granularity)
  fakebin=$(make_quota_axi_stub "$home")
  # The provider-wide window is spent. Every model in the family is bounded by
  # it, including one the catalog has never heard of.
  write_snapshot "$home/axi-json" "$(provider_block codex known 1 false all_models weekly)"
  write_catalog "$home/axi-models" "$(model_block known-model codex known 1 all_models weekly)"

  out=$(run_guard "$home" "$fakebin" preflight --harness codex --model known-model)
  expect_code 1 "$?" "a catalogued model under the provider-wide window must be refused"

  out=$(run_guard "$home" "$fakebin" preflight --harness codex --model never-heard-of-it)
  expect_code 1 "$?" "an uncatalogued model is still bounded by the provider-wide window"
  assert_contains "$out" "not in quota-axi's catalog" \
    "the missing catalog entry was not disclosed"
  assert_contains "$out" "provider-wide allowance bounds this launch" \
    "the guard did not say which bound it fell back to"
  pass "a provider-level window bounds every model in the family, catalogued or not"
}

# --- 8. transitions, configuration, and the wake path -----------------------

test_heartbeat_escalates_by_transition_and_reports_recovery() {
  local home fakebin out
  home=$(make_home transitions)
  fakebin=$(make_quota_axi_stub "$home")
  write_snapshot "$home/axi-json" "$(provider_block codex known 4 false all_models weekly)"
  prime "$home" "$fakebin"

  out=$(run_guard "$home" "$fakebin" heartbeat)
  assert_contains "$out" "codex has 4% of its allowance left" "the crossed floor did not escalate"
  assert_contains "$out" "resets $RESET_AT" "the escalation did not say when the window resets"

  out=$(run_guard "$home" "$fakebin" heartbeat)
  [ -z "$out" ] || fail "a floor that stays crossed escalated again: $out"

  write_snapshot "$home/axi-json" "$(provider_block codex known 55 false all_models weekly)"
  prime "$home" "$fakebin"
  out=$(run_guard "$home" "$fakebin" heartbeat)
  assert_contains "$out" "back to 55% of its allowance" "a recovery was not reported"
  assert_contains "$out" "can take new work again" "the recovery did not say dispatch is unblocked"

  out=$(run_guard "$home" "$fakebin" heartbeat)
  [ -z "$out" ] || fail "a steady healthy provider produced a wake: $out"
  pass "the heartbeat escalates a crossed floor once and reports the recovery that clears it"
}

test_config_sets_floors_and_bindings_and_discloses_a_bad_line() {
  local home fakebin out
  home=$(make_home configured)
  fakebin=$(make_quota_axi_stub "$home")
  write_snapshot "$home/axi-json" \
    "$(provider_block codex known 40 false all_models weekly)" \
    "$(provider_block kimi known 40 false all_models weekly)"

  # Default floor unchanged would pass 40%; a per-provider floor must bite, an
  # "off" must excuse, and a launch binding must resolve an unbound harness.
  cat > "$home/config/quota-floor" <<'EOF'
# a fixture
floor default 5
floor codex 60
floor kimi off
launch opencode codex
EOF
  out=$(run_guard "$home" "$fakebin" preflight --harness codex)
  expect_code 1 "$?" "a per-provider floor did not apply"
  assert_contains "$out" "under the 60% floor" "the configured floor was not used"

  out=$(run_guard "$home" "$fakebin" preflight --harness kimi)
  expect_code 0 "$?" "'floor kimi off' did not excuse that provider"
  assert_contains "$out" "turns the floor off for kimi" "the excused provider was not disclosed"

  out=$(run_guard "$home" "$fakebin" preflight --harness opencode)
  expect_code 1 "$?" "a configured launch binding did not resolve the harness"
  assert_contains "$out" "config/quota-floor's launch binding" \
    "the refusal did not name where the binding came from"

  printf 'floor codex 60\nfloor codex notanumber\n' > "$home/config/quota-floor"
  out=$(run_guard "$home" "$fakebin" preflight --harness codex)
  expect_code 1 "$?" "a malformed line must not disable the good lines around it"
  assert_contains "$out" "line 2 floor 'notanumber' is not 0-100 or off" \
    "a malformed configuration line was accepted silently"
  pass "config/quota-floor sets floors and bindings, and a bad line is disclosed rather than swallowed"
}

test_floors_are_inherited_into_secondmate_homes() {
  # A secondmate's crewmates spend the same provider allowances the primary's do,
  # so the primary's floors and launch bindings must reach that home. Asserted
  # against the inheritance library's own declared set, the same way
  # tests/fm-trace-context-lib.test.sh pins its item.
  local set
  set=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-config-inherit-lib.sh" >/dev/null 2>&1
    printf '%s' "$FM_INHERITABLE_CONFIG"
  )
  case " $set " in
    *" quota-floor "*) : ;;
    *) fail "config/quota-floor must be in FM_INHERITABLE_CONFIG so secondmate homes keep the primary's floors"$'\n'"got: $set" ;;
  esac
  pass "config/quota-floor is inherited into secondmate homes, so one floor governs the whole fleet"
}

test_watcher_heartbeat_routes_a_crossed_floor_to_the_wake_queue() {
  local home fakebin out pid drain_out waited
  home=$(make_home watcher-wake)
  fakebin=$(make_quota_axi_stub "$home")
  out="$home/watch.out"
  drain_out="$home/drain.out"
  write_snapshot "$home/axi-json" "$(provider_block codex known 0 false all_models weekly)"
  # The watcher's first heartbeat must find a reading, not the bootstrap transient.
  prime "$home" "$fakebin"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TEST_AXI_DIR="$home" FM_QUOTA_GUARD=on \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
    "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the watcher did not wake for a crossed quota floor: $(cat "$out")"
  fi
  wait "$pid" 2>/dev/null || true

  assert_grep 'check: quota guard:' "$out" "the watcher did not report the floor as a check wake"
  assert_grep 'under the 10% floor' "$out" "the wake reason did not carry the measured floor"
  FM_STATE_OVERRIDE="$home/state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "draining the queue after the quota wake failed"
  assert_grep 'quota-floor' "$drain_out" "the quota wake was not recorded durably in the queue"
  pass "a crossed floor reaches the durable wake queue as a check, the path that escalates under away mode"
}

test_spawn_refuses_a_provider_under_its_floor
test_spawn_launches_on_an_unmeasurable_window
test_unbound_harness_has_no_floor_and_launches
test_failed_read_is_uncertainty_not_a_verdict
test_missing_quota_axi_is_uncertainty_not_a_verdict
test_guard_issues_no_control_or_teardown_against_running_work
test_heartbeat_stays_bounded_when_the_read_hangs
test_heartbeat_stays_bounded_when_the_read_fails
test_stale_windows_are_not_headroom
test_prepaid_credits_balance_is_not_exhaustion
test_named_model_window_bounds_only_that_model
test_provider_level_window_bounds_every_model
test_heartbeat_escalates_by_transition_and_reports_recovery
test_config_sets_floors_and_bindings_and_discloses_a_bad_line
test_floors_are_inherited_into_secondmate_homes
test_watcher_heartbeat_routes_a_crossed_floor_to_the_wake_queue
