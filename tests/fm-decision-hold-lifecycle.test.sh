#!/usr/bin/env bash
# End-to-end tests for durable captain-held decisions discovered by investigations
# and visual reviews.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved decision is report prose,
# no held backlog item or open status exists, and the authoritative Bearings view
# correctly omits it. Completion must now refuse before teardown can erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-scratch" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-decision regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved decision"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved decision is reproduced and completion refuses before loss"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind"
}

test_structured_holds_survive_teardown_and_route_resolution() {
  local home id route_hold access_hold before after json open show
  home=$(make_home durable-lifecycle)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
done: report and visual review complete
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_decisions "$home" complete "$id" route access > "$home/early-complete.out" 2> "$home/early-complete.err"; then
    fail "completion succeeded before unresolved decisions had captain holds"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"

  route_hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register route hold"
  [ "$route_hold" = "$id-decision-route" ] || fail "route hold identity was not deterministic: $route_hold"
  run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  if run_decisions "$home" complete "$id" route access > "$home/partial-complete.out" 2> "$home/partial-complete.err"; then
    fail "completion succeeded while one of two distinct decisions lacked a hold"
  fi
  access_hold=$(run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample) \
    || fail "could not register access hold"
  [ "$access_hold" = "$id-decision-access" ] || fail "access hold identity was not distinct: $access_hold"
  [ "$(grep -cE "^- \[ \] $route_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the route hold"
  [ "$(grep -cE "^- \[ \] $access_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "second decision did not retain one distinct backlog identity"

  run_decisions "$home" complete "$id" route access >/dev/null \
    || fail "shared investigation completion gate failed"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=access,route" "$home/state/$id.meta" "decision inventory was not deterministic"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close duplicate live status decisions: $open"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with captain-held decisions"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold" and .owner == "(main)"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == $route or .id == $access) | not)
  ' >/dev/null || fail "Bearings did not surface structured captain holds: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  ! grep -E "^- \[[ x]\] $id -" "$home/data/backlog.md" >/dev/null \
    || fail "origin remained in the live backlog after archival"
  grep -E "^- \[x\] $id -" "$home/data/done-archive.md" >/dev/null \
    || fail "origin was not durably archived"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held decision: $json"

  tasks_in "$home" add sample-route-implementation "Apply the selected sample route" \
    --kind ship --repo sample >/dev/null \
    || fail "could not create dependent work fixture"
  printf 'Use route north for the sample system.\n' > "$home/route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation > "$home/early-resolve.out" 2> "$home/early-resolve.err"; then
    fail "captain hold closed before dependent work had a durable routing edge"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "failed routing attempt closed the hold"
  assert_contains "$show" "held: yes" "failed routing attempt released the hold"
  tasks_in "$home" block sample-route-implementation --by "$route_hold" >/dev/null \
    || fail "could not route dependent work behind the decision hold"
  tasks_in "$home" add sample-route-followup "Check the selected sample route" \
    --kind ship --repo sample --blocked-by "$route_hold" >/dev/null \
    || fail "could not create second dependent work fixture"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = unblock ] && [ "${2:-}" = sample-route-implementation ] \
  && [ ! -f "$FM_HOME/unblock-failed-once" ]; then
  : > "$FM_HOME/unblock-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-route.out" 2> "$home/partial-route.err"; then
    fail "resolution succeeded after a partial dependent-routing failure"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "partial routing failure closed the hold"
  show=$(tasks_in "$home" show sample-route-followup --full)
  assert_contains "$show" "blocked: no" "partial routing fixture did not release its first dependent"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: yes" "partial routing fixture unexpectedly released its second dependent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-followup > "$home/reduced-retry.out" 2> "$home/reduced-retry.err"; then
    fail "partial resolution retry accepted a reduced routed task set"
  fi
  printf 'Use route south for the sample system.\n' > "$home/changed-route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-drifted-decision.out" 2> "$home/partial-drifted-decision.err"; then
    fail "partial resolution retry accepted a different captain decision"
  fi
  tasks_in "$home" "done" sample-route-followup >/dev/null \
    || fail "could not complete already-routed dependent work"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "could not resume and complete partial decision routing"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "identical resolution retry was not idempotent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/drifted-decision.out" 2> "$home/drifted-decision.err"; then
    fail "resolution retry accepted a different captain decision"
  fi
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation \
    > "$home/drifted-routes.out" 2> "$home/drifted-routes.err"; then
    fail "resolution retry accepted a different routed task set"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: done" "resolved hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "resolved hold lost the decision record"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: no" "recorded decision did not release dependent work"
  json=$(run_bearings "$home") || fail "Bearings failed after decision resolution"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route) | not)
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.gates | any(.id == "sample-route-implementation"))
      and (.decisions_open | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "resolved or decision-like report prose produced a false hold: $json"
  pass "captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close"
}

test_scout_teardown_always_requires_inventory_verification() {
  local home id
  home=$(make_home unconditional-teardown)
  id=sample-absent-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample absent review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  if run_teardown "$home" "$id" > "$home/absent-teardown.out" 2> "$home/absent-teardown.err"; then
    fail "scout teardown skipped verification when its backlog task was absent"
  fi
  assert_present "$home/state/$id.meta" "refused absent-task teardown removed metadata"

  home=$(make_home unavailable-teardown)
  id=sample-unavailable-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample unavailable review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_teardown "$home" "$id" > "$home/unavailable-teardown.out" 2> "$home/unavailable-teardown.err"; then
    fail "scout teardown skipped verification when tasks-axi was unavailable"
  fi
  assert_present "$home/state/$id.meta" "refused unavailable-task teardown removed metadata"
  pass "non-forced scout teardown always requires durable inventory verification"
}

test_origin_slug_validation_precedes_path_construction() {
  local home escaped
  home=$(make_home origin-validation)
  escaped="$home/escaped-origin.meta"
  printf 'sentinel=unchanged\n' > "$escaped"
  if run_decisions "$home" complete ../escaped-origin --none \
    > "$home/invalid-complete.out" 2> "$home/invalid-complete.err"; then
    fail "completion accepted an origin path traversal"
  fi
  if run_decisions "$home" verify ../escaped-origin \
    > "$home/invalid-verify.out" 2> "$home/invalid-verify.err"; then
    fail "verification accepted an origin path traversal"
  fi
  [ "$(cat "$escaped")" = "sentinel=unchanged" ] \
    || fail "invalid origin changed metadata outside the state directory"
  pass "completion and verification validate origins before constructing paths"
}

test_visual_review_uses_shared_completion_owner() {
  local home id hold json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  hold=$(run_decisions "$home" hold "$id" layout \
    --title "Choose the sample layout" --reason "captain layout choice pending" --repo sample) \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_decisions "$home" complete "$id" layout >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  [ "$hold" = "$id-decision-layout" ] || fail "visual review used a separate identity policy"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.id == $hold and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same decision-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-decision inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-decision inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false hold: $json"
  pass "resolved findings and decision-like prose do not create false holds"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_decisions "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate origin hold json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  hold=$(run_decisions "$mate" hold "$origin" release \
    --title "Choose the sample release" --reason "captain release choice pending" --repo sample) \
    || fail "secondmate-owned hold creation failed"
  run_decisions "$mate" complete "$origin" release >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read secondmate hold"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold" and (.id | endswith($hold)))
  ' >/dev/null || fail "secondmate captain hold did not surface with authoritative owner: $json"
  assert_no_grep "$hold" "$parent/data/backlog.md" "secondmate hold leaked into the main backlog"
  assert_grep "$hold" "$mate/data/backlog.md" "secondmate hold left its authoritative backlog"
  pass "main-home and secondmate-home captain holds remain correctly routed"
}

# tasks-axi quotes multi-entry blocked_by values as "a,b,c". resolve must strip
# those surrounding quotes before comma-boundary membership so the first and last
# list elements match, not only middle elements.
test_resolve_matches_quoted_blocked_by_edges() {
  local home origin hold_first hold_mid hold_last hold_absent show
  home=$(make_home quoted-blocked-by-edges)
  origin=sample-quote-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Quoted blocked_by edge review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create quote-edge origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Quote edge review\n\nThree edge decisions and one absent control.\n' > "$home/data/$origin/report.md"

  hold_first=$(run_decisions "$home" hold "$origin" edge-first \
    --title "First edge decision" --reason "captain first pending" --repo sample) \
    || fail "could not register first-edge hold"
  hold_mid=$(run_decisions "$home" hold "$origin" edge-mid \
    --title "Middle edge decision" --reason "captain mid pending" --repo sample) \
    || fail "could not register mid-edge hold"
  hold_last=$(run_decisions "$home" hold "$origin" edge-last \
    --title "Last edge decision" --reason "captain last pending" --repo sample) \
    || fail "could not register last-edge hold"
  hold_absent=$(run_decisions "$home" hold "$origin" edge-absent \
    --title "Absent edge decision" --reason "captain absent pending" --repo sample) \
    || fail "could not register absent-edge hold"

  tasks_in "$home" add pad-a "Pad A" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-a blocker"
  tasks_in "$home" add pad-b "Pad B" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-b blocker"

  tasks_in "$home" add dep-first "Dep first position" --kind ship --repo sample >/dev/null \
    || fail "could not create first-position dependent"
  tasks_in "$home" block dep-first --by "$hold_first" >/dev/null || fail "could not block dep-first by first hold"
  tasks_in "$home" block dep-first --by pad-a >/dev/null || fail "could not block dep-first by pad-a"
  tasks_in "$home" block dep-first --by pad-b >/dev/null || fail "could not block dep-first by pad-b"
  show=$(tasks_in "$home" show dep-first --full)
  assert_contains "$show" "blocked_by: \"$hold_first,pad-a,pad-b\"" \
    "first-position fixture must quote multi-entry blocked_by"
  printf 'Decide first edge.\n' > "$home/d-first.txt"
  if ! run_decisions "$home" resolve "$origin" edge-first --decision-file "$home/d-first.txt" \
    --routed-to dep-first > "$home/first.out" 2> "$home/first.err"; then
    fail "resolve failed when hold id is FIRST in quoted blocked_by: $(cat "$home/first.err")"
  fi

  tasks_in "$home" add dep-mid "Dep mid position" --kind ship --repo sample >/dev/null \
    || fail "could not create mid-position dependent"
  tasks_in "$home" block dep-mid --by pad-a >/dev/null || fail "could not block dep-mid by pad-a"
  tasks_in "$home" block dep-mid --by "$hold_mid" >/dev/null || fail "could not block dep-mid by mid hold"
  tasks_in "$home" block dep-mid --by pad-b >/dev/null || fail "could not block dep-mid by pad-b"
  show=$(tasks_in "$home" show dep-mid --full)
  assert_contains "$show" "blocked_by: \"pad-a,$hold_mid,pad-b\"" \
    "middle-position fixture must quote multi-entry blocked_by"
  printf 'Decide mid edge.\n' > "$home/d-mid.txt"
  if ! run_decisions "$home" resolve "$origin" edge-mid --decision-file "$home/d-mid.txt" \
    --routed-to dep-mid > "$home/mid.out" 2> "$home/mid.err"; then
    fail "resolve failed when hold id is MIDDLE in quoted blocked_by: $(cat "$home/mid.err")"
  fi

  tasks_in "$home" add dep-last "Dep last position" --kind ship --repo sample >/dev/null \
    || fail "could not create last-position dependent"
  tasks_in "$home" block dep-last --by pad-a >/dev/null || fail "could not block dep-last by pad-a"
  tasks_in "$home" block dep-last --by pad-b >/dev/null || fail "could not block dep-last by pad-b"
  tasks_in "$home" block dep-last --by "$hold_last" >/dev/null || fail "could not block dep-last by last hold"
  show=$(tasks_in "$home" show dep-last --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b,$hold_last\"" \
    "last-position fixture must quote multi-entry blocked_by"
  printf 'Decide last edge.\n' > "$home/d-last.txt"
  if ! run_decisions "$home" resolve "$origin" edge-last --decision-file "$home/d-last.txt" \
    --routed-to dep-last > "$home/last.out" 2> "$home/last.err"; then
    fail "resolve failed when hold id is LAST in quoted blocked_by: $(cat "$home/last.err")"
  fi

  tasks_in "$home" add dep-absent "Dep absent control" --kind ship --repo sample >/dev/null \
    || fail "could not create absent-control dependent"
  tasks_in "$home" block dep-absent --by pad-a >/dev/null || fail "could not block dep-absent by pad-a"
  tasks_in "$home" block dep-absent --by pad-b >/dev/null || fail "could not block dep-absent by pad-b"
  show=$(tasks_in "$home" show dep-absent --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b\"" \
    "absent-control fixture must quote multi-entry blocked_by without the hold id"
  printf 'Decide absent edge.\n' > "$home/d-absent.txt"
  if run_decisions "$home" resolve "$origin" edge-absent --decision-file "$home/d-absent.txt" \
    --routed-to dep-absent > "$home/absent.out" 2> "$home/absent.err"; then
    fail "resolve succeeded when hold id is genuinely absent from blocked_by"
  fi
  assert_grep "not durably blocked by" "$home/absent.err" \
    "absent id must fail with durable-block error"
  show=$(tasks_in "$home" show "$hold_absent" --full)
  assert_contains "$show" "state: queued" "failed absent resolve must leave the hold open"
  assert_contains "$show" "held: yes" "failed absent resolve must leave the hold held"

  pass "resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id"
}

# --- structured decision record ---------------------------------------------

classify() {  # <function> <args...>
  bash -c '. "$1"; shift; "$@"' _ "$ROOT/bin/fm-classify-lib.sh" "$@"
}

record_origin() {  # <home> <origin-id>
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample canary" --kind scout --repo sample --start >/dev/null \
    || fail "could not create record-test origin"
  write_origin_meta "$home" "$id"
  printf '# Sample canary\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
}

# The authored fields for the canary decision, reused across the record tests.
canary_record_flags=(
  --question "Send one real application to Fielmann?"
  --consequence "One submission to a real employer. It cannot be recalled."
  --recommend hold
  --option "hold/Hold"
  --option "send/Send it/destructive"
  --expires-at 2026-08-01T09:00:00Z
  --sensitivity private
  --safe-preview "Bewerbungsbot: one decision"
)
canary_reason="The canary would post one real application to one real employer and the employer list is still unverified"

test_structured_record_is_authored_stored_and_read_back() {
  local home id hold json line note block
  home=$(make_home structured-record)
  id=sample-canary-review
  record_origin "$home" "$id"

  hold=$(run_decisions "$home" hold "$id" one-send --title "Canary send" --repo sample \
    --reason "$canary_reason" "${canary_record_flags[@]}") \
    || fail "could not register a structured captain hold"
  [ "$hold" = "$id-decision-one-send" ] || fail "structured hold changed the identity contract: $hold"

  run_decisions "$home" record "$id" one-send > "$home/record.out" \
    || fail "could not read the structured record back"
  assert_grep "question: Send one real application to Fielmann?" "$home/record.out" "question was not stored"
  assert_grep "consequence: One submission to a real employer" "$home/record.out" "consequence was not stored"
  assert_grep "recommend: hold" "$home/record.out" "recommendation was not stored"
  assert_grep "option: hold/Hold" "$home/record.out" "first option was not stored"
  assert_grep "option: send/Send it/destructive" "$home/record.out" "destructive option was not stored"
  assert_grep "expires_at: 2026-08-01T09:00:00Z" "$home/record.out" "expiry was not stored"
  assert_grep "sensitivity: private" "$home/record.out" "sensitivity was not stored"
  assert_grep "safe_preview: Bewerbungsbot: one decision" "$home/record.out" "safe preview was not stored"
  assert_grep "why: $canary_reason" "$home/record.out" "the existing prose did not survive as the why disclosure"

  json=$(run_decisions "$home" record "$id" one-send --json) || fail "could not read the record as JSON"
  printf '%s' "$json" | jq -e '
    .question == "Send one real application to Fielmann?"
      and .recommend == "hold"
      and (.options | length) == 2
      and .options[0] == {id: "hold", label: "Hold", destructive: false}
      and .options[1] == {id: "send", label: "Send it", destructive: true}
      and .expires_at == "2026-08-01T09:00:00Z"
      and .sensitivity == "private"
      and .safe_preview == "Bewerbungsbot: one decision"
      and (.why | length) > 80
  ' >/dev/null || fail "the record did not render as a structured decision: $json"

  # A retry with no record options preserves the record instead of erasing it.
  run_decisions "$home" hold "$id" one-send --title "Canary send" --repo sample \
    --reason "$canary_reason" >/dev/null || fail "record-preserving retry failed"
  assert_contains "$(run_decisions "$home" record "$id" one-send)" "safe_preview: Bewerbungsbot" \
    "a retry without record options erased the authored record"

  # The same record travels on a status line, and every pre-record parser reads
  # that line exactly as it reads a prose-only one.
  line=$(run_decisions "$home" status-line needs-decision one-send "${canary_record_flags[@]}" \
    --why "$canary_reason") || fail "could not compose a structured status line"
  [ "$(classify status_line_verb "$line")" = needs-decision ] || fail "record line broke the verb parser"
  [ "$(classify _fm_decision_key "$line")" = one-send ] || fail "record line broke the key parser"
  note=$(classify status_line_note "$line")
  [ "$note" = "$canary_reason" ] || fail "the record leaked into the human-readable summary: $note"
  block=$(classify status_line_record "$line")
  [ "$(classify decision_record_get "$block" question)" = "Send one real application to Fielmann?" ] \
    || fail "the status line did not carry the question"
  [ "$(classify decision_record_get "$block" option)" = "hold/Hold
send/Send it/destructive" ] || fail "the status line did not carry both options"
  classify status_is_captain_relevant "$line" || fail "a structured needs-decision line stopped being captain-relevant"

  printf '%s\n' "$line" > "$home/state/$id.status"
  assert_contains "$(classify status_open_decisions "$home/state/$id.status")" \
    "one-send	needs-decision	$canary_reason" "the decision fold did not summarise the record line as prose"
  pass "an authored decision record is stored, read back as fields and JSON, and travels on a status line"
}

test_record_ceilings_are_enforced() {
  local home id base
  home=$(make_home record-ceilings)
  id=sample-ceiling-review
  record_origin "$home" "$id"
  base=(--why "the sample evidence lives in the report")

  refuse_line() {  # <expected-error> <flags...>
    local expect=$1
    shift
    if run_decisions "$home" status-line needs-decision c "$@" > "$home/line.out" 2> "$home/line.err"; then
      fail "an unrenderable record was accepted: $*"
    fi
    assert_grep "$expect" "$home/line.err" "wrong refusal for: $*"
  }

  # A 52-character question is renderable; a 53-character one is not.
  run_decisions "$home" status-line needs-decision c \
    --question "Send one real application to one real employer now?" \
    --consequence "One real submission" --recommend hold \
    --option "hold/Hold everything!" --option "send/Send it/destructive" \
    --sensitivity normal --safe-preview "one canary decision waits" "${base[@]}" >/dev/null \
    || fail "a question or label exactly at the ceiling was refused"
  refuse_line "question is 53 characters, ceiling is 52" \
    --question "Send one real application to one real employer today?" \
    --consequence "One real submission" --recommend hold \
    --option "hold/Hold" --option "send/Send it/destructive" \
    --sensitivity normal --safe-preview "one canary decision waits" "${base[@]}"
  refuse_line "consequence is 101 characters, ceiling is 100" \
    --question "Send it?" --consequence "$(printf 'c%.0s' $(seq 101))" --recommend hold \
    --option "hold/Hold" --option "send/Send it/destructive" \
    --sensitivity normal --safe-preview "one canary decision waits" "${base[@]}"
  refuse_line "safe_preview is 43 characters, ceiling is 42" \
    --question "Send it?" --consequence "One real submission" --recommend hold \
    --option "hold/Hold" --option "send/Send it/destructive" \
    --sensitivity normal --safe-preview "$(printf 'p%.0s' $(seq 43))" "${base[@]}"
  refuse_line "option hold label is 17 characters, ceiling is 16" \
    --question "Send it?" --consequence "One real submission" --recommend hold \
    --option "hold/Hold everything!!" --option "send/Send it/destructive" \
    --sensitivity normal --safe-preview "one canary decision waits" "${base[@]}"
  refuse_line "at least 2 options" \
    --question "Send it?" --consequence "One real submission" --recommend hold \
    --option "hold/Hold" --sensitivity normal --safe-preview "one canary decision waits" "${base[@]}"
  refuse_line "at most 4 options" \
    --question "Send it?" --consequence "One real submission" --recommend hold \
    --option "hold/Hold" --option "a/A" --option "b/B" --option "c/C" --option "d/D" \
    --sensitivity normal --safe-preview "one canary decision waits" "${base[@]}"
  # The first action is what an Apple Watch double tap fires without confirmation.
  refuse_line "first option must not be destructive" \
    --question "Send it?" --consequence "One real submission" --recommend send \
    --option "send/Send it/destructive" --option "hold/Hold" \
    --sensitivity normal --safe-preview "one canary decision waits" "${base[@]}"
  refuse_line "recommend must name one of the options" \
    --question "Send it?" --consequence "One real submission" --recommend later \
    --option "hold/Hold" --option "send/Send it/destructive" \
    --sensitivity normal --safe-preview "one canary decision waits" "${base[@]}"
  refuse_line "duplicate option id" \
    --question "Send it?" --consequence "One real submission" --recommend hold \
    --option "hold/Hold" --option "hold/Wait" \
    --sensitivity normal --safe-preview "one canary decision waits" "${base[@]}"
  refuse_line "expires_at must be absolute UTC" \
    --question "Send it?" --consequence "One real submission" --recommend hold \
    --option "hold/Hold" --option "send/Send it/destructive" --expires-at tomorrow \
    --sensitivity normal --safe-preview "one canary decision waits" "${base[@]}"
  refuse_line "sensitivity must be one of" \
    --question "Send it?" --consequence "One real submission" --recommend hold \
    --option "hold/Hold" --option "send/Send it/destructive" \
    --sensitivity urgent --safe-preview "one canary decision waits" "${base[@]}"
  refuse_line "consequence is required" \
    --question "Send it?" --recommend hold \
    --option "hold/Hold" --option "send/Send it/destructive" \
    --sensitivity normal --safe-preview "one canary decision waits" "${base[@]}"

  # The ceilings hold on the registration path, not only on the status line.
  if run_decisions "$home" hold "$id" over-budget --title "Over budget" --repo sample \
    --reason "$canary_reason" \
    --question "Send one real application to one real employer today?" \
    --consequence "One real submission" --recommend hold \
    --option "hold/Hold" --option "send/Send it/destructive" \
    --sensitivity normal --safe-preview "one canary decision waits" \
    > "$home/over.out" 2> "$home/over.err"; then
    fail "an over-budget question was registered as a captain decision"
  fi
  assert_grep "ceiling is 52" "$home/over.err" "the registration path did not enforce the ceiling"
  assert_no_grep "over-budget" "$home/data/backlog.md" "a refused record still created a backlog identity"
  pass "every record ceiling and option rule is enforced, not merely documented"
}

test_safe_preview_cannot_carry_evidence() {
  local home why
  home=$(make_home safe-preview)
  why="the vault says the employer list is unverified and the token expires soon"

  refuse_preview() {  # <expected-error> <preview> [sensitivity]
    local expect=$1 preview=$2 sensitivity=${3:-normal}
    if run_decisions "$home" status-line needs-decision p \
      --question "Send it?" --consequence "One real submission" --recommend hold \
      --option "hold/Hold" --option "send/Send it/destructive" \
      --sensitivity "$sensitivity" --safe-preview "$preview" --why "$why" \
      > "$home/p.out" 2> "$home/p.err"; then
      fail "a leaking safe_preview was accepted: $preview"
    fi
    assert_grep "$expect" "$home/p.err" "wrong refusal for preview: $preview"
  }

  refuse_preview "must not contain a link" "see https://sample.example/x"
  refuse_preview "must not contain an address or handle" "ask sample@example.com"
  refuse_preview "must not contain a path" "see ~/data/report.md"
  refuse_preview "must not contain a path" "see data/sample/report.md"
  refuse_preview "must not contain an identifier or amount" "invoice 4711299 waits"
  refuse_preview "must not contain an opaque token" "key aB3xQ9zL7mP2rT5vW8yC"
  refuse_preview "not copied out of the why prose" "the employer list is unverified"
  refuse_preview "without | { } \" \\ or invisible characters" "$(printf 'one \xE2\x81\xA3decision')"
  refuse_preview "needs a safe_preview distinct from its question" "Send it?" private

  # An authored line survives every one of those checks.
  run_decisions "$home" status-line needs-decision p \
    --question "Send it?" --consequence "One real submission" --recommend hold \
    --option "hold/Hold" --option "send/Send it/destructive" \
    --sensitivity private --safe-preview "Bewerbungsbot: one decision" --why "$why" >/dev/null \
    || fail "an authored safe preview was refused"
  pass "safe_preview refuses links, handles, paths, identifiers, tokens, and copied evidence"
}

test_sensitivity_classifies_but_grants_nothing() {
  local home id level hold show consumers
  home=$(make_home sensitivity-authority)
  id=sample-sensitivity-review
  record_origin "$home" "$id"

  for level in normal private secret; do
    hold=$(run_decisions "$home" hold "$id" "$level" --title "Sensitivity $level" --repo sample \
      --reason "$canary_reason" \
      --question "Send one real application to Fielmann?" \
      --consequence "One submission to a real employer. It cannot be recalled." \
      --recommend hold --option "hold/Hold" --option "send/Send it/destructive" \
      --sensitivity "$level" --safe-preview "Bewerbungsbot: $level call") \
      || fail "could not register a $level decision"
    show=$(tasks_in "$home" show "$hold" --full)
    # Identical gate state at every classification: nothing about the captain's
    # authority, the hold, or its closing conditions moves with sensitivity.
    assert_contains "$show" "state: queued" "$level changed the decision state"
    assert_contains "$show" "held: yes" "$level changed whether the decision is held"
    assert_contains "$show" "kind: captain" "$level changed the decision owner"
    assert_contains "$show" "hold_kind: captain" "$level changed who the decision is held for"
  done

  # A secret decision still closes only through the same evidence and routing.
  printf 'Hold the canary.\n' > "$home/secret-decision.txt"
  tasks_in "$home" add sample-secret-followup "Apply the canary decision" --kind ship --repo sample >/dev/null
  if run_decisions "$home" resolve "$id" secret --decision-file "$home/secret-decision.txt" \
    --routed-to sample-secret-followup > "$home/secret.out" 2> "$home/secret.err"; then
    fail "a secret classification let a decision close without a durable routing edge"
  fi

  # Nothing outside the record's owner and its grammar may read sensitivity, so a
  # future authority path cannot start branching on it unnoticed.
  consumers=$(cd "$ROOT" && grep -rl 'sensitivity' bin/ | LC_ALL=C sort | paste -sd' ' -)
  [ "$consumers" = "bin/fm-classify-lib.sh bin/fm-decision-hold.sh" ] \
    || fail "sensitivity reached a script outside the record owner and its grammar: $consumers"
  pass "sensitivity classifies a decision and grants no authority anywhere"
}

# The live fleet carried 118 open captain decisions on 2026-07-29, recorded as one
# prose hold reason each, measured at min 60, median 310 and max 1457 characters.
# Every one of them must keep working untouched, so this fixture reproduces that
# distribution and drives the whole lifecycle over it.
test_existing_prose_decisions_keep_working_untouched() {
  local home id length key hold json before after reason
  home=$(make_home prose-compatibility)
  id=sample-legacy-review
  record_origin "$home" "$id"
  printf 'needs-decision [key=legacy-60]: choose route north or route south\n' > "$home/state/$id.status"

  for length in 60 100 310 406 1271 1457; do
    key="legacy-$length"
    reason="captain decision pending; $(printf 'e%.0s' $(seq $((length - 26))))"
    [ "${#reason}" = "$length" ] || fail "fixture reason length drifted: ${#reason} != $length"
    hold=$(run_decisions "$home" hold "$id" "$key" --title "Legacy decision $length" \
      --repo sample --reason "$reason") \
      || fail "a $length-character prose decision could no longer be registered"
    [ "$hold" = "$id-decision-$key" ] || fail "prose decision identity drifted: $hold"
    assert_grep "hold: $reason" "$home/data/backlog.md" \
      "the $length-character prose reason was not preserved byte for byte"
    if run_decisions "$home" record "$id" "$key" > "$home/legacy.out" 2> "$home/legacy.err"; then
      fail "a prose-only decision reported a structured record it never had"
    fi
    assert_grep "carries no structured decision record" "$home/legacy.err" \
      "a prose-only decision failed for the wrong reason"
  done

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed on prose-only decisions"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "reading prose-only decisions rewrote the backlog"
  printf '%s' "$json" | jq -e --arg id "$id" '
    [.decisions_open[] | select(.id | startswith($id + "-decision-legacy-"))] | length == 6
  ' >/dev/null || fail "prose-only decisions stopped surfacing as captain decisions: $json"

  # The prose-only status line still folds exactly as it always has.
  assert_contains "$(classify status_open_decisions "$home/state/$id.status")" \
    "legacy-60	needs-decision	choose route north or route south" \
    "a prose-only status decision changed shape"

  run_decisions "$home" complete "$id" legacy-60 legacy-100 legacy-310 legacy-406 legacy-1271 legacy-1457 >/dev/null \
    || fail "the completion gate rejected prose-only decisions"
  run_decisions "$home" verify "$id" >/dev/null || fail "verification rejected prose-only decisions"

  tasks_in "$home" add sample-legacy-followup "Apply the legacy decision" --kind ship --repo sample \
    --blocked-by "$id-decision-legacy-1457" >/dev/null || fail "could not route legacy dependent work"
  printf 'Take route north.\n' > "$home/legacy-decision.txt"
  run_decisions "$home" resolve "$id" legacy-1457 --decision-file "$home/legacy-decision.txt" \
    --routed-to sample-legacy-followup >/dev/null \
    || fail "a prose-only decision could no longer be resolved"
  assert_contains "$(tasks_in "$home" show "$id-decision-legacy-1457" --full)" "state: done" \
    "a prose-only decision did not close"
  pass "prose-only captain decisions at the live length distribution keep working untouched"
}

test_record_survives_resolution() {
  local home id hold
  home=$(make_home record-resolution)
  id=sample-resolved-record
  record_origin "$home" "$id"
  hold=$(run_decisions "$home" hold "$id" one-send --title "Canary send" --repo sample \
    --reason "$canary_reason" "${canary_record_flags[@]}") \
    || fail "could not register the structured hold"
  tasks_in "$home" add sample-record-followup "Apply the canary decision" --kind ship --repo sample \
    --blocked-by "$hold" >/dev/null || fail "could not route dependent work"
  printf 'Hold the canary.\n' > "$home/record-decision.txt"
  run_decisions "$home" resolve "$id" one-send --decision-file "$home/record-decision.txt" \
    --routed-to sample-record-followup >/dev/null || fail "could not resolve the structured decision"
  assert_contains "$(tasks_in "$home" show "$hold" --full)" "Decision record v1:" \
    "resolution erased the authored record"
  assert_contains "$(run_decisions "$home" record "$id" one-send)" "question: Send one real application" \
    "a resolved decision could no longer be rendered"
  run_decisions "$home" resolve "$id" one-send --decision-file "$home/record-decision.txt" \
    --routed-to sample-record-followup >/dev/null || fail "resolution stopped being idempotent"
  pass "an authored record survives resolution and stays renderable"
}

test_uninventoried_report_decision_refuses_completion

test_scout_teardown_always_requires_inventory_verification
test_structured_holds_survive_teardown_and_route_resolution
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
test_structured_record_is_authored_stored_and_read_back
test_record_ceilings_are_enforced
test_safe_preview_cannot_carry_evidence
test_sensitivity_classifies_but_grants_nothing
test_existing_prose_decisions_keep_working_untouched
test_record_survives_resolution
