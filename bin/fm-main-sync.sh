#!/usr/bin/env bash
# fm-main-sync.sh - keep pull requests that wait for approval current with main.
#
# Usage: fm-main-sync.sh [<task-id>...]
#
# A ready pull request that waits for the captain's approval goes stale as the
# PR's base branch moves, and a stale one can grow a conflict nobody sees until
# the merge. This command walks every waiting task (or the named ones) and, for
# each, takes at most one conservative step:
#   - only a task the board (bin/fm-board-lib.sh) lists as ready to approve
#     or as a main-sync conflict is considered; it needs recorded pr= and
#     pr_head= metadata, not just a PR URL in its done event;
#   - only an open, non-draft GitHub pull request whose head branch lives in the
#     base repository is considered; a fork branch is never pushed to;
#   - the live head must equal the recorded pr_head=. The sole exception is
#     adoption after a synced result whose head equals that recorded pr_head:
#     fetch the live commit and require exactly two parents, the first equal
#     to pr_head and the second contained in the current base branch. Only
#     then re-record through bin/fm-pr-check.sh; every other moved head is
#     skipped without calling it, including a worker commit on the synced head
#     or a merge whose second parent is not on the base branch;
#   - a pull request that is not behind its base is recorded current;
#   - one GitHub reports conflicting is recorded conflict and never updated;
#   - otherwise GitHub's update-branch merges the base into the head
#     server-side, pinned to the recorded head with expected_head_sha. GitHub
#     refuses rather than merging anything that conflicts, so nothing is
#     forced, rebased, or rewritten; a conflict refusal is recorded conflict,
#     while other update failures are recorded error.
# Local-only ready branches are not moved: bin/fm-merge-local.sh lands them
# only as a clean fast-forward and refuses a diverged branch itself.
#
# Completed comparisons and update attempts write state/<id>.main-sync, a private
# key=value record: version=fm-main-sync-v1, task, spawn_gen, pr, head (the
# pull request head the result applies to), base, result
# (current|synced|conflict|error), detail, and at. The board reads it: a
# conflict at the current recorded head shows the task under NEEDS YOU instead
# of READY TO APPROVE; re-recording a different pr_head makes that conflict
# stale without anyone clearing it. Teardown removes it with the task.
# The watcher runs this command detached every FM_MAIN_SYNC_INTERVAL seconds
# (default 900); it never lands a PR, approves it, or changes merge authority.
# Result lines are <id> <result>: <detail>; live eligibility or read refusals
# print <id> skipped: <reason> without replacing an existing result record.
# Tasks lacking recorded PR metadata, unsupported forges, and local-only tasks
# are skipped silently.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PR_CHECK_BIN="${FM_PR_CHECK_BIN:-$SCRIPT_DIR/fm-pr-check.sh}"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || { echo "fm-main-sync: jq not found" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "fm-main-sync: gh not found" >&2; exit 1; }
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "fm-main-sync: state directory is unavailable" >&2; exit 1; }

# shellcheck source=bin/fm-board-lib.sh
. "$SCRIPT_DIR/fm-board-lib.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-main-sync.XXXXXX") || exit 1
trap 'rm -rf -- "$TMP"' EXIT

record() {  # <id> <spawn_gen> <pr> <head> <base> <result> <detail>
  local tmp
  tmp=$(umask 077; mktemp "$STATE/.fm-main-sync.XXXXXX") || return 1
  if printf 'version=fm-main-sync-v1\ntask=%s\nspawn_gen=%s\npr=%s\nhead=%s\nbase=%s\nresult=%s\ndetail=%s\nat=%s\n' \
      "$1" "$2" "$3" "$4" "$5" "$6" "$(printf '%s' "$7" | tr '\n' ' ' | cut -c1-200)" "$(date +%s)" > "$tmp" \
    && mv -f -- "$tmp" "$STATE/$1.main-sync"; then
    printf '%s %s: %s\n' "$1" "$6" "$7"
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

gh_api() {  # <owner> <args...>
  local owner=$1
  shift
  fm_gh_owner_run "$owner" gh "$@"
}

# 0 when <new> contains <old> on <repo>; ancestry alone proves no sync ownership.
head_contains() {  # <owner> <repo-path> <old> <new>
  local behind
  behind=$(gh_api "$1" api "repos/$2/compare/$3...$4" --jq '.behind_by' 2>/dev/null) || return 1
  [ "$behind" = 0 ]
}

is_sync_merge() {  # <owner> <repo-path> <recorded-head> <live-head> <base>
  local parents first second extra
  parents=$(gh_api "$1" api "repos/$2/commits/$4" --jq '.parents | map(.sha) | join(" ")' 2>/dev/null) || return 1
  read -r first second extra <<EOF2
$parents
EOF2
  [ -n "$second" ] && [ -z "$extra" ] && [ "$first" = "$3" ] || return 1
  fm_pr_head_valid "$second" || return 1
  head_contains "$1" "$2" "$second" "$5"
}

sync_one() {  # <facts-json-line>
  local facts=$1 id spawn_gen url pr_head view state draft cross head base mergeable owner behind
  local last_result last_head err
  id=$(printf '%s' "$facts" | jq -r '.id')
  spawn_gen=$(printf '%s' "$facts" | jq -r '.spawn_gen // ""')
  url=$(printf '%s' "$facts" | jq -r '.pr // ""')
  pr_head=$(printf '%s' "$facts" | jq -r '.pr_head // ""')
  [ -n "$url" ] && [ -n "$pr_head" ] || return 0
  fm_pr_url_parse "$url" >/dev/null 2>&1 && [ "$FM_PR_PROVIDER" = github ] || return 0
  owner=${FM_PR_PATH%%/*}
  view=$(gh_api "$owner" pr view "$url" --json state,isDraft,isCrossRepository,headRefOid,baseRefName,mergeable 2>"$TMP/err") || {
    echo "$id skipped: pull request unreadable: $(head -c 160 "$TMP/err")"
    return 0
  }
  state=$(printf '%s' "$view" | jq -r '.state')
  draft=$(printf '%s' "$view" | jq -r '.isDraft')
  cross=$(printf '%s' "$view" | jq -r '.isCrossRepository')
  head=$(printf '%s' "$view" | jq -r '.headRefOid')
  base=$(printf '%s' "$view" | jq -r '.baseRefName')
  mergeable=$(printf '%s' "$view" | jq -r '.mergeable')
  [ "$state" = OPEN ] && [ "$draft" = false ] || { echo "$id skipped: pull request is not an open ready pull request"; return 0; }
  [ "$cross" = false ] || { echo "$id skipped: head branch lives in a fork"; return 0; }
  fm_pr_head_valid "$head" || { echo "$id skipped: live head unreadable"; return 0; }
  if [ "$head" != "$pr_head" ]; then
    last_result=$(fm_board_record_get "$STATE/$id.main-sync" result)
    last_head=$(fm_board_record_get "$STATE/$id.main-sync" head)
    if [ "$last_result" = synced ] && [ "$last_head" = "$pr_head" ] && is_sync_merge "$owner" "$FM_PR_PATH" "$pr_head" "$head" "$base"; then
      if ! err=$("$PR_CHECK_BIN" "$id" "$url" 2>&1 >/dev/null); then
        record "$id" "$spawn_gen" "$url" "$pr_head" "$base" error "synced, but re-recording the new head failed: $err"
        return 0
      fi
      pr_head=$head
    else
      echo "$id skipped: live head $head differs from recorded pr_head $pr_head"
      return 0
    fi
  fi
  behind=$(gh_api "$owner" api "repos/$FM_PR_PATH/compare/$base...$head" --jq '.behind_by' 2>"$TMP/err") || {
    echo "$id skipped: comparison with $base unreadable: $(head -c 160 "$TMP/err")"
    return 0
  }
  case "$behind" in ''|*[!0-9]*) echo "$id skipped: comparison with $base unreadable"; return 0 ;; esac
  if [ "$behind" = 0 ]; then
    record "$id" "$spawn_gen" "$url" "$head" "$base" current "up to date with $base"
    return
  fi
  case "$mergeable" in
    CONFLICTING)
      record "$id" "$spawn_gen" "$url" "$head" "$base" conflict "$behind commits behind $base and GitHub reports conflicts; needs a rebase by its worker"
      return
      ;;
    MERGEABLE) ;;
    *) echo "$id skipped: GitHub has not computed mergeability yet"; return 0 ;;
  esac
  if gh_api "$owner" api -X PUT "repos/$FM_PR_PATH/pulls/$FM_PR_NUMBER/update-branch" \
      -f "expected_head_sha=$head" >/dev/null 2>"$TMP/err"; then
    record "$id" "$spawn_gen" "$url" "$head" "$base" synced "merged $behind new $base commits into the branch"
  elif grep -qi 'conflict' "$TMP/err"; then
    record "$id" "$spawn_gen" "$url" "$head" "$base" conflict "GitHub refused to merge $base: $(head -c 120 "$TMP/err")"
  else
    record "$id" "$spawn_gen" "$url" "$head" "$base" error "update-branch failed: $(head -c 160 "$TMP/err")"
  fi
}

"$SCRIPT_DIR/fm-fleet-snapshot.sh" --backlog-json > "$TMP/backlog.json" \
  || { echo "fm-main-sync: backlog read failed" >&2; exit 1; }
fm_board_home_json "$STATE" "$TMP/backlog.json" \
  | jq -r '.items[] | select(.group == "ready" or .reason == "conflict") | .id' > "$TMP/ready" \
  || { echo "fm-main-sync: board derivation failed" >&2; exit 1; }
fm_board_task_facts "$STATE" > "$TMP/facts.jsonl" || { echo "fm-main-sync: task read failed" >&2; exit 1; }

while IFS= read -r line; do
  [ -n "$line" ] || continue
  id=$(printf '%s' "$line" | jq -r '.id')
  grep -qxF -- "$id" "$TMP/ready" || continue
  if [ "$#" -gt 0 ]; then
    want=0
    for arg in "$@"; do [ "$arg" = "$id" ] && want=1; done
    [ "$want" = 1 ] || continue
  fi
  printf '%s' "$line" | jq -e '.mode != "local-only"' >/dev/null || continue
  sync_one "$line"
done < "$TMP/facts.jsonl"
