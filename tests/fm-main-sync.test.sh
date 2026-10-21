#!/usr/bin/env bash
# Behavior tests for bin/fm-main-sync.sh against a fake gh.
# Covers: a ready pull request behind main is updated server-side through
# update-branch pinned to the recorded head; a conflicting one is recorded and
# never updated, and the board then lists it under needs you; a refused update
# is recorded conflict; an up-to-date one is recorded current; a head someone
# else moved, a fork head, and a draft are left alone; a head this command moved
# itself is re-recorded through fm-pr-check before the next step; a task that is
# not ready, and a local-only ready branch, are never touched; named tasks
# limit the walk.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

SYNC="$ROOT/bin/fm-main-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-main-sync)
FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"
mkdir -p "$FM_ROOT_OVERRIDE"
export FM_ROOT_OVERRIDE

H="$TMP_ROOT/home"
GHFAKE="$TMP_ROOT/gh"
mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects" "$GHFAKE/compare" "$GHFAKE/commits"
GHLOG="$TMP_ROOT/gh.log"
CHECKLOG="$TMP_ROOT/pr-check.log"
: > "$GHLOG"
: > "$CHECKLOG"

# The fake gh answers from files under $GHFAKE: <n>.view for `pr view`,
# compare/<base...head> for a comparison's behind_by, and <n>.update-fail as
# the stderr of a refused update-branch.
FB=$(fm_fakebin "$TMP_ROOT/fakebin")
cat > "$FB/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$GHLOG"
case "$1 $2" in
  "pr view")
    n=${3##*/}
    [ -f "$GHFAKE/$n.view" ] || { echo "no such pull request" >&2; exit 1; }
    cat "$GHFAKE/$n.view"
    ;;
  "api -X")
    path=$4
    n=${path%/update-branch}
    n=${n##*/}
    if [ -f "$GHFAKE/$n.update-fail" ]; then
      cat "$GHFAKE/$n.update-fail" >&2
      exit 1
    fi
    echo '{"message":"Updating pull request branch."}'
    ;;
  api\ repos/*/commits/*)
    ref=${2##*/commits/}
    [ -f "$GHFAKE/commits/$ref" ] || { echo "no commit" >&2; exit 1; }
    cat "$GHFAKE/commits/$ref"
    ;;
  api\ repos/*/compare/*)
    ref=${2##*/compare/}
    [ -f "$GHFAKE/compare/$ref" ] || { echo "no comparison" >&2; exit 1; }
    cat "$GHFAKE/compare/$ref"
    ;;
  *) echo "unexpected gh call" >&2; exit 1 ;;
esac
SH
chmod +x "$FB/gh"

# The pr-check stub re-records pr_head the way the real one does: from the
# live head, replacing the old line.
cat > "$FB/fm-pr-check" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$CHECKLOG"
if [ -f "$GHFAKE/$1.check-fail" ]; then
  rm -f "$GHFAKE/$1.check-fail"
  echo "transient failure" >&2
  exit 1
fi
meta="$FM_HOME/state/$1.meta"
grep -v '^pr_head=' "$meta" > "$meta.tmp"
printf 'pr_head=%s\n' "$(cat "$GHFAKE/new-head")" >> "$meta.tmp"
mv -f "$meta.tmp" "$meta"
SH
chmod +x "$FB/fm-pr-check"

sha() { printf '%040d' "$1" | tr 0 "$2"; }

view() {  # <n> <state> <draft> <cross> <head> <mergeable>
  jq -n --arg s "$2" --argjson d "$3" --argjson c "$4" --arg h "$5" --arg m "$6" \
    '{state:$s, isDraft:$d, isCrossRepository:$c, headRefOid:$h, baseRefName:"main", mergeable:$m}' \
    > "$GHFAKE/$1.view"
}

ready_ship() {  # <id> <n> <pr_head> [extra meta k=v...]
  local id=$1 n=$2 head=$3
  shift 3
  mkdir -p "$H/projects/$id"
  fm_write_meta "$H/state/$id.meta" \
    "worktree=$H/projects/$id" "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=s1.$id" "pr=https://github.com/acme/repo/pull/$n" "pr_head=$head" "$@"
  printf 'done: PR https://github.com/acme/repo/pull/%s checks green\n' "$n" > "$H/state/$id.status"
}

sync_field() { awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$H/state/$1.main-sync" 2>/dev/null; }

run_sync() {
  PATH="$FB:$PATH" GHLOG="$GHLOG" GHFAKE="$GHFAKE" CHECKLOG="$CHECKLOG" FM_HOME="$H" \
    FM_PR_CHECK_BIN="$FB/fm-pr-check" "$SYNC" "$@"
}

{
  printf '## In flight\n'
  for id in behind conflicting moved fork current refused own worker offbase retry draft local busy; do
    printf -- '- [ ] %s - Task %s (repo: firstmate) (kind: ship) (since 2026-10-19)\n' "$id" "$id"
  done
  printf '\n## Queued\n\n## Done\n'
} > "$H/data/backlog.md"

H1=$(sha 1 a); ready_ship behind 1 "$H1"; view 1 OPEN false false "$H1" MERGEABLE
echo 3 > "$GHFAKE/compare/main...$H1"
H2=$(sha 1 b); ready_ship conflicting 2 "$H2"; view 2 OPEN false false "$H2" CONFLICTING
echo 2 > "$GHFAKE/compare/main...$H2"
H3=$(sha 1 c); ready_ship moved 3 "$H3"; view 3 OPEN false false "$(sha 1 d)" MERGEABLE
H4=$(sha 1 e); ready_ship fork 4 "$H4"; view 4 OPEN false true "$H4" MERGEABLE
echo 1 > "$GHFAKE/compare/main...$H4"
H5=$(sha 1 f); ready_ship current 5 "$H5"; view 5 OPEN false false "$H5" MERGEABLE
echo 0 > "$GHFAKE/compare/main...$H5"
H6=$(sha 2 a); ready_ship refused 6 "$H6"; view 6 OPEN false false "$H6" MERGEABLE
echo 1 > "$GHFAKE/compare/main...$H6"
echo 'gh: merge conflict between base and head (HTTP 422)' > "$GHFAKE/6.update-fail"
H7=$(sha 2 b); H7B=$(sha 2 c); ready_ship own 7 "$H7"; view 7 OPEN false false "$H7B" MERGEABLE
printf 'version=fm-main-sync-v1\ntask=own\nspawn_gen=s1.own\npr=https://github.com/acme/repo/pull/7\nhead=%s\nbase=main\nresult=synced\ndetail=merged\nat=1\n' "$H7" \
  > "$H/state/own.main-sync"
echo 0 > "$GHFAKE/compare/$H7...$H7B"
BASE7=$(sha 2 f); echo "$H7 $BASE7" > "$GHFAKE/commits/$H7B"
echo 0 > "$GHFAKE/compare/$BASE7...main"
echo 0 > "$GHFAKE/compare/main...$H7B"
echo "$H7B" > "$GHFAKE/new-head"
synced_ship() {  # <id> <n> <recorded> <live> <parents>
  ready_ship "$1" "$2" "$3"; view "$2" OPEN false false "$4" MERGEABLE
  printf 'version=fm-main-sync-v1\ntask=%s\nspawn_gen=s1.%s\npr=https://github.com/acme/repo/pull/%s\nhead=%s\nbase=main\nresult=synced\ndetail=merged\nat=1\n' \
    "$1" "$1" "$2" "$3" > "$H/state/$1.main-sync"
  echo "$5" > "$GHFAKE/commits/$4"
}
H10=$(sha 3 b); H10B=$(sha 3 c); synced_ship worker 10 "$H10" "$H10B" "$H10"
echo 0 > "$GHFAKE/compare/$H10...$H10B"
H11=$(sha 3 d); H11B=$(sha 3 e); synced_ship offbase 11 "$H11" "$H11B" "$H11 $(sha 3 f)"
echo 2 > "$GHFAKE/compare/$(sha 3 f)...main"
H12=$(sha 4 b); H12B=$(sha 4 c); BASE12=$(sha 4 d); synced_ship retry 12 "$H12" "$H12B" "$H12 $BASE12"
echo 0 > "$GHFAKE/compare/$H12...$H12B"
echo 0 > "$GHFAKE/compare/$BASE12...main"
echo 0 > "$GHFAKE/compare/main...$H12B"
echo "$H12B" > "$GHFAKE/new-head"
touch "$GHFAKE/retry.check-fail"
H8=$(sha 2 d); ready_ship draft 8 "$H8"; view 8 OPEN true false "$H8" MERGEABLE
mkdir -p "$H/projects/local"
fm_write_meta "$H/state/local.meta" "worktree=$H/projects/local" "project=firstmate" "harness=claude" \
  "kind=ship" "mode=local-only" "spawn_gen=s1.local"
printf 'done: ready branch fm/local\n' > "$H/state/local.status"
H9=$(sha 2 e); ready_ship busy 9 "$H9"; view 9 OPEN false false "$H9" MERGEABLE
printf 'working: still building\n' > "$H/state/busy.status"
echo 4 > "$GHFAKE/compare/main...$H9"

# --- named tasks limit the walk ----------------------------------------------
OUT=$(run_sync current 2>&1) || fail "a named run exits zero: $OUT"
assert_equals "current current: up to date with main" "$OUT" "a named run considers only the named task"
assert_absent "$H/state/behind.main-sync" "a named run leaves other tasks alone"
assert_no_grep 'update-branch' "$GHLOG" "a named run updates nothing it was not asked to"

# --- full walk ----------------------------------------------------------------
: > "$GHLOG"
OUT=$(run_sync 2>&1) || fail "a full run exits zero: $OUT"

assert_equals synced "$(sync_field behind result)" "a ready PR behind main is synced"
assert_equals "$H1" "$(sync_field behind head)" "the synced record names the head it applied to"
assert_grep "api -X PUT repos/acme/repo/pulls/1/update-branch -f expected_head_sha=$H1" "$GHLOG" \
  "the update is pinned to the recorded head"

assert_equals conflict "$(sync_field conflicting result)" "a conflicting PR is recorded conflict"
assert_no_grep 'pulls/2/update-branch' "$GHLOG" "a conflicting PR is never updated"

assert_equals conflict "$(sync_field refused result)" "a refused update is recorded conflict"

assert_equals current "$(sync_field current result)" "a PR not behind main is current"
assert_no_grep 'pulls/5/update-branch' "$GHLOG" "a current PR is not updated"

assert_absent "$H/state/moved.main-sync" "a head someone else moved gets no record"
assert_no_grep 'pulls/3/update-branch' "$GHLOG" "a head someone else moved is never updated"
assert_contains "$OUT" "moved skipped: live head" "the moved head is reported"

assert_absent "$H/state/fork.main-sync" "a fork head gets no record"
assert_no_grep 'pulls/4/update-branch' "$GHLOG" "a fork head is never pushed to"

assert_absent "$H/state/draft.main-sync" "a draft gets no record"
assert_no_grep 'pulls/8/update-branch' "$GHLOG" "a draft is never updated"

assert_grep 'own https://github.com/acme/repo/pull/7' "$CHECKLOG" "a head this command moved is re-recorded through fm-pr-check"
assert_equals current "$(sync_field own result)" "after re-recording, the moved head is compared afresh"
assert_equals "$H7B" "$(sync_field own head)" "the record follows the re-recorded head"
assert_no_grep 'pulls/7/update-branch' "$GHLOG" "the re-recorded head needed no further update"

assert_equals "$H10" "$(sync_field worker head)" "a worker commit on top of the synced head is not adopted"
assert_no_grep 'worker https://github.com/acme/repo/pull/10' "$CHECKLOG" "a single-parent head never reaches fm-pr-check"
assert_no_grep 'offbase https://github.com/acme/repo/pull/11' "$CHECKLOG" "a merge whose second parent is off base never reaches fm-pr-check"
assert_contains "$OUT" "worker skipped: live head" "the worker commit is reported as a moved head"
assert_contains "$OUT" "offbase skipped: live head" "the off-base merge is reported as a moved head"

assert_equals synced "$(sync_field retry result)" "a failed re-record leaves the synced record untouched"
assert_equals "$H12" "$(sync_field retry head)" "a failed re-record keeps the synced head"
assert_contains "$OUT" "retry skipped: re-recording" "the failed re-record is reported"
OUT=$(run_sync retry 2>&1) || fail "the retry run exits zero: $OUT"
assert_equals current "$(sync_field retry result)" "the next run adopts the sync merge"
assert_equals "$H12B" "$(sync_field retry head)" "the retried record follows the adopted head"

assert_absent "$H/state/local.main-sync" "a local-only ready branch is not moved"
assert_absent "$H/state/busy.main-sync" "a task still working is not synced"
assert_no_grep 'pull/9' "$GHLOG" "a task still working is not even read from the forge"

# --- the board shows the conflict, then forgets it once the head moves --------
BOARD=$(PATH="$FB:$PATH" GHLOG="$GHLOG" FM_HOME="$H" "$ROOT/bin/fm-board.sh" --json --home-only) \
  || fail "the board renders after a sync"
assert_equals conflict "$(printf '%s' "$BOARD" | jq -r '.groups.needs_you[] | select(.id == "conflicting") | .reason')" \
  "a conflict at the recorded head moves the PR to needs you"
assert_equals behind "$(printf '%s' "$BOARD" | jq -r '.groups.ready[] | select(.id == "behind") | .id')" \
  "a synced PR stays ready to approve"
assert_equals working "$(printf '%s' "$BOARD" | jq -r '[.groups | to_entries[] | .key as $g | .value[] | select(.id == "busy") | $g] | join(",")')" \
  "a recorded PR whose worker is back at work is working, not ready"
sed -i.bak "s/^pr_head=.*/pr_head=$(sha 3 a)/" "$H/state/conflicting.meta"
BOARD=$(PATH="$FB:$PATH" GHLOG="$GHLOG" FM_HOME="$H" "$ROOT/bin/fm-board.sh" --json --home-only)
assert_equals conflicting "$(printf '%s' "$BOARD" | jq -r '.groups.ready[] | select(.id == "conflicting") | .id')" \
  "a conflict at an older head no longer holds the PR under needs you"
pass "fm-main-sync keeps waiting pull requests current without forcing anything"
