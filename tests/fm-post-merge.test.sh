#!/usr/bin/env bash
# Behavior tests for bin/fm-post-merge.sh, the post-merge watch, witness, and
# automatic revert, and for the cleanup rule bin/fm-post-merge-lib.sh owns.
#
# A pull request task runs against a fake `gh` that serves the merged pull
# request, the check runs and commit statuses of any commit, the revert
# mutation, and the revert pull request, and against a fake merge command in
# place of bin/fm-pr-merge.sh that records what it was asked to merge. A
# local-only task runs against a real git repository through the real
# bin/fm-merge-local.sh. The backlog is a real tasks-axi markdown backlog in a
# temporary home, so a revert is seen returning the item to Queued.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PM="$ROOT/bin/fm-post-merge.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-post-merge)
fm_git_identity

MERGE_SHA=1111111111111111111111111111111111111111
HEAD_SHA=3333333333333333333333333333333333333333
REVERT_SHA=2222222222222222222222222222222222222222
PR_URL=https://github.com/acme/widget/pull/7
REVERT_URL=https://github.com/acme/widget/pull/8

W_HOME=
W_FAKE=
W_BIN=
W_ID=

# A fake gh serving pull requests and checks from files under $FAKE_GH_DIR:
# pr-<n>.json for `gh pr view`, checks-<sha>.json and status-<sha>.json for the
# commit check endpoints (both empty when absent), and pr-list.json for
# `gh pr list` (newest first, filtered by --head and cut to --limit, default 30,
# as gh does; it fails while pr-list-fail exists). The revert mutation opens pull request 8 on revert-7-feature
# with head $REVERT_SHA and a message naming $MERGE_SHA, or fails when graphql-fail exists.
write_fake_gh() {  # <fakebin>
  cat > "$1/gh" <<'EOF'
#!/usr/bin/env bash
d=$FAKE_GH_DIR
printf '%s\n' "$*" >> "$d/calls"
jq_arg() {
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --jq ]; then printf '%s\n' "$2"; return 0; fi
    shift
  done
  printf '.\n'
}
case "$1 ${2:-}" in
  "pr view")
    for arg in "$@"; do
      case "$arg" in
        *isInMergeQueue*)
          echo "Unknown JSON field: isInMergeQueue" >&2
          exit 1
          ;;
      esac
    done
    f="$d/pr-${3##*/}.json"
    [ -f "$f" ] || { echo "no such pull request" >&2; exit 1; }
    cat "$f"
    ;;
  "pr list")
    [ ! -e "$d/pr-list-fail" ] || { echo "HTTP 502: listing unavailable" >&2; exit 1; }
    [ -f "$d/pr-list.json" ] || echo '[]' > "$d/pr-list.json"
    head='' limit=30
    set -- "$@" --
    while [ "$1" != -- ]; do
      case "$1" in
        --head) head=$2; shift ;;
        --limit) limit=$2; shift ;;
      esac
      shift
    done
    jq -c --arg head "$head" --argjson limit "$limit" \
      '[ .[] | select($head == "" or .headRefName == $head) ] | .[:$limit]' "$d/pr-list.json"
    ;;
  "api graphql")
    query=
    for arg in "$@"; do
      case "$arg" in
        query=*) query=${arg#query=} ;;
      esac
    done
    if [[ "$query" == *'pullRequest(number:'* ]]; then
      field_mode=
      for arg in "$@"; do
        case "$arg" in
          -f|-F) field_mode=$arg ;;
          owner=*|repo=*)
            value=${arg#*=}
            if [ "$field_mode" = -F ] && [[ "$value" =~ ^([0-9]+|true|false|null)$ ]]; then
              echo 'GraphQL: expected String variable' >&2
              exit 1
            fi
            ;;
        esac
      done
      jq -c '{data:{repository:{pullRequest:.}}}' "$d/pr-7.json"
      exit 0
    fi
    [ ! -e "$d/graphql-fail" ] || { echo "GraphQL: revert refused" >&2; exit 1; }
    printf '{"state":"OPEN","headRefOid":"%s","commits":[{"messageHeadline":"Revert change","messageBody":"This reverts commit %s."}]}\n' \
      "$FAKE_REVERT_SHA" "$FAKE_MERGE_SHA" > "$d/pr-8.json"
    printf '[{"url":"%s","headRefName":"revert-7-feature"}]\n' "$FAKE_REVERT_URL" > "$d/pr-list.json"
    printf '%s\n' "$FAKE_REVERT_URL"
    ;;
  "api --hostname")
    path=
    for arg in "$@"; do case "$arg" in repos/*) path=$arg ;; esac; done
    case "$path" in
      */rules/branches/*) f="$d/rules-main.json" ;;
      */branches/*) f="$d/branch-main.json" ;;
      */commits/*/check-runs*)
        sha=${path#*/commits/}
        sha=${sha%%/*}
        f="$d/checks-$sha.json"
        empty='{"check_runs":[]}'
        ;;
      */commits/*/status)
        sha=${path#*/commits/}
        sha=${sha%%/*}
        f="$d/status-$sha.json"
        empty='{"statuses":[]}'
        ;;
      *) echo "unexpected api path $path" >&2; exit 1 ;;
    esac
    if [ -f "$f" ]; then
      case "$path" in
        */branches/*|*/rules/branches/*) cat "$f" ;;
        *) jq -r "$(jq_arg "$@")" "$f" ;;
      esac
    else
      printf '%s\n' "${empty:-[]}"
    fi
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
  # The stand-in for bin/fm-pr-merge.sh: records its arguments and marks the
  # named pull request merged, or refuses when merge-refuse exists.
  cat > "$1/fake-pr-merge" <<'EOF'
#!/usr/bin/env bash
d=$FAKE_GH_DIR
printf '%s\n' "$*" >> "$d/merges"
[ ! -e "$d/merge-refuse" ] || { echo "REFUSED: checks are not green" >&2; exit 1; }
f="$d/pr-${2##*/}.json"
jq '.state = "MERGED"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
EOF
  chmod +x "$1/gh" "$1/fake-pr-merge"
}

# One temporary home with a merged pull request task <id> and its backlog item
# In flight. Sets W_HOME, W_FAKE, W_BIN, and W_ID.
make_pr_world() {  # <name> <yolo>
  local dir="$TMP_ROOT/$1"
  W_ID=$1
  W_HOME="$dir/home"
  W_FAKE="$dir/gh"
  W_BIN="$dir/bin"
  mkdir -p "$W_HOME/state" "$W_HOME/data" "$W_HOME/config" "$W_FAKE" "$W_BIN"
  fm_test_track_procevent_home "$W_HOME"
  write_fake_gh "$W_BIN"
  fm_write_meta "$W_HOME/state/$W_ID.meta" "project=$dir/widget" mode=no-mistakes "yolo=$2" \
    branch=feature spawn_gen=1 "pr=$PR_URL"
  printf '{"state":"MERGED","mergeCommit":{"oid":"%s"},"headRefOid":"%s","baseRefName":"main","headRefName":"feature","id":"PR_node7","title":"Add the widget"}\n' \
    "$MERGE_SHA" "$HEAD_SHA" > "$W_FAKE/pr-7.json"
  printf '{"name":"main","protected":false}\n' > "$W_FAKE/branch-main.json"
  printf '[]\n' > "$W_FAKE/rules-main.json"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$W_HOME/data/backlog.md"
  run_tasks add "$W_ID" "Add the widget" --kind ship --repo widget >/dev/null \
    || fail "could not seed the backlog item for $W_ID"
  run_tasks start "$W_ID" >/dev/null || fail "could not start the backlog item for $W_ID"
}

run_tasks() {
  FM_HOME="$W_HOME" "$ROOT/bin/fm-tasks-axi.sh" "$@"
}

pm_raw() {
  FM_HOME="$W_HOME" PATH="$W_BIN:$PATH" FAKE_GH_DIR="$W_FAKE" FM_PR_MERGE_BIN="$W_BIN/fake-pr-merge" \
    FAKE_REVERT_SHA="$REVERT_SHA" FAKE_REVERT_URL="$REVERT_URL" FAKE_MERGE_SHA="$MERGE_SHA" "$PM" "$@"
}

pm() {
  local -a args=("$@")
  if [ "${args[0]:-}" = arm ] && [ "${PM_TEST_RAW_ARM:-0}" != 1 ]; then
    case " ${args[*]} " in
      *\ --witness\ *|*\ --no-witness\ *) ;;
      *) args+=(--no-witness "not a live-site or team project") ;;
    esac
  fi
  FM_HOME="$W_HOME" PATH="$W_BIN:$PATH" FAKE_GH_DIR="$W_FAKE" FM_PR_MERGE_BIN="$W_BIN/fake-pr-merge" \
    FAKE_REVERT_SHA="$REVERT_SHA" FAKE_REVERT_URL="$REVERT_URL" FAKE_MERGE_SHA="$MERGE_SHA" "$PM" "${args[@]}"
}

set_checks() {  # <sha> <name> <status> <conclusion>
  printf '{"check_runs":[{"name":"%s","status":"%s","conclusion":%s}]}\n' "$2" "$3" \
    "$( [ -n "$4" ] && printf '"%s"' "$4" || printf null)" > "$W_FAKE/checks-$1.json"
}

set_required_check() {  # <context>
  jq -cn --arg context "$1" \
    '{name:"main",protected:true,protection:{required_status_checks:{contexts:[$context],checks:[]}}}' \
    > "$W_FAKE/branch-main.json"
}

set_required_ruleset() {  # <context>
  jq -cn --arg context "$1" \
    '[{type:"required_status_checks",parameters:{required_status_checks:[{context:$context,integration_id:null}]}}]' \
    > "$W_FAKE/rules-main.json"
}

record_field() {  # <key>
  grep "^$1=" "$W_HOME/state/$W_ID.post-merge" | tail -1 | cut -d= -f2-
}

backlog_section_of() {  # <id>: the backlog section heading the item sits under
  awk -v id="$1" '/^## /{s=$0} index($0, id) {print s; exit}' "$W_HOME/data/backlog.md"
}

# What cleanup would do with the backlog item, through the library cleanup uses.
teardown_rule() {
  bash -c '. "$1"; if fm_post_merge_teardown_transition "$2" "$3" "$4"; then echo "$FM_POST_MERGE_TEARDOWN"; else echo "refuse: $FM_POST_MERGE_TEARDOWN_ERROR"; fi' \
    _ "$ROOT/bin/fm-post-merge-lib.sh" "$W_HOME/state" "$W_ID" "$W_HOME/state/$W_ID.meta"
}

test_red_merge_checks_revert_on_green() {
  local out
  make_pr_world pm-red on
  set_required_check build
  out=$(pm arm "$W_ID" 2>&1) || fail "arm refused a merged pull request: $out"
  assert_contains "$out" "phase checks" "arm did not start by watching the merge commit's checks"
  assert_present "$W_HOME/state/when/when-pm-$W_ID.spec" "arm did not register the wait on the merge commit's checks"
  assert_equals refuse: "$(teardown_rule | cut -d' ' -f1)" "cleanup did not refuse while the merge's checks were unsettled"

  set_checks "$MERGE_SHA" build in_progress ""
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed on running checks: $out"
  assert_contains "$out" "waiting: checks on merge commit" "running checks did not wait"
  expect_code 1 "$(pm checks "$W_ID" --settled >/dev/null 2>&1; echo $?)" "the watch condition on running checks"

  set_checks "$MERGE_SHA" build completed failure
  expect_code 0 "$(pm checks "$W_ID" --settled >/dev/null 2>&1; echo $?)" "the watch condition on failed checks"
  set_checks "$REVERT_SHA" build queued ""
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed on red checks: $out"
  assert_contains "$out" "reverting: opened $REVERT_URL to revert $PR_URL" "red checks did not open a revert"
  assert_contains "$out" "waiting: checks on the revert $REVERT_URL" "the revert did not wait for its own checks"
  assert_absent "$W_FAKE/merges" "the revert was merged before its checks were green"

  set_checks "$REVERT_SHA" build completed success
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed on a green revert: $out"
  assert_equals "$W_ID $REVERT_URL" "$(cat "$W_FAKE/merges")" "the green revert was not merged through the merge command"
  assert_contains "$out" "reverted: $PR_URL by $REVERT_URL" "the landed revert was not reported"
  assert_contains "$out" "notify: Reverted $PR_URL with $REVERT_URL because the checks on main went red after the merge (build)" \
    "the captain line does not name both links and the cause"
  assert_equals reverted "$(record_field phase)" "the record does not show the revert"
  assert_absent "$W_HOME/state/when/when-pm-$W_ID.spec" "the finished watch left its wait registered"
  assert_absent "$W_HOME/state/when/when-pmr-$W_ID.spec" "the finished revert left its wait registered"

  out=$(jq -c 'select(.event == "post-merge")' "$W_HOME/state/jev-merge.jsonl")
  assert_contains "$out" '"outcome":"reverted"' "the merge-gate log entry is not marked reverted"
  assert_contains "$out" "\"merge_commit\":\"$MERGE_SHA\"" "the log entry does not name the merge commit"
  assert_contains "$out" "\"revert\":\"$REVERT_URL\"" "the log entry does not name the revert"
  assert_contains "$out" '"cause":"checks-red"' "the log entry does not name the cause"
  assert_equals "## Queued" "$(backlog_section_of "$W_ID")" "the reverted task was not returned to the queue"
  assert_equals retain "$(teardown_rule)" "cleanup would close a reverted task instead of keeping it queued"

  out=$(pm advance "$W_ID" 2>&1) || fail "advance after the revert failed: $out"
  assert_equals 1 "$(wc -l < "$W_FAKE/merges" | tr -d ' ')" "a second advance merged again"
  pass "fm-post-merge: red checks on a merge open a revert that merges once its own checks are green"
}

test_missing_required_check_blocks_merge_watch() {
  local out
  make_pr_world pm-required-missing on
  set_required_ruleset validate
  out=$(pm arm "$W_ID" --grace 0 2>&1) || fail "arm refused a merged pull request: $out"
  set_checks "$MERGE_SHA" optional completed success
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed on a missing required check: $out"
  assert_contains "$out" "not green (none)" "a non-required success hid the missing required check"
  assert_equals blocked "$(record_field phase)" "cleanup could proceed without the required check"
  assert_equals refuse: "$(teardown_rule | cut -d' ' -f1)" "cleanup did not refuse a missing required check"
  pass "fm-post-merge: a non-required success cannot satisfy a missing required check"
}

test_null_required_checks_are_empty_and_malformed_protection_fails() {
  local out
  make_pr_world pm-required-null on
  printf '{"name":"main","protected":true,"protection":{"required_status_checks":null}}\n' > "$W_FAKE/branch-main.json"
  out=$(pm arm "$W_ID" --grace 0 2>&1) || fail "arm refused a merged pull request: $out"
  set_checks "$MERGE_SHA" build completed success
  out=$(pm advance "$W_ID" 2>&1) || fail "null required checks blocked the watch: $out"
  assert_contains "$out" "clear: checks on" "null required checks did not behave as an empty list"
  assert_equals clear "$(record_field phase)" "null required checks did not clear the watch"

  make_pr_world pm-required-malformed on
  printf '{"name":"main","protected":true,"protection":{"required_status_checks":"invalid"}}\n' > "$W_FAKE/branch-main.json"
  pm arm "$W_ID" --grace 0 >/dev/null 2>&1 || fail "arm refused a merged pull request"
  set_checks "$MERGE_SHA" build completed success
  out=$(pm advance "$W_ID" 2>&1) && fail "malformed branch protection was accepted: $out"
  assert_contains "$out" "could not read the checks" "malformed branch protection did not fail safely"
  assert_equals checks "$(record_field phase)" "malformed branch protection moved the watch"
  pass "fm-post-merge: null required checks are empty and malformed protection fails closed"
}

test_all_required_merge_checks_green() {
  local out
  make_pr_world pm-required-green on
  set_required_check validate
  out=$(pm arm "$W_ID" --grace 0 2>&1) || fail "arm refused a merged pull request: $out"
  set_checks "$MERGE_SHA" validate completed success
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed with all required checks green: $out"
  assert_contains "$out" "clear: checks on" "all required green checks did not clear the watch"
  assert_equals clear "$(record_field phase)" "all required green checks did not clear the record"
  pass "fm-post-merge: all required checks green permits the merge watch to clear"
}

test_missing_required_revert_check_blocks_merge() {
  local out
  make_pr_world pm-revert-required-missing on
  set_required_ruleset validate
  out=$(pm arm "$W_ID" --grace 0 2>&1) || fail "arm refused a merged pull request: $out"
  set_checks "$MERGE_SHA" build completed failure
  set_checks "$REVERT_SHA" optional completed success
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed while checking the revert: $out"
  assert_contains "$out" "no green checks" "a non-required revert success hid the missing required check"
  assert_equals blocked "$(record_field phase)" "the revert merged without its required check"
  assert_absent "$W_FAKE/merges" "a revert merged without its required check"
  pass "fm-post-merge: a non-required revert success cannot satisfy a missing required check"
}

test_all_required_revert_checks_green() {
  local out
  make_pr_world pm-revert-required-green on
  set_required_check validate
  out=$(pm arm "$W_ID" --grace 0 2>&1) || fail "arm refused a merged pull request: $out"
  set_checks "$MERGE_SHA" build completed failure
  set_checks "$REVERT_SHA" validate completed success
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed with all required revert checks green: $out"
  assert_contains "$out" "reverted: $PR_URL by $REVERT_URL" "the revert with all required checks green did not complete"
  assert_equals reverted "$(record_field phase)" "the required-green revert did not finish"
  assert_equals "$W_ID $REVERT_URL" "$(cat "$W_FAKE/merges")" "the green required-check revert was not merged"
  pass "fm-post-merge: a revert advances when all required checks are green"
}

test_witness_failure_reverts() {
  local out report
  make_pr_world pm-witness on
  printf 'SHOP_ADMIN=s3cret-value\n' > "$W_HOME/config/witness-logins.env"
  chmod 600 "$W_HOME/config/witness-logins.env"
  out=$(pm arm "$W_ID" --witness https://widget.example.com 2>&1) || fail "arm with a witness refused: $out"
  set_checks "$MERGE_SHA" build completed success
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed on green checks: $out"
  assert_contains "$out" "witness: checks on" "green checks with a witness required did not ask for one"
  assert_equals refuse: "$(teardown_rule | cut -d' ' -f1)" "cleanup did not refuse while the witness was outstanding"

  out=$(pm witness-task "$W_ID" 2>&1) || fail "witness-task failed: $out"
  assert_contains "$out" "Merge commit $MERGE_SHA of $PR_URL" "the witness instructions do not name the merge"
  assert_contains "$out" "Use it at https://widget.example.com" "the witness instructions do not name the URL"
  assert_contains "$out" "Available login names: SHOP_ADMIN" "the witness instructions do not name the login"
  assert_not_contains "$out" "s3cret-value" "the witness instructions leaked a login value"

  report="$TMP_ROOT/pm-witness/report.md"
  printf 'Checkout button does nothing.\nwitness-verdict: fail %s checkout button does nothing\n' "$MERGE_SHA" > "$report"
  set_checks "$REVERT_SHA" build completed success
  out=$(pm witness-result "$report" "$W_ID" 2>&1) || fail "witness-result failed on a fail verdict: $out"
  assert_contains "$out" "recorded: witness fail" "the fail verdict was not recorded"
  assert_contains "$out" "reverting: opened $REVERT_URL" "a witness failure did not open a revert"
  assert_contains "$out" "because the witness found it broken: checkout button does nothing" "the captain line does not carry the witness's reason"
  assert_equals "$W_ID $REVERT_URL" "$(cat "$W_FAKE/merges")" "the witness-triggered revert was not merged on green"
  assert_contains "$(cat "$W_HOME/state/jev-merge.jsonl")" '"cause":"witness-fail"' "the log entry does not name the witness failure"
  assert_equals "## Queued" "$(backlog_section_of "$W_ID")" "the task was not returned to the queue after a witness failure"
  pass "fm-post-merge: a witness failure on a landed change takes the same revert path"
}

test_registered_witness_cannot_be_waived_or_lost() {
  local out
  make_pr_world pm-eligible on
  printf '%s\n' '- widget [no-mistakes branch= witness=https://widget.example.com] - live product' > "$W_HOME/data/projects.md"
  out=$(FM_HOME="$W_HOME" "$ROOT/bin/fm-project-mode.sh" --witness widget 2>&1) \
    || fail "project mode refused the registered witness: $out"
  assert_equals https://widget.example.com "$out" "the empty branch field shifted the registered witness"
  out=$(pm_raw arm "$W_ID" --no-witness 'skip' 2>&1) && fail "an eligible project accepted --no-witness: $out"
  assert_contains "$out" 'requires its registered witness' "the refusal did not name the project policy"
  out=$(pm_raw arm "$W_ID" 2>&1) || fail "the registered witness target was not selected: $out"
  assert_equals https://widget.example.com "$(record_field witness)" "the record did not bind the registered target"
  grep -v '^witness=' "$W_HOME/state/$W_ID.post-merge" > "$W_FAKE/record"
  printf 'witness=\n' >> "$W_FAKE/record"
  mv "$W_FAKE/record" "$W_HOME/state/$W_ID.post-merge"
  set_checks "$MERGE_SHA" build completed success
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed on green checks: $out"
  assert_contains "$out" 'requires a witness' "green checks cleared an eligible project without a recorded witness"
  assert_equals blocked "$(record_field phase)" "the missing required witness did not block cleanup"
  pass "fm-post-merge: project registration prevents witness waiver and missing witness clear"
}

test_green_without_witness_is_clear() {
  local out
  make_pr_world pm-clear on
  pm arm "$W_ID" >/dev/null 2>&1 || fail "arm refused a merged pull request"
  set_checks "$MERGE_SHA" build completed success
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed on green checks: $out"
  assert_contains "$out" "clear: checks on" "green checks with no witness were not clear"
  assert_equals close "$(teardown_rule)" "cleanup would not close a confirmed landing"
  assert_contains "$(cat "$W_HOME/state/jev-merge.jsonl")" '"outcome":"witness-waived"' "the no-witness decision was not audited"
  assert_contains "$(cat "$W_HOME/state/jev-merge.jsonl")" '"reason":"not a live-site or team project"' "the no-witness reason was not recorded"
  assert_equals "## In flight" "$(backlog_section_of "$W_ID")" "a clean landing moved the backlog item"
  pass "fm-post-merge: green checks with no witness confirm the landing"
}

test_no_checks_wait_for_grace() {
  local out
  make_pr_world pm-grace on
  pm arm "$W_ID" >/dev/null 2>&1 || fail "arm refused a merged pull request"
  out=$(pm checks "$W_ID" 2>&1) || fail "checks failed: $out"
  assert_contains "$out" "checks pending" "a commit with no checks yet was not pending inside the grace period"
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed inside the grace period: $out"
  assert_contains "$out" "waiting: checks on merge commit" "empty API results did not remain pending during grace"
  make_pr_world pm-nograce on
  pm arm "$W_ID" --grace 0 >/dev/null 2>&1 || fail "arm refused --grace 0"
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed with no checks after the grace period: $out"
  assert_contains "$out" "blocked: checks on merge commit" "no checks after the grace period did not hold for review"
  assert_contains "$out" "notify: $PR_URL has no green checks" "missing checks were not escalated to the captain"
  assert_equals blocked "$(record_field phase)" "missing checks did not hold the watch"
  pass "fm-post-merge: empty check APIs wait through grace then hold without green checks"
}

test_red_revert_checks_block() {
  local out
  make_pr_world pm-blocked on
  pm arm "$W_ID" >/dev/null 2>&1 || fail "arm refused a merged pull request"
  set_checks "$MERGE_SHA" build completed failure
  set_checks "$REVERT_SHA" lint completed failure
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed: $out"
  assert_contains "$out" "blocked: the revert $REVERT_URL has red checks (lint)" "red checks on the revert did not block"
  assert_contains "$out" "notify: $PR_URL broke main" "the blocked revert was not relayed"
  assert_absent "$W_FAKE/merges" "a red revert was merged"
  assert_equals refuse: "$(teardown_rule | cut -d' ' -f1)" "cleanup did not refuse while the revert was blocked"
  out=$(pm close "$W_ID" --reason "reverted by hand" 2>&1) || fail "close refused a blocked watch: $out"
  assert_equals close "$(teardown_rule)" "cleanup would not proceed after the watch was closed"
  pass "fm-post-merge: a revert with red checks stops and is relayed instead of merged"
}

test_reverted_audit_append_failure_keeps_watch_retryable() {
  local out log
  make_pr_world pm-audit-append on
  log="$W_HOME/state/jev-merge.jsonl"
  pm arm "$W_ID" >/dev/null 2>&1 || fail "arm refused a merged pull request"
  set_checks "$MERGE_SHA" build completed failure
  set_checks "$REVERT_SHA" build completed success
  rm -f "$log"
  mkdir "$log"
  out=$(pm advance "$W_ID" 2>&1) && fail "audit append failure was reported as reverted: $out"
  assert_contains "$out" "could not record the reverted outcome" "audit failure was not reported"
  assert_equals reverting "$(record_field phase)" "audit failure allowed the watch to become reverted"
  assert_equals refuse: "$(teardown_rule | cut -d' ' -f1)" "cleanup proceeded without the reverted audit row"
  rmdir "$log" || fail "could not restore the audit-log path for retry"
  out=$(pm advance "$W_ID" 2>&1) || fail "retry after audit recovery failed: $out"
  assert_equals reverted "$(record_field phase)" "successful audit retry did not finish the watch"
  assert_contains "$(jq -c 'select(.event == "post-merge")' "$log")" '"outcome":"reverted"' "retry did not append the reverted outcome"
  pass "fm-post-merge: failed reverted audit append keeps the watch retryable"
}

test_revert_refused_by_github_blocks() {
  local out
  make_pr_world pm-refused on
  pm arm "$W_ID" >/dev/null 2>&1 || fail "arm refused a merged pull request"
  set_checks "$MERGE_SHA" build completed failure
  : > "$W_FAKE/graphql-fail"
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed: $out"
  assert_contains "$out" "blocked: GitHub refused to open a revert of $PR_URL" "a refused revert did not block"
  assert_equals blocked "$(record_field phase)" "a refused revert left the watch running"
  pass "fm-post-merge: a revert GitHub refuses to open stops and is relayed"
}

test_yolo_off_asks_before_merging_the_revert() {
  local out
  make_pr_world pm-approval off
  pm arm "$W_ID" >/dev/null 2>&1 || fail "arm refused a merged pull request"
  set_checks "$MERGE_SHA" build completed failure
  set_checks "$REVERT_SHA" build completed success
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed: $out"
  assert_contains "$out" "approval: the revert $REVERT_URL of $PR_URL is green" "a non-yolo task did not stop for approval"
  assert_absent "$W_FAKE/merges" "a non-yolo task's revert was merged without approval"
  pass "fm-post-merge: without yolo the green revert waits for approval"
}

test_interrupted_revert_candidate_blocks_for_captain() {
  local out
  make_pr_world pm-interrupted on
  pm arm "$W_ID" >/dev/null 2>&1 || fail "arm refused a merged pull request"
  set_checks "$MERGE_SHA" build completed failure
  set_checks "$REVERT_SHA" build queued ""
  pm advance "$W_ID" >/dev/null 2>&1 || fail "advance failed"
  grep -v '^revert_pr=' "$W_HOME/state/$W_ID.post-merge" > "$W_FAKE/rec" && cat "$W_FAKE/rec" > "$W_HOME/state/$W_ID.post-merge"
  printf '[{"url":"%s","headRefName":"revert-7-feature"}]\n' "$REVERT_URL" > "$W_FAKE/pr-list.json"
  printf '{"state":"OPEN","headRefOid":"%s","commits":[{"messageHeadline":"unrelated change","messageBody":"This mentions %s but is not the automatic revert."}]}\n' \
    "$REVERT_SHA" "$MERGE_SHA" > "$W_FAKE/pr-8.json"
  set_checks "$REVERT_SHA" build completed success
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed to hold on the interrupted candidate: $out"
  assert_contains "$out" "blocked: found $REVERT_URL" "the candidate did not block recovery"
  assert_contains "$out" "notify: $PR_URL broke main" "the captain was not notified about the candidate"
  assert_equals "$REVERT_URL" "$(record_field revert_candidate)" "the candidate URL was not recorded"
  assert_equals blocked "$(record_field phase)" "the interrupted candidate did not hold the watch"
  assert_absent "$W_FAKE/merges" "the candidate was merged automatically"
  pass "fm-post-merge: recovery records a candidate and holds for captain review"
}

test_failed_revert_listing_never_opens_a_duplicate() {
  local out opened
  make_pr_world pm-listing-fails on
  pm arm "$W_ID" >/dev/null 2>&1 || fail "arm refused a merged pull request"
  set_checks "$MERGE_SHA" build completed failure
  set_checks "$REVERT_SHA" build queued ""
  pm advance "$W_ID" >/dev/null 2>&1 || fail "advance failed"
  grep -v '^revert_pr=' "$W_HOME/state/$W_ID.post-merge" > "$W_FAKE/rec" && cat "$W_FAKE/rec" > "$W_HOME/state/$W_ID.post-merge"
  opened=$(grep -c 'revertPullRequest' "$W_FAKE/calls")
  : > "$W_FAKE/pr-list-fail"
  out=$(pm advance "$W_ID" 2>&1) && fail "a failed revert listing was treated as no earlier revert: $out"
  assert_contains "$out" "could not list pull requests to check for an earlier revert of $PR_URL" "the listing failure was not reported"
  assert_equals "$opened" "$(grep -c 'revertPullRequest' "$W_FAKE/calls")" "a failed listing opened a second revert"
  assert_equals reverting "$(record_field phase)" "a failed listing moved the watch out of reverting"
  assert_equals "" "$(record_field revert_pr)" "a failed listing recorded a revert"
  rm -f "$W_FAKE/pr-list-fail"
  out=$(pm advance "$W_ID" 2>&1) || fail "advance after the listing recovered failed: $out"
  assert_contains "$out" "blocked: found $REVERT_URL" "the recovered listing did not find the earlier revert"
  assert_equals "$opened" "$(grep -c 'revertPullRequest' "$W_FAKE/calls")" "the recovered listing opened a second revert"
  pass "fm-post-merge: a failed revert listing never opens a duplicate revert"
}

test_earlier_revert_beyond_recent_pull_requests_is_found() {
  local out
  make_pr_world pm-old-revert on
  pm arm "$W_ID" >/dev/null 2>&1 || fail "arm refused a merged pull request"
  set_checks "$MERGE_SHA" build completed failure
  # 150 newer unrelated pull requests come first, so the earlier revert is
  # beyond any window of recent results.
  jq -n --arg url "$REVERT_URL" '
    [ range(1; 151) | {url: "https://github.com/acme/widget/pull/\(1000 + .)", headRefName: "topic-\(.)"} ]
    + [ {url: $url, headRefName: "revert-7-feature"} ]' > "$W_FAKE/pr-list.json"
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed to hold on the earlier revert: $out"
  assert_contains "$out" "blocked: found $REVERT_URL" "an earlier revert beyond the recent pull requests was missed"
  assert_equals 0 "$(grep -c 'revertPullRequest' "$W_FAKE/calls")" "a duplicate revert was opened"
  assert_equals blocked "$(record_field phase)" "the earlier revert did not hold the watch"
  pass "fm-post-merge: an earlier revert beyond the recent pull requests is found by its branch"
}

test_newer_failed_run_beats_older_long_running_success() {
  local out
  make_pr_world pm-newest-by-created on
  set_required_check build
  pm arm "$W_ID" --grace 0 >/dev/null 2>&1 || fail "arm refused"
  printf '{"check_runs":[{"name":"build","status":"completed","conclusion":"success","created_at":"2026-01-01T10:00:00Z","started_at":"2026-01-01T10:01:00Z","completed_at":"2026-01-01T10:30:00Z","id":41},{"name":"build","status":"completed","conclusion":"failure","created_at":"2026-01-01T10:20:00Z","started_at":"2026-01-01T10:20:00Z","completed_at":"2026-01-01T10:25:00Z","id":42}]}' \
    > "$W_FAKE/checks-$MERGE_SHA.json"
  set_checks "$REVERT_SHA" build in_progress ""
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed on newer failed run: $out"
  assert_contains "$out" "reverting: opened $REVERT_URL" "an older long-running success masked the newer failure"
  assert_equals reverting "$(record_field phase)" "the newer failed check did not initiate a revert"
  assert_absent "$W_FAKE/merges" "the stale success allowed a green decision"
  pass "fm-post-merge: newer failed run beats older long-running success"
}

test_latest_check_result_wins() {
  local out
  make_pr_world pm-rerun on
  pm arm "$W_ID" --grace 0 >/dev/null 2>&1 || fail "arm refused"
  printf '{"check_runs":[{"name":"build","status":"completed","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:01:00Z","id":1},{"name":"build","status":"completed","conclusion":"success","started_at":"2026-01-01T00:02:00Z","completed_at":"2026-01-01T00:03:00Z","id":2}]}\n' \
    > "$W_FAKE/checks-$MERGE_SHA.json"
  printf '{"statuses":[{"context":"deploy","state":"failure","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:01:00Z","id":1},{"context":"deploy","state":"success","created_at":"2026-01-01T00:02:00Z","updated_at":"2026-01-01T00:03:00Z","id":2}]}\n' \
    > "$W_FAKE/status-$MERGE_SHA.json"
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed after successful reruns: $out"
  assert_contains "$out" "clear: checks on" "older failed check results overrode newer successes"
  assert_equals clear "$(record_field phase)" "the latest green results did not clear the watch"
  assert_absent "$W_FAKE/merges" "an older failed result triggered an automatic revert"
  pass "fm-post-merge: latest check and status results override earlier failures"
}

test_unknown_completed_check_conclusions_wait() {
  local out
  make_pr_world pm-action-main on
  pm arm "$W_ID" --grace 0 >/dev/null 2>&1 || fail "arm refused"
  printf '{"check_runs":[{"name":"build","status":"completed","conclusion":"success"},{"name":"approval","status":"completed","conclusion":"action_required"}]}\n' \
    > "$W_FAKE/checks-$MERGE_SHA.json"
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed on action_required: $out"
  assert_contains "$out" "waiting: checks on merge commit" "action_required beside a successful check was treated as green"
  assert_equals checks "$(record_field phase)" "the merge watch did not remain open"

  make_pr_world pm-action-revert on
  pm arm "$W_ID" --grace 0 >/dev/null 2>&1 || fail "arm refused"
  set_checks "$MERGE_SHA" build completed failure
  printf '{"check_runs":[{"name":"build","status":"completed","conclusion":"success"},{"name":"approval","status":"completed","conclusion":"action_required"}]}\n' \
    > "$W_FAKE/checks-$REVERT_SHA.json"
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed on action_required revert: $out"
  assert_contains "$out" "waiting: checks on the revert $REVERT_URL" "action_required on the revert was treated as green"
  assert_absent "$W_FAKE/merges" "the revert with action_required was merged"
  assert_equals reverting "$(record_field phase)" "the revert watch did not remain open"
  pass "fm-post-merge: action_required never yields a green verdict"
}

test_revert_without_green_checks_is_held() {
  local out
  make_pr_world pm-none on
  pm arm "$W_ID" --grace 0 >/dev/null 2>&1 || fail "arm refused"
  set_checks "$MERGE_SHA" build completed failure
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed: $out"
  assert_contains "$out" "blocked: the revert $REVERT_URL has no green checks (none)" "a revert with no checks was not held"
  assert_contains "$out" "notify: $PR_URL broke main" "the captain was not notified about missing green checks"
  assert_absent "$W_FAKE/merges" "a revert without green checks was merged"
  assert_equals blocked "$(record_field phase)" "a revert without green checks did not remain blocked"
  pass "fm-post-merge: missing revert checks never count as green"
}

test_witness_result_needs_exactly_one_verdict() {
  local out report
  make_pr_world pm-verdicts on
  pm arm "$W_ID" --witness https://widget.example.com >/dev/null 2>&1 || fail "arm refused"
  set_checks "$MERGE_SHA" build completed success
  pm advance "$W_ID" >/dev/null 2>&1 || fail "advance failed"
  report="$TMP_ROOT/pm-verdicts/report.md"
  printf 'Looked fine.\n' > "$report"
  out=$(pm witness-result "$report" "$W_ID" 2>&1) && fail "a report with no verdict line was accepted: $out"
  assert_contains "$out" "has 0 verdict lines" "a missing verdict was not named"
  printf 'witness-verdict: pass %s\nwitness-verdict: fail %s broken\n' "$MERGE_SHA" "$MERGE_SHA" > "$report"
  out=$(pm witness-result "$report" "$W_ID" 2>&1) && fail "a report with two verdict lines was accepted: $out"
  printf 'witness-verdict: pass %s\n' "${MERGE_SHA:0:12}" > "$report"
  out=$(pm witness-result "$report" "$W_ID" 2>&1) && fail "a verdict bound to a short commit id was accepted: $out"
  assert_equals witness "$(record_field phase)" "a refused report moved the watch"
  printf 'witness-verdict: pass %s\n' "$MERGE_SHA" > "$report"
  out=$(pm witness-result "$report" "$W_ID" 2>&1) || fail "a single pass verdict was refused: $out"
  assert_contains "$out" "clear: the witness passed" "a pass verdict did not confirm the landing"
  pass "fm-post-merge: a witness report needs exactly one verdict bound to the full merge commit"
}

test_merge_queue_field_is_graphql_compatible() {
  local out name PR_URL
  for name in widget 2026 true false null; do
    PR_URL="https://github.com/$name/$name/pull/7"
    make_pr_world "pm-queue-graphql-$name" on
    printf '{"state":"OPEN","isInMergeQueue":true,"mergeCommit":null,"headRefOid":"%s","baseRefName":"main","id":"PR_node7","title":"Add the widget"}\n' \
      "$HEAD_SHA" > "$W_FAKE/pr-7.json"
    out=$(pm arm "$W_ID" 2>&1) || fail "arm refused a queued pull request when gh rejects the JSON field: $out"
    assert_contains "$out" "armed: post-merge watch for queued $PR_URL" "arm did not read the queued PR state through GraphQL"
    assert_equals "" "$(record_field merge_commit)" "arm recorded a merge commit for a queued pull request"
    out=$(pm advance "$W_ID" 2>&1) || fail "advance failed while the pull request remained queued: $out"
    assert_contains "$out" "waiting: pull request $PR_URL remains in GitHub's merge queue" "advance did not read the queued PR state through GraphQL"
    assert_equals checks "$(record_field phase)" "advance did not keep the queued watch open"
  done
  pass "fm-post-merge: arm and advance preserve string identities and read merge-queue state through GraphQL"
}

test_queued_record_retries_after_merge() {
  local out
  make_pr_world pm-queued-retry on
  printf 'post_merge_watch_required=pending\n' >> "$W_HOME/state/$W_ID.meta"
  printf '{"state":"OPEN","isInMergeQueue":true,"mergeCommit":null,"headRefOid":"%s","baseRefName":"main","id":"PR_node7","title":"Add the widget"}\n' \
    "$HEAD_SHA" > "$W_FAKE/pr-7.json"
  mkdir -p "$W_HOME/state/procevent"
  printf 'collision\n' > "$W_HOME/state/procevent/when-pm-$W_ID.source"
  chmod 600 "$W_HOME/state/procevent/when-pm-$W_ID.source"
  out=$(pm arm "$W_ID" 2>&1) && fail "a scheduler collision was reported as an armed queued watch: $out"
  assert_contains "$out" 'could not arm the post-merge checks watch' "the queued scheduler failure was not surfaced"
  assert_equals '' "$(record_field merge_commit)" "the queued record unexpectedly had a merge commit"
  assert_grep 'post_merge_watch_required=pending' "$W_HOME/state/$W_ID.meta" "the failed queued handoff cleared its marker"

  printf '{"state":"MERGED","isInMergeQueue":false,"mergeCommit":{"oid":"%s"},"headRefOid":"%s","baseRefName":"main","id":"PR_node7","title":"Add the widget"}\n' \
    "$MERGE_SHA" "$HEAD_SHA" > "$W_FAKE/pr-7.json"
  rm -f "$W_HOME/state/procevent/when-pm-$W_ID.source"
  out=$(pm arm "$W_ID" 2>&1) || fail "the queued record could not recover after merge: $out"
  assert_equals "$MERGE_SHA" "$(record_field merge_commit)" "retry did not bind the merged commit to the same record"
  assert_no_grep 'post_merge_watch_required=' "$W_HOME/state/$W_ID.meta" "successful scheduler retry did not clear the marker"
  assert_present "$W_HOME/state/when/when-pm-$W_ID.spec" "retry did not register the merge-check scheduler"
  set_checks "$MERGE_SHA" build completed success
  out=$(pm advance "$W_ID" 2>&1) || fail "advance failed after recovered watch: $out"
  assert_contains "$out" 'clear: checks on' "the recovered watch did not complete after checks went green"
  assert_equals close "$(teardown_rule)" "cleanup remained blocked after the recovered watch completed"
  pass "fm-post-merge: a queued watch retry adopts its merge and restores scheduler coverage"
}

test_scheduler_arm_failure_is_retryable() {
  local out
  make_pr_world pm-scheduler-failure on
  printf 'post_merge_watch_required=pending\n' >> "$W_HOME/state/$W_ID.meta"
  mkdir -p "$W_HOME/state/procevent"
  printf 'collision\n' > "$W_HOME/state/procevent/when-pm-$W_ID.source"
  chmod 600 "$W_HOME/state/procevent/when-pm-$W_ID.source"
  out=$(pm arm "$W_ID" 2>&1) && fail "a scheduler collision was reported as an armed watch: $out"
  assert_contains "$out" 'could not arm the post-merge checks watch' "the scheduler failure was not surfaced"
  assert_grep 'post_merge_watch_required=pending' "$W_HOME/state/$W_ID.meta" "a failed scheduler arm cleared the handoff marker"
  assert_equals checks "$(record_field phase)" "the failed initial arm lost its retryable watch record"
  rm -f "$W_HOME/state/procevent/when-pm-$W_ID.source"
  out=$(pm arm "$W_ID" 2>&1) || fail "retrying the same merge did not re-arm the scheduler: $out"
  assert_no_grep 'post_merge_watch_required=' "$W_HOME/state/$W_ID.meta" "successful retry did not clear the marker"

  FM_HOME="$W_HOME" FM_STATE_OVERRIDE="$W_HOME/state" "$ROOT/bin/fm-procevent-when.sh" retire "pm-$W_ID" >/dev/null 2>&1 || fail "could not retire the test watch"
  printf 'collision\n' > "$W_HOME/state/procevent/when-pm-$W_ID.source"
  chmod 600 "$W_HOME/state/procevent/when-pm-$W_ID.source"
  set_checks "$MERGE_SHA" build in_progress ''
  out=$(pm advance "$W_ID" 2>&1) && fail "a failed pending-check re-arm reported waiting: $out"
  assert_contains "$out" 'could not re-arm the post-merge checks watch' "the pending-check re-arm failure was hidden"
  rm -f "$W_HOME/state/procevent/when-pm-$W_ID.source"
  out=$(pm advance "$W_ID" 2>&1) || fail "pending-check re-arm retry failed: $out"
  assert_contains "$out" 'waiting: checks on merge commit' "successful pending-check re-arm did not resume waiting"

  set_checks "$MERGE_SHA" build completed failure
  set_checks "$REVERT_SHA" build queued ''
  out=$(pm advance "$W_ID" 2>&1) || fail "red checks did not open a revert: $out"
  FM_HOME="$W_HOME" FM_STATE_OVERRIDE="$W_HOME/state" "$ROOT/bin/fm-procevent-when.sh" retire "pmr-$W_ID" >/dev/null 2>&1 || fail "could not retire the test revert watch"
  printf 'collision\n' > "$W_HOME/state/procevent/when-pmr-$W_ID.source"
  chmod 600 "$W_HOME/state/procevent/when-pmr-$W_ID.source"
  set_checks "$REVERT_SHA" build in_progress ''
  out=$(pm advance "$W_ID" 2>&1) && fail "a failed revert-check re-arm reported waiting: $out"
  assert_contains "$out" 'could not re-arm the revert checks watch' "the revert-check re-arm failure was hidden"
  rm -f "$W_HOME/state/procevent/when-pmr-$W_ID.source"
  out=$(pm advance "$W_ID" 2>&1) || fail "revert-check re-arm retry failed: $out"
  assert_contains "$out" 'waiting: checks on the revert' "successful revert-check re-arm did not resume waiting"
  pass "fm-post-merge: scheduler arm failures stay retryable across initial, merge, and revert checks"
}

test_arm_refusals_and_rearm() {
  local out
  make_pr_world pm-arm on
  out=$(pm_raw arm "$W_ID" 2>&1) && fail "arm accepted a missing witness disposition: $out"
  assert_contains "$out" "choose exactly one" "arm did not require a witness disposition"
  out=$(pm arm "$W_ID" --no-witness "not a live-site project" --witness https://widget.example.com 2>&1) \
    && fail "arm accepted both witness dispositions: $out"
  assert_contains "$out" "choose exactly one" "arm did not reject conflicting witness dispositions"
  out=$(pm arm "$W_ID" --no-witness " " 2>&1) && fail "arm accepted an empty no-witness reason: $out"
  assert_contains "$out" "needs a reason" "an empty no-witness reason was not refused"
  mv "$W_FAKE/pr-7.json" "$W_FAKE/pr-7.json.hidden"
  out=$(pm arm "$W_ID" 2>&1) && fail "arm accepted a pull request GitHub could not read: $out"
  assert_contains "$out" "could not read $PR_URL from GitHub" "an unreadable pull request was not refused plainly"
  assert_absent "$W_HOME/state/$W_ID.post-merge" "an unreadable pull request left a record"
  mv "$W_FAKE/pr-7.json.hidden" "$W_FAKE/pr-7.json"
  printf '{"state":"OPEN","headRefOid":"%s","id":"PR_node7"}\n' "$HEAD_SHA" > "$W_FAKE/pr-7.json"
  out=$(pm_raw arm "$W_ID" --no-witness "not a live-site project" 2>&1) && fail "arm accepted an unmerged pull request: $out"
  assert_contains "$out" "is not merged" "an unmerged pull request was not named"
  assert_absent "$W_HOME/state/$W_ID.post-merge" "a refused arm left a record"
  printf '{"state":"MERGED","mergeCommit":{"oid":"%s"},"headRefOid":"%s","baseRefName":"main","id":"PR_node7","title":"t"}\n' \
    "$MERGE_SHA" "$HEAD_SHA" > "$W_FAKE/pr-7.json"
  pm arm "$W_ID" >/dev/null 2>&1 || fail "arm refused a merged pull request"
  out=$(pm arm "$W_ID" 2>&1) || fail "re-arming the same merge failed: $out"
  assert_contains "$out" "is already in phase checks" "re-arming the same merge was not a no-op"
  printf 'pr=https://gitlab.com/acme/widget/-/merge_requests/7\n' >> "$W_HOME/state/$W_ID.meta"
  rm -f "$W_HOME/state/$W_ID.post-merge"
  out=$(pm arm "$W_ID" 2>&1) && fail "arm accepted a non-GitHub pull request: $out"
  assert_contains "$out" "supports GitHub pull requests and local landings" "a non-GitHub forge was not refused plainly"
  pass "fm-post-merge: arm refuses an unreadable, unmerged, or non-GitHub pull request and re-arming is a no-op"
}

test_record_from_an_earlier_incarnation_is_ignored() {
  make_pr_world pm-stale on
  pm arm "$W_ID" >/dev/null 2>&1 || fail "arm refused a merged pull request"
  assert_equals refuse: "$(teardown_rule | cut -d' ' -f1)" "an open watch did not hold cleanup"
  fm_write_meta "$W_HOME/state/$W_ID.meta" "project=$TMP_ROOT/pm-stale/widget" mode=no-mistakes yolo=on \
    branch=feature spawn_gen=2 "pr=$PR_URL"
  assert_equals close "$(teardown_rule)" "a record left by an earlier incarnation held cleanup"
  printf 'version=other\n' > "$W_HOME/state/$W_ID.post-merge"
  assert_equals refuse: "$(teardown_rule | cut -d' ' -f1)" "an unreadable record did not refuse cleanup"
  pass "fm-post-merge: cleanup ignores an earlier incarnation's record and refuses an unreadable one"
}

# --- local-only ---------------------------------------------------------------

L_PROJ=
L_FIX=
L_MERGE_RC=0
L_MERGE_OUT=

# A local-only task whose branch adds a broken file, merged through the real
# fm-merge-local.sh. Sets W_HOME, W_ID, L_PROJ, and L_FIX.
make_local_world() {  # <name> [fail-arm]
  local dir="$TMP_ROOT/$1" out
  W_ID=$1
  W_HOME="$dir/home"
  W_FAKE="$dir/gh"
  W_BIN="$dir/bin"
  L_PROJ="$dir/proj"
  mkdir -p "$W_HOME/state" "$W_HOME/data" "$W_HOME/config" "$W_FAKE" "$W_BIN"
  fm_test_track_procevent_home "$W_HOME"
  write_fake_gh "$W_BIN"
  if [ "${2:-}" = fail-arm ]; then
    printf '%s\n' '- proj [local-only witness=invalid] - staged local project' > "$W_HOME/data/projects.md"
  else
    printf '%s\n' '- proj [local-only witness=http://localhost:4321] - staged local project' > "$W_HOME/data/projects.md"
  fi
  fm_git_init_commit "$L_PROJ"
  git -C "$L_PROJ" checkout -qb "fm/$W_ID"
  printf 'broken\n' > "$L_PROJ/feature.txt"
  git -C "$L_PROJ" add feature.txt
  git -C "$L_PROJ" commit -qm "add feature"
  L_FIX=$(git -C "$L_PROJ" rev-parse HEAD)
  git -C "$L_PROJ" checkout -q main
  fm_write_meta "$W_HOME/state/$W_ID.meta" "project=$L_PROJ" mode=local-only yolo=on "branch=fm/$W_ID" spawn_gen=1
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$W_HOME/data/backlog.md"
  run_tasks add "$W_ID" "Add the feature" --kind ship --start >/dev/null 2>&1 \
    || run_tasks add "$W_ID" "Add the feature" --kind ship >/dev/null || fail "could not seed the backlog item"
  run_tasks start "$W_ID" >/dev/null 2>&1 || true
  L_MERGE_RC=0
  if out=$(FM_HOME="$W_HOME" "$MERGE_LOCAL" "$W_ID" 2>&1); then
    L_MERGE_OUT=$out
  else
    L_MERGE_RC=$?
    L_MERGE_OUT=$out
  fi
  if [ "${2:-}" != fail-arm ]; then
    [ "$L_MERGE_RC" -eq 0 ] || fail "the local merge failed: $L_MERGE_OUT"
    assert_present "$W_HOME/state/$W_ID.post-merge" "the local merge did not arm its post-merge watch"
  fi
}

merge_local() {
  FM_HOME="$W_HOME" "$MERGE_LOCAL" "$@"
}

test_local_arm_failure_keeps_marker_for_retry() {
  local out decision
  make_local_world pm-local-arm-failure fail-arm
  assert_equals 1 "$L_MERGE_RC" "the local landing returned success when watch arming failed"
  assert_contains "$L_MERGE_OUT" 'landed fm/pm-local-arm-failure but post-merge watch could not be armed' "the local failure did not identify the failed handoff"
  assert_contains "$L_MERGE_OUT" 'retry: FM_HOME=' "the local failure omitted its exact retry command"
  assert_grep 'post_merge_watch_required=pending' "$W_HOME/state/$W_ID.meta" "the local failed handoff dropped its marker"
  assert_absent "$W_HOME/state/$W_ID.post-merge" "the deliberately failed arm created a watch"
  decision=$(teardown_rule)
  assert_contains "$decision" 'pending post-merge watch marker' "teardown accepted a failed local handoff"
  printf '%s\n' '- proj [local-only witness=http://localhost:4321] - staged local project' > "$W_HOME/data/projects.md"
  out=$(pm_raw arm "$W_ID" 2>&1) || fail "retry did not arm the local watch: $out"
  assert_present "$W_HOME/state/$W_ID.post-merge" "retry did not create the local watch"
  assert_no_grep 'post_merge_watch_required=' "$W_HOME/state/$W_ID.meta" "retry did not clear the marker after recording the watch"
  pass "fm-merge-local: failed watch handoff remains blocked until arm retry succeeds"
}

test_local_watch_marker_without_record_blocks_teardown() {
  make_local_world pm-local-interrupted
  rm -f "$W_HOME/state/$W_ID.post-merge"
  printf 'post_merge_watch_required=pending\n' >> "$W_HOME/state/$W_ID.meta"
  assert_contains "$(teardown_rule)" 'pending post-merge watch marker' "teardown accepted an interrupted local handoff"
  pass "fm-merge-local: an interrupted handoff marker prevents cleanup"
}

test_local_witness_failure_reverts() {
  local out report base
  make_local_world pm-local
  base=$(git -C "$L_PROJ" rev-parse main~1)
  assert_grep "local_landed=$base..$L_FIX" "$W_HOME/state/$W_ID.meta" "the local merge did not record the landed range"
  out=$(pm arm "$W_ID" --witness http://localhost:4321 2>&1) || fail "arm refused a local landing: $out"
  assert_contains "$out" "already in phase witness" "the automatic local watch did not require its registered witness"
  assert_equals http://localhost:4321 "$(record_field witness)" "the automatic local watch did not bind its registered witness target"
  report="$TMP_ROOT/pm-local/report.md"
  printf 'witness-verdict: fail %s feature page is blank\n' "$L_FIX" > "$report"
  out=$(pm witness-result "$report" "$W_ID" 2>&1) || fail "the local witness failure did not revert: $out"
  assert_contains "$out" "reverted: local landing $base..$L_FIX" "the local revert was not reported"
  assert_contains "$out" "notify: Reverted the local landing of fm/$W_ID" "the local captain line is missing"
  assert_absent "$L_PROJ/feature.txt" "the revert did not take the broken file back out"
  assert_equals "$L_FIX" "$(git -C "$L_PROJ" rev-parse main~1)" "the revert rewrote history instead of adding a commit"
  assert_equals "" "$(git -C "$L_PROJ" status --porcelain)" "the revert left the project dirty"
  assert_grep "local_reverted=$(git -C "$L_PROJ" rev-parse main)" "$W_HOME/state/$W_ID.meta" "the revert commit was not recorded"
  assert_contains "$(cat "$W_HOME/state/jev-merge.jsonl")" '"kind":"local"' "the local revert was not logged"
  assert_equals "## Queued" "$(backlog_section_of "$W_ID")" "the local task was not returned to the queue"
  assert_equals retain "$(teardown_rule)" "cleanup would close the reverted local task"
  out=$(merge_local --revert "$W_ID" 2>&1) && fail "a second local revert was accepted: $out"
  assert_contains "$out" "was already reverted" "a second local revert was not refused plainly"
  pass "fm-post-merge: a witness failure on a local landing reverts it with one new commit"
}

test_post_merge_resumes_durable_local_revert() {
  local out report revert_sha
  make_local_world pm-local-durable
  out=$(pm arm "$W_ID" --witness http://localhost:4321 2>&1) || fail "arm refused a local landing: $out"
  merge_local --revert "$W_ID" >/dev/null 2>&1 || fail "the simulated interrupted revert failed"
  revert_sha=$(git -C "$L_PROJ" rev-parse main)
  report="$TMP_ROOT/pm-local-durable/report.md"
  printf 'witness-verdict: fail %s feature page is blank\n' "$L_FIX" > "$report"
  out=$(pm witness-result "$report" "$W_ID" 2>&1) || fail "advance did not resume from the durable local revert: $out"
  assert_contains "$out" "by $revert_sha" "advance did not use the durable revert marker"
  assert_equals "$revert_sha" "$(git -C "$L_PROJ" rev-parse main)" "advance created a second revert commit"
  pass "fm-post-merge: retry resumes from a durable local revert marker"
}

test_interrupted_local_revert_is_idempotent() {
  local out report base revert_sha
  make_local_world pm-local-retry
  base=$(git -C "$L_PROJ" rev-parse main~1)
  out=$(pm arm "$W_ID" --witness http://localhost:4321 2>&1) || fail "arm refused a local landing: $out"
  merge_local --revert "$W_ID" >/dev/null 2>&1 || fail "the simulated interrupted revert failed"
  revert_sha=$(git -C "$L_PROJ" rev-parse main)
  grep -v '^local_reverted=' "$W_HOME/state/$W_ID.meta" > "$W_FAKE/meta" \
    && mv "$W_FAKE/meta" "$W_HOME/state/$W_ID.meta"
  report="$TMP_ROOT/pm-local-retry/report.md"
  printf 'witness-verdict: fail %s feature page is blank\n' "$L_FIX" > "$report"
  out=$(pm witness-result "$report" "$W_ID" 2>&1) || fail "advance did not recover the interrupted local revert: $out"
  assert_contains "$out" "by $revert_sha" "advance did not report the already-landed revert"
  assert_equals "$revert_sha" "$(git -C "$L_PROJ" rev-parse main)" "retry created a second revert commit"
  assert_grep "local_reverted=$revert_sha" "$W_HOME/state/$W_ID.meta" "retry did not durably record the landed revert"
  assert_absent "$L_PROJ/feature.txt" "retry restored the broken file"
  assert_equals "$L_FIX" "$(git -C "$L_PROJ" rev-parse main~1)" "retry rewrote the landing history"
  pass "fm-post-merge: retry records an interrupted local revert without applying it again"
}

# The local revert refuses whatever the local merge refuses.
test_local_revert_keeps_every_merge_guard() {
  local out head
  make_local_world pm-guards
  head=$(git -C "$L_PROJ" rev-parse main)

  printf 'dirty\n' > "$L_PROJ/README.md"
  out=$(merge_local "$W_ID" 2>&1) && fail "the merge accepted a dirty tree"
  out=$(merge_local --revert "$W_ID" 2>&1) && fail "the revert accepted a dirty tree: $out"
  assert_contains "$out" "dirty working tree" "the revert did not refuse a dirty tree like the merge"
  git -C "$L_PROJ" checkout -q -- README.md

  git -C "$L_PROJ" checkout -q "fm/$W_ID"
  out=$(merge_local --revert "$W_ID" 2>&1) && fail "the revert accepted the wrong branch: $out"
  assert_contains "$out" "expected default branch 'main'" "the revert did not refuse the wrong branch like the merge"
  git -C "$L_PROJ" checkout -q main

  cp "$W_HOME/state/$W_ID.meta" "$W_FAKE/meta"
  sed 's/^mode=.*/mode=no-mistakes/' "$W_FAKE/meta" > "$W_HOME/state/$W_ID.meta"
  out=$(merge_local --revert "$W_ID" 2>&1) && fail "the revert accepted a pull request task: $out"
  assert_contains "$out" "not local-only" "the revert did not refuse a pull request task like the merge"
  grep -v '^local_landed=' "$W_FAKE/meta" > "$W_HOME/state/$W_ID.meta"
  out=$(merge_local --revert "$W_ID" 2>&1) && fail "the revert accepted a task with no recorded landing: $out"
  assert_contains "$out" "no recorded local landing" "a missing landing was not refused"
  rm -f "$W_HOME/state/$W_ID.meta"
  out=$(merge_local --revert "$W_ID" 2>&1) && fail "the revert accepted a task with no record: $out"
  assert_contains "$out" "no meta for task" "a missing task record was not refused like the merge"
  cp "$W_FAKE/meta" "$W_HOME/state/$W_ID.meta"

  # A later commit that changes the same line makes the revert conflict.
  printf 'fixed by hand\n' > "$L_PROJ/feature.txt"
  git -C "$L_PROJ" commit -qam "hand fix"
  head=$(git -C "$L_PROJ" rev-parse main)
  out=$(merge_local --revert "$W_ID" 2>&1) && fail "a conflicting revert was accepted: $out"
  assert_contains "$out" "does not revert cleanly" "a conflicting revert was not refused plainly"
  assert_equals "$head" "$(git -C "$L_PROJ" rev-parse main)" "a refused revert moved the default branch"
  assert_equals "" "$(git -C "$L_PROJ" status --porcelain)" "a refused revert left the project dirty"
  assert_no_grep "local_reverted=" "$W_HOME/state/$W_ID.meta" "a refused revert was recorded"

  git -C "$L_PROJ" reset -q --hard HEAD~1
  FM_HOME="$W_HOME" "$ROOT/bin/fm-captain-hold.sh" hold "$W_ID" --reason "wait" >/dev/null 2>&1 \
    || fail "could not hold the task for the captain"
  out=$(merge_local --revert "$W_ID" 2>&1) && fail "the revert accepted a held task: $out"
  assert_contains "$out" "still held for the captain" "the revert did not refuse a held task like the merge"
  assert_present "$L_PROJ/feature.txt" "a held task's landing was reverted"
  pass "fm-merge-local: the revert refuses everything the merge refuses and leaves a conflict untouched"
}

pe_env() {
  FM_HOME="$W_HOME" PATH="$W_BIN:$PATH" FAKE_GH_DIR="$W_FAKE" "$ROOT/bin/fm-procevent.sh" "$@"
}

pending_results() {  # <source-id>: captured results with no handled acknowledgement
  local result n=0
  for result in "$W_HOME/state/procevent-inbox/$1".*.result; do
    [ -e "$result" ] || continue
    [ -e "${result%.result}.handled" ] || n=$((n + 1))
  done
  echo "$n"
}

# The watch's real runner captures its terminal outcome; close must both retire
# the source and acknowledge that outcome, or reconcile re-announces it forever.
test_close_acknowledges_captured_watch_result() {
  local out sid n
  make_pr_world pm-close-captured on
  set_checks "$MERGE_SHA" build completed success
  out=$(pm arm "$W_ID" 2>&1) || fail "arm refused a merged pull request: $out"
  sid="when-pm-$W_ID"
  assert_present "$W_HOME/state/procevent/$sid.source" "arm did not register the watch source"
  pe_env start "$sid" >/dev/null 2>&1 &
  for n in $(seq 1 300); do
    [ "$(pending_results "$sid")" -gt 0 ] && break
    sleep 0.1
  done
  assert_equals 1 "$(pending_results "$sid")" "the watch runner did not capture its settled outcome"

  out=$(pm close "$W_ID" --reason "resolved by hand" 2>&1) || fail "close failed: $out"
  assert_contains "$out" "closed: post-merge watch for $W_ID" "close did not report the closed watch"
  assert_absent "$W_HOME/state/procevent/$sid.source" "close left the watch source registered"
  assert_equals 0 "$(pending_results "$sid")" "close left the captured outcome unacknowledged, so it keeps re-announcing"
  : > "$W_HOME/state/.wake-queue"
  pe_env reconcile >/dev/null 2>&1 || true
  assert_no_grep "$sid" "$W_HOME/state/.wake-queue" "reconcile re-announced the closed watch's outcome"
  wait
  pass "close retires the watch and acknowledges its captured outcome"
}

test_red_merge_checks_revert_on_green
test_missing_required_check_blocks_merge_watch
test_all_required_merge_checks_green
test_null_required_checks_are_empty_and_malformed_protection_fails
test_missing_required_revert_check_blocks_merge
test_all_required_revert_checks_green
test_witness_failure_reverts
test_registered_witness_cannot_be_waived_or_lost
test_green_without_witness_is_clear
test_no_checks_wait_for_grace
test_red_revert_checks_block
test_reverted_audit_append_failure_keeps_watch_retryable
test_revert_refused_by_github_blocks
test_yolo_off_asks_before_merging_the_revert
test_interrupted_revert_candidate_blocks_for_captain
test_failed_revert_listing_never_opens_a_duplicate
test_earlier_revert_beyond_recent_pull_requests_is_found
test_newer_failed_run_beats_older_long_running_success
test_latest_check_result_wins
test_unknown_completed_check_conclusions_wait
test_revert_without_green_checks_is_held
test_witness_result_needs_exactly_one_verdict
test_merge_queue_field_is_graphql_compatible
test_queued_record_retries_after_merge
test_arm_refusals_and_rearm
test_scheduler_arm_failure_is_retryable
test_record_from_an_earlier_incarnation_is_ignored
test_local_arm_failure_keeps_marker_for_retry
test_local_watch_marker_without_record_blocks_teardown
test_local_witness_failure_reverts
test_post_merge_resumes_durable_local_revert
test_interrupted_local_revert_is_idempotent
test_local_revert_keeps_every_merge_guard
test_close_acknowledges_captured_watch_result
