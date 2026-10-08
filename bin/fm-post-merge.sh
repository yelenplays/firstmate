#!/usr/bin/env bash
# fm-post-merge.sh - watch a landed merge, take its witness's verdict, and revert
# it when it is found broken.
#
# The captain's rule this serves: after every merge the Jev merge gate approved,
# code watches the merge commit's checks on the default branch; a fresh witness
# agent that built none of the change uses the result where one is required
# (per merge on a live-site project against its production URL, per wave on a
# team project); and when those checks go red or the witness finds the change
# broken, firstmate opens a revert of the merge and merges it on green checks
# without asking Jev, sends the captain one line with both links, reopens the
# task, and marks the merge-gate log entry reverted. A revert is never itself
# watched or gated: it restores the earlier state. Local-only landings are
# exempt from remote default-branch check watching.
# The witness practice is adapted from korallis/agent-stack (Apache-2.0,
# https://github.com/korallis/agent-stack, rig/template/witness-slice/SPEC.md):
# a fresh agent, logins typed by name, and what it saw kept as evidence; see
# NOTICE.
#
# Usage:
#   fm-post-merge.sh arm <task-id> (--witness <url>|--no-witness <reason>) [--grace <secs>]
#   fm-post-merge.sh advance <task-id>
#   fm-post-merge.sh checks <task-id> [--settled]
#   fm-post-merge.sh witness-task <task-id>...
#   fm-post-merge.sh witness-result <report> <task-id>...
#   fm-post-merge.sh status <task-id>
#   fm-post-merge.sh close <task-id> --reason <text>
#
# arm           Run after merge acceptance, before cleanup. A PR task (any mode
#               but local-only) needs its recorded pr= to be a merged GitHub
#               pull request or an open one in GitHub's merge queue. Queued
#               watches wait for the merge before checking its commit; the
#               merge commit, head, and base are read live from GitHub.
#               A local-only task needs the local_landed= range
#               bin/fm-merge-local.sh records. Exactly one of --witness or
#               --no-witness is required. --witness names the URL a witness
#               must use; --no-witness records why none is required.
#               --grace is how long a merge commit with no checks at all is
#               still treated as pending, because checks can take a while to
#               appear (default 600). For a PR task, arm registers the wait on
#               the merge commit's checks as a condition->action watch
#               (bin/fm-procevent-when.sh) named pm-<task-id>, so firstmate is
#               woken once they settle. A local landing has no forge checks and
#               starts at the witness phase, or clear when an explicit
#               --no-witness disposition was recorded.
#               Re-arming the same merge is a no-op; a new merge of the same
#               task replaces a finished record and refuses an open one.
# advance       Take the one deterministic step the record and the live state
#               allow, and print what happened. Run it on every wake for this
#               watch. Lines it prints:
#                 waiting: <what>          nothing to do until the named wait ends
#                 witness: <what>          a witness is needed (see witness-task)
#                 clear: <what>            landing confirmed; cleanup may proceed
#                 reverting: <what>        a revert is under way
#                 approval: <what>         the revert is green but the task's
#                                          merge posture is not yolo, so its
#                                          merge needs the captain's word
#                 blocked: <what>          a check or the revert cannot proceed on its own
#                 reverted: <what>         the revert landed
#                 notify: <one line>       relay to the captain as written
# checks        Print the verdict of the checks the current phase waits on: the
#               merge commit's checks on the default branch while watching, the
#               revert pull request's head while reverting. --settled is the
#               watch condition: exit 0 once the verdict is green, red, or none
#               (or the phase waits on no checks), 1 while pending, 2 on error.
# witness-task  Print the witness instructions for one merge, or for a wave
#               of merges, to fill a witness scout's `## Firstmate spec`. Every
#               named task must be in the witness phase. Login names (never
#               values) come from bin/fm-witness-login.sh names.
# witness-result Read a witness report and record its verdict for each named
#               task, then advance each one. The report carries one line per
#               merge, bound to the full merge commit id:
#                 witness-verdict: pass <merge-commit>
#                 witness-verdict: fail <merge-commit> <one-line reason>
#               A task with no verdict line, or more than one, is refused and
#               left waiting; a pass never comes from a missing line.
# status        Print the record.
# close         End an open watch early on the captain's word (for example a
#               blocked revert the captain resolved by hand); records the words
#               as the reason. Like every step that ends a wait, it retires the
#               watch and acknowledges any result the watch already captured,
#               so nothing is re-announced after the watch ends.
#
# Phases (record field phase): checks -> witness -> clear, or checks/witness ->
# reverting -> reverted, with blocked when a revert cannot go ahead by itself
# and closed when the captain ended the watch. bin/fm-post-merge-lib.sh owns
# what cleanup does with each phase: it refuses while the watch is open and
# returns the backlog item to Queued after a revert.
#
# Check verdicts use only the latest run per check name and latest commit
# status per context. A check run that failed, timed out, or failed to start, or
# a commit status of failure or error, is red; any check still queued or running
# is pending; otherwise one or more successful checks is green. No checks, or
# only cancelled, skipped, or stale ones after the grace period, is none and
# blocks for captain review. Red wins over pending, because a failed run is final.
#
# A PR revert uses GitHub's revertPullRequest mutation, so nothing is written
# to the project locally. If a run is interrupted after opening its revert but
# before recording its URL, a matching revert-<number>- PR is recorded as a
# candidate and the watch blocks for captain review; it is never adopted or
# merged automatically. A newly opened revert is merged through
# bin/fm-pr-merge.sh, which re-checks that every check is green at the exact
# head, only when the task's recorded merge posture is yolo=on; otherwise
# advance stops at approval. Red or non-green checks on the revert, or a
# revert closed without merging, block. Only GitHub pull requests and local landings are
# supported; arm refuses anything else.
# A local revert is bin/fm-merge-local.sh --revert, which runs every guard the
# local merge runs.
#
# When a revert lands, advance appends one outcome line to state/jev-merge.jsonl
# (event post-merge, outcome reverted, with the task, project, pull request or
# branch, head, base, merge commit, revert, and cause; no evidence text), and
# returns the backlog item to Queued through bin/fm-tasks-axi.sh reopen. A
# failed reopen is reported and does not undo the revert; cleanup's own
# retention returns the item to Queued again.
#
# The record lives at state/<task-id>.post-merge (bin/fm-post-merge-lib.sh).
# Fields: version, task, spawn_gen, kind (pr|local), project, pr, head, base,
# merge_commit, landed, branch, merged_at, grace, witness,
# no_witness_reason, phase, checks, red_checks, witness_verdict,
# witness_reason, witness_report, cause,
# revert_pr, revert_candidate, revert_opened_at, revert, note.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SELF="$SCRIPT_DIR/fm-post-merge.sh"
PR_MERGE_BIN="${FM_PR_MERGE_BIN:-$SCRIPT_DIR/fm-pr-merge.sh}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-post-merge-lib.sh
. "$SCRIPT_DIR/fm-post-merge-lib.sh"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; }
# checks is a watch condition, where exit 1 means "not yet", so its errors exit 2.
DIE_STATUS=1
die() { echo "error: $*" >&2; exit "$DIE_STATUS"; }

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac
CMD=$1
shift

ID=
META=
RECORD=
RECORD_LOCK=
RECORD_LOCK_HELD=0
cleanup() {
  if [ "$RECORD_LOCK_HELD" = 1 ]; then
    fm_lock_release "$RECORD_LOCK" || true
    RECORD_LOCK_HELD=0
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

load_task() {  # <id>
  fm_pr_task_id_valid "${1-}" || { echo "error: invalid task id '${1-}'" >&2; exit 2; }
  ID=$1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  META="$STATE/$ID.meta"
  RECORD=$(fm_post_merge_record_path "$STATE" "$ID")
  RECORD_LOCK="$STATE/.post-merge-$ID.lock"
}

lock_record() {
  fm_lock_acquire_wait "$RECORD_LOCK" || die "could not lock the post-merge record for $ID"
  RECORD_LOCK_HELD=1
}

meta_get() {  # <key>
  [ -f "$META" ] && [ ! -L "$META" ] || { printf '\n'; return 0; }
  fm_post_merge_record_get "$META" "$1"
}

project_witness_target() {
  "$SCRIPT_DIR/fm-project-mode.sh" --witness "$(basename "$(meta_get project)")"
}

rget() {  # <key>
  fm_post_merge_record_get "$RECORD" "$1"
}

record_present() {
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] && [ "$(rget version)" = fm-post-merge-v1 ]
}

# Rewrite the record with each <key>=<value> argument replacing that key's
# earlier value. The caller holds the record lock. A value never spans lines.
rset() {
  local tmp line key pair found
  local -a pairs=("$@")
  for pair in "${pairs[@]}"; do
    case "$pair" in
      *$'\n'*) die "record value for ${pair%%=*} spans lines" ;;
    esac
  done
  umask 077
  tmp=$(mktemp "$STATE/.fm-post-merge.XXXXXX") || die "could not write the post-merge record for $ID"
  if [ -f "$RECORD" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      key=${line%%=*}
      found=0
      for pair in "${pairs[@]}"; do
        [ "${pair%%=*}" = "$key" ] && { found=1; break; }
      done
      [ "$found" = 1 ] || printf '%s\n' "$line" >> "$tmp"
    done < "$RECORD"
  fi
  for pair in "${pairs[@]}"; do
    printf '%s\n' "$pair" >> "$tmp"
  done
  if ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    die "could not write the post-merge record for $ID"
  fi
}

now() { date +%s; }

short() { printf '%s\n' "${1:0:12}"; }

# A procevent-when watch name: pm-<id> or pmr-<id>, shortened with a stable
# hash suffix when the task id is too long for a source id.
watch_name() {  # <prefix>
  local name="$1-$ID" sum
  if [ "${#name}" -gt 59 ]; then
    sum=$(printf '%s' "$ID" | cksum | cut -d' ' -f1)
    name="$1-${ID:0:40}-$sum"
    name=${name:0:59}
  fi
  printf '%s\n' "$name"
}

arm_watch() {  # <prefix>
  local name out status=0
  name=$(watch_name "$1")
  out=$("$SCRIPT_DIR/fm-procevent-when.sh" arm "$name" --interval 60 --stable 1 --deadline 21600 \
    --condition "$SELF" checks "$ID" --settled --action "$SELF" checks "$ID" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    echo "warning: could not arm the wait $name: $out; run bin/fm-post-merge.sh advance $ID again to retry" >&2
    return 1
  fi
}

# Every caller is a terminal path of the watch, whose record now owns the
# outcome, so it also acknowledges any captured result the watch left behind;
# retiring alone leaves that result re-announced on every reconcile.
retire_watch() {  # <prefix>
  local sid result base
  sid="when-$(watch_name "$1")"
  "$SCRIPT_DIR/fm-procevent-when.sh" retire "${sid#when-}" >/dev/null 2>&1 || true
  while IFS= read -r result; do
    base=${result%.result}
    [ "${base%.*}" = "$(fm_procevent_inbox_dir "$STATE")/$sid" ] || continue
    "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "${base##*.}" >/dev/null 2>&1 \
      || echo "warning: could not acknowledge the captured result of $sid; run bin/fm-procevent.sh handled $sid ${base##*.}" >&2
  done < <(fm_procevent_pending "$STATE")
}

need_gh() {
  command -v gh >/dev/null 2>&1 || die "gh is required for a pull request's post-merge watch"
  command -v jq >/dev/null 2>&1 || die "jq is required for a pull request's post-merge watch"
}

# Parse the record's pull request URL into FM_PR_* (GitHub only).
parse_record_pr() {
  local url
  url=$(rget pr)
  fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] \
    || die "the post-merge record for $ID names no GitHub pull request"
}

# Read the live GitHub pull request fields used by the post-merge watch.
# Use GraphQL for isInMergeQueue rather than relying on gh pr view --json
# exposing that field.
read_merge_pr() {  # <url>
  local url=$1 json
  fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] || return 1
  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  json=$(gh api graphql --hostname "$FM_PR_HOST" \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state isInMergeQueue mergeCommit{oid} headRefOid baseRefName id title}}}' \
    -f "owner=$FM_PR_OWNER" -f "repo=$FM_PR_REPO" -F "number=$FM_PR_NUMBER" \
    2>/dev/null) || return 1
  printf '%s' "$json" | jq -e -c '
    if (.data.repository.pullRequest? | type) == "object" then
      .data.repository.pullRequest
    else
      error("missing pull request")
    end
  ' 2>/dev/null
}

# Verdict of one commit's checks on GitHub. Sets VERDICT (green|red|pending|none)
# and VERDICT_NAMES (the red checks, comma-separated). Returns 1 on a read error.
VERDICT=
VERDICT_NAMES=
LIVE_MERGE_SHA=
LIVE_MERGE_HEAD=
LIVE_MERGE_BASE=
REQUIRED_CONTEXTS=[]
github_read_required_contexts() {
  local base=$1 branch_path branch_json rules_json classic ruleset api_err api_err_text
  REQUIRED_CONTEXTS=[]
  [ -n "$base" ] || return 1
  branch_path=$(printf '%s' "$base" | jq -sRr '@uri') || return 1
  branch_json=$(fm_gh_owner_run "$FM_PR_OWNER" gh api --hostname "$FM_PR_HOST" \
    "repos/$FM_PR_PATH/branches/$branch_path" 2>/dev/null) || return 1
  classic=$(printf '%s' "$branch_json" | jq -c '
    if type != "object" or (.protected | type) != "boolean" then error("invalid branch response")
    elif .protected == false then []
    elif (.protection | type) != "object" then error("invalid branch protection")
    elif (.protection | has("required_status_checks") | not) then error("invalid branch protection")
    elif .protection.required_status_checks == null then []
    elif (.protection.required_status_checks | type) != "object" then error("invalid branch protection")
    else .protection.required_status_checks as $checks
      | [ (($checks.checks // [])[] | {context, app_id}),
          (($checks.contexts // [])[] | {context: ., app_id: null}) ]
      | map(if (.context | type) == "string" and (.context | length) > 0
              and (.app_id == null or (.app_id | type) == "number")
            then . else error("invalid required check") end)
      | map(if .app_id == -1 then .app_id = null else . end)
    end' 2>/dev/null) || return 1
  api_err=$(mktemp "${TMPDIR:-/tmp}/fm-post-merge-rules.XXXXXX") || return 1
  if ! rules_json=$(fm_gh_owner_run "$FM_PR_OWNER" gh api --hostname "$FM_PR_HOST" --paginate \
    "repos/$FM_PR_PATH/rules/branches/$branch_path" 2>"$api_err"); then
    api_err_text=$(cat "$api_err" 2>/dev/null)
    rm -f "$api_err"
    case "$api_err_text" in
      *"Upgrade to GitHub Pro or make this repository public"*) ruleset='[]' ;;
      *) return 1 ;;
    esac
  else
    rm -f "$api_err"
    ruleset=$(printf '%s' "$rules_json" | jq -c '
    if type != "array" then error("invalid rules response")
    else [ .[] | if type != "object" then error("invalid rule") else . end
      | select(.type == "required_status_checks")
      | if (.parameters.required_status_checks | type) != "array" then error("invalid required check rule")
        else .parameters.required_status_checks[] end
      | if (.context | type) == "string" and (.context | length) > 0
           and (.integration_id == null or (.integration_id | type) == "number")
        then {context, app_id: .integration_id} else error("invalid required check rule") end
      | if .app_id == -1 then .app_id = null else . end ]
    end' 2>/dev/null) || return 1
  fi
  REQUIRED_CONTEXTS=$(jq -cn --argjson classic "$classic" --argjson ruleset "$ruleset" '
    ($classic + $ruleset) | unique_by([.context, .app_id]) | group_by(.context)
    | map(if any(.[]; .app_id != null) then map(select(.app_id != null)) else . end) | add // []') || return 1
}

required_check_states() {  # <requirements-json> <run-rows-json> <status-rows-json>
  jq -nr --argjson required "$1" --argjson runs "$2" --argjson statuses "$3" '
    def latest_runs: group_by([.name, (.app_id // -1)])
      | map(max_by([(.created_at // ""), (.id // 0)]));
    def latest_statuses: group_by(.context)
      | map(max_by([(.updated_at // .created_at // ""), (.id // 0)]));
    [ $required[] as $requirement
      | ($runs | latest_runs | map(select(.name == $requirement.context
          and ($requirement.app_id == null or .app_id == $requirement.app_id)))) as $check_runs
      | ($statuses | latest_statuses | map(select($requirement.app_id == null
          and .context == $requirement.context))) as $contexts
      | if (($check_runs | length) + ($contexts | length)) == 0 then
          {context: $requirement.context, state: "missing"}
        elif (any($check_runs[]; .status == "completed"
              and (.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure"))
              or any($contexts[]; .state == "failure" or .state == "error")) then
          {context: $requirement.context, state: "red"}
        elif (any($check_runs[]; .status == "completed"
              and (.conclusion == "success" or .conclusion == "neutral"))
              or any($contexts[]; .state == "success")) then
          {context: $requirement.context, state: "green"}
        elif any($check_runs[]; .status != "completed")
              or any($check_runs[]; .status == "completed"
                and (.conclusion != "cancelled" and .conclusion != "skipped" and .conclusion != "stale"))
              or any($contexts[]; .state != "failure" and .state != "error" and .state != "success") then
          {context: $requirement.context, state: "pending"}
        else
          {context: $requirement.context, state: "not_green"}
        end
    ][] | [.context, .state] | @tsv
  ' 2>/dev/null
}

commit_verdict() {  # <sha> <since-epoch> <grace>
  local sha=$1 since=$2 grace=$3 run_rows status_rows runs statuses name status conclusion state
  local required_states required_json status_json required_not_green='' required_red=''
  local red='' pending=0 good=0
  VERDICT=
  VERDICT_NAMES=
  run_rows=$(gh api --hostname "$FM_PR_HOST" "repos/$FM_PR_PATH/commits/$sha/check-runs?per_page=100" --paginate \
    --jq '.check_runs[] | {name, status, conclusion, created_at, started_at, completed_at, id, app_id: (.app.id // null)}' 2>/dev/null) || return 1
  status_rows=$(gh api --hostname "$FM_PR_HOST" "repos/$FM_PR_PATH/commits/$sha/status" \
    --jq '.statuses[] | {context, state, created_at, updated_at, id}' 2>/dev/null) || return 1
  github_read_required_contexts "$(rget base)" || return 1
  required_json=$(printf '%s\n' "$run_rows" | jq -sc '.') || return 1
  status_json=$(printf '%s\n' "$status_rows" | jq -sc '.') || return 1
  required_states=$(required_check_states "$REQUIRED_CONTEXTS" "$required_json" "$status_json") || return 1
  while IFS=$'\t' read -r name state; do
    case "$state" in
      missing|not_green) required_not_green="${required_not_green:+$required_not_green,}$name" ;;
      red) required_red="${required_red:+$required_red,}$name" ;;
    esac
  done <<EOF
$required_states
EOF
  [ -z "$required_red" ] || red=$required_red
  if [ -n "$run_rows" ]; then
    runs=$(printf '%s\n' "$run_rows" | jq -sr '
      group_by([.name, (.app_id // -1)]) | map(max_by([(.created_at // ""), (.id // 0)]))[] |
      [.name, .status, (.conclusion // "")] | @tsv
    ') || return 1
  else
    runs=
  fi
  if [ -n "$status_rows" ]; then
    statuses=$(printf '%s\n' "$status_rows" | jq -sr '
      group_by(.context) | map(max_by([(.updated_at // .created_at // ""), (.id // 0)]))[] |
      [.context, .state] | @tsv
    ') || return 1
  else
    statuses=
  fi
  while IFS=$'\t' read -r name status conclusion; do
    [ -n "$name" ] || continue
    case "$status" in
      completed)
        case "$conclusion" in
          success|neutral) good=$((good + 1)) ;;
          failure|timed_out|startup_failure)
            case ",$red," in *",$name,"*) ;; *) red="${red:+$red,}$name" ;; esac
            ;;
          cancelled|skipped|stale) ;;
          *) pending=$((pending + 1)) ;;
        esac
        ;;
      *) pending=$((pending + 1)) ;;
    esac
  done <<EOF
$runs
EOF
  while IFS=$'\t' read -r name state; do
    [ -n "$name" ] || continue
    case "$state" in
      success) good=$((good + 1)) ;;
      failure|error)
        case ",$red," in *",$name,"*) ;; *) red="${red:+$red,}$name" ;; esac
        ;;
      *) pending=$((pending + 1)) ;;
    esac
  done <<EOF
$statuses
EOF
  if [ -n "$red" ]; then
    VERDICT=red
    VERDICT_NAMES=$red
  elif [ "$pending" -gt 0 ]; then
    VERDICT=pending
  elif [ -n "$required_not_green" ]; then
    VERDICT_NAMES=$required_not_green
    if [ "$(( $(now) - since ))" -lt "$grace" ]; then VERDICT=pending; else VERDICT=none; fi
  elif [ "$good" -gt 0 ]; then
    VERDICT=green
  elif [ "$(( $(now) - since ))" -lt "$grace" ]; then
    VERDICT=pending
  else
    VERDICT=none
  fi
}

# Live state of the revert pull request: REVERT_STATE and REVERT_HEAD.
REVERT_STATE=
REVERT_HEAD=
read_revert_pr() {
  local url json
  url=$(rget revert_pr)
  json=$(gh pr view "$url" --json state,headRefOid 2>/dev/null) || return 1
  REVERT_STATE=$(printf '%s' "$json" | jq -r '.state // ""') || return 1
  REVERT_HEAD=$(printf '%s' "$json" | jq -r '.headRefOid // ""') || return 1
  [ -n "$REVERT_STATE" ]
}

# The checks the current phase waits on. Sets VERDICT; returns 1 on a read
# error, 3 when the phase waits on no checks.
phase_verdict() {
  local phase grace merge json state queued head base
  LIVE_MERGE_SHA=
  LIVE_MERGE_HEAD=
  LIVE_MERGE_BASE=
  phase=$(rget phase)
  grace=$(rget grace)
  case "$phase" in
    checks)
      need_gh
      parse_record_pr
      merge=$(rget merge_commit)
      if [ -z "$merge" ]; then
        json=$(read_merge_pr "$(rget pr)") || return 1
        state=$(printf '%s' "$json" | jq -r '.state // ""') || return 1
        queued=$(printf '%s' "$json" | jq -r '.isInMergeQueue // false') || return 1
        case "$state:$queued" in
          OPEN:true)
            VERDICT=pending
            VERDICT_NAMES=
            return 0
            ;;
          MERGED:*) ;;
          *) VERDICT=none; VERDICT_NAMES=; return 0 ;;
        esac
        merge=$(printf '%s' "$json" | jq -r '.mergeCommit.oid // ""') || return 1
        head=$(printf '%s' "$json" | jq -r '.headRefOid // ""') || return 1
        base=$(printf '%s' "$json" | jq -r '.baseRefName // ""') || return 1
        fm_pr_head_valid "$merge" && [ -n "$base" ] || return 1
        LIVE_MERGE_SHA=$merge
        LIVE_MERGE_HEAD=$head
        LIVE_MERGE_BASE=$base
        commit_verdict "$merge" "$(now)" "${grace:-600}"
      else
        commit_verdict "$merge" "$(rget merged_at)" "${grace:-600}"
      fi
      ;;
    reverting)
      [ "$(rget kind)" = pr ] && [ -n "$(rget revert_pr)" ] || return 3
      need_gh
      parse_record_pr
      read_revert_pr || return 1
      [ "$REVERT_STATE" = OPEN ] || return 3
      commit_verdict "$REVERT_HEAD" "$(rget revert_opened_at)" "${grace:-600}"
      ;;
    *) return 3 ;;
  esac
}

persist_live_merge() {
  local release=0
  [ -n "$LIVE_MERGE_SHA" ] || return 0
  if [ "$RECORD_LOCK_HELD" != 1 ]; then
    lock_record
    release=1
  fi
  if record_present && [ "$(rget phase)" = checks ] && [ -z "$(rget merge_commit)" ]; then
    rset "head=$LIVE_MERGE_HEAD" "base=$LIVE_MERGE_BASE" "merge_commit=$LIVE_MERGE_SHA" "merged_at=$(now)"
  fi
  if [ "$release" = 1 ]; then
    fm_lock_release "$RECORD_LOCK" || die "could not unlock the post-merge record for $ID"
    RECORD_LOCK_HELD=0
  fi
}

cmd_checks() {
  local settled=0 status=0 target merge
  DIE_STATUS=2
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  load_task "$1"
  shift
  [ "${1:-}" = --settled ] && { settled=1; shift; }
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  record_present || { echo "error: no post-merge watch for $ID" >&2; exit 2; }
  phase_verdict || status=$?
  case "$status" in
    0) ;;
    3)
      echo "post-merge $ID: phase $(rget phase) waits on no checks"
      exit 0
      ;;
    *)
      echo "error: could not read the checks for $ID's post-merge watch" >&2
      exit 2
      ;;
  esac
  persist_live_merge || die "could not record the merge commit for $ID's post-merge watch"
  case "$(rget phase)" in
    checks)
      merge=$(rget merge_commit)
      [ -n "$merge" ] || merge=$LIVE_MERGE_SHA
      if [ -n "$merge" ]; then target="merge commit $(short "$merge") on $(rget base)"; else target="queued pull request $(rget pr)"; fi
      ;;
    *) target="revert $(rget revert_pr)" ;;
  esac
  echo "post-merge $ID: $target checks $VERDICT${VERDICT_NAMES:+: $VERDICT_NAMES}"
  if [ "$settled" = 1 ] && [ "$VERDICT" = pending ]; then
    exit 1
  fi
  exit 0
}

cmd_arm() {
  local witness='' registered_witness='' no_witness_reason='' witness_choice='' grace=600 kind mode pr url json state queued merge head base node title landed gen phase old_phase merged_at
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  load_task "$1"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --witness)
        [ -z "$witness_choice" ] || die "choose exactly one of --witness or --no-witness"
        witness_choice=witness
        [ "$#" -ge 2 ] || die "--witness needs a URL"
        case "$2" in
          http://*|https://*) witness=$2 ;;
          *) die "--witness needs an http(s) URL" ;;
        esac
        case "$witness" in
          *[[:space:]]*) die "--witness URL must not contain whitespace" ;;
        esac
        shift 2
        ;;
      --no-witness)
        [ -z "$witness_choice" ] || die "choose exactly one of --witness or --no-witness"
        witness_choice=no-witness
        [ "$#" -ge 2 ] && [ -n "$(printf '%s' "${2:-}" | tr -d '[:space:]')" ] || die "--no-witness needs a reason"
        case "$2" in *$'\n'*) die "--no-witness reason must be one line" ;; esac
        no_witness_reason=$(printf '%s' "$2" | tr '\t' ' ')
        shift 2
        ;;
      --grace)
        [ "$#" -ge 2 ] || die "--grace needs seconds"
        case "$2" in ''|*[!0-9]*) die "--grace needs whole seconds" ;; esac
        grace=$2
        shift 2
        ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  [ -f "$META" ] && [ ! -L "$META" ] || die "no task meta for $ID"
  registered_witness=$(project_witness_target) || die "could not read the project's registered witness target"
  if [ -n "$registered_witness" ]; then
    [ "$witness_choice" != no-witness ] || die "$(basename "$(meta_get project)") requires its registered witness at $registered_witness; --no-witness is refused"
    if [ -n "$witness" ] && [ "$witness" != "$registered_witness" ]; then
      die "$(basename "$(meta_get project)") requires its registered witness at $registered_witness"
    fi
    witness=$registered_witness
    witness_choice=witness
  elif [ -n "$(meta_get post_merge_watch_required)" ] && [ -z "$witness_choice" ]; then
    witness_choice=no-witness
    no_witness_reason='project has no registered witness target'
  fi
  [ -n "$witness_choice" ] || die "choose exactly one of --witness <url> or --no-witness <reason>"
  mode=$(meta_get mode)
  gen=$(meta_get spawn_gen)
  if [ "$mode" = local-only ]; then
    kind=local
    landed=$(meta_get local_landed)
    [ -n "$landed" ] || die "task $ID has no recorded local landing; arm after bin/fm-merge-local.sh $ID"
    merge=${landed#*..}
    head=$merge
    base=
  else
    kind="pr"
    pr=$(meta_get pr)
    [ -n "$pr" ] || die "task $ID has no recorded pull request; arm after bin/fm-pr-merge.sh"
    fm_pr_url_parse "$pr" || die "task $ID has an unreadable pull request URL"
    [ "$FM_PR_PROVIDER" = github ] || die "the post-merge watch supports GitHub pull requests and local landings; $pr is not one, so watch it by hand"
    url=$FM_PR_URL
    need_gh
    json=$(read_merge_pr "$url") \
      || die "could not read $url from GitHub"
    state=$(printf '%s' "$json" | jq -r '.state // ""')
    queued=$(printf '%s' "$json" | jq -r '.isInMergeQueue // false')
    merge=$(printf '%s' "$json" | jq -r '.mergeCommit.oid // ""')
    head=$(printf '%s' "$json" | jq -r '.headRefOid // ""')
    base=$(printf '%s' "$json" | jq -r '.baseRefName // ""')
    node=$(printf '%s' "$json" | jq -r '.id // ""')
    title=$(printf '%s' "$json" | jq -r '.title // ""' | tr '\n\t' '  ')
    case "$state:$queued" in
      MERGED:*)
        fm_pr_head_valid "$merge" || die "GitHub reported no merge commit for $url"
        merged_at=$(now)
        ;;
      OPEN:true)
        fm_pr_head_valid "$head" || die "GitHub reported no head commit for queued pull request $url"
        merged_at=
        ;;
      *) die "$url is not merged or queued (state ${state:-unknown}); arm only after merge acceptance" ;;
    esac
    [ -n "$node" ] || die "GitHub reported no node id for $url"
  fi
  lock_record
  if record_present && [ "$(rget spawn_gen)" = "$gen" ]; then
    old_phase=$(rget phase)
    if [ "$(rget kind)" = pr ] && [ "$old_phase" = checks ] \
      && [ -z "$(rget merge_commit)" ] && [ "$(rget pr)" = "$url" ] \
      && [ "$state" = MERGED ] && [ -n "$merge" ]; then
      rset "head=$head" "base=$base" "merge_commit=$merge" "merged_at=$merged_at"
    fi
    if [ "$(rget merge_commit)" = "$merge" ]; then
      if [ "$(rget kind)" = pr ] && [ "$old_phase" = checks ]; then
        arm_watch pm || die "could not arm the post-merge checks watch for $ID; retry bin/fm-post-merge.sh arm $ID"
      fi
      fm_post_merge_watch_required_set "$STATE" "$META" '' || die "watch for $ID exists but its pending marker could not be cleared; retry bin/fm-post-merge.sh arm $ID"
      echo "armed: post-merge watch for $ID on $(short "$merge") is already in phase $old_phase"
      exit 0
    fi
    case "$old_phase" in
      clear|closed|reverted) ;;
      *) die "task $ID already has an open post-merge watch on $(short "$(rget merge_commit)") (phase $old_phase); finish or close it first" ;;
    esac
  fi
  rm -f -- "$RECORD"
  if [ "$kind" = pr ]; then
    phase=checks
    rset version=fm-post-merge-v1 "task=$ID" "spawn_gen=$gen" kind=pr "project=$(meta_get project)" \
      "pr=$url" "pr_node=$node" "pr_title=$title" "head=$head" "base=$base" "merge_commit=$merge" \
      "branch=$(meta_get branch)" "merged_at=$merged_at" "grace=$grace" "witness=$witness" \
      "no_witness_reason=$no_witness_reason" "phase=$phase"
    arm_watch pm || die "could not arm the post-merge checks watch for $ID; retry bin/fm-post-merge.sh arm $ID"
  else
    if [ -n "$witness" ]; then phase=witness; else phase=clear; fi
    rset version=fm-post-merge-v1 "task=$ID" "spawn_gen=$gen" kind=local "project=$(meta_get project)" \
      "landed=$landed" "head=$head" "merge_commit=$merge" "branch=$(meta_get branch)" \
      "merged_at=$(now)" "grace=$grace" "witness=$witness" \
      "no_witness_reason=$no_witness_reason" "phase=$phase"
  fi
  fm_post_merge_watch_required_set "$STATE" "$META" '' || die "watch for $ID was recorded but its pending marker could not be cleared; retry bin/fm-post-merge.sh arm $ID"
  if [ "$witness_choice" = no-witness ]; then log_no_witness "$no_witness_reason"; fi
  if [ -n "$merge" ]; then
    echo "armed: post-merge watch for $ID on $(short "$merge") (phase $phase)"
  else
    echo "armed: post-merge watch for queued $url (phase $phase)"
  fi
  [ "$phase" != witness ] || echo "witness: a witness must use $witness; fill its instructions from bin/fm-post-merge.sh witness-task $ID"
  [ "$phase" != clear ] || echo "clear: no checks or witness to wait on for $ID's local landing; cleanup may proceed"
}

log_no_witness() {
  local reason=$1 log="$STATE/jev-merge.jsonl" line
  command -v jq >/dev/null 2>&1 || die "jq is required to audit a no-witness decision"
  line=$(jq -cn --arg ts "$(now)" --arg task "$ID" --arg project "$(basename "$(rget project)")" \
    --arg kind "$(rget kind)" --arg pr "$(rget pr)" --arg branch "$(rget branch)" \
    --arg head "$(rget head)" --arg base "$(rget base)" --arg merge "$(rget merge_commit)" \
    --arg reason "$reason" \
    '{ts: ($ts | tonumber), event: "post-merge", outcome: "witness-waived", task: $task,
      project: $project, kind: $kind, pr: $pr, branch: $branch, head: $head, base: $base,
      merge_commit: $merge, reason: $reason}') || die "could not compose the no-witness audit row"
  printf '%s\n' "$line" >> "$log" || die "could not append the no-witness audit row to $log"
}

# What the revert is for, in plain words, from the record.
revert_cause_text() {
  case "$(rget cause)" in
    checks-red) printf 'the checks on %s went red after the merge (%s)\n' "${1:-the default branch}" "$(rget red_checks)" ;;
    witness-fail) printf 'the witness found it broken: %s\n' "$(rget witness_reason)" ;;
    *) printf 'it was found broken\n' ;;
  esac
}

log_reverted() {
  local log="$STATE/jev-merge.jsonl" line
  command -v jq >/dev/null 2>&1 || { echo "warning: jq is unavailable; the reverted outcome was not logged to $log" >&2; return 1; }
  line=$(jq -cn --arg ts "$(now)" --arg task "$ID" --arg project "$(basename "$(rget project)")" \
    --arg kind "$(rget kind)" --arg pr "$(rget pr)" --arg branch "$(rget branch)" --arg head "$(rget head)" \
    --arg base "$(rget base)" --arg merge "$(rget merge_commit)" --arg revert "$(rget revert)" \
    --arg cause "$(rget cause)" \
    '{ts: ($ts | tonumber), event: "post-merge", outcome: "reverted", task: $task, project: $project,
      kind: $kind, pr: $pr, branch: $branch, head: $head, base: $base, merge_commit: $merge,
      revert: $revert, cause: $cause}') || { echo "warning: the reverted outcome could not be composed for $log" >&2; return 1; }
  printf '%s\n' "$line" >> "$log" || { echo "warning: the reverted outcome could not be appended to $log" >&2; return 1; }
}

finish_reverted() {
  local reason notify reopen_out
  log_reverted || die "could not record the reverted outcome in $STATE/jev-merge.jsonl; retry bin/fm-post-merge.sh advance $ID"
  rset phase=reverted "reverted_at=$(now)"
  retire_watch pm
  retire_watch pmr
  if ! reopen_out=$("$SCRIPT_DIR/fm-tasks-axi.sh" reopen "$ID" 2>&1); then
    echo "warning: the backlog item $ID could not be reopened ($reopen_out); cleanup returns it to Queued, or reopen it by hand" >&2
  fi
  reason=$(revert_cause_text "$(rget base)")
  if [ "$(rget kind)" = pr ]; then
    echo "reverted: $(rget pr) by $(rget revert)"
    notify="Reverted $(rget pr) with $(rget revert) because $reason; the task is back in the queue."
  else
    echo "reverted: local landing $(rget landed) by $(rget revert)"
    notify="Reverted the local landing of $(rget branch) in $(basename "$(rget project)") (revert commit $(short "$(rget revert)")) because $reason; the task is back in the queue."
  fi
  echo "notify: $notify"
  echo "cleanup: run bin/fm-teardown.sh $ID when its worker is done; cleanup keeps the item Queued"
}

# Open a new revert pull request; never adopt a candidate after interruption.
ensure_revert_pr() {
  local number url body listing head_ref revert_branch
  [ -z "$(rget revert_pr)" ] || return 0
  number=$FM_PR_NUMBER
  # A revert is opened only once GitHub has positively answered that no
  # earlier one exists; a listing error is not an empty listing. GitHub names
  # a revert's branch revert-<number>-<head branch>, so ask for exactly that
  # branch rather than scanning a window of recent pull requests.
  head_ref=$(gh pr view "$(rget pr)" --json headRefName 2>/dev/null | jq -r '.headRefName // ""' 2>/dev/null) || head_ref=
  [ -n "$head_ref" ] \
    || die "could not read the head branch of $(rget pr) to check for an earlier revert; retry bin/fm-post-merge.sh advance $ID"
  revert_branch="revert-$number-$head_ref"
  listing=$(gh pr list -R "$FM_PR_HOST/$FM_PR_PATH" --head "$revert_branch" --state all --json url,headRefName 2>/dev/null) \
    || die "could not list pull requests to check for an earlier revert of $(rget pr); retry bin/fm-post-merge.sh advance $ID"
  url=$(printf '%s' "$listing" | jq -r --arg branch "$revert_branch" '
    if type != "array" then error("pull request listing is not an array")
    else [ .[] | select(.headRefName == $branch) | .url ] | first // "" end' 2>/dev/null) \
    || die "could not read the pull request listing while checking for an earlier revert of $(rget pr); retry bin/fm-post-merge.sh advance $ID"
  if [ -n "$url" ]; then
    rset phase=blocked "revert_candidate=$url" "note=interrupted revert candidate needs captain review"
    echo "blocked: found $url while recovering the revert of $(rget pr); it was not adopted or merged"
    echo "notify: $(rget pr) broke $(rget base) ($(revert_cause_text "$(rget base)")); existing revert candidate $url needs captain review."
    return 2
  fi
  body="Automatic revert of $(rget pr) (merge commit $(rget merge_commit)): $(revert_cause_text "$(rget base)")."
  # shellcheck disable=SC2016  # $id and $body are GraphQL variables, not shell.
  url=$(gh api graphql --hostname "$FM_PR_HOST" \
    -f query='mutation($id: ID!, $body: String!) { revertPullRequest(input: {pullRequestId: $id, body: $body}) { revertPullRequest { url } } }' \
    -f id="$(rget pr_node)" -f body="$body" \
    --jq '.data.revertPullRequest.revertPullRequest.url' 2>&1) || {
    echo "blocked: GitHub refused to open a revert of $(rget pr): $url"
    echo "notify: $(rget pr) broke $(rget base) ($(revert_cause_text "$(rget base)")), and GitHub refused to open its revert, so the broken change is still live and needs you."
    rset phase=blocked "note=revert could not be opened"
    exit 0
  }
  fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] || die "GitHub returned an unexpected revert URL '$url'"
  parse_record_pr
  rset "revert_pr=$url" "revert_opened_at=$(now)"
  echo "reverting: opened $url to revert $(rget pr)"
}

advance_reverting_pr() {
  local out status=0 grace
  need_gh
  parse_record_pr
  if ensure_revert_pr; then
    :
  else
    status=$?
    [ "$status" -eq 2 ] && return 0
    die "could not prepare a revert pull request for $(rget pr)"
  fi
  read_revert_pr || die "could not read $(rget revert_pr) from GitHub"
  case "$REVERT_STATE" in
    MERGED)
      rset "revert=$(rget revert_pr)"
      finish_reverted
      return 0
      ;;
    OPEN) ;;
    *)
      rset phase=blocked "note=revert pull request is $REVERT_STATE"
      echo "blocked: $(rget revert_pr) is $REVERT_STATE without merging"
      echo "notify: $(rget pr) broke $(rget base) ($(revert_cause_text "$(rget base)")), but its revert $(rget revert_pr) was closed without merging, so the broken change is still live and needs you."
      return 0
      ;;
  esac
  grace=$(rget grace)
  commit_verdict "$REVERT_HEAD" "$(rget revert_opened_at)" "${grace:-600}" || die "could not read the checks on $(rget revert_pr)"
  case "$VERDICT" in
    pending)
      arm_watch pmr || die "could not re-arm the revert checks watch for $ID; retry bin/fm-post-merge.sh advance $ID"
      echo "waiting: checks on the revert $(rget revert_pr) are still running"
      return 0
      ;;
    red)
      retire_watch pmr
      rset phase=blocked "note=revert checks red: $VERDICT_NAMES"
      echo "blocked: the revert $(rget revert_pr) has red checks ($VERDICT_NAMES)"
      echo "notify: $(rget pr) broke $(rget base) ($(revert_cause_text "$(rget base)")), and its revert $(rget revert_pr) has red checks ($VERDICT_NAMES), so the broken change is still live and needs you."
      return 0
      ;;
    none)
      retire_watch pmr
      rset phase=blocked "note=revert checks are not green (none)"
      echo "blocked: the revert $(rget revert_pr) has no green checks (none)"
      echo "notify: $(rget pr) broke $(rget base) ($(revert_cause_text "$(rget base)")), and its revert $(rget revert_pr) has no green checks, so the broken change is still live and needs you."
      return 0
      ;;
    green) ;;
  esac
  retire_watch pmr
  if [ "$(meta_get yolo)" != on ]; then
    echo "approval: the revert $(rget revert_pr) of $(rget pr) is green; this task's merges need the captain's word, so ask before merging it with bin/fm-pr-merge.sh $ID $(rget revert_pr)"
    return 0
  fi
  out=$("$PR_MERGE_BIN" "$ID" "$(rget revert_pr)" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    echo "error: merging the revert $(rget revert_pr) was refused; fix what the merge names and run bin/fm-post-merge.sh advance $ID again" >&2
    exit 1
  fi
  rset "revert=$(rget revert_pr)"
  finish_reverted
}

advance_reverting_local() {
  local out status=0 sha
  sha=$(meta_get local_reverted)
  if [ -z "$sha" ]; then
    out=$("$SCRIPT_DIR/fm-merge-local.sh" --revert "$ID" 2>&1) || status=$?
    sha=$(meta_get local_reverted)
    if [ "$status" -ne 0 ] && [ -z "$sha" ]; then
      printf '%s\n' "$out" >&2
      echo "error: the local revert of $(rget landed) was refused; fix what it names and run bin/fm-post-merge.sh advance $ID again" >&2
      exit 1
    fi
  fi
  [ -n "$sha" ] || die "the local revert of $(rget landed) finished without recording local_reverted"
  rset "revert=$sha"
  finish_reverted
}

start_revert() {  # <cause>
  rset phase=reverting "cause=$1"
  retire_watch pm
  if [ "$(rget kind)" = pr ]; then
    advance_reverting_pr
  else
    advance_reverting_local
  fi
}

cmd_advance() {
  local phase status=0 required_witness
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  load_task "$1"
  lock_record
  record_present || die "no post-merge watch for $ID"
  required_witness=$(project_witness_target) || die "could not read the project's registered witness target"
  phase=$(rget phase)
  case "$phase" in
    checks)
      phase_verdict || status=$?
      [ "$status" -eq 0 ] || die "could not read the checks on $ID's merge commit"
      persist_live_merge || die "could not record the merge commit for $ID's post-merge watch"
      case "$VERDICT" in
        pending)
          arm_watch pm || die "could not re-arm the post-merge checks watch for $ID; retry bin/fm-post-merge.sh advance $ID"
          if [ -n "$(rget merge_commit)" ]; then
            echo "waiting: checks on merge commit $(short "$(rget merge_commit)") on $(rget base) are still running"
          else
            echo "waiting: pull request $(rget pr) remains in GitHub's merge queue"
          fi
          ;;
        red)
          rset checks=red "red_checks=$VERDICT_NAMES"
          start_revert checks-red
          ;;
        none)
          retire_watch pm
          if [ -z "$(rget merge_commit)" ]; then
            rset checks=none phase=blocked "note=queued pull request is no longer queued or merged"
            echo "blocked: $(rget pr) left the merge queue without a confirmed merge"
            echo "notify: $(rget pr) left the merge queue without a confirmed merge; the watch is held for captain review."
          else
            rset checks=none phase=blocked "note=merge checks are not green (none)"
            echo "blocked: checks on merge commit $(short "$(rget merge_commit)") on $(rget base) are not green (none)"
            echo "notify: $(rget pr) has no green checks on $(rget base); the merge is held for captain review."
          fi
          ;;
        green)
          rset checks=green
          retire_watch pm
          if [ -n "$(rget witness)" ]; then
            rset phase=witness
            echo "witness: checks on $(short "$(rget merge_commit)") are green; a witness must use $(rget witness) - fill its instructions from bin/fm-post-merge.sh witness-task $ID"
          elif [ -n "$required_witness" ]; then
            rset phase=blocked "note=project requires a witness but the watch has no witness target"
            echo "blocked: $(basename "$(rget project)") requires a witness; no witness target is recorded"
          else
            rset phase=clear
            echo "clear: checks on $(short "$(rget merge_commit)") on $(rget base) are green; cleanup may proceed"
          fi
          ;;
      esac
      ;;
    witness)
      [ -n "$(rget witness)" ] || {
        rset phase=blocked "note=project requires a witness but the watch has no witness target"
        echo "blocked: $(basename "$(rget project)") requires a witness; no witness target is recorded"
        return 0
      }
      case "$(rget witness_verdict)" in
        pass)
          rset phase=clear
          echo "clear: the witness passed $(short "$(rget merge_commit)"); cleanup may proceed"
          ;;
        fail) start_revert witness-fail ;;
        *) echo "waiting: no witness verdict yet for $(short "$(rget merge_commit)"); record it with bin/fm-post-merge.sh witness-result <report> $ID" ;;
      esac
      ;;
    reverting)
      if [ "$(rget kind)" = pr ]; then
        advance_reverting_pr
      else
        advance_reverting_local
      fi
      ;;
    blocked) echo "blocked: $(rget note); end the watch with bin/fm-post-merge.sh close $ID --reason <the captain's words> once resolved" ;;
    clear) echo "clear: landing of $(short "$(rget merge_commit)") confirmed; cleanup may proceed" ;;
    reverted) echo "reverted: $(rget revert)" ;;
    closed) echo "closed: $(rget note)" ;;
    *) die "post-merge record for $ID has an unknown phase '$phase'" ;;
  esac
}

cmd_witness_task() {
  local id names target
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  for id in "$@"; do
    load_task "$id"
    record_present || die "no post-merge watch for $ID"
    [ "$(rget phase)" = witness ] || die "$ID's post-merge watch is in phase $(rget phase), not witness"
  done
  names=$("$SCRIPT_DIR/fm-witness-login.sh" names 2>/dev/null | tr '\n' ' ') || names=
  echo "You are the witness for the merged change(s) below. You built, reviewed, and tested none of it."
  echo "Use each change the way its real user would, through its real interface, and report what you saw."
  echo "Tests, merges, and deploys are not a witness; only your own use of the running product is."
  echo
  for id in "$@"; do
    load_task "$id"
    target=$(rget witness)
    if [ "$(rget kind)" = pr ]; then
      echo "- Merge commit $(rget merge_commit) of $(rget pr) ($(rget pr_title)) on $(rget base) of $(basename "$(rget project)"). Use it at $target."
    else
      echo "- Merge commit $(rget merge_commit), the local landing $(rget landed) of $(rget branch) in $(basename "$(rget project)"). Use it at $target."
    fi
  done
  echo
  echo "Confirm what is deployed at each URL is the named merge before you start; if you cannot, say so and report fail."
  echo "Browser work goes through chrome-devtools-axi with CHROME_DEVTOOLS_AXI_SESSION set to your task id."
  if [ -n "$names" ]; then
    echo "Logins are typed by name, never by value: FM_HOME='$FM_HOME' '$SCRIPT_DIR/fm-witness-login.sh' fill @<uid> <NAME>."
    echo "Available login names: $names"
    echo "Once a login is used, run every other browser command through FM_HOME='$FM_HOME' '$SCRIPT_DIR/fm-witness-login.sh' run <chrome-devtools-axi arguments> so no value can reach your transcript."
  else
    echo "No witness logins are configured; if a step needs one, report that step as not confirmed rather than guessing a login."
  fi
  echo "Never type, paste, or echo a credential value anywhere, and use test data only: if real customer data would show, stop and report it."
  echo "Keep screenshots as evidence beside your report and name them in it."
  echo
  echo "Your report states, per change: the deployed commit you confirmed, each step you took and what you saw, and anything you could not confirm with where you looked."
  echo "It ends with exactly one verdict line per merge commit, using the full commit id:"
  echo "  witness-verdict: pass <merge-commit>"
  echo "  witness-verdict: fail <merge-commit> <one-line reason a user would recognise>"
  echo "Report fail when a promised journey does not work for a user; report pass only when you saw it work."
}

cmd_witness_result() {
  local report id merge lines count verdict rest reason
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  report=$1
  shift
  [ -f "$report" ] && [ ! -L "$report" ] && [ -r "$report" ] || die "witness report $report is not a readable regular file"
  case "$report" in /*) ;; *) report="$PWD/$report" ;; esac
  for id in "$@"; do
    load_task "$id"
    lock_record
    record_present || die "no post-merge watch for $ID"
    [ "$(rget phase)" = witness ] || die "$ID's post-merge watch is in phase $(rget phase), not witness"
    merge=$(rget merge_commit)
    lines=$(grep -E "^[[:space:]]*witness-verdict:[[:space:]]+(pass|fail)[[:space:]]+$merge([[:space:]]|$)" "$report" || true)
    count=$(printf '%s' "$lines" | grep -c . || true)
    if [ "$count" -ne 1 ]; then
      fm_lock_release "$RECORD_LOCK" || true
      RECORD_LOCK_HELD=0
      die "witness report $report has $count verdict lines for $ID's merge commit $merge; it needs exactly one"
    fi
    lines=$(printf '%s\n' "$lines" | sed 's/^[[:space:]]*witness-verdict:[[:space:]]*//')
    verdict=${lines%%[[:space:]]*}
    rest=${lines#"$verdict"}
    rest=$(printf '%s' "$rest" | sed 's/^[[:space:]]*//')
    reason=${rest#"$merge"}
    reason=$(printf '%s' "$reason" | sed 's/^[[:space:]]*//' | tr '\t' ' ')
    if [ "$verdict" = fail ] && [ -z "$reason" ]; then
      reason="no reason given"
    fi
    rset "witness_verdict=$verdict" "witness_reason=$reason" "witness_report=$report"
    fm_lock_release "$RECORD_LOCK" || true
    RECORD_LOCK_HELD=0
    echo "recorded: witness $verdict for $ID on $(short "$merge")"
    "$SELF" advance "$ID" || exit $?
  done
}

cmd_status() {
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  load_task "$1"
  record_present || { echo "no post-merge watch for $ID"; exit 0; }
  cat "$RECORD"
}

cmd_close() {
  local reason=''
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  load_task "$1"
  shift
  [ "${1:-}" = --reason ] && [ "$#" -eq 2 ] && [ -n "$2" ] || die "close needs --reason <the captain's words>"
  reason=$(printf '%s' "$2" | tr '\n\t' '  ')
  lock_record
  record_present || die "no post-merge watch for $ID"
  case "$(rget phase)" in
    clear|closed|reverted) die "$ID's post-merge watch already ended (phase $(rget phase))" ;;
  esac
  retire_watch pm
  retire_watch pmr
  rset phase=closed "note=$reason"
  echo "closed: post-merge watch for $ID ($reason)"
}

case "$CMD" in
  arm) cmd_arm "$@" ;;
  advance) cmd_advance "$@" ;;
  checks) cmd_checks "$@" ;;
  witness-task) cmd_witness_task "$@" ;;
  witness-result) cmd_witness_result "$@" ;;
  status) cmd_status "$@" ;;
  close) cmd_close "$@" ;;
  *) usage >&2; exit 2 ;;
esac
