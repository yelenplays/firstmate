#!/usr/bin/env bash
# fm-task-execution.sh - durable execution obligation, not a scheduler.
#
# Usage (FM_HOME must name the owning home):
#   approve ID --basis captain-approved|accepted-intent
#   attempt ID [--spawn-gen GENERATION]
#   started ID TOKEN                   (worker, from its isolated worktree)
#   show ID | scan | notify
#   confirmed ID                      (read-only receipt check for crew-state)
#
# approve is an explicit semantic attestation by firstmate that implementation
# is authorized for this backlog item within its existing bounded intent. It
# never infers consent from prose, a scout report, a released hold, or yolo.
# Register it at intake BEFORE dispatch or waiting for a bounded scout. A retry
# preserves the existing obligation and attempt. Legacy work needs explicit
# enrollment; unregistered parked projects are never discovered or dispatched.
#
# state/<id>.execution is private, versioned JSON written atomically under a
# per-task lock. It distinguishes authority, attempted delivery, and the
# worker's receipt. attempt rotates the token and binds its expected incarnation,
# invalidating every old receipt;
# spawn/relaunch and promotion call it before delivering instructions. Output
# is the token to put in the worker's instructions. started accepts it only
# from the recorded isolated worktree, for kind=ship, and binds the receipt
# to spawn_gen. Executing this instruction proves processing of this handoff,
# not successful implementation, activity, or progress. It is independent of
# vendor text and works even when a harness has no semantic busy source.
#
# scan derives accountable owner and concrete next action from the obligation,
# the existing backlog parser (holds/dependencies), and fm-crew-state's current
# evidence. A status-log working event or spawn-seeded busy record is never
# progress. A finished scout is never an implementing owner. Validation, idle
# turns, failed launches, and landing remain unfinished until guarded landing
# and teardown retire the obligation. Captain/dated external holds and true task
# dependencies remain with their existing owners; no hold is lifted here.
#
# notify runs only inside the existing watcher. Per-task queue keys coalesce;
# reminders recur after FM_EXECUTION_REMIND (default 300 seconds), even after
# queue acknowledgement, until current evidence changes. Reconciliation runs at
# FM_EXECUTION_SCAN_INTERVAL (default 30 seconds), independent of fleet signals.
# Drain always prints
# the outstanding firstmate actions. Neither notification nor acknowledgement
# is handling. No dispatch, send, recovery, merge, or other project mutation is
# performed here. Errors retain obligations and surface reconciliation failure.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${FM_HOME:?fm-task-execution requires explicit FM_HOME}"
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

crew_state() { fm_run_timed 10 "${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}" "$1"; }

fail() { printf 'fm-task-execution: %s\n' "$*" >&2; exit 1; }
meta() { awk -F= -v key="$2" '$1==key {v=substr($0,length(key)+2)} END {print v}' "$1" 2>/dev/null || true; }
valid_id() { fm_task_id_creation_valid "$1" || fail 'invalid task identity'; }
record_valid() {
  [ -f "$1" ] && [ ! -L "$1" ] && jq -e '
    .version == 1 and (.basis == "captain-approved" or .basis == "accepted-intent")
    and (.phase == "approved" or .phase == "attempted" or .phase == "processing")
    and (.attempt | type == "string") and (.spawn_gen | type == "string")
    and (.attempt_gen | type == "string")
  ' "$1" >/dev/null 2>&1
}
read_backlog() { "$SCRIPT_DIR/fm-fleet-snapshot.sh" --backlog-json; }
row() { printf '%s' "$BACKLOG_JSON" | jq -c --arg id "$1" '[.records[] | select(.structured and .id == $id)] | if length == 1 then .[0] else null end'; }

scan_one() {
  local id=$1 file="$STATE/$1.execution" task kind gen phase attempt receipt current busy state source wait_until hold blockers
  record_valid "$file" || { printf '%s\tfirstmate\treconcile-corrupt-execution-record\n' "$id"; return; }
  task=$(row "$id")
  if [ "$task" = null ]; then
    printf '%s\tfirstmate\treconcile-missing-backlog-item\n' "$id"; return
  fi
  if [ "$(printf '%s' "$task" | jq -r .state)" = 'done' ]; then
    printf '%s\tfirstmate\treconcile-recorded-completion-before-dispatch-or-cleanup\n' "$id"; return
  fi
  hold=$(printf '%s' "$task" | jq -r '.hold_reason // empty')
  wait_until=$(printf '%s' "$task" | jq -r '.hold_until // empty')
  if [ -n "$hold" ] && { [ -z "$wait_until" ] || [[ "$wait_until" > "$(date -u +%Y-%m-%d)" ]]; }; then
    # An undated non-captain wait needs a concrete recheck, not eternal silence.
    if [ "$(printf '%s' "$task" | jq -r '.hold_kind')" = captain ]; then
      printf '%s\tcaptain\tanswer-recorded-hold\n' "$id"
    elif [ -n "$wait_until" ]; then
      printf '%s\texternal\trecheck-at-%s\n' "$id" "$wait_until"
    else
      printf '%s\tfirstmate\treconcile-undated-external-wait\n' "$id"
    fi
    return
  fi
  blockers=$(printf '%s' "$task" | jq -r '.unresolved_blocker_ids | join(",")')
  if [ -n "$blockers" ]; then
    printf '%s\tdependency\twait-for-%s\n' "$id" "$blockers"; return
  fi
  kind=$(meta "$STATE/$id.meta" kind)
  if [ "$kind" != ship ]; then
    if [ "$kind" = scout ]; then
      current=$(crew_state "$id" 2>/dev/null || true)
      case "$current" in
        'state: working · source: pane'*)
          printf '%s\tworker\tfinish-authorized-research-then-handoff\n' "$id"; return ;;
      esac
    fi
    printf '%s\tfirstmate\timplementation owner missing; dispatch or promote within approved intent\n' "$id"; return
  fi
  phase=$(jq -r .phase "$file")
  gen=$(meta "$STATE/$id.meta" spawn_gen)
  receipt=$(jq -r .spawn_gen "$file")
  attempt=$(jq -r .attempt "$file")
  if [ "$phase" != processing ] || [ -z "$gen" ] || [ "$receipt" != "$gen" ] \
    || [ "$(jq -r .attempt_gen "$file")" != "$gen" ] || [ -z "$attempt" ]; then
    printf '%s\tfirstmate\timplementation owner unconfirmed; verify processing or recover failed handoff\n' "$id"; return
  fi
  current=$(crew_state "$id" 2>/dev/null || true)
  state=${current#state: }; state=${state%% ·*}
  source=${current#*source: }; source=${source%% ·*}
  case "$state:$source" in
    working:run-step) printf '%s\tworker\tcontinue-validation\n' "$id" ;;
    working:pane)
      busy=$(fm_busy_record_read "$STATE" "$id" 2>/dev/null || true)
      case "$busy" in
        *' fm-spawn '*|*' fm-recovery '*) printf '%s\tfirstmate\tverify-progress-not-launch-seed\n' "$id" ;;
        *) printf '%s\tworker\tcontinue-implementation\n' "$id" ;;
      esac ;;
    done:*)
      if [ -n "$(meta "$STATE/$id.meta" pr)" ] || [ "$(meta "$STATE/$id.meta" mode)" = local-only ]; then
        printf '%s\tfirstmate\tverify-landing-with-configured-approval-authority\n' "$id"
      else
        printf '%s\tfirstmate\tcontinue-selected-validation-and-PR-path\n' "$id"
      fi ;;
    parked:*|blocked:*) printf '%s\tfirstmate\treconcile-current-decision-with-configured-authority\n' "$id" ;;
    paused:*) printf '%s\tfirstmate\trecord-concrete-external-dependency-and-recheck\n' "$id" ;;
    *) printf '%s\tfirstmate\tverify-idle-or-failed-owner-and-recover-or-escalate\n' "$id" ;;
  esac
}

LOCK='' TMP=''
cleanup() {
  [ -z "$TMP" ] || rm -f -- "$TMP"
  [ -z "$LOCK" ] || fm_lock_release "$LOCK" || true
}
trap cleanup EXIT
command=${1:---help}; shift || true
case "$command" in
  -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
  scan|notify)
    found=0
    for file in "$STATE"/*.execution; do
      if [ -e "$file" ] || [ -L "$file" ]; then found=1; fi
    done
    [ "$found" = 1 ] || exit 0
    if [ "$command" = notify ]; then
      scan_marker="$STATE/.execution-scan-at"
      [ ! -L "$scan_marker" ] || fail 'scan marker is a symlink'
      now=$(date +%s); scan_interval=${FM_EXECUTION_SCAN_INTERVAL:-30}
      case "$scan_interval" in ''|*[!0-9]*) fail 'invalid scan interval' ;; esac
      last=$(awk 'NR==1 {print $1}' "$scan_marker" 2>/dev/null || true)
      case "$last" in ''|*[!0-9]*) last=0 ;; esac
      [ $((now - last)) -ge "$scan_interval" ] || exit 0
      printf '%s\n' "$now" > "$scan_marker"
    fi
    BACKLOG_JSON=$(read_backlog) || fail 'backlog reconciliation unavailable'
    for file in "$STATE"/*.execution; do
      [ -e "$file" ] || [ -L "$file" ] || continue
      id=$(basename "$file" .execution); valid_id "$id"
      line=$(scan_one "$id")
      if [ "$command" = scan ]; then printf '%s\n' "$line"; continue; fi
      owner=$(printf '%s' "$line" | cut -f2)
      [ "$owner" = firstmate ] || continue
      now=$(date +%s)
      interval=${FM_EXECUTION_REMIND:-300}
      case "$interval" in ''|*[!0-9]*) fail 'invalid reminder interval' ;; esac
      marker="$STATE/.$id.execution-notified"
      [ ! -L "$marker" ] || fail 'reminder marker is a symlink'
      previous=$(awk 'NR==1 {print $1}' "$marker" 2>/dev/null || true)
      case "$previous" in ''|*[!0-9]*) previous=0 ;; esac
      [ $((now - previous)) -ge "$interval" ] || continue
      fm_wake_append check "execution:$id" "check: execution $id" || exit 1
      printf '%s\n' "$now" > "$marker"
      printf '%s\n' "$line"
    done
    exit 0 ;;
  approve|attempt|started|show|confirmed) ;;
  *) fail 'unknown command (use --help)' ;;
esac
id=${1:-}; shift || true; valid_id "$id"
file="$STATE/$id.execution"
if [ "$command" = confirmed ]; then
  [ -e "$file" ] || [ -L "$file" ] || exit 0 # Absence never creates approval.
  record_valid "$file" || exit 1
  gen=$(meta "$STATE/$id.meta" spawn_gen)
  [ -n "$gen" ] && jq -e --arg gen "$gen" '.phase == "processing" and .spawn_gen == $gen and .attempt_gen == $gen and .attempt != ""' "$file" >/dev/null
  exit $?
fi
if [ "$command" = show ]; then
  BACKLOG_JSON=$(read_backlog); scan_one "$id"; exit 0
fi
# An inherited test or worker override must never redirect a mutation into a
# different operational home. Read-only consumers retain fixture overrides.
if [ "$command" = attempt ] && [ ! -e "$file" ] && [ ! -L "$file" ]; then exit 0; fi
home_real=$(cd "$FM_HOME" && pwd -P) || fail 'operational home is unavailable'
if [ -d "$STATE" ]; then
  [ "$(cd "$STATE" && pwd -P)" = "$home_real/state" ] || fail 'state override escapes the selected operational home'
else
  [ "$STATE" = "$FM_HOME/state" ] && [ ! -L "$STATE" ] || fail 'state override escapes the selected operational home'
fi
data_dir=${FM_DATA_OVERRIDE:-$FM_HOME/data}
[ -d "$data_dir" ] && [ "$(cd "$data_dir" && pwd -P)" = "$home_real/data" ] \
  || fail 'data override escapes the selected operational home'
mkdir -p "$STATE"
[ ! -L "$file" ] || fail 'execution record is a symlink'
LOCK="$STATE/.$id.execution.lock"
fm_lock_acquire_wait "$LOCK"
case "$command" in
  approve)
    [ "${1:-}" = --basis ] && [ "$#" = 2 ] || fail 'approve requires --basis'
    case "$2" in captain-approved|accepted-intent) basis=$2 ;; *) fail 'invalid approval basis' ;; esac
    if [ -e "$file" ]; then record_valid "$file" || fail 'invalid existing obligation'; exit 0; fi
    BACKLOG_JSON=$(read_backlog)
    task=$(row "$id")
    [ "$task" != null ] || fail 'record the backlog work item before approving execution'
    printf '%s' "$task" | jq -e '.state != "done" and .kind != "secondmate"' >/dev/null \
      || fail 'approval requires an unfinished work item, not a completed task or persistent secondmate'
    content=$(jq -n --arg basis "$basis" '{version:1,basis:$basis,phase:"approved",attempt:"",attempt_gen:"",spawn_gen:""}') ;;
  attempt)
    # Old callers without explicit implementation authority remain unenrolled.
    [ -e "$file" ] || exit 0
    record_valid "$file" || fail 'invalid execution obligation'
    gen=$(meta "$STATE/$id.meta" spawn_gen)
    if [ "$#" -gt 0 ]; then
      if [ "$#" != 2 ] || [ "$1" != --spawn-gen ] || ! fm_busy_token_valid "$2"; then
        fail 'invalid expected spawn generation'
      fi
      gen=$2
    fi
    token="e$(date +%s).${BASHPID:-$$}.$RANDOM"
    content=$(jq --arg token "$token" --arg gen "$gen" '.phase="attempted" | .attempt=$token | .attempt_gen=$gen | .spawn_gen=""' "$file") ;;
  started)
    record_valid "$file" || fail 'no valid execution obligation'
    [ "$#" = 1 ] && [ -n "$1" ] || fail 'started requires handoff token'
    [ "$(jq -r .attempt "$file")" = "$1" ] || fail 'stale or mismatched handoff token'
    [ "$(meta "$STATE/$id.meta" kind)" = ship ] || fail 'a scout or secondmate is not an implementation owner'
    wt=$(meta "$STATE/$id.meta" worktree); project=$(meta "$STATE/$id.meta" project)
    gen=$(meta "$STATE/$id.meta" spawn_gen)
    [ -n "$gen" ] && [ -d "$wt" ] && [ -d "$project" ] || fail 'missing dispatch identity'
    [ "$(jq -r .attempt_gen "$file")" = "$gen" ] || fail 'handoff belongs to another spawn incarnation'
    wt=$(cd "$wt" && pwd -P); project=$(cd "$project" && pwd -P)
    [ "$(pwd -P)" = "$wt" ] && [ "$wt" != "$project" ] \
      && [ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$wt" ] \
      || fail 'receipt must run in the isolated worker copy'
    content=$(jq --arg gen "$gen" '.phase="processing" | .spawn_gen=$gen' "$file") ;;
esac
TMP="$STATE/.$id.execution.${BASHPID:-$$}"
(umask 077; printf '%s\n' "$content" > "$TMP")
mv -f -- "$TMP" "$file"; TMP=
[ "$command" != attempt ] || printf '%s\n' "$token"
