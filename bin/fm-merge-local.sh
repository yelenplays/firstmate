#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's immutable ship branch recorded in
# state/<task-id>.meta ("fm/<id>" for records created before that field existed).
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# The task's existing per-task control lock serializes the captain-hold check
# through that fast-forward. A still-held or unreadable row refuses before the
# merge, so a captain approval must be recorded as an `answer --release` before
# this entrypoint is invoked. The lock ends when the fast-forward returns;
# docs/captain-hold-lifecycle.md owns the accepted merge-to-cleanup residual.
# A merge that moves the default branch records the exact landed range as
# local_landed=<before>..<after> (full commit ids) in the task meta, so a later
# revert undoes exactly what this script landed rather than a caller-supplied
# range.
#
# --revert is the guarded revert of that recorded landing, which
# bin/fm-post-merge.sh runs when a landed change is found broken. It runs every
# guard the merge runs, with the same refusals: a valid task id and state
# directory, the lease role refusal, the task meta and its incarnation under the
# same control lock, mode=local-only, the recorded ship branch existing, the
# default branch checked out, a clean working tree, and a released captain
# hold. Only the fast-forward check is merge-specific; the revert replaces it
# with its own: a recorded landing that was not already reverted, a non-empty
# range, and a range end still on the default branch. The whole range is
# reverted as one new commit on top of the default branch, so nothing is forced,
# reset, or discarded. A range that does not revert cleanly is abandoned with
# `git revert --abort`, which restores the clean tree the guard verified, and
# the script refuses. The revert commit is recorded as local_reverted=<sha>,
# which makes a second revert refuse.
# Usage: fm-merge-local.sh <task-id>
#        fm-merge-local.sh --revert <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
REVERT=0
if [ "$#" -eq 2 ] && [ "$1" = --revert ]; then
  REVERT=1
  shift
fi
if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
ID=$1
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-post-merge-lib.sh
. "$SCRIPT_DIR/fm-post-merge-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). This action is deliberately NOT
# relocated under the away-posture record: unlike the PR merge it has no
# record-side grant gate of its own, so a parked main keeps it held for the
# captain's return. This precedes reading the task record, because the wrong
# actor is refused for its role whatever it says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
if [ "$REVERT" = 1 ]; then
  fm_lease_forbid_branch "local-only landing revert (fm-merge-local --revert)"
else
  fm_lease_forbid_branch "local-only landing (fm-merge-local)"
fi

[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

MERGE_CONTROL_LOCK=
merge_control_cleanup() {
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH=$(grep '^branch=' "$META" | cut -d= -f2- || true)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
  exit 1
fi
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

meta_value() {  # <key>: the last recorded value, empty when absent
  grep "^$1=" "$META" | tail -1 | cut -d= -f2- || true
}

commit_id_valid() {
  case "$1" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}

find_recorded_revert() {
  local commits commit subject body
  commits=$(git -C "$PROJ" rev-list --reverse "$LANDED_AFTER..$DEFAULT") || return 2
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    subject=$(git -C "$PROJ" show -s --format=%s "$commit") || return 2
    body=$(git -C "$PROJ" show -s --format=%b "$commit") || return 2
    if [ "$subject" = "Revert local landing of $BRANCH" ] \
      && [ "$body" = "This reverts $LANDED_BEFORE..$LANDED_AFTER (task $ID)." ]; then
      printf '%s\n' "$commit"
      return 0
    fi
  done <<< "$commits"
  return 1
}

# Rewrite the task meta with <key>=<value> replacing any earlier value. Runs
# under the meta lock while the control lock is still held, the same
# control-then-meta order bin/fm-pr-merge.sh uses.
record_meta_value() {  # <key> <value>
  local key=$1 value=$2 lock tmp line status=0
  lock=$(fm_meta_lock_path "$META") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  tmp=$(mktemp "$STATE/.fm-merge-local-meta.XXXXXX") || { fm_lock_release "$lock" || true; return 1; }
  {
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$key="*) ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$META"
    printf '%s=%s\n' "$key" "$value"
  } > "$tmp" || status=1
  [ "$status" -ne 0 ] || chmod 0600 "$tmp" || status=1
  [ "$status" -ne 0 ] || mv -f -- "$tmp" "$META" || status=1
  [ "$status" -eq 0 ] || rm -f -- "$tmp"
  fm_lock_release "$lock" || status=1
  return "$status"
}

if [ "$REVERT" = 1 ]; then
  LANDED=$(meta_value local_landed)
  [ -n "$LANDED" ] || { echo "error: task $ID has no recorded local landing to revert" >&2; exit 1; }
  if [ -n "$(meta_value local_reverted)" ]; then
    echo "error: task $ID's local landing $LANDED was already reverted by $(meta_value local_reverted)" >&2
    exit 1
  fi
  LANDED_BEFORE=${LANDED%%..*}
  LANDED_AFTER=${LANDED#*..}
  if ! commit_id_valid "$LANDED_BEFORE" || ! commit_id_valid "$LANDED_AFTER" \
    || [ "$LANDED_BEFORE..$LANDED_AFTER" != "$LANDED" ]; then
    echo "error: task $ID has an unreadable recorded local landing '$LANDED'" >&2
    exit 1
  fi
  if [ "$LANDED_BEFORE" = "$LANDED_AFTER" ] \
    || ! git -C "$PROJ" merge-base --is-ancestor "$LANDED_BEFORE" "$LANDED_AFTER" 2>/dev/null; then
    echo "error: task $ID's recorded local landing $LANDED is not a non-empty range of commits in $PROJ" >&2
    exit 1
  fi
  if ! git -C "$PROJ" merge-base --is-ancestor "$LANDED_AFTER" "$DEFAULT" 2>/dev/null; then
    echo "REFUSED: the recorded landing $LANDED is no longer on local $DEFAULT in $PROJ; nothing to revert there." >&2
    exit 1
  fi
# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
elif ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

if [ "$REVERT" = 1 ]; then
  ACTION=revert
else
  ACTION=merge
fi
before=$(git -C "$PROJ" rev-parse "$DEFAULT")
hold_status=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
case "$hold_status" in
  0)
    echo "error: task $ID is still held for the captain; release it before the local $ACTION" >&2
    exit 1
    ;;
  1|3) ;;
  *)
    echo "error: could not determine whether task $ID is still held for the captain; refusing to $ACTION" >&2
    exit 1
    ;;
esac
if [ "$REVERT" = 1 ]; then
  if already_reverted=$(find_recorded_revert); then
    if ! record_meta_value local_reverted "$already_reverted"; then
      echo "error: local landing $LANDED was already reverted by $already_reverted, but local_reverted= could not be recorded in the task meta" >&2
      exit 1
    fi
    echo "recovered local revert of $LANDED on local $DEFAULT in $PROJ with $already_reverted"
    exit 0
  else
    search_status=$?
    if [ "$search_status" -ne 1 ]; then
      echo "error: could not inspect local $DEFAULT history for an existing revert of $LANDED in $PROJ; refusing to revert again" >&2
      exit 1
    fi
  fi
  revert_status=0
  git -C "$PROJ" revert --no-commit "$LANDED_BEFORE..$LANDED_AFTER" >/dev/null 2>&1 || revert_status=$?
  if [ "$revert_status" -eq 0 ]; then
    git -C "$PROJ" commit -q -m "Revert local landing of $BRANCH" \
      -m "This reverts $LANDED_BEFORE..$LANDED_AFTER (task $ID)." >/dev/null 2>&1 || revert_status=$?
  fi
  if [ "$revert_status" -ne 0 ]; then
    git -C "$PROJ" revert --abort >/dev/null 2>&1 || true
    if [ "$(git -C "$PROJ" rev-parse "$DEFAULT")" = "$before" ] \
      && [ -z "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
      echo "REFUSED: the landing $LANDED does not revert cleanly onto local $DEFAULT in $PROJ; nothing was changed." >&2
    else
      echo "error: the revert of $LANDED in $PROJ failed and its abort did not restore the clean $DEFAULT at $before; inspect $PROJ by hand, nothing further was attempted" >&2
    fi
    exit 1
  fi
  after=$(git -C "$PROJ" rev-parse "$DEFAULT")
  if ! record_meta_value local_reverted "$after"; then
    echo "error: reverted $LANDED on local $DEFAULT in $PROJ with $after, but local_reverted= could not be recorded in the task meta" >&2
    exit 1
  fi
  fm_lock_release "$MERGE_CONTROL_LOCK" || true
  MERGE_CONTROL_LOCK=
  echo "reverted local landing $LANDED of $BRANCH on local $DEFAULT in $PROJ with $after"
  exit 0
fi
if [ -n "$(meta_value post_merge_watch_required)" ]; then
  echo "error: task $ID has a pending post-merge watch; retry bin/fm-post-merge.sh arm $ID instead of merging again" >&2
  exit 1
fi
if [ "$(git -C "$PROJ" rev-parse "$BRANCH")" != "$before" ]; then
  fm_post_merge_watch_required_set "$STATE" "$META" pending || {
    echo "error: could not persist the post-merge watch marker; refusing to merge" >&2
    exit 1
  }
fi
merge_status=0
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null || merge_status=$?
if [ "$merge_status" -ne 0 ]; then
  if [ -n "$(meta_value post_merge_watch_required)" ]; then
    fm_post_merge_watch_required_set "$STATE" "$META" '' || {
      echo "error: local merge failed and its watch marker could not be cleared; retry bin/fm-post-merge.sh arm $ID only if the landing occurred" >&2
      exit 1
    }
  fi
  fm_lock_release "$MERGE_CONTROL_LOCK" || true
  MERGE_CONTROL_LOCK=
  exit "$merge_status"
fi
after=$(git -C "$PROJ" rev-parse "$DEFAULT")
if [ "$after" != "$before" ] && ! record_meta_value local_landed "$before..$after"; then
  echo "actionable: merged $BRANCH into local $DEFAULT in $PROJ, but local_landed= could not be recorded in the task meta; a later --revert will refuse" >&2
fi
fm_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
[ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-fleet-ledger.sh" merged "$ID" local || true
if [ "$after" = "$before" ]; then
  echo "merged $BRANCH into local $DEFAULT ($(git -C "$PROJ" rev-parse --short "$before") -> $(git -C "$PROJ" rev-parse --short "$after")) in $PROJ"
  exit 0
fi
arm_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-post-merge.sh" arm "$ID" 2>&1) || {
  echo "error: landed $BRANCH but post-merge watch could not be armed: $arm_out" >&2
  printf 'retry: FM_HOME=%q FM_STATE_OVERRIDE=%q %q arm %q\n' \
    "$FM_HOME" "$STATE" "$SCRIPT_DIR/fm-post-merge.sh" "$ID" >&2
  exit 1
}
printf '%s\n' "$arm_out"
echo "merged $BRANCH into local $DEFAULT ($(git -C "$PROJ" rev-parse --short "$before") -> $(git -C "$PROJ" rev-parse --short "$after")) in $PROJ"
