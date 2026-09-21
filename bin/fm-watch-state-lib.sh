#!/usr/bin/env bash
# bin/fm-watch-state-lib.sh - the ONE owner of the watcher pane-supervision
# marker lifecycle under state/.
#
# fm-watch.sh names every per-window bookkeeping file by one derivation
# (fm_watch_state_key): the recorded endpoint target with ':', '/', and '.'
# flattened to '_'. That key outlives the task that created it: a window handed
# to a successor (a reused pane slot, a relaunched endpoint, a remote route
# claimed again) resolves to the NEW task through window_to_task while the OLD
# task's .hash-/.count-/.stale-/.stale-since-/.wedge-escalations- and
# pause/write/wait markers still sit on disk. The first stable-hash sight then
# classifies the successor inside the predecessor's escalation timeline - the
# false "possible wedge, escalation N" alarms on healthy workers that this
# retirement exists to stop (the 2026-09 phantom stale/wedge incidents).
#
# Retirement has two complementary mechanisms, both inside existing lifecycle
# paths - no ad-hoc cleaner:
#
#   bind    fm_watch_window_bind, called by the watcher for every recorded
#           window once at startup and again per poll before any marker is
#           read. The .window-owner-<key> marker records which task the key's
#           state belongs to. Three cases: the recorded owner IS the task -
#           one marker read and return; a DIFFERENT owner is recorded - the
#           key belongs to a predecessor, so every window-keyed marker is
#           retired before it can be read, then the new owner is written; no
#           owner is recorded - the markers can only be this task's own
#           not-yet-claimed state (spawn claims at publish, so a predecessor's
#           residue always still carries ITS owner), so the task just claims
#           the key without touching the markers. Detection semantics are
#           unchanged: the successor's own fresh counters still classify,
#           absorb, and escalate exactly as before.
#
#   retire  fm_watch_retire_window_state + fm_watch_retire_task_state, called
#           by bin/fm-teardown.sh when a task's endpoint goes away and by
#           bin/fm-spawn.sh just before it publishes a task record claiming an
#           endpoint. fm_watch_orphan_state_sweep, called by bin/fm-bootstrap.sh
#          's locked session-start mutating phase after backlog reconciliation
#           settles the live meta set, removes whatever those paths could not:
#           window-keyed markers whose key no live meta records, task-keyed
#           markers whose task has no meta, signal files whose task is gone,
#           and seen markers whose signal file is gone.
#
# The status-paired marker families (.seen-<task>_status, .hb-surfaced-<task>,
# .subsuper-seen-status-<task>, .<task>.open-decisions-cursor) stay owned by
# status_retire_presentation_task (bin/fm-classify-lib.sh), which removes them
# together with <task>.status - a deliberately kept orphan log keeps its
# markers so it can never replay. The sweep removes one of those markers only
# when its <task>.status is gone.
#
# Requires fm-backend.sh sourced (fm_meta_get, fm_backend_target_of_meta);
# every production caller already has it.
set -u

# The ONE derivation of a watcher marker key: ':', '/', and '.' become '_' so
# an endpoint target or task id is usable as a filename suffix. Every per-
# window file the watcher keeps is named by it (.hash-, .count-, .stale-,
# .stale-since-, .wedge-escalations-, .paused-*, .writing-*, .waiting-*,
# .churn-since-, .dead-reported-, .window-owner-), the sub-supervisor keys its
# per-task episode markers with the same derivation (.subsuper-stale-,
# .subsuper-paused-, .subsuper-pause-until-due-), and live homes hold those
# markers on disk under this exact format, so the format lives here alone: a
# second copy is how a future change silently orphans markers instead of
# retiring them.
fm_watch_state_key() {  # <window-target-or-task-id> -> marker key
  local key=${1//:/_}
  key=${key//\//_}
  printf '%s' "${key//./_}"
}

# Every per-window marker family, as filename prefixes after state/. Order
# matters for the sweep's glob pass: a family that prefixes another must come
# first (.stale-since- before .stale-, .paused-rechecked-/.paused-resurfaced-
# before .paused-) so each file is claimed by its longest family exactly once.
fm_watch_window_marker_families() {
  printf '%s\n' \
    .stale-since- \
    .paused-rechecked- \
    .paused-resurfaced- \
    .writing-since- \
    .writing-resurfaced- \
    .waiting-resurfaced- \
    .wedge-escalations- \
    .churn-since- \
    .dead-reported- \
    .window-owner- \
    .count- \
    .hash- \
    .paused- \
    .stale-
}

# Remove every per-window marker one recorded endpoint target owns. Idempotent;
# safe to call for a target that never had markers written.
fm_watch_retire_window_state() {  # <state-dir> <window-target>
  local state=$1 w=$2 key family
  [ -n "$w" ] || return 0
  key=$(fm_watch_state_key "$w")
  while IFS= read -r family; do
    [ -n "$family" ] || continue
    rm -f -- "$state/$family$key" || return 1
  done <<EOF
$(fm_watch_window_marker_families)
EOF
}

# Remove the task-keyed supervision markers a retired or replaced task leaves:
# the sub-supervisor's per-task stale/pause episode markers (keyed by the same
# derivation) and the parent-side secondmate wake-stall trackers (keyed by the
# raw task id). Deliberately excludes the status-paired families - the
# status-presentation owner retires those with <task>.status, and a task's
# log legitimately outlives one incarnation. Safe at both teardown (task gone)
# and spawn (fresh incarnation of a reused id or claimed endpoint).
fm_watch_retire_task_state() {  # <state-dir> <task-id>
  local state=$1 task=$2 enc
  [ -n "$task" ] || return 0
  enc=$(fm_watch_state_key "$task")
  rm -f -- "$state/.subsuper-stale-$enc" "$state/.subsuper-paused-$enc" \
    "$state/.subsuper-pause-until-due-$enc" \
    "$state/.secondmate-wake-stall-$task" "$state/.secondmate-wake-progress-$task" \
    || return 1
  if [ -d "$state/.secondmate-wake-stall-receipts/$task" ]; then
    rm -rf -- "$state/.secondmate-wake-stall-receipts/$task" || return 1
  fi
}

# Write an owner record atomically. A reader that caught a partial owner line
# would retire the whole marker set as if another task owned it, so the record
# is staged and renamed.
fm_watch_window_owner_write() {  # <owner-file> <task>
  local owner_file=$1 task=$2 tmp
  tmp="$owner_file.tmp.$$"
  printf '%s' "$task" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$owner_file"
}

# Claim an endpoint's marker set for a task at record time: retire whatever a
# previous owner left under the key, then publish this task as the owner. Spawn
# calls this just before it publishes the task's meta, so the owner's task id
# is already recorded by the time any watcher poll can see the window - a
# first-poll bind then never mistakes the new task's own fresh markers for a
# predecessor's residue.
fm_watch_window_claim() {  # <state-dir> <window-target> <task>
  local state=$1 w=$2 task=$3 key
  [ -n "$w" ] && [ -n "$task" ] || return 0
  key=$(fm_watch_state_key "$w")
  fm_watch_retire_window_state "$state" "$w" || return 1
  fm_watch_window_owner_write "$state/.window-owner-$key" "$task"
}

# Bind a recorded window's marker set to its current owning task. The owner
# recorded in .window-owner-<key> decides:
#   same task:        one marker read and return - the steady-state cost.
#   different owner:  the key belongs to a predecessor, so the whole marker
#                     set is retired before it can be read, then the new
#                     owner is written.
#   no owner record:  claim the key for this task and leave the markers alone.
#                     Spawn writes the owner at claim time before the meta is
#                     published, so a predecessor's residue always still
#                     carries ITS owner record; whatever sits under an
#                     unclaimed key is this task's own not-yet-bound state
#                     (including anything a signal path wrote earlier in the
#                     same poll) and must never be mistaken for residue.
fm_watch_window_bind() {  # <state-dir> <window-target> <task>
  local state=$1 w=$2 task=$3 key owner_file owner
  [ -n "$w" ] && [ -n "$task" ] || return 0
  key=$(fm_watch_state_key "$w")
  owner_file="$state/.window-owner-$key"
  owner=$(cat "$owner_file" 2>/dev/null || true)
  if [ -z "$owner" ]; then
    fm_watch_window_owner_write "$owner_file" "$task"
    return $?
  fi
  [ "$owner" = "$task" ] && return 0
  fm_watch_retire_window_state "$state" "$w" || return 1
  fm_watch_window_owner_write "$owner_file" "$task"
}

# Retire watcher bookkeeping whose owner is gone. Prints the number of files
# removed. Runs inside bootstrap's locked session-start mutating phase after
# backlog reconciliation, so the meta set it reads is settled for this session.
#
#   window-keyed markers: removed when no live *.meta records a target that
#     derives their key (longest-family-first claiming handles prefixes that
#     nest, like .stale- inside .stale-since-).
#   task-keyed markers: .subsuper-{stale,paused,pause-until-due}-<enc>,
#     .secondmate-wake-{stall,progress}-<task>, and
#     .secondmate-wake-stall-receipts/<task>/ removed when no <task>.meta lives.
#   signal files: <task>.turn-ended and <task>.progress removed when no
#     <task>.meta lives - a dead task's marker can only phantom-signal.
#   seen markers: .seen-<enc>_status and .seen-<enc>_turn-ended removed when
#     their signal file is gone; .hb-surfaced-<enc>,
#     .subsuper-seen-status-<enc>, and .<task>.open-decisions-cursor removed
#     when <task>.status is gone. Kept while the log survives: an orphan log
#     must keep its markers or it replays as fresh on the next scan.
#   <task>.status itself is NEVER touched: deliberately kept orphan logs are a
#     session-start digest input, not watcher residue.
fm_watch_orphan_state_sweep() {  # <state-dir>
  local state=$1 meta task w family marker base key enc f d removed=0
  local live_tasks=$'\n' live_keys=$'\n' live_enc=$'\n'
  local status_enc=$'\n' status_raw=$'\n' seen_status=$'\n' seen_turnend=$'\n'
  local seen_files=$'\n'

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    live_tasks="$live_tasks$task"$'\n'
    live_enc="$live_enc$(fm_watch_state_key "$task")"$'\n'
    w=$(fm_backend_target_of_meta "$meta") || w=
    if [ -n "$w" ]; then
      live_keys="$live_keys$(fm_watch_state_key "$w")"$'\n'
    fi
  done

  # Meta-less signal-source files are residue; removing them first also makes
  # their .seen- markers orphans for the pairing passes below.
  for f in "$state"/*.turn-ended "$state"/*.progress; do
    [ -f "$f" ] || [ -L "$f" ] || continue
    base=${f##*/}
    task=${base%.*}
    case "$live_tasks" in *$'\n'"$task"$'\n'*) continue ;; esac
    rm -f -- "$f" || return 1
    removed=$((removed + 1))
  done

  # Pairing keep-sets are built from the surviving signal FILES, because the
  # marker-name encoding is lossy (a.b and a_b share one encoded name; a marker
  # is live while any file it could encode exists).
  for f in "$state"/*.status; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    base=${f##*/}
    seen_status="$seen_status$(fm_watch_state_key "$base")"$'\n'
    task=${base%.status}
    status_enc="$status_enc$(fm_watch_state_key "$task")"$'\n'
    status_raw="$status_raw$task"$'\n'
  done
  for f in "$state"/*.turn-ended; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    seen_turnend="$seen_turnend$(fm_watch_state_key "${f##*/}")"$'\n'
  done

  for marker in "$state"/.seen-*_status; do
    [ -f "$marker" ] || [ -L "$marker" ] || continue
    enc=${marker##*/.seen-}
    case "$seen_status" in *$'\n'"$enc"$'\n'*) continue ;; esac
    rm -f -- "$marker" || return 1
    removed=$((removed + 1))
  done
  for marker in "$state"/.seen-*_turn-ended; do
    [ -f "$marker" ] || [ -L "$marker" ] || continue
    enc=${marker##*/.seen-}
    case "$seen_turnend" in *$'\n'"$enc"$'\n'*) continue ;; esac
    rm -f -- "$marker" || return 1
    removed=$((removed + 1))
  done
  for marker in "$state"/.hb-surfaced-* "$state"/.subsuper-seen-status-*; do
    [ -f "$marker" ] || [ -L "$marker" ] || continue
    base=${marker##*/}
    enc=${base#.hb-surfaced-}
    enc=${enc#.subsuper-seen-status-}
    case "$status_enc" in *$'\n'"$enc"$'\n'*) continue ;; esac
    rm -f -- "$marker" || return 1
    removed=$((removed + 1))
  done
  for marker in "$state"/.*.open-decisions-cursor; do
    [ -f "$marker" ] || [ -L "$marker" ] || continue
    base=${marker##*/}
    task=${base#.}
    task=${task%.open-decisions-cursor}
    case "$status_raw" in *$'\n'"$task"$'\n'*) continue ;; esac
    rm -f -- "$marker" || return 1
    removed=$((removed + 1))
  done

  for marker in "$state"/.subsuper-stale-* "$state"/.subsuper-paused-* \
      "$state"/.subsuper-pause-until-due-*; do
    [ -f "$marker" ] || [ -L "$marker" ] || continue
    base=${marker##*/}
    enc=${base#.subsuper-stale-}
    enc=${enc#.subsuper-paused-}
    enc=${enc#.subsuper-pause-until-due-}
    case "$live_enc" in *$'\n'"$enc"$'\n'*) continue ;; esac
    rm -f -- "$marker" || return 1
    removed=$((removed + 1))
  done
  for marker in "$state"/.secondmate-wake-stall-* "$state"/.secondmate-wake-progress-*; do
    [ -f "$marker" ] || [ -L "$marker" ] || continue
    base=${marker##*/}
    case "$base" in
      .secondmate-wake-stall-*)   task=${base#.secondmate-wake-stall-} ;;
      *)                          task=${base#.secondmate-wake-progress-} ;;
    esac
    case "$live_tasks" in *$'\n'"$task"$'\n'*) continue ;; esac
    rm -f -- "$marker" || return 1
    removed=$((removed + 1))
  done
  if [ -d "$state/.secondmate-wake-stall-receipts" ]; then
    for d in "$state"/.secondmate-wake-stall-receipts/*/; do
      [ -d "$d" ] || continue
      task=${d%/}
      task=${task##*/}
      case "$live_tasks" in *$'\n'"$task"$'\n'*) continue ;; esac
      rm -rf -- "$d" || return 1
      removed=$((removed + 1))
    done
  fi

  while IFS= read -r family; do
    [ -n "$family" ] || continue
    for marker in "$state/$family"*; do
      [ -f "$marker" ] || [ -L "$marker" ] || continue
      base=${marker##*/}
      case "$seen_files" in *$'\n'"$base"$'\n'*) continue ;; esac
      seen_files="$seen_files$base"$'\n'
      key=${base#$family}
      case "$live_keys" in *$'\n'"$key"$'\n'*) continue ;; esac
      rm -f -- "$marker" || return 1
      removed=$((removed + 1))
    done
  done <<EOF
$(fm_watch_window_marker_families)
EOF

  printf '%s\n' "$removed"
}
