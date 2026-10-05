#!/usr/bin/env bash
# Post-merge watch record: the durable state bin/fm-post-merge.sh keeps for one
# task's watched landing, and the teardown predicate that reads it.
#
# The record is state/<task-id>.post-merge, a private (0600) key=value file
# rewritten atomically by bin/fm-post-merge.sh under its own lock. It is bound
# to the task incarnation through spawn_gen, so a record left by an earlier
# incarnation of a reused task id is ignored rather than trusted.
# bin/fm-post-merge.sh's header owns the field list and the phase machine;
# this library owns only reading a record and what cleanup does with it.
#
# Cleanup (bin/fm-teardown.sh) asks fm_post_merge_teardown_transition before
# any destructive step:
#   - a merge's post_merge_watch_required marker without a valid same-incarnation
#     watch record refuses cleanup;
#   - no marker and no record, a record from another incarnation, or phase clear
#     or closed: cleanup proceeds and closes the backlog item as usual;
#   - phase reverted: cleanup proceeds but returns the backlog item to Queued
#     instead of closing it, because the landed work was taken back out;
#   - any other phase (the watch is still waiting on checks, a witness, or a
#     revert): cleanup refuses, because the task record is what the revert
#     still needs and landing is not confirmed yet;
#   - an unreadable record: cleanup refuses rather than guess.
# --force does not lift that refusal: it authorizes discarding unlanded work,
# and a post-merge watch is about landed work. `bin/fm-post-merge.sh close`
# is the one way to end a watch early.

fm_post_merge_record_path() {  # <state> <id>
  printf '%s/%s.post-merge\n' "$1" "$2"
}

# Print the last value recorded for <key>; empty when absent.
fm_post_merge_record_get() {  # <record> <key>
  local record=$1 key=$2 line value=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) value=${line#*=} ;;
    esac
  done < "$record"
  printf '%s\n' "$value"
}

fm_post_merge_watch_required_set() {  # <state> <meta> <value>; empty removes the marker
  local state=$1 meta=$2 value=$3 lock tmp line status=0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  tmp=$(mktemp "$state/.fm-post-merge-meta.XXXXXX") || { fm_lock_release "$lock" || true; return 1; }
  {
    [ -z "$value" ] || printf 'post_merge_watch_required=%s\n' "$value"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        post_merge_watch_required=*) ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$meta"
  } > "$tmp" || status=1
  [ "$status" -ne 0 ] || chmod 0600 "$tmp" || status=1
  [ "$status" -ne 0 ] || mv -f -- "$tmp" "$meta" || status=1
  [ "$status" -eq 0 ] || rm -f -- "$tmp"
  fm_lock_release "$lock" || status=1
  return "$status"
}

# Sets FM_POST_MERGE_TEARDOWN to close or retain and returns 0, or sets
# FM_POST_MERGE_TEARDOWN_ERROR and returns 1 when cleanup must refuse.
# shellcheck disable=SC2034  # Both results are read by bin/fm-teardown.sh.
fm_post_merge_teardown_transition() {  # <state> <id> <meta>
  local state=$1 id=$2 meta=$3 record phase record_gen meta_gen='' watch_required=''
  FM_POST_MERGE_TEARDOWN=close
  FM_POST_MERGE_TEARDOWN_ERROR=
  record=$(fm_post_merge_record_path "$state" "$id")
  if [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ]; then
    watch_required=$(fm_post_merge_record_get "$meta" post_merge_watch_required)
    meta_gen=$(fm_post_merge_record_get "$meta" spawn_gen)
  fi
  if [ -n "$watch_required" ] && { [ ! -e "$record" ] && [ ! -L "$record" ]; }; then
    FM_POST_MERGE_TEARDOWN_ERROR="task $id has a pending post-merge watch marker without a watch record; retry with bin/fm-post-merge.sh arm $id"
    return 1
  fi
  [ -e "$record" ] || [ -L "$record" ] || return 0
  if [ ! -f "$record" ] || [ -L "$record" ] || [ ! -r "$record" ]; then
    FM_POST_MERGE_TEARDOWN_ERROR="the post-merge watch record for $id is not a readable regular file"
    return 1
  fi
  if [ "$(fm_post_merge_record_get "$record" version)" != fm-post-merge-v1 ]; then
    FM_POST_MERGE_TEARDOWN_ERROR="the post-merge watch record for $id is unreadable"
    return 1
  fi
  record_gen=$(fm_post_merge_record_get "$record" spawn_gen)
  if [ -n "$watch_required" ] && [ "$record_gen" != "$meta_gen" ]; then
    FM_POST_MERGE_TEARDOWN_ERROR="task $id has a pending post-merge watch marker but no same-incarnation watch record; retry with bin/fm-post-merge.sh arm $id"
    return 1
  fi
  [ "$record_gen" = "$meta_gen" ] || return 0
  phase=$(fm_post_merge_record_get "$record" phase)
  case "$phase" in
    clear|closed) return 0 ;;
    reverted)
      FM_POST_MERGE_TEARDOWN=retain
      return 0
      ;;
    checks|witness|reverting|blocked)
      FM_POST_MERGE_TEARDOWN_ERROR="the post-merge watch for $id is still in phase '$phase', so its landing is not confirmed; run bin/fm-post-merge.sh advance $id, or end the watch with bin/fm-post-merge.sh close $id on the captain's word"
      return 1
      ;;
    *)
      FM_POST_MERGE_TEARDOWN_ERROR="the post-merge watch record for $id has an unknown phase '$phase'"
      return 1
      ;;
  esac
}
