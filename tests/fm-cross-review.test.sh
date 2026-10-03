#!/usr/bin/env bash
# Behavioral tests for bin/fm-cross-review.sh: a task's exact head counts as
# independently reviewed only by an AI family other than the builder's, and a
# confirmation counts only for the exact sha it names.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-cross-review.sh"
TMP_ROOT=$(fm_test_tmproot fm-cross-review-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
command -v jq >/dev/null 2>&1 || fail "these tests need jq, which was not found"

CATALOG="$TMP_ROOT/pi-models.txt"
cat > "$CATALOG" <<'EOF'
provider      model        context  max-out  thinking  images
openai-codex  gpt-6-luna   400K     128K     yes       yes
opencode-go   gpt-6-luna   400K     128K     yes       yes
openai-codex  gpt-6-astra  400K     128K     yes       yes
xai           grok-5       256K     64K      yes       yes
EOF

# The fake no-mistakes answers from the case's captured status and stats, in
# the shapes the installed CLI prints.
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "axi status") cat "$FM_TEST_NM_DIR/status" ;;
  "stats --run") cat "$FM_TEST_NM_DIR/stats" ;;
  *) printf 'unexpected no-mistakes call: %s\n' "$*" >&2; exit 91 ;;
esac
SH
chmod +x "$FAKEBIN/no-mistakes"

TASK=xr-task
CASE=
HOME_DIR=
PROJ=
HEAD_SHA=
NM_DIR=

# new_case <name> <mode> <harness> <model> [<ai_family>]
new_case() {
  local name=$1 mode=$2 harness=$3 model=$4 fam=${5:-}
  CASE="$TMP_ROOT/$name"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/proj"
  NM_DIR="$CASE/nm"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$TASK" "$HOME_DIR/config" "$PROJ" "$NM_DIR"
  git -C "$PROJ" init -q -b main
  git -C "$PROJ" config user.email t@example.invalid
  git -C "$PROJ" config user.name t
  printf 'one\n' > "$PROJ/a.md"
  git -C "$PROJ" add a.md
  git -C "$PROJ" commit -qm base
  git -C "$PROJ" checkout -qb "fm/$TASK"
  printf 'two\n' >> "$PROJ/a.md"
  git -C "$PROJ" commit -qam change
  HEAD_SHA=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$PROJ" checkout -q main
  {
    printf 'harness=%s\nmodel=%s\nmode=%s\n' "$harness" "$model" "$mode"
    printf 'branch=fm/%s\nworktree=%s\nproject=%s\n' "$TASK" "$PROJ" "$PROJ"
    [ -z "$fam" ] || printf 'ai_family=%s\nai_family_source=test\n' "$fam"
  } > "$HOME_DIR/state/$TASK.meta"
  printf '# %s\n\n## Captain'"'"'s intent\n\nA change.\n' "$TASK" > "$HOME_DIR/data/$TASK/brief.md"
}

# nm_run <head> <review-step-status> <agent> <model>
nm_run() {
  cat > "$NM_DIR/status" <<EOF
run:
  id: "01RUNTEST"
  branch: fm/$TASK
  status: running
  head_sha: $1
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,3
    review,$2,0,181793
    test,running,0,0
EOF
  cat > "$NM_DIR/stats" <<EOF
run 01RUNTEST (running), parked at gates 1m total

STEP      ROUND  PURPOSE   AGENT  MODEL       SESSION  KEY  DURATION  MODEL  SUBPROC  RT  TOOLS (w/t/e/r/g/o)  FIND  WORK (f/l)  FALLBACK  EXIT
review    1      review    $3     $4          cold          3m1.7s    -      -        -   -                    0     86/6742     -         ok
test      1      test      $3     $4          cold          32m28.2s  -      -        -   -                    1     -           -         ok

STEP      ROUND  PURPOSE   SESSION  REASON
review    1      review    cold     -
EOF
}

xr() {
  env -u FM_WIKIS_ROOT FM_HOME="$HOME_DIR" NM_HOME="$CASE/nm-home" PATH="$FAKEBIN:$PATH" \
    FM_AI_FAMILY_PI_CATALOG="$CATALOG" FM_TEST_NM_DIR="$NM_DIR" bash "$SCRIPT" "$@"
}

field() {  # <output> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -1
}

# add_reviewer <rid> <harness> <model> <family>
add_reviewer() {
  mkdir -p "$HOME_DIR/data/$1"
  printf 'harness=%s\nmodel=%s\nai_family=%s\nai_family_source=test\n' "$2" "$3" "$4" > "$HOME_DIR/state/$1.meta"
}

request() {  # <rid> <kind>
  mkdir -p "$HOME_DIR/data/$1"
  printf 'task=%s\nhead=%s\nkind=%s\n' "$TASK" "$HEAD_SHA" "$2" > "$HOME_DIR/data/$1/cross-review-request"
}

collect() {  # <rid>
  env -u FM_WIKIS_ROOT FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" bash "$SCRIPT" collect "$TASK" "$1"
}

test_same_family_pipeline_review_needs_a_reviewer() {
  local out
  new_case same-family no-mistakes pi openai-codex/gpt-6-astra openai
  nm_run "$HEAD_SHA" completed pi gpt-6-astra
  out=$(xr status "$TASK" --head "$HEAD_SHA" <&-) || fail "status failed: $out"
  assert_contains "$out" "pipeline_review=present" "the head-bound pipeline review was not found"
  assert_contains "$out" "pipeline_review_family=openai" "the pipeline reviewer family"
  assert_contains "$out" "independent_review=missing" "a same-family review must not count"
  out=$(xr plan "$TASK" --head "$HEAD_SHA" <&-) || fail "plan failed: $out"
  assert_equals spawn-reviewer "$(field "$out" action)" "a same-family pipeline review needs a one-shot reviewer"
  assert_equals review "$(field "$out" kind)" "kind"
  assert_equals pi "$(field "$out" reviewer_harness)" "first reviewer in the chain"
  assert_equals xai "$(field "$out" reviewer_family)" "reviewer family"
  assert_equals "$TASK-xr-${HEAD_SHA:0:8}" "$(field "$out" reviewer_id)" "reviewer id is bound to the head"
  assert_grep "pipeline_review_family=openai" "$HOME_DIR/state/$TASK.meta" "the pipeline family was not recorded in the task record"
  pass "a same-family pipeline review triggers a one-shot reviewer from another family"
}

test_cross_family_pipeline_review_counts() {
  local out json
  new_case cross-family no-mistakes claude claude-opus-5-5 anthropic
  nm_run "$HEAD_SHA" completed pi gpt-6-astra
  out=$(xr plan "$TASK" --head "$HEAD_SHA" <&-) || fail "plan failed: $out"
  assert_equals none "$(field "$out" action)" "a cross-family pipeline review needs no reviewer"
  assert_contains "$(field "$out" reason)" "pipeline review by openai" "reason names the reviewing family"
  assert_grep "independent_review_family=openai" "$HOME_DIR/state/$TASK.meta" "independent family not recorded"
  assert_grep "independent_review_head=$HEAD_SHA" "$HOME_DIR/state/$TASK.meta" "independent review head not recorded"
  json=$(xr status "$TASK" --head "$HEAD_SHA" --json <&-) || fail "status --json failed: $json"
  assert_equals anthropic "$(printf '%s' "$json" | jq -r .builder.family)" "gate evidence names the builder family"
  assert_equals openai "$(printf '%s' "$json" | jq -r .independent_review.family)" "gate evidence names the reviewer family"
  assert_equals "$HEAD_SHA" "$(printf '%s' "$json" | jq -r .independent_review.head)" "gate evidence is bound to the head"
  assert_contains "$(printf '%s' "$json" | jq -r .confirm)" "MISSING:" "an absent confirmation says MISSING"
  pass "a pipeline review from another family counts as the independent review"
}

test_pipeline_provider_read_from_the_state_database() {
  local out db
  command -v sqlite3 >/dev/null 2>&1 || { pass "sqlite3 absent: provider read from the state database not exercised"; return 0; }
  new_case provider-db no-mistakes claude claude-opus-5-5 anthropic
  # gpt-6-luna is listed under two catalog providers, so the stats table alone
  # cannot name its family; the recorded provider can.
  nm_run "$HEAD_SHA" completed pi gpt-6-luna
  out=$(xr status "$TASK" --head "$HEAD_SHA" <&-) || fail "status failed: $out"
  assert_contains "$out" "pipeline_review_family=unknown" "an ambiguous model without its provider must stay unknown"
  assert_contains "$out" "independent_review=missing" "an unknown family never counts"
  mkdir -p "$CASE/nm-home"
  db="$CASE/nm-home/state.sqlite"
  sqlite3 "$db" "create table agent_invocations (id integer primary key, run_id text, purpose text, agent text, model text, model_provider text, exit_status text, started_at integer);
    insert into agent_invocations (run_id, purpose, agent, model, model_provider, exit_status, started_at)
      values ('01RUNTEST', 'review', 'pi', 'gpt-6-luna', 'openai-codex', 'ok', 1);"
  out=$(xr status "$TASK" --head "$HEAD_SHA" <&-) || fail "status failed: $out"
  assert_contains "$out" "pipeline_review_family=openai" "the recorded provider names the family"
  assert_contains "$out" "independent_review=present" "the cross-family review counts"
  pass "the pipeline reviewer's provider is read from the no-mistakes state database"
}

test_pipeline_review_of_another_head_does_not_count() {
  local out other
  new_case head-mismatch no-mistakes claude claude-opus-5-5 anthropic
  other=$(git -C "$PROJ" rev-parse main)
  nm_run "$other" completed pi gpt-6-astra
  out=$(xr status "$TASK" --head "$HEAD_SHA" <&-) || fail "status failed: $out"
  assert_contains "$out" "pipeline_review=missing" "a run of another head must not count"
  assert_contains "$out" "validated head $other, not $HEAD_SHA" "the mismatch is named"
  nm_run "$HEAD_SHA" running pi gpt-6-astra
  out=$(xr status "$TASK" --head "$HEAD_SHA" <&-) || fail "status failed: $out"
  assert_contains "$out" "review step of no-mistakes run 01RUNTEST is running" "an unfinished review step is named"
  pass "a pipeline review counts only for the exact head with a completed review step"
}

test_direct_pr_gets_a_head_bound_review() {
  local out rid brief
  new_case direct-pr direct-PR claude claude-opus-5-5 anthropic
  out=$(xr status "$TASK" <&-) || fail "status failed: $out"
  assert_contains "$out" "head=$HEAD_SHA" "the head defaults to the task branch tip"
  assert_contains "$out" "pipeline_review=n/a" "direct-PR runs no pipeline review"
  out=$(xr plan "$TASK" <&-) || fail "plan failed: $out"
  assert_equals spawn-reviewer "$(field "$out" action)" "direct-PR always needs a one-shot reviewer"
  rid=$(field "$out" reviewer_id)
  out=$(xr brief "$TASK" "$rid" --head "$HEAD_SHA" <&-) || fail "brief failed: $out"
  brief="$HOME_DIR/data/$rid/brief.md"
  assert_present "$brief" "the reviewer instructions were not written"
  assert_grep "git checkout --detach $HEAD_SHA" "$brief" "the reviewer is pinned to the exact head"
  assert_grep "reviewed head $HEAD_SHA" "$brief" "the reviewer is told the declaration line"
  assert_no_grep "{TASK}" "$brief" "the intent placeholder was left unfilled"
  assert_no_grep "{FIRSTMATE_SPEC}" "$brief" "the spec placeholder was left unfilled"
  assert_grep "head=$HEAD_SHA" "$HOME_DIR/data/$rid/cross-review-request" "the request record names the head"
  add_reviewer "$rid" pi openai-codex/gpt-6-luna openai
  printf '# Review\n\nreviewed head %s\n\nVerdict: PASS\n' "$HEAD_SHA" > "$HOME_DIR/data/$rid/report.md"
  out=$(collect "$rid") || fail "collect failed: $out"
  assert_contains "$out" "recorded accepted=yes" "a correct head-bound review was refused"
  out=$(xr status "$TASK" <&-) || fail "status failed: $out"
  assert_contains "$out" "independent_review=present" "the one-shot review did not count"
  assert_contains "$out" "independent_review_source=one-shot" "source"
  assert_contains "$out" "independent_review_family=openai" "family"
  out=$(xr plan "$TASK" <&-) || fail "plan failed: $out"
  assert_equals none "$(field "$out" action)" "a recorded review satisfies the plan"
  pass "a direct-PR task gets a one-shot review bound to its head"
}

install_fake_gh() {
  cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
[ "$1 $2" = "pr view" ] || exit 91
printf '%s\n' "$FM_TEST_GH_HEAD"
SH
  chmod +x "$FAKEBIN/gh"
}

test_github_pr_without_recorded_head_reads_forge_head() {
  local out gh_log url
  new_case github-head direct-PR claude claude-opus-5-5 anthropic
  gh_log="$CASE/gh.log"
  url=https://github.com/example/project/pull/17
  printf 'pr=%s\n' "$url" >> "$HOME_DIR/state/$TASK.meta"
  install_fake_gh
  out=$(FM_TEST_GH_HEAD="$HEAD_SHA" FM_TEST_GH_LOG="$gh_log" xr plan "$TASK" <&-) \
    || fail "plan failed: $out"
  assert_contains "$out" "head=$HEAD_SHA" "plan must bind to the forge's exact PR head"
  assert_equals "pr view $url --json headRefOid -q .headRefOid" "$(<"$gh_log")" "the exact GitHub head field was queried"
  pass "a GitHub PR without pr_head reads and binds its exact forge head"
}

test_github_pr_refreshes_a_recorded_head() {
  local out gh_log url fresh_head
  new_case github-stale-head direct-PR claude claude-opus-5-5 anthropic
  gh_log="$CASE/gh.log"
  url=https://github.com/example/project/pull/18
  fresh_head=$(git -C "$PROJ" rev-parse main)
  printf 'pr=%s\npr_head=%s\n' "$url" "$HEAD_SHA" >> "$HOME_DIR/state/$TASK.meta"
  install_fake_gh
  out=$(FM_TEST_GH_HEAD="$fresh_head" FM_TEST_GH_LOG="$gh_log" xr plan "$TASK" <&-) \
    || fail "plan failed: $out"
  assert_equals "$fresh_head" "$(field "$out" head)" "the live forge head replaces the stale recorded pr_head"
  assert_equals "pr view $url --json headRefOid -q .headRefOid" "$(<"$gh_log")" "the current GitHub head was queried"
  pass "GitHub planning refreshes stale recorded PR heads"
}

test_non_github_pr_without_recorded_head_requires_explicit_sha() {
  local out url=https://gitlab.example.invalid/group/project/-/merge_requests/17 gh_log
  new_case gitlab-head direct-PR claude claude-opus-5-5 anthropic
  gh_log="$CASE/gh.log"
  printf 'pr=%s\n' "$url" >> "$HOME_DIR/state/$TASK.meta"
  install_fake_gh
  if out=$(FM_TEST_GH_HEAD="$HEAD_SHA" FM_TEST_GH_LOG="$gh_log" xr plan "$TASK" 2>&1 <&-); then
    fail "a GitLab PR without an exact head unexpectedly planned: $out"
  fi
  assert_contains "$out" "records a gitlab PR without pr_head; pass --head <sha>" "the unsupported forge path explains how to supply the head"
  [ ! -e "$gh_log" ] || fail "the GitHub CLI was called for a GitLab merge request"
  pass "a non-GitHub PR without pr_head refuses until its exact sha is supplied"
}

test_collect_refuses_reports_not_bound_to_the_head() {
  local out rid=xr-r1 other
  new_case collect-refuse direct-PR claude claude-opus-5-5 anthropic
  other=$(git -C "$PROJ" rev-parse main)
  add_reviewer "$rid" pi openai-codex/gpt-6-luna openai
  request "$rid" review
  printf 'confirm %s\n' "$HEAD_SHA" > "$HOME_DIR/data/$rid/report.md"
  out=$(collect "$rid") || fail "collect failed: $out"
  assert_contains "$out" "accepted=no" "a confirmation-only report was accepted as a review"
  assert_contains "$out" "head declaration and an explicit Verdict" "the missing review contract is named"
  printf 'reviewed head %s\nVerdict: MAYBE\n' "$HEAD_SHA" > "$HOME_DIR/data/$rid/report.md"
  out=$(collect "$rid") || fail "collect failed: $out"
  assert_contains "$out" "accepted=no" "an unrecognized review verdict was accepted"
  assert_contains "$out" "recognized PASS or FAIL" "the unrecognized verdict is named"
  printf 'reviewed head %s\nVerdict: PASS\n' "$other" > "$HOME_DIR/data/$rid/report.md"
  out=$(collect "$rid") || fail "collect failed: $out"
  assert_contains "$out" "accepted=no" "a review of another commit was accepted"
  assert_contains "$out" "declares $other, not the requested head" "the wrong sha is named"
  printf 'reviewed head %s\nhead: %s\nVerdict: PASS\n' "$HEAD_SHA" "$other" > "$HOME_DIR/data/$rid/report.md"
  out=$(collect "$rid") || fail "collect failed: $out"
  assert_contains "$out" "declares 2 candidate commits" "a report declaring two commits was accepted"
  # shellcheck disable=SC2016 # The backticks are a literal Markdown fence.
  printf 'reviewed head %s\n\n```\nhead: %s\n```\n> reviewed head %s\n\n**Verdict: PASS**\n' "$HEAD_SHA" "$other" "$other" > "$HOME_DIR/data/$rid/report.md"
  out=$(collect "$rid") || fail "collect failed: $out"
  assert_contains "$out" "accepted=yes" "fenced and quoted shas must not count as declarations"
  add_reviewer "$rid" claude claude-opus-5-5 anthropic
  out=$(collect "$rid") || fail "collect failed: $out"
  assert_contains "$out" "accepted=no" "a same-family reviewer was accepted"
  assert_contains "$out" "not provably different" "the family clash is named"
  [ "$(wc -l < "$HOME_DIR/data/$TASK/cross-review.jsonl" | tr -d ' ')" = 6 ] || fail "every collect must append one record"
  out=$(xr status "$TASK" <&-) || fail "status failed: $out"
  assert_contains "$out" "independent_review=missing" "the latest record decides, and it was refused"
  pass "collect accepts a report only when it declares exactly the requested head from another family"
}

test_confirm_is_bound_to_the_exact_sha() {
  local out rid other
  new_case confirm direct-PR claude claude-opus-5-5 anthropic
  other=$(git -C "$PROJ" rev-parse main)
  out=$(xr plan "$TASK" --confirm <&-) || fail "plan failed: $out"
  assert_equals spawn-reviewer "$(field "$out" action)" "an unconfirmed head needs a confirming reviewer"
  assert_equals confirm "$(field "$out" kind)" "kind"
  rid=$(field "$out" reviewer_id)
  assert_equals "$TASK-xc-${HEAD_SHA:0:8}" "$rid" "confirm reviewer id"
  out=$(xr brief "$TASK" "$rid" --head "$HEAD_SHA" --confirm <&-) || fail "brief failed: $out"
  assert_grep "confirm $HEAD_SHA" "$HOME_DIR/data/$rid/brief.md" "the confirm line is in the instructions"
  add_reviewer "$rid" pi openai-codex/gpt-6-luna openai
  printf 'reviewed head %s\nVerdict: HOLD\nThe tests are missing.\n' "$HEAD_SHA" > "$HOME_DIR/data/$rid/report.md"
  out=$(collect "$rid") || fail "collect failed: $out"
  assert_contains "$out" "accepted=no" "a hold was recorded as a confirmation"
  if out=$(xr verify-confirm "$TASK" "$HEAD_SHA" 2>&1 <&-); then fail "a hold verified as confirmed: $out"; fi
  printf 'confirm %s\n' "$HEAD_SHA" > "$HOME_DIR/data/$rid/report.md"
  out=$(collect "$rid") || fail "collect failed: $out"
  assert_contains "$out" "accepted=yes" "a correct confirmation was refused"
  out=$(xr verify-confirm "$TASK" "$HEAD_SHA" <&-) || fail "the exact sha did not verify: $out"
  assert_contains "$out" "confirmed $HEAD_SHA" "the confirmation names the exact sha"
  if out=$(xr verify-confirm "$TASK" "$other" 2>&1 <&-); then fail "a confirmation verified for another sha: $out"; fi
  assert_contains "$out" "the recorded confirmation is for $HEAD_SHA, not $other" "the other sha is refused by name"
  out=$(xr status "$TASK" <&-) || fail "status failed: $out"
  assert_contains "$out" "confirm=present" "status shows the confirmation"
  assert_contains "$out" "independent_review=missing" "a confirmation is not a review"
  pass "a confirmation names the exact sha and verifies for no other"
}

test_reviewer_chain_skips_the_builder_family() {
  local out
  new_case pi-builder direct-PR pi openai-codex/gpt-6-luna openai
  out=$(xr plan "$TASK" <&-) || fail "plan failed: $out"
  assert_equals pi "$(field "$out" reviewer_harness)" "the fixed catalog-backed reviewer is selected"
  assert_equals xai "$(field "$out" reviewer_family)" "the same-family candidate is skipped"
  assert_equals xai/grok-5 "$(field "$out" reviewer_model)" "the fixed chain advances to its next disjoint family"
  pass "the fixed reviewer chain skips candidates from the builder family"
}

test_unknown_builder_family_escalates() {
  local out
  new_case unknown-builder direct-PR devin swe-2 unknown
  out=$(xr plan "$TASK" <&-) || fail "plan failed: $out"
  assert_equals escalate "$(field "$out" action)" "an unknown builder family must escalate"
  assert_contains "$(field "$out" reason)" "builder family is unknown" "reason"
  pass "an unknown builder family escalates instead of guessing a reviewer"
}

test_record_without_family_resolves_from_harness() {
  local out
  new_case legacy-record direct-PR pi openai-codex/gpt-6-astra
  out=$(xr status "$TASK" <&-) || fail "status failed: $out"
  assert_contains "$out" "builder_family=openai" "a record from before family recording resolves its harness"
  assert_contains "$out" "predates family recording" "the fallback is disclosed"
  pass "a task record without ai_family resolves its recorded harness and model"
}

# vault_case <cloud> <page-front-matter>
vault_case() {
  local wikis="$CASE/wikis"
  mkdir -p "$wikis/routing"
  printf '{"vaults":[{"wiki":"proj","id":"proj","cloud":"%s"}]}\n' "$1" > "$wikis/routing/estate.json"
  git -C "$PROJ" checkout -q "fm/$TASK"
  printf -- '---\n%s\n---\nbody\n' "$2" > "$PROJ/page.md"
  git -C "$PROJ" add page.md
  git -C "$PROJ" commit -qm page
  HEAD_SHA=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$PROJ" checkout -q main
  # The vault's own scaffold is on its default branch, as in a real vault.
  mkdir -p "$PROJ/_meta"
  printf '#!/bin/sh\n' > "$PROJ/_meta/pruefe.sh"
  git -C "$PROJ" add _meta/pruefe.sh
  git -C "$PROJ" commit -qm scaffold
  printf '%s\n' "$wikis" > "$HOME_DIR/config/wikis-root"
}

test_private_page_rename_stays_private() {
  local out wikis
  new_case vault-private-rename direct-PR claude claude-opus-5-5 anthropic
  git -C "$PROJ" checkout -q main
  mkdir -p "$PROJ/_meta"
  printf '#!/bin/sh\n' > "$PROJ/_meta/pruefe.sh"
  printf -- '---\nprivate: true\n---\nsecret\n' > "$PROJ/secret.md"
  git -C "$PROJ" add _meta/pruefe.sh secret.md
  git -C "$PROJ" commit -qm 'add private page and vault scaffold'
  git -C "$PROJ" checkout -q "fm/$TASK"
  git -C "$PROJ" reset --hard -q main
  git -C "$PROJ" mv secret.md public.md
  printf -- '---\ntitle: public\n---\npublic\n' > "$PROJ/public.md"
  git -C "$PROJ" add public.md
  git -C "$PROJ" commit -qm 'rename private page as public'
  HEAD_SHA=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$PROJ" checkout -q main
  wikis="$CASE/wikis"
  mkdir -p "$wikis/routing"
  printf '{"vaults":[{"wiki":"proj","id":"proj","cloud":"ja"}]}\n' > "$wikis/routing/estate.json"
  printf '%s\n' "$wikis" > "$HOME_DIR/config/wikis-root"
  out=$(xr plan "$TASK" <&-) || fail "plan failed: $out"
  assert_equals none "$(field "$out" action)" "renaming a private page must stay on the private path"
  assert_contains "$(field "$out" reason)" "secret.md" "the old private path is named"
  pass "renaming a private page cannot expose it to a reviewer"
}

test_private_vault_change_gets_no_new_reviewer() {
  local out
  new_case vault-private-card direct-PR claude claude-opus-5-5 anthropic
  vault_case nein 'title: x'
  out=$(xr plan "$TASK" <&-) || fail "plan failed: $out"
  assert_equals none "$(field "$out" action)" "a cloud: nein vault must get no new reviewer"
  assert_contains "$(field "$out" reason)" "cloud: nein" "reason"
  if out=$(xr brief "$TASK" "$TASK-xr-${HEAD_SHA:0:8}" --head "$HEAD_SHA" 2>&1 <&-); then
    fail "brief created reviewer instructions for a cloud: nein vault: $out"
  fi
  assert_contains "$out" "private path" "brief refusal names the private path"
  assert_contains "$out" "cloud: nein" "brief refusal names the card reason"
  assert_absent "$HOME_DIR/data/$TASK-xr-${HEAD_SHA:0:8}/brief.md" "brief wrote reviewer instructions for a private vault"
  assert_absent "$HOME_DIR/data/$TASK-xr-${HEAD_SHA:0:8}/cross-review-request" "brief wrote a request record for a private vault"
  new_case vault-private-page direct-PR claude claude-opus-5-5 anthropic
  vault_case ja 'private: true'
  out=$(xr plan "$TASK" <&-) || fail "plan failed: $out"
  assert_equals none "$(field "$out" action)" "a private page must get no new reviewer"
  assert_contains "$(field "$out" reason)" "page.md, a page marked private" "reason"
  new_case vault-public direct-PR claude claude-opus-5-5 anthropic
  vault_case ja 'title: public'
  out=$(xr plan "$TASK" <&-) || fail "plan failed: $out"
  assert_equals spawn-reviewer "$(field "$out" action)" "a public vault change still gets a reviewer"
  pass "a private vault change stays on today's path and no new reviewer sees it"
}

test_usage_errors() {
  local out status
  new_case usage direct-PR claude claude-opus-5-5 anthropic
  out=$(xr status "$TASK" --head abc 2>&1 <&-)
  status=$?
  assert_equals 2 "$status" "a short sha is a usage error"
  out=$(xr nonsense 2>&1 <&-)
  status=$?
  assert_equals 2 "$status" "an unknown subcommand is a usage error"
  out=$(xr status missing-task 2>&1 <&-)
  status=$?
  assert_equals 1 "$status" "a missing task record exits 1"
  assert_contains "$out" "no task record" "missing record named"
  pass "usage errors exit 2 and missing records exit 1"
}

test_same_family_pipeline_review_needs_a_reviewer
test_cross_family_pipeline_review_counts
test_pipeline_provider_read_from_the_state_database
test_pipeline_review_of_another_head_does_not_count
test_direct_pr_gets_a_head_bound_review
test_github_pr_without_recorded_head_reads_forge_head
test_github_pr_refreshes_a_recorded_head
test_non_github_pr_without_recorded_head_requires_explicit_sha
test_collect_refuses_reports_not_bound_to_the_head
test_confirm_is_bound_to_the_exact_sha
test_reviewer_chain_skips_the_builder_family
test_unknown_builder_family_escalates
test_record_without_family_resolves_from_harness
test_private_page_rename_stays_private
test_private_vault_change_gets_no_new_reviewer
test_usage_errors
