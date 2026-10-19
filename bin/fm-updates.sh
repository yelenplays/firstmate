#!/usr/bin/env bash
# fm-updates.sh - report every finished task once, then flag it for cleanup.
#
# Usage:
#   fm-updates.sh scan             local read only: what is still unreported or
#                                  waiting for cleanup, for the wake drain
#   fm-updates.sh tick             post every owed outcome and a due morning
#                                  digest; fm-slack-bridge.sh check runs it
#   fm-updates.sh settle <task>    post that task's owed outcome now; teardown
#                                  runs it before removing the task's record
#   fm-updates.sh digest [--print] post the morning digest now, or only print it
#   fm-updates.sh --help
#
# Why this exists: "finished" used to be a one-shot signal. When the supervising
# session missed it, the result stayed in files nobody read and the worker sat
# idle. This script derives every owed report from durable state instead, so a
# missed signal is caught by the next check, drain, or cleanup.
#
# What a task owes, read from state/<id>.meta, the last event of
# state/<id>.status (bin/fm-classify-lib.sh), and the merge marker
# state/<id>.pr-poll-merge-notified:
#   merged    the merge marker exists                    -> ✅ merged
#   finished  a scout's, a local-only task's, or a ship task's last event is
#             done: and no PR is named                   -> ✅ finished
#   ready     a ship task's last event is done: naming a PR, auto-merge is not
#             on (yolo= is not on), and the PR is not merged -> 🙋 approval needed
#   stuck     the last event is failed:, or an auto-merge task's PR is closed
#             unmerged, or it is still unmerged FM_UPDATES_STALE seconds
#             (default 86400) after its done: event      -> ⚠️ stuck
# An auto-merge task's PR state is read through one bounded gh call once its
# grace period passed: merged without a marker owes merged, open and fresh
# owes nothing yet. Secondmates owe
# nothing here; their own homes report. An outcome is owed only after
# FM_UPDATES_GRACE seconds (default 900) since its event, so the supervisor's own
# richer post goes first and this is the backstop, not a duplicate.
# Posting goes through `fm-slack-bridge.sh post <kind> --task <id>`, which
# records the outcome in state/slack-bridge/outcomes and refuses a second post
# of the same task incarnation and kind, so every outcome reaches Slack once.
#
# Cleanup: a task whose merge is recorded, a finished scout, and a finished
# local-only task are done for good. Once their outcome is reported (or the
# Slack bridge is off, so chat is the report), `scan` lists them as cleanup due
# on every drain until bin/fm-teardown.sh removes their record. Nothing finished
# can sit idle without a line saying so.
#
# Output of `scan`, one line per task, nothing when all is clear:
#   unreported <task> <kind>: <title>
#   cleanup-due <task>: <reason>
# Output of `tick`: "posted <task> <kind>", "posted digest", or
# "failed <task|digest> <kind>: <reason>" lines; silent when nothing was owed.
# `settle` exits 0 when nothing is owed or the post landed, 1 when the post
# failed, so teardown keeps the record and a rerun retries.
#
# The morning digest (#updates, at most five lines): what needs the captain
# (captain-held calls from the backlog plus owed approvals), what finished,
# merged, or went live in the last 24 hours (from state/slack-bridge/posts), how
# many workers are running, and the board link. It posts once per local day
# within four hours after the configured digest-hour; state/updates/digest-last
# records the day.
#
# docs/configuration.md "Slack bridge" owns the config keys this reads through
# `fm-slack-bridge.sh settings`.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE, FM_UPDATES_GRACE,
# FM_UPDATES_STALE, FM_UPDATES_DEADLINE (epoch by which `tick` must stop starting posts),
# FM_SLACK_BRIDGE_NOW (epoch override for tests).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
UPDATES_STATE="$STATE/updates"
DIGEST_LAST="$UPDATES_STATE/digest-last"
POSTS="$STATE/slack-bridge/posts"
BRIDGE="$SCRIPT_DIR/fm-slack-bridge.sh"
POST_SECS=12

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-updates.sh scan             list unreported outcomes and finished workers due for cleanup
  fm-updates.sh tick             post owed outcomes and a due morning digest
  fm-updates.sh settle <task>    post one task's owed outcome before its cleanup
  fm-updates.sh digest [--print] post the morning digest now, or only print it
  fm-updates.sh --help           print this help
EOF
}

die() { printf 'fm-updates: %s\n' "$*" >&2; exit 1; }

now_epoch() {
  case "${FM_SLACK_BRIDGE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_SLACK_BRIDGE_NOW" ;;
  esac
}

local_time() {  # <epoch> <format>
  date -r "$1" "+$2" 2>/dev/null || date -d "@$1" "+$2"
}

grace_secs() {
  case "${FM_UPDATES_GRACE:-}" in
    ''|*[!0-9]*) printf '900\n' ;;
    *) printf '%s\n' "$FM_UPDATES_GRACE" ;;
  esac
}

stale_secs() {
  case "${FM_UPDATES_STALE:-}" in
    ''|*[!0-9]*) printf '86400\n' ;;
    *) printf '%s\n' "$FM_UPDATES_STALE" ;;
  esac
}

# The PR's state (OPEN, MERGED, CLOSED) through one bounded gh call; empty when
# it cannot be read.
pr_state() {  # <pr-url>
  fm_gh_run_timed 5 gh pr view "$1" --json state -q .state 2>/dev/null | sed -n 1p
}

# ------------------------------------------------------------- settings

S_ON=0
S_LANG=en
S_UPDATES=
S_DIGEST_HOUR=8
S_BOARD=
settings_load() {
  local out key value
  out=$("$BRIDGE" settings 2>/dev/null) || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      bridge) [ "$value" = on ] && S_ON=1 ;;
      language) S_LANG=$value ;;
      updates-channel) S_UPDATES=$value ;;
      digest-hour) S_DIGEST_HOUR=$value ;;
      board-url) S_BOARD=$value ;;
    esac
  done <<EOF
$out
EOF
}

# Pick the post's words in the configured language.
say() {  # <en> <de>
  if [ "$S_LANG" = de ]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

# ---------------------------------------------------------------- tasks

meta_get() {  # <meta-file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | sed -n 1p
}

task_ids() {
  local f id
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    id=${f##*/}
    id=${id%.meta}
    [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
    printf '%s\n' "$id"
  done
}

# The backlog's human title, without its trailing links and annotations;
# the task id when the backlog is not a readable markdown file.
task_title() {  # <task>
  local title=
  [ -f "$DATA/backlog.md" ] && title=$(awk -v id="$1" '
    index($0, "- [ ] " id " - ") == 1 || index($0, "- [x] " id " - ") == 1 {
      t = substr($0, length(id) + 10)
      sub(/ (https?:\/\/|data\/|\().*$/, "", t)
      print t
      exit
    }' "$DATA/backlog.md" 2>/dev/null)
  printf '%s\n' "${title:-$1}"
}

# What one task owes. 0 with O_KIND, O_TITLE, O_PROJECT, O_NEXT, O_URL, O_DUE
# (1 once the grace period passed), and O_FINAL (1 when nothing follows the
# outcome but cleanup); 1 when the task owes nothing.
O_KIND= O_TITLE= O_PROJECT= O_NEXT= O_URL= O_DUE=0 O_FINAL=0
task_outcome() {  # <task>
  local id=$1 meta="$STATE/$1.meta" kind mode yolo pr line verb at project
  O_KIND= O_TITLE= O_PROJECT= O_NEXT= O_URL= O_DUE=0 O_FINAL=0
  [ -f "$meta" ] || return 1
  kind=$(meta_get "$meta" kind)
  [ "$kind" != secondmate ] || return 1
  mode=$(meta_get "$meta" mode)
  yolo=$(meta_get "$meta" yolo)
  pr=$(meta_get "$meta" pr)
  line=$(last_status_line "$STATE/$id.status")
  status_line_verb "$line" verb
  project=$(meta_get "$meta" project)
  project=${project%/}
  O_PROJECT=${project##*/}
  O_TITLE=$(task_title "$id")
  case "$pr" in https://*) ;; *) pr= ;; esac
  if [ -s "$STATE/$id.pr-poll-merge-notified" ]; then
    O_KIND=merged
    O_URL=$pr
    O_NEXT=$(say "Merged. Nothing to do." "Ist übernommen. Nichts zu tun.")
    O_FINAL=1
    at=$(fm_updates_mtime "$STATE/$id.pr-poll-merge-notified")
  else
    case "$verb" in
      done)
        if [ -z "$pr" ]; then
          pr=$(printf '%s\n' "$line" | grep -oE 'https://github\.com/[^[:space:]]+/pull/[0-9]+' | sed -n 1p)
        fi
        if [ "$kind" = scout ]; then
          O_KIND=finished
          O_NEXT=$(say "The result is ready; ask Firstmate for the summary." "Das Ergebnis ist fertig; frag Firstmate nach der Zusammenfassung.")
          O_FINAL=1
        elif [ "$mode" = local-only ]; then
          O_KIND=finished
          O_NEXT=$(say "Done and kept on this computer. Nothing to do." "Fertig und auf diesem Rechner übernommen. Nichts zu tun.")
          O_FINAL=1
        elif [ -z "$pr" ]; then
          O_KIND=finished
          O_NEXT=$(say "Done. Nothing to do." "Fertig. Nichts zu tun.")
          O_FINAL=1
        elif [ "$yolo" != on ]; then
          O_KIND=ready
          O_URL=$pr
          O_NEXT=$(say "Look at it, then reply merge or hold in the thread." "Schau es dir an und antworte im Thread mit merge oder warten.")
        else
          at=$(status_line_at_epoch "$line") || at=$(fm_updates_mtime "$STATE/$id.status")
          [ $(( $(now_epoch) - ${at:-0} )) -ge "$(grace_secs)" ] || return 1
          O_URL=$pr
          case "$(pr_state "$pr")" in
            MERGED)
              O_KIND=merged
              O_NEXT=$(say "Merged. Nothing to do." "Ist übernommen. Nichts zu tun.")
              O_FINAL=1
              ;;
            CLOSED) O_KIND=stuck ;;
            *)
              [ $(( $(now_epoch) - ${at:-0} )) -ge "$(stale_secs)" ] || return 1
              O_KIND=stuck
              ;;
          esac
          [ "$O_KIND" != stuck ] || O_NEXT=$(say "Firstmate is looking into it; nothing to do for now." "Firstmate kümmert sich darum; du musst gerade nichts tun.")
        fi
        ;;
      failed)
        O_KIND=stuck
        O_URL=$pr
        O_NEXT=$(say "Firstmate is looking into it; nothing to do for now." "Firstmate kümmert sich darum; du musst gerade nichts tun.")
        ;;
      *) return 1 ;;
    esac
    at=$(status_line_at_epoch "$line") || at=$(fm_updates_mtime "$STATE/$id.status")
  fi
  [ -n "$at" ] || at=0
  [ $(( $(now_epoch) - at )) -lt "$(grace_secs)" ] || O_DUE=1
  return 0
}

fm_updates_mtime() {  # <file>
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf '0\n'
}

outcome_posted() {  # <task> <kind>
  "$BRIDGE" posted --task "$1" "$2" >/dev/null 2>&1
}

outcome_post() {  # <task>; posts the current O_* outcome
  local title=$O_TITLE
  case "$O_KIND" in
    ready) title="$(say "Approval needed" "Freigabe nötig"): $title" ;;
    stuck) title="$title $(say "is stuck" "hängt")" ;;
  esac
  local -a args=(post "$O_KIND" --task "$1" --title "$title" --context "$O_NEXT")
  [ -z "$O_PROJECT" ] || args+=(--project "$O_PROJECT")
  [ -z "$O_URL" ] || args+=(--url "$O_URL")
  "$BRIDGE" "${args[@]}" 2>&1
}

# ----------------------------------------------------------------- scan

action_scan() {
  local id
  settings_load
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    task_outcome "$id" || continue
    if [ "$S_ON" -eq 1 ] && ! outcome_posted "$id" "$O_KIND"; then
      [ "$O_DUE" -eq 1 ] || continue
      printf 'unreported %s %s: %s\n' "$id" "$O_KIND" "$O_TITLE"
    elif [ "$O_FINAL" -eq 1 ]; then
      case "$O_KIND" in
        merged) printf 'cleanup-due %s: merged and reported; run bin/fm-teardown.sh %s\n' "$id" "$id" ;;
        *) printf 'cleanup-due %s: finished and reported; run bin/fm-teardown.sh %s\n' "$id" "$id" ;;
      esac
    fi
  done <<EOF
$(task_ids)
EOF
}

# ----------------------------------------------------------------- tick

deadline_left() {
  case "${FM_UPDATES_DEADLINE:-}" in
    ''|*[!0-9]*) printf '%s\n' 600 ;;
    *) printf '%s\n' $((FM_UPDATES_DEADLINE - $(now_epoch))) ;;
  esac
}

action_tick() {
  local id out
  settings_load
  [ "$S_ON" -eq 1 ] || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    task_outcome "$id" || continue
    [ "$O_DUE" -eq 1 ] || continue
    outcome_posted "$id" "$O_KIND" && continue
    [ "$(deadline_left)" -ge "$POST_SECS" ] || return 0
    if out=$(outcome_post "$id"); then
      case "$out" in *"already posted"*) ;; *) printf 'posted %s %s\n' "$id" "$O_KIND" ;; esac
    else
      printf 'failed %s %s: %s\n' "$id" "$O_KIND" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
    fi
  done <<EOF
$(task_ids)
EOF
  digest_due || return 0
  [ "$(deadline_left)" -ge "$POST_SECS" ] || return 0
  if out=$(digest_post 2>&1); then
    printf 'posted digest\n'
  else
    printf 'failed digest: %s\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  fi
}

# --------------------------------------------------------------- settle

action_settle() {
  local id=${1:-} out
  [ "$#" -eq 1 ] && [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { usage >&2; exit 2; }
  settings_load
  [ "$S_ON" -eq 1 ] || return 0
  task_outcome "$id" || return 0
  outcome_posted "$id" "$O_KIND" && return 0
  out=$(outcome_post "$id") || { printf 'fm-updates: could not report %s (%s) before cleanup: %s\n' "$id" "$O_KIND" "$out" >&2; return 1; }
  printf 'posted %s %s\n' "$id" "$O_KIND"
}

# --------------------------------------------------------------- digest

digest_due() {
  local now hour today last
  [ -n "$S_UPDATES" ] || return 1
  now=$(now_epoch)
  hour=$(local_time "$now" %H) || return 1
  hour=$((10#$hour))
  [ "$hour" -ge "$S_DIGEST_HOUR" ] && [ "$hour" -lt $((S_DIGEST_HOUR + 4)) ] || return 1
  today=$(local_time "$now" %F) || return 1
  last=
  [ -f "$DIGEST_LAST" ] && last=$(sed -n 1p "$DIGEST_LAST")
  [ "$last" != "$today" ]
}

# Captain-held calls by title, one per line; empty when the backlog is unreadable.
captain_calls() {
  "$SCRIPT_DIR/fm-tasks-axi.sh" list --state held --fields hold_kind 2>/dev/null | awk '
    /^  / && /,captain$/ {
      line = $0
      sub(/^  /, "", line)
      sub(/,captain$/, "", line)
      for (i = 0; i < 4; i++) sub(/^[^,]*,/, "", line)
      gsub(/^"|"$/, "", line)
      sub(/\\n.*$/, "", line)
      print line
    }'
}

DIGEST_LINES=()
digest_compose() {
  local now since id verb needs=0 running=0 names='' title finished merged live calls
  now=$(now_epoch)
  since=$((now - 86400))
  calls=$(captain_calls)
  while IFS= read -r title; do
    [ -n "$title" ] || continue
    needs=$((needs + 1))
    [ "$needs" -gt 3 ] || names="$names${names:+, }$title"
  done <<EOF
$calls
EOF
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if task_outcome "$id"; then
      if [ "$O_KIND" = ready ]; then
        needs=$((needs + 1))
        [ "$needs" -gt 3 ] || names="$names${names:+, }$O_TITLE"
      fi
      continue
    fi
    [ "$(meta_get "$STATE/$id.meta" kind)" != secondmate ] || continue
    status_line_verb "$(last_status_line "$STATE/$id.status")" verb
    [ "$verb" = working ] || continue
    running=$((running + 1))
  done <<EOF
$(task_ids)
EOF
  finished=0 merged=0 live=0
  if [ -f "$POSTS" ]; then
    read -r finished merged live <<EOF
$(awk -F '\t' -v s="$since" '$1 == "v1" && $5 + 0 >= s { n[$4]++ }
  END { printf "%d %d %d\n", n["finished"], n["merged"], n["live"] }' "$POSTS")
EOF
  fi
  DIGEST_LINES=()
  if [ "$needs" -eq 0 ]; then
    DIGEST_LINES+=("🙋 $(say "Nothing needs you." "Nichts wartet auf dich.")")
  else
    DIGEST_LINES+=("🙋 $(say "Needs you" "Wartet auf dich"): $needs - $names")
  fi
  DIGEST_LINES+=("✅ $(say "Last 24 hours: $finished finished, $merged merged, $live live" "Letzte 24 Stunden: $finished fertig, $merged übernommen, $live live")")
  DIGEST_LINES+=("⏳ $(say "Running now: $running" "Läuft gerade: $running")")
}

digest_post() {
  local today
  local -a args
  digest_compose
  args=(post digest --title "$(say "Good morning - your summary" "Guten Morgen - dein Überblick")")
  for line in "${DIGEST_LINES[@]}"; do args+=(--line "$line"); done
  [ -z "$S_BOARD" ] || args+=(--url "$S_BOARD")
  "$BRIDGE" "${args[@]}" || return 1
  today=$(local_time "$(now_epoch)" %F) || return 1
  mkdir -p "$UPDATES_STATE" && printf '%s\n' "$today" > "$DIGEST_LAST"
}

action_digest() {
  settings_load
  case "${1:-}" in
    --print)
      digest_compose
      say "Good morning - your summary" "Guten Morgen - dein Überblick"
      printf '\n'
      printf '%s\n' "${DIGEST_LINES[@]}"
      [ -z "$S_BOARD" ] || printf '%s\n' "$S_BOARD"
      ;;
    '')
      [ "$S_ON" -eq 1 ] || die "the Slack bridge is off; write config/slack-bridge first"
      digest_post
      ;;
    *) usage >&2; exit 2 ;;
  esac
}

case "${1:-}" in
  scan) action_scan ;;
  tick) action_tick ;;
  settle) shift; action_settle "$@" ;;
  digest) shift; action_digest "$@" ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) printf 'fm-updates: unknown action: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
