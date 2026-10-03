#!/usr/bin/env bash
# Cross-family review: prove that a task's exact head was reviewed by an AI
# family other than the one that built it, and record confirmations bound to
# that head.
#
# Adapted from korallis/agent-stack (https://github.com/korallis/agent-stack),
# Apache License 2.0; see NOTICE and LICENSES/agent-stack-Apache-2.0. Its
# merge-evidence review rules - a review counts only from another model family
# than the author's, only when it declares exactly the full head sha on a line
# of its own, and the latest record decides - are rebuilt here on task records
# instead of seat names.
#
# Families come from bin/fm-ai-family-lib.sh, which reads each harness's own
# catalog and never infers a family from a name. The builder's families are the
# task record's `ai_family=` set written by bin/fm-spawn.sh (every family that
# has driven the task); a record from before that field existed resolves its
# recorded harness and model the same way.
#
# An independent review of head H is, in order:
#   1. the no-mistakes pipeline review, when the task's run on its branch has
#      head H, its review step completed, and the agent that actually ran the
#      last successful review invocation resolves to a family disjoint from the
#      builder's (read from `no-mistakes axi status` and `no-mistakes stats
#      --run` in the task's worktree); or
#   2. the latest one-shot reviewer record for H in
#      data/<task-id>/cross-review.jsonl whose reviewer family, read from the
#      reviewer's own task record, is still disjoint from the builder's.
# direct-PR and local-only tasks run no pipeline review, so only (2) applies.
#
# Usage:
#   fm-cross-review.sh status <task-id> [--head <sha>] [--run <run-id>] [--json]
#     Print the review evidence for the task's head and record the families in
#     the task record (pipeline_review_family/_head and
#     independent_review_family/_head/_source). The head is --head, else the
#     recorded pr_head= when the task has pr=, else the tip of the task's local
#     branch. --run names the no-mistakes run instead of reading the worktree's.
#     --json prints one object for the merge gate instead of key=value lines;
#     every field is filled or says MISSING or N/A with its reason.
#   fm-cross-review.sh plan <task-id> [--head <sha>] [--run <run-id>] [--confirm]
#     Decide whether a one-shot reviewer is needed and which one. Prints
#     `action=none` with a reason, `action=spawn-reviewer` with reviewer_id,
#     reviewer_harness, reviewer_model, reviewer_effort and reviewer_family, or
#     `action=escalate` with the reason no reviewer can be chosen. --confirm asks
#     for the exact-head confirmation an unsure merge decision needs instead of
#     a review. A private vault change (bin/fm-wiki-lib.sh
#     fm_wiki_change_private) always gets action=none: it stays on today's path
#     and no new reviewer sees it. The fixed candidate chain is
#     `pi openai-codex/gpt-6-luna high`, `pi xai/grok-5 high`; the first whose
#     family is proven by its catalog and disjoint from the builder's wins.
#   fm-cross-review.sh brief <task-id> <reviewer-id> --head <sha> [--confirm]
#     Scaffold the reviewer's scout instructions with bin/fm-brief.sh --scout,
#     fill them for this exact head, and write the request record
#     data/<reviewer-id>/cross-review-request. Spawn the reviewer as a scout of
#     the task's project with the profile `plan` printed.
#   fm-cross-review.sh collect <task-id> <reviewer-id>
#     Read the reviewer's data/<reviewer-id>/report.md, check it against the
#     request and the reviewer's own task record, and append the result to
#     data/<task-id>/cross-review.jsonl. Prints `recorded accepted=yes|no ...`.
#     A report counts only when its own lines (outside code fences and quotes)
#     declare exactly one candidate - `reviewed head <sha>`, `head: <sha>`,
#     `candidate_sha: <sha>` or `confirm <sha>` - and it is the full requested
#     head; a confirmation also needs its `confirm <sha>` line. Run it before
#     the reviewer is cleaned up: the reviewer's family is read from its record.
#   fm-cross-review.sh verify-confirm <task-id> <sha>
#     Exit 0 and print the confirmation when an accepted, still cross-family
#     `confirm <sha>` record exists for exactly that sha; exit 1 naming why not,
#     including a confirmation recorded for another sha.
#
# Exit status: 0 on success, 1 when a record is missing or unreadable or a
# verification fails, 2 on a usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
NM_TIMEOUT="${FM_CROSS_REVIEW_NM_TIMEOUT:-30}"

# shellcheck source=bin/fm-ai-family-lib.sh
. "$SCRIPT_DIR/fm-ai-family-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-wiki-lib.sh
. "$SCRIPT_DIR/fm-wiki-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0" | sed '$d'
}

die() {
  printf 'fm-cross-review: %s\n' "$*" >&2
  exit "${2:-1}"
}

usage_die() {
  printf 'fm-cross-review: %s\n' "$*" >&2
  exit 2
}

sha_valid() {
  case "$1" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#1}" -eq 40 ]
}

meta_field() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" | tail -1
}

# ---- task record -------------------------------------------------------------

TASK=
META=
T_HARNESS=
T_MODEL=
T_MODE=
T_BRANCH=
T_WT=
T_PROJ=
T_PR=
T_PR_HEAD=
B_FAM=
B_FAM_SRC=

load_task() {  # <task-id>
  TASK=$1
  fm_task_id_path_safe "$TASK" || usage_die "invalid task id"
  META="$STATE/$TASK.meta"
  [ -f "$META" ] && [ ! -L "$META" ] || die "no task record for $TASK"
  T_HARNESS=$(meta_field "$META" harness)
  T_MODEL=$(meta_field "$META" model)
  T_MODE=$(meta_field "$META" mode)
  T_BRANCH=$(meta_field "$META" branch)
  [ -n "$T_BRANCH" ] || T_BRANCH="fm/$TASK"
  T_WT=$(meta_field "$META" worktree)
  T_PROJ=$(meta_field "$META" project)
  T_PR=$(meta_field "$META" pr)
  T_PR_HEAD=$(meta_field "$META" pr_head)
  B_FAM=$(meta_field "$META" ai_family)
  B_FAM_SRC=$(meta_field "$META" ai_family_source)
  if [ -z "$B_FAM" ]; then
    fm_ai_family_resolve "$T_HARNESS" "$T_MODEL"
    B_FAM=$FM_AI_FAMILY
    B_FAM_SRC="$FM_AI_FAMILY_SOURCE (resolved from the recorded harness and model; the record predates family recording)"
  fi
}

resolve_head() {  # <explicit-head-or-empty>
  local h=$1
  if [ -n "$h" ]; then
    sha_valid "$h" || usage_die "--head must be a full 40-character lowercase sha"
    printf '%s\n' "$h"
    return 0
  fi
  if [ -n "$T_PR" ]; then
    sha_valid "$T_PR_HEAD" || die "task $TASK records PR $T_PR without an exact pr_head; pass --head"
    printf '%s\n' "$T_PR_HEAD"
    return 0
  fi
  [ -n "$T_PROJ" ] && [ -d "$T_PROJ" ] || die "task $TASK has no readable project to read its branch head from; pass --head"
  h=$(git -C "$T_PROJ" rev-parse --verify --quiet "refs/heads/$T_BRANCH^{commit}" 2>/dev/null) \
    || die "branch $T_BRANCH has no local tip in $T_PROJ; pass --head"
  printf '%s\n' "$h"
}

default_base_ref() {
  local ref
  ref=$(git -C "$T_PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "$ref"
    return 0
  fi
  for ref in main master; do
    if git -C "$T_PROJ" show-ref --verify --quiet "refs/heads/$ref"; then
      printf '%s\n' "$ref"
      return 0
    fi
  done
  return 1
}

# Write review fields into the task record under its meta lock.
record_meta() {  # <key=value>...
  local lock tmp kv key line keys=' '
  lock=$(fm_meta_lock_path "$META") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  if [ ! -f "$META" ] || [ -L "$META" ]; then
    fm_lock_release "$lock" || true
    return 1
  fi
  for kv in "$@"; do keys="$keys${kv%%=*} "; done
  tmp=$(mktemp "$STATE/.fm-cross-review-meta.XXXXXX") || { fm_lock_release "$lock" || true; return 1; }
  # cp -p carries the record's own mode over before the content is replaced.
  if ! cp -p -- "$META" "$tmp" || ! {
    while IFS= read -r line || [ -n "$line" ]; do
      key=${line%%=*}
      case "$keys" in *" $key "*) continue ;; esac
      printf '%s\n' "$line"
    done < "$META"
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "$tmp" || ! mv -f -- "$tmp" "$META"; then
    rm -f -- "$tmp"
    fm_lock_release "$lock" || true
    return 1
  fi
  fm_lock_release "$lock" || true
}

# ---- pipeline review ---------------------------------------------------------

P_STATE=        # present | missing | n/a
P_DETAIL=
P_RUN=
P_AGENT=
P_MODEL=
P_FAM=
P_FAM_SRC=

nm_status_field() {  # <toon> <field>
  printf '%s\n' "$1" | awk -v f="$2" '
    /^run:/ || /^other_branch_run:/ { inrun = ($0 ~ /^run:/); next }
    inrun && $1 == f":" { v = $0; sub(/^[ \t]*[a-z_]+:[ \t]*/, "", v); gsub(/^"|"$/, "", v); print v; exit }
  '
}

nm_review_step_status() {  # <toon>
  printf '%s\n' "$1" | awk -F, '
    /^run:/ { inrun = 1; next }
    /^other_branch_run:/ { inrun = 0; next }
    inrun && /^[ \t]+review,/ { s = $2; print s; exit }
  '
}

# The agent, model and provider no-mistakes recorded for the run's last
# successful review invocation, tab-separated, read read-only from its state
# database because no CLI surface prints the provider. Prints nothing when the
# database, sqlite3, or that record is unavailable; the caller then reads the
# stats CLI, which names agent and model only.
nm_review_invocation_db() {  # <run-id>
  local db="${NM_HOME:-$HOME/.no-mistakes}/state.sqlite"
  case "$1" in ''|*[!0-9A-Za-z]*) return 0 ;; esac
  [ -f "$db" ] && command -v sqlite3 >/dev/null 2>&1 || return 0
  fm_run_timed "$NM_TIMEOUT" sqlite3 -readonly -separator "$(printf '\t')" "$db" \
    "select agent, coalesce(model, ''), coalesce(model_provider, '') from agent_invocations where run_id = '$1' and purpose = 'review' and exit_status = 'ok' order by started_at desc, id desc limit 1" \
    2>/dev/null || true
}

pipeline_review() {  # <head> <run-id-or-empty>
  local head=$1 run=$2 toon branch run_head step stats row provider=
  P_STATE=missing P_DETAIL='' P_RUN='' P_AGENT='' P_MODEL='' P_FAM='' P_FAM_SRC=''
  if [ "$T_MODE" != no-mistakes ]; then
    P_STATE=n/a
    P_DETAIL="${T_MODE:-this} mode runs no pipeline review"
    return 0
  fi
  if [ -z "$T_WT" ] || [ ! -d "$T_WT" ]; then
    P_DETAIL="the task's worktree is gone, so its pipeline run cannot be read"
    return 0
  fi
  if [ -n "$run" ]; then
    toon=$(fm_nm_run "$T_WT" "$NM_TIMEOUT" axi status --run "$run")
    toon=$(printf '%s\n' "$toon" | sed 's/^other_branch_run:/run:/')
  else
    toon=$(fm_nm_run "$T_WT" "$NM_TIMEOUT" axi status)
  fi
  P_RUN=$(nm_status_field "$toon" id)
  if [ -z "$P_RUN" ]; then
    P_DETAIL="no no-mistakes run is recorded for branch $T_BRANCH"
    return 0
  fi
  branch=$(nm_status_field "$toon" branch)
  if [ "$branch" != "$T_BRANCH" ]; then
    P_DETAIL="no-mistakes run $P_RUN is for branch ${branch:-unknown}, not $T_BRANCH"
    return 0
  fi
  run_head=$(nm_status_field "$toon" head_sha)
  if [ "$run_head" != "$head" ]; then
    P_DETAIL="no-mistakes run $P_RUN validated head ${run_head:-unknown}, not $head"
    return 0
  fi
  step=$(nm_review_step_status "$toon")
  if [ "$step" != completed ]; then
    P_DETAIL="the review step of no-mistakes run $P_RUN is ${step:-absent}, not completed"
    return 0
  fi
  row=$(nm_review_invocation_db "$P_RUN")
  if [ -z "$row" ]; then
    stats=$(fm_nm_run "$T_WT" "$NM_TIMEOUT" stats --run "$P_RUN")
    # The first table lists one invocation per row; the key column may be
    # blank, so only the leading step/round/purpose/agent/model fields and the
    # trailing exit field are positional. It names no provider.
    row=$(printf '%s\n' "$stats" | awk '
      /^STEP[ \t]/ { if (seen++) exit; table = 1; next }
      table && NF == 0 { exit }
      table && $3 == "review" && $NF == "ok" { last = $4 "\t" ($5 == "-" ? "" : $5) "\t" }
      END { if (last != "") print last }
    ')
  fi
  if [ -z "$row" ]; then
    P_DETAIL="no-mistakes run $P_RUN records no successful review invocation"
    return 0
  fi
  IFS=$(printf '\t') read -r P_AGENT P_MODEL provider <<<"$row" || true
  case "$P_AGENT" in
    acp:*) fm_ai_family_resolve "$P_AGENT" "" ;;
    *)
      if [ -n "$provider" ] && [ -n "$P_MODEL" ]; then
        fm_ai_family_resolve "$P_AGENT" "$provider/$P_MODEL"
      else
        fm_ai_family_resolve "$P_AGENT" "$P_MODEL"
      fi
      ;;
  esac
  P_FAM=$FM_AI_FAMILY
  P_FAM_SRC=$FM_AI_FAMILY_SOURCE
  P_STATE=present
  P_DETAIL="no-mistakes run $P_RUN reviewed head $head with $P_AGENT${P_MODEL:+ $P_MODEL}"
}

# ---- one-shot records --------------------------------------------------------

records_file() { printf '%s/%s/cross-review.jsonl\n' "$DATA" "$1"; }

# The latest one-shot record of <kind> (review or confirm) for <head>, as
# compact JSON, or nothing.
latest_record() {  # <head> <kind>
  local file
  file=$(records_file "$TASK")
  [ -f "$file" ] || return 0
  jq -c --arg h "$1" --arg k "$2" 'select(.head == $h and .kind == $k)' "$file" 2>/dev/null | tail -1
}

I_STATE=
I_SOURCE=
I_FAM=
I_VERDICT=
I_DETAIL=
I_REVIEWER=
C_STATE=
C_DETAIL=
C_FAM=
C_REVIEWER=

independent_review() {  # <head>
  local head=$1 rec fam accepted verdict rid reason
  I_STATE=missing I_SOURCE='' I_FAM='' I_VERDICT='' I_DETAIL='' I_REVIEWER=''
  if [ "$P_STATE" = present ] && fm_ai_family_disjoint "$B_FAM" "$P_FAM"; then
    I_STATE=present I_SOURCE=pipeline I_FAM=$P_FAM I_VERDICT=completed
    I_DETAIL="pipeline review by $P_FAM ($P_DETAIL); the builder is $B_FAM"
    return 0
  fi
  rec=$(latest_record "$head" review)
  if [ -n "$rec" ]; then
    fam=$(printf '%s' "$rec" | jq -r '.family')
    accepted=$(printf '%s' "$rec" | jq -r '.accepted')
    verdict=$(printf '%s' "$rec" | jq -r '.verdict')
    rid=$(printf '%s' "$rec" | jq -r '.reviewer')
    reason=$(printf '%s' "$rec" | jq -r '.reason')
    if [ "$accepted" = true ] && fm_ai_family_disjoint "$B_FAM" "$fam"; then
      I_STATE=present I_SOURCE=one-shot I_FAM=$fam I_VERDICT=$verdict I_REVIEWER=$rid
      I_DETAIL="one-shot review by $rid ($fam) declares head $head with verdict $verdict; the builder is $B_FAM"
      return 0
    fi
    I_DETAIL="the latest one-shot record for $head (reviewer $rid) does not count: ${reason:-its family $fam is not disjoint from the builder family $B_FAM}"
  fi
  if [ "$P_STATE" = present ]; then
    I_DETAIL="${I_DETAIL:+$I_DETAIL; }the pipeline review ran on $P_FAM, which is not provably a different family from the builder's $B_FAM"
  elif [ -z "$I_DETAIL" ]; then
    case "$P_STATE" in
      n/a) I_DETAIL="no one-shot review is recorded for $head, and $P_DETAIL" ;;
      *) I_DETAIL="no one-shot review is recorded for $head, and the pipeline review is missing: $P_DETAIL" ;;
    esac
  fi
}

confirmation() {  # <head>
  local head=$1 rec fam accepted rid reason
  C_STATE=missing C_DETAIL='' C_FAM='' C_REVIEWER=''
  rec=$(latest_record "$head" confirm)
  if [ -z "$rec" ]; then
    C_DETAIL="no confirm $head is recorded"
    return 0
  fi
  fam=$(printf '%s' "$rec" | jq -r '.family')
  accepted=$(printf '%s' "$rec" | jq -r '.accepted')
  rid=$(printf '%s' "$rec" | jq -r '.reviewer')
  reason=$(printf '%s' "$rec" | jq -r '.reason')
  if [ "$accepted" = true ] && fm_ai_family_disjoint "$B_FAM" "$fam"; then
    C_STATE=present C_FAM=$fam C_REVIEWER=$rid
    C_DETAIL="confirm $head by $rid ($fam); the builder is $B_FAM"
  else
    C_DETAIL="the latest confirmation record for $head (reviewer $rid) does not count: ${reason:-its family $fam is not disjoint from the builder family $B_FAM}"
  fi
}

# ---- status ------------------------------------------------------------------

gather() {  # <explicit-head> <run>
  HEAD_SHA=$(resolve_head "$1")
  pipeline_review "$HEAD_SHA" "$2"
  independent_review "$HEAD_SHA"
  confirmation "$HEAD_SHA"
}

record_families() {
  local kv=()
  if [ "$P_STATE" = present ]; then
    kv+=("pipeline_review_family=$P_FAM" "pipeline_review_head=$HEAD_SHA")
  fi
  if [ "$I_STATE" = present ]; then
    kv+=("independent_review_family=$I_FAM" "independent_review_head=$HEAD_SHA" "independent_review_source=$I_SOURCE")
  fi
  [ "${#kv[@]}" -eq 0 ] || record_meta "${kv[@]}" || echo "fm-cross-review: warning: could not record review families in $META" >&2
}

cmd_status() {
  local head='' run='' json=0
  [ "$#" -ge 1 ] || usage_die "usage: fm-cross-review.sh status <task-id> [--head <sha>] [--run <run-id>] [--json]"
  load_task "$1"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head) [ "$#" -ge 2 ] || usage_die "--head needs a sha"; head=$2; shift 2 ;;
      --run) [ "$#" -ge 2 ] || usage_die "--run needs a run id"; run=$2; shift 2 ;;
      --json) json=1; shift ;;
      *) usage_die "unknown argument: $1" ;;
    esac
  done
  gather "$head" "$run"
  record_families
  if [ "$json" = 1 ]; then
    jq -n \
      --arg task "$TASK" --arg head "$HEAD_SHA" --arg mode "$T_MODE" \
      --arg bf "$B_FAM" --arg bfs "$B_FAM_SRC" \
      --arg ps "$P_STATE" --arg pd "$P_DETAIL" --arg pr "$P_RUN" --arg pa "$P_AGENT" --arg pm "$P_MODEL" \
      --arg pf "$P_FAM" --arg pfs "$P_FAM_SRC" \
      --arg is "$I_STATE" --arg isrc "$I_SOURCE" --arg if "$I_FAM" --arg iv "$I_VERDICT" --arg id "$I_DETAIL" --arg ir "$I_REVIEWER" \
      --arg cs "$C_STATE" --arg cd "$C_DETAIL" --arg cf "$C_FAM" --arg cr "$C_REVIEWER" '
      def miss($why): "MISSING: " + $why;
      {
        task: $task, head: $head, mode: $mode,
        builder: { family: $bf, source: $bfs },
        pipeline_review: (if $ps == "present" then
            { run: $pr, agent: $pa, model: (if $pm == "" then null else $pm end), family: $pf, source: $pfs, head: $head, detail: $pd }
          elif $ps == "n/a" then ("N/A: " + $pd) else miss($pd) end),
        independent_review: (if $is == "present" then
            { source: $isrc, family: $if, verdict: $iv, head: $head, reviewer: (if $ir == "" then null else $ir end), detail: $id }
          else miss($id) end),
        confirm: (if $cs == "present" then { sha: $head, family: $cf, reviewer: $cr, detail: $cd } else miss($cd) end)
      }'
    return 0
  fi
  printf 'task=%s\nhead=%s\nmode=%s\n' "$TASK" "$HEAD_SHA" "$T_MODE"
  printf 'builder_family=%s\nbuilder_family_source=%s\n' "$B_FAM" "$B_FAM_SRC"
  printf 'pipeline_review=%s\n' "$P_STATE"
  if [ "$P_STATE" = present ]; then
    printf 'pipeline_review_family=%s\npipeline_review_family_source=%s\npipeline_review_run=%s\n' "$P_FAM" "$P_FAM_SRC" "$P_RUN"
  fi
  printf 'pipeline_review_detail=%s\n' "$P_DETAIL"
  printf 'independent_review=%s\n' "$I_STATE"
  if [ "$I_STATE" = present ]; then
    printf 'independent_review_source=%s\nindependent_review_family=%s\nindependent_review_verdict=%s\n' "$I_SOURCE" "$I_FAM" "$I_VERDICT"
  fi
  printf 'independent_review_detail=%s\n' "$I_DETAIL"
  printf 'confirm=%s\nconfirm_detail=%s\n' "$C_STATE" "$C_DETAIL"
}

# ---- plan --------------------------------------------------------------------

private_change() {  # <head>, decision-time vault exclusion for plan and brief
  local head=$1 base_ref base
  [ -n "$T_PROJ" ] && [ -d "$T_PROJ" ] || return 1
  if base_ref=$(default_base_ref) && base=$(git -C "$T_PROJ" merge-base "$base_ref" "$head" 2>/dev/null); then
    fm_wiki_change_private "$CONFIG" "$T_PROJ" "$(basename "$T_PROJ")" "$base" "$head"
  elif [ -e "$T_PROJ/_meta/pruefe.sh" ] || [ -e "$T_PROJ/_meta/einstieg.sh" ]; then
    FM_WIKI_PRIVATE_REASON="vault $(basename "$T_PROJ") change base cannot be read, so it cannot be cleared for a new reviewer"
    return 0
  else
    return 1
  fi
}

reviewer_candidates() {
  printf 'pi openai-codex/gpt-6-luna high\n'
  printf 'pi xai/grok-5 high\n'
}

reviewer_id_for() {  # <tag> <head>
  local base=${TASK:0:48}
  base=${base%-}
  printf '%s-%s-%s\n' "$base" "$1" "${2:0:8}"
}

cmd_plan() {
  local head='' run='' want=review base_ref base h m e f chosen=''
  [ "$#" -ge 1 ] || usage_die "usage: fm-cross-review.sh plan <task-id> [--head <sha>] [--run <run-id>] [--confirm]"
  load_task "$1"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head) [ "$#" -ge 2 ] || usage_die "--head needs a sha"; head=$2; shift 2 ;;
      --run) [ "$#" -ge 2 ] || usage_die "--run needs a run id"; run=$2; shift 2 ;;
      --confirm) want=confirm; shift ;;
      *) usage_die "unknown argument: $1" ;;
    esac
  done
  gather "$head" "$run"
  record_families
  printf 'task=%s\nhead=%s\nbuilder_family=%s\n' "$TASK" "$HEAD_SHA" "$B_FAM"
  if private_change "$HEAD_SHA"; then
    printf 'action=none\nreason=private path: %s; no new reviewer sees this change\n' "$FM_WIKI_PRIVATE_REASON"
    return 0
  fi
  if [ "$want" = review ] && [ "$I_STATE" = present ]; then
    printf 'action=none\nreason=%s\n' "$I_DETAIL"
    return 0
  fi
  if [ "$want" = confirm ] && [ "$C_STATE" = present ]; then
    printf 'action=none\nreason=%s\n' "$C_DETAIL"
    return 0
  fi
  case ",$B_FAM," in
    *,unknown,*)
      printf 'action=escalate\nreason=the builder family is unknown (%s), so no reviewer can be proven to be another family\n' "$B_FAM_SRC"
      return 0
      ;;
  esac
  while read -r h m e; do
    [ -n "$h" ] || continue
    fm_ai_family_resolve "$h" "$m"
    if fm_ai_family_disjoint "$B_FAM" "$FM_AI_FAMILY"; then
      chosen="$h $m $e $FM_AI_FAMILY"
      break
    fi
  done <<EOF
$(reviewer_candidates)
EOF
  if [ -z "$chosen" ]; then
    printf 'action=escalate\nreason=no catalog-proven reviewer family differs from the builder'"'"'s %s\n' "$B_FAM"
    return 0
  fi
  read -r h m e f <<<"$chosen"
  printf 'action=spawn-reviewer\nkind=%s\n' "$want"
  if [ "$want" = review ]; then
    printf 'reason=%s\n' "$I_DETAIL"
    printf 'reviewer_id=%s\n' "$(reviewer_id_for xr "$HEAD_SHA")"
  else
    printf 'reason=%s\n' "$C_DETAIL"
    printf 'reviewer_id=%s\n' "$(reviewer_id_for xc "$HEAD_SHA")"
  fi
  printf 'reviewer_harness=%s\nreviewer_model=%s\nreviewer_effort=%s\nreviewer_family=%s\n' "$h" "$m" "$e" "$f"
}

# ---- brief -------------------------------------------------------------------

cmd_brief() {
  local rid head='' want=review brief task_body spec_body fetch_line base_ref subject pr_number
  [ "$#" -ge 2 ] || usage_die "usage: fm-cross-review.sh brief <task-id> <reviewer-id> --head <sha> [--confirm]"
  load_task "$1"
  rid=$2
  shift 2
  fm_task_id_creation_valid "$rid" || usage_die "invalid reviewer id"
  [ "$rid" != "$TASK" ] || usage_die "the reviewer id must differ from the task id"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head) [ "$#" -ge 2 ] || usage_die "--head needs a sha"; head=$2; shift 2 ;;
      --confirm) want=confirm; shift ;;
      *) usage_die "unknown argument: $1" ;;
    esac
  done
  sha_valid "$head" || usage_die "--head must be a full 40-character lowercase sha"
  [ -n "$T_PROJ" ] && [ -d "$T_PROJ" ] || die "task $TASK has no readable project"
  base_ref=$(default_base_ref) || die "cannot determine the default branch of $T_PROJ"
  if private_change "$head"; then
    die "private path: $FM_WIKI_PRIVATE_REASON; refusing to scaffold a reviewer"
  fi
  if [ -n "$T_PR" ] && fm_pr_url_parse "$T_PR" && [ "$FM_PR_PROVIDER" = github ]; then
    pr_number=$FM_PR_NUMBER
    subject="pull request $T_PR"
    fetch_line="Fetch it with \`git fetch origin pull/$pr_number/head\` and, when the default branch is not current, \`git fetch origin\`."
  elif [ -n "$T_PR" ]; then
    subject="change $T_PR"
    fetch_line="Fetch the change's head commit from origin by its sha with \`git fetch origin $head\`."
  else
    subject="local branch $T_BRANCH"
    fetch_line="It is the local branch \`$T_BRANCH\` of the shared repository; \`git rev-parse --verify $head^{commit}\` must find it without fetching."
  fi
  "$SCRIPT_DIR/fm-brief.sh" "$rid" "$(basename "$T_PROJ")" --scout >/dev/null \
    || die "could not scaffold the reviewer instructions"
  brief="$DATA/$rid/brief.md"
  [ -f "$brief" ] || die "the reviewer scaffold did not write $brief"
  if [ "$want" = review ]; then
    task_body="Every PR and landing gets a review from a different AI family than the builder before Jev decides, fast-path work included.

This review covers $subject of task $TASK in $(basename "$T_PROJ"), at exactly commit $head. The change was built by the $B_FAM AI family; this reviewer belongs to another family."
  else
    task_body="When Jev is unsure, a reviewer from a different AI family than the builder confirms the exact commit and then it merges. Without that confirmation it holds and the gap gets fixed.

This confirmation covers $subject of task $TASK in $(basename "$T_PROJ"), at exactly commit $head. The change was built by the $B_FAM AI family; this reviewer belongs to another family."
  fi
  spec_body="- Review exactly commit \`$head\` and nothing else. $fetch_line
- Run \`git checkout --detach $head\` and check that \`git rev-parse HEAD\` prints exactly \`$head\`; if it cannot, append \`blocked\` naming why and stop.
- Review the change against \`$(git -C "$T_PROJ" rev-parse --abbrev-ref "$base_ref" 2>/dev/null || printf '%s' "$base_ref")\`: \`git diff \$(git merge-base $base_ref $head) $head\`. The change's own instructions are at \`$DATA/$TASK/brief.md\`; judge it against its \`## Captain's intent\` section.
- Look for correctness bugs, regressions, security and data risks, missing tests, and work outside the stated intent. Run the project's own checks where that is cheap.
- Do not change the code, push, or comment on any pull request. Your report is the only output.
- Write the report to \`$DATA/$rid/report.md\`. Put these lines in it, each on a line of its own and outside code blocks and quotes:"
  if [ "$want" = review ]; then
    spec_body="$spec_body
  - \`reviewed head $head\`
  - \`Verdict: PASS\` when nothing blocks merging this exact commit, otherwise \`Verdict: FAIL\` followed by the blocking findings."
  else
    spec_body="$spec_body
  - \`confirm $head\` only when you confirm this exact commit is safe to merge;
  - otherwise \`reviewed head $head\` and \`Verdict: HOLD\` followed by what must change."
  fi
  spec_body="$spec_body
  Never write any other full 40-character sha on a line of its own: a report that declares two commits counts for neither.
- Then record it: \`FM_HOME='$FM_HOME' '$SCRIPT_DIR/fm-cross-review.sh' collect '$TASK' '$rid'\`. It must print \`recorded accepted=yes\`; if it prints \`accepted=no\`, fix the report lines it names and run it again.
- If these instructions carry a \`# Wiki guide\` section, its draft is the single line \`no guide: one-shot cross-family review of one commit\`."
  XR_TASK_BODY=$task_body XR_SPEC_BODY=$spec_body perl -0pi -e '
    s/\{TASK\}/$ENV{XR_TASK_BODY}/; s/\{FIRSTMATE_SPEC\}/$ENV{XR_SPEC_BODY}/;
  ' "$brief" || die "could not fill $brief"
  printf 'task=%s\nhead=%s\nkind=%s\n' "$TASK" "$head" "$want" > "$DATA/$rid/cross-review-request" \
    || die "could not write the reviewer request record"
  printf 'brief=%s\n' "$brief"
}

# ---- collect -----------------------------------------------------------------

# The record's own lines: code fences and quoted lines are examples or
# citations, never declarations; bold and code markers are dropped.
own_lines() {  # <file>
  awk '
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^[ \t]*>/ { next }
    { gsub(/\*\*|`/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print }
  ' "$1"
}

verdict_word() {  # <word...>
  local w
  w=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  case "$w" in
    PASS|PASSED|APPROVE|APPROVED|YES|MERGE|SHIP) printf 'success\n' ;;
    FAIL|FAILED|BLOCK|BLOCKED|BLOCKING|NO|HOLD|CHANGES_REQUESTED|REQUEST_CHANGES) printf 'failure\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

cmd_collect() {
  local rid req r_task r_head r_kind rmeta r_fam r_fam_src report lines candidates cand_count
  local verdicts=() verdict confirm_line=0 review_line=0 explicit_verdict=0 accepted=false reason='' l w file sum
  [ "$#" -eq 2 ] || usage_die "usage: fm-cross-review.sh collect <task-id> <reviewer-id>"
  load_task "$1"
  rid=$2
  fm_task_id_path_safe "$rid" || usage_die "invalid reviewer id"
  req="$DATA/$rid/cross-review-request"
  [ -f "$req" ] || die "no review request is recorded for $rid"
  r_task=$(meta_field "$req" task)
  r_head=$(meta_field "$req" head)
  r_kind=$(meta_field "$req" kind)
  [ "$r_task" = "$TASK" ] || die "reviewer $rid was asked to review task ${r_task:-unknown}, not $TASK"
  sha_valid "$r_head" || die "the request for $rid names no valid head"
  case "$r_kind" in review|confirm) ;; *) die "the request for $rid names no valid kind" ;; esac
  rmeta="$STATE/$rid.meta"
  [ -f "$rmeta" ] || die "reviewer $rid has no task record, so its family cannot be read; collect before cleanup"
  r_fam=$(meta_field "$rmeta" ai_family)
  r_fam_src=$(meta_field "$rmeta" ai_family_source)
  if [ -z "$r_fam" ]; then
    fm_ai_family_resolve "$(meta_field "$rmeta" harness)" "$(meta_field "$rmeta" model)"
    r_fam=$FM_AI_FAMILY
    r_fam_src=$FM_AI_FAMILY_SOURCE
  fi
  report="$DATA/$rid/report.md"
  [ -f "$report" ] || die "reviewer $rid has written no report at $report"
  lines=$(own_lines "$report")
  candidates=$(printf '%s\n' "$lines" | perl -ne '
    if (/^confirm\s+([0-9a-f]{40})$/i) { print lc($1), "\n"; next }
    if (/^(?:reviewed\s+)?(?:head|candidate(?:[_ ]sha)?|sha|commit)\s*[:=]?\s*([0-9a-f]{40})\.?$/i) { print lc($1), "\n" }
  ' | awk '!seen[$0]++')
  cand_count=$(printf '%s' "$candidates" | grep -c . || true)
  while IFS= read -r l; do
    if printf '%s\n' "$l" | grep -Eiq '^confirm[[:space:]]+[0-9a-f]{40}$'; then
      verdicts+=(success)
      [ "$(printf '%s' "$l" | awk '{ print tolower($2) }')" != "$r_head" ] || confirm_line=1
      continue
    fi
    if printf '%s\n' "$l" | grep -Eiq '^(reviewed[[:space:]]+)?(head|candidate([_ ]sha)?|sha|commit)[[:space:]]*[:=]?[[:space:]]*[0-9a-f]{40}\.?$'; then
      review_line=1
    fi
    if printf '%s\n' "$l" | grep -Eiq '^verdict[[:space:]]*[:=-]'; then
      explicit_verdict=1
      w=$(printf '%s\n' "$l" | sed -E 's/^[Vv][Ee][Rr][Dd][Ii][Cc][Tt][[:space:]]*[:=-][[:space:]]*//' | awk '{ print $1 }' | tr -d '.,;:()')
      verdicts+=("$(verdict_word "$w")")
    fi
  done <<EOF
$lines
EOF
  if [ "${#verdicts[@]}" -eq 0 ]; then
    verdict=unclear
  elif printf '%s\n' "${verdicts[@]}" | grep -qx failure; then
    verdict=failure
  elif printf '%s\n' "${verdicts[@]}" | grep -qvx success; then
    verdict=unclear
  else
    verdict=success
  fi
  if [ "$cand_count" -ne 1 ]; then
    reason="the report declares $cand_count candidate commits; exactly one, the full head $r_head, is required"
  elif [ "$candidates" != "$r_head" ]; then
    reason="the report declares $candidates, not the requested head $r_head"
  elif ! fm_ai_family_disjoint "$B_FAM" "$r_fam"; then
    reason="the reviewer family $r_fam is not provably different from the builder's $B_FAM"
  elif [ "$r_kind" = review ] && { [ "$review_line" != 1 ] || [ "$explicit_verdict" != 1 ]; }; then
    reason="a review needs a head declaration and an explicit Verdict line"
  elif [ "$r_kind" = confirm ] && [ "$confirm_line" != 1 ] && [ "$verdict" = failure ]; then
    reason="the reviewer did not confirm $r_head: its verdict is $verdict"
  elif [ "$r_kind" = confirm ] && [ "$confirm_line" != 1 ]; then
    reason="a confirmation needs the line confirm $r_head"
  elif [ "$r_kind" = confirm ] && [ "$verdict" != success ]; then
    reason="the report confirms $r_head but also declares a $verdict verdict"
  else
    accepted=true
  fi
  file=$(records_file "$TASK")
  mkdir -p "${file%/*}" || die "cannot create ${file%/*}"
  sum=$(shasum -a 256 "$report" | awk '{ print $1 }')
  jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg task "$TASK" --arg rid "$rid" --arg kind "$r_kind" \
    --arg head "$r_head" --arg declared "$candidates" --arg fam "$r_fam" --arg fsrc "$r_fam_src" \
    --arg bf "$B_FAM" --arg verdict "$verdict" --argjson accepted "$accepted" --arg reason "$reason" --arg sum "$sum" '
    { at: $at, task: $task, reviewer: $rid, kind: $kind, head: $head,
      declared: ($declared | split("\n") | map(select(length > 0))),
      family: $fam, family_source: $fsrc, builder_family: $bf, verdict: $verdict,
      accepted: $accepted, reason: (if $reason == "" then null else $reason end), report_sha256: $sum }
  ' >> "$file" || die "could not append to $file"
  if [ "$accepted" = true ]; then
    record_meta "independent_review_family=$r_fam" "independent_review_head=$r_head" "independent_review_source=one-shot" \
      || echo "fm-cross-review: warning: could not record the reviewer family in $META" >&2
    printf 'recorded accepted=yes kind=%s verdict=%s head=%s reviewer_family=%s\n' "$r_kind" "$verdict" "$r_head" "$r_fam"
  else
    printf 'recorded accepted=no kind=%s head=%s reason=%s\n' "$r_kind" "$r_head" "$reason"
  fi
}

# ---- verify-confirm ----------------------------------------------------------

cmd_verify_confirm() {
  local sha file other
  [ "$#" -eq 2 ] || usage_die "usage: fm-cross-review.sh verify-confirm <task-id> <sha>"
  load_task "$1"
  sha=$2
  sha_valid "$sha" || usage_die "the sha must be a full 40-character lowercase sha"
  confirmation "$sha"
  if [ "$C_STATE" = present ]; then
    printf 'confirmed %s by %s (%s); the builder is %s\n' "$sha" "$C_REVIEWER" "$C_FAM" "$B_FAM"
    return 0
  fi
  file=$(records_file "$TASK")
  if [ -f "$file" ]; then
    other=$(jq -r --arg h "$sha" 'select(.kind == "confirm" and .accepted == true and .head != $h) | .head' "$file" 2>/dev/null | tail -1)
    if [ -n "$other" ]; then
      printf 'not confirmed: the recorded confirmation is for %s, not %s\n' "$other" "$sha" >&2
      return 1
    fi
  fi
  printf 'not confirmed: %s\n' "$C_DETAIL" >&2
  return 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  status) shift; cmd_status "$@" ;;
  plan) shift; cmd_plan "$@" ;;
  brief) shift; cmd_brief "$@" ;;
  collect) shift; cmd_collect "$@" ;;
  verify-confirm) shift; cmd_verify_confirm "$@" ;;
  *) usage >&2; exit 2 ;;
esac
