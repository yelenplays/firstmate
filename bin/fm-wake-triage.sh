#!/usr/bin/env bash
# fm-wake-triage.sh - one call per wake batch: drain, read, classify, summarize.
#
# Usage:
#   fm-wake-triage.sh [--auto-ack]
#
# Runs bin/fm-wake-drain.sh exactly once, reads the current state of every
# task a presented wake names (bin/fm-crew-state.sh, plus the pane's last
# lines through bin/fm-peek.sh only when that state is unknown), and sorts
# every presented item into ACT NOW or ROUTINE. It prints one compact ACT NOW
# line per item (task, what happened, the next action, and any PR URL or
# findings file), one ROUTINE summary line, and the drain's exact
# WAKE_ACK_REQUIRED acknowledgement command. The full drain output is kept in
# state/.wake-triage-last.out for any item that needs the raw text.
#
# The drain stays the single owner of presentation and acknowledgement; this
# script never edits the queue, a status log, the backlog, or a worker.
#
# Deterministic rules decide first:
#   routine  an execution reminder to verify progress for a worker
#            crew-state reads as working, to verify an idle or failed owner
#            whose run-step reads working (validation is running), or for a
#            recorded PR that only awaits merge authority; an
#            execution obligation whose owner is not firstmate; an idle
#            alert or bare turn-end for a worker that is working, paused, held
#            for the captain (bin/fm-captain-hold.sh open), finished with a
#            recorded PR, or parked on an already-open decision; a status
#            line declaring working:, paused:, resolved:, or captain-held:;
#            a done: line without a PR whose worker is now validating; a
#            task's earlier done:/failed: lines superseded by a newer one and
#            decision lines the OPEN DECISIONS fold no longer holds open;
#            a secondmate turn-end or idle alert with no status line while
#            the secondmate's state is healthy; OPEN DECISIONS
#            identical to the set the previous triage presented.
#   act-now  needs-decision:, blocked:, failed:, a done: line (with its PR
#            URL when present), a worker whose state reads done, parked,
#            failed, blocked, or unknown without a covering reason (for a
#            secondmate, failed, blocked, or unknown whatever the reason), a
#            possible-wedge alert unless the worker is finished with a
#            recorded PR or parked on a listed open decision, a dead-agent or
#            unread-instruction idle alert, every other firstmate-owned
#            execution obligation (every reconcile-* action included)
#            whatever the pane shows, a procevent/board, inbox, merge, or
#            any other check result, a heartbeat, a changed OPEN DECISIONS
#            set, RECORD DIVERGENCE, and every drain notice or error. UNREAD
#            STATUS and STATUS OUTCOME BACKSTOP lines are judged by the same
#            status-line rules.
# Only the leftover ambiguous status lines (a note:, a nonstandard or missing
# verb, or a secondmate done: with no URL) go to Jev, in one bounded call
# through bin/fm-jev-lib.sh, and only when a Jev key is configured. A line
# becomes routine only on a confident routine answer; no key, an unsure
# answer, or a failed call keeps it act-now. Whatever Jev answers, the task is
# also judged by its current state, and one whose state alone is act-now by
# the rules above stays act-now.
#
# Jev payload policy (the captain's privacy line). A line's free text reaches
# Jev only when BOTH hold: this triage runs in the main home (FM_HOME carries
# no secondmate-home marker, bin/fm-primary-scope-lib.sh), and the task is a
# ship or scout task whose recorded project resolves to this firstmate
# repository itself. That text is scrubbed by fm_jev_compact_state and capped
# at LINE_CAP. Every other line - a secondmate task, any run in a secondmate
# home, another project (wikis, websites, vaults), or a task whose kind or
# project cannot be established - sends structured facts only: task kind, a
# vocabulary-checked verb, whether a URL, a file= reference, or a key=/corr=
# token is present, and a coarse length bucket. Pane content is never sent.
#
# --auto-ack  when every presented item is routine, run the printed
#             acknowledgement itself and print WAKE_ACKED instead. Any act-now
#             item, drain notice, or unparseable acknowledgement prevents it.
#
# Exit: the drain's own non-zero status when the drain failed (its output is
# printed unchanged), 2 for usage, otherwise 0.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, and the Jev keys and JEV_* settings
# documented in bin/fm-jev-lib.sh. When no JEV_TIMEOUT is configured in the
# environment or $FM_HOME/.env, the triage call is bounded at 8 seconds.
# Test seams: FM_WAKE_DRAIN_BIN, FM_CREW_STATE_BIN, FM_PEEK_BIN,
# FM_CAPTAIN_HOLD_BIN. Every Jev call appends one metadata-only record
# (counts and verdicts, never status text) to state/jev-wake-triage.jsonl.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

DRAIN_BIN=${FM_WAKE_DRAIN_BIN:-$SCRIPT_DIR/fm-wake-drain.sh}
CREW_STATE_BIN=${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}
PEEK_BIN=${FM_PEEK_BIN:-$SCRIPT_DIR/fm-peek.sh}
CAPTAIN_HOLD_BIN=${FM_CAPTAIN_HOLD_BIN:-$SCRIPT_DIR/fm-captain-hold.sh}
LAST_OUT="$STATE/.wake-triage-last.out"
DECISIONS_SEEN="$STATE/.wake-triage-open-decisions"
JEV_LOG="$STATE/jev-wake-triage.jsonl"
PANE_LINES=6
LINE_CAP=240

AUTO_ACK=false
TRIAGE_JEV_TIMEOUT=8

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --auto-ack) AUTO_ACK=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fm-wake-triage: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-wake-triage.XXXXXX") || exit 1
trap 'rm -rf -- "$WORK"' EXIT
OUT="$WORK/drain.out"
ERR="$WORK/drain.err"

drain_rc=0
"$DRAIN_BIN" > "$OUT" 2> "$ERR" || drain_rc=$?

if [ -d "$STATE" ]; then
  (umask 077; { cat "$OUT"; sed 's/^/[stderr] /' "$ERR"; } > "$LAST_OUT.tmp.$$" \
    && mv -f "$LAST_OUT.tmp.$$" "$LAST_OUT") 2>/dev/null || rm -f "$LAST_OUT.tmp.$$"
fi

if [ "$drain_rc" -ne 0 ]; then
  cat "$OUT"
  cat "$ERR" >&2
  printf 'WAKE TRIAGE: the drain failed (exit %s); its output is printed above unchanged - handle it directly.\n' "$drain_rc" >&2
  exit "$drain_rc"
fi

# --- parse the drain output --------------------------------------------------
# Tagged records, one per line, tab-separated:
#   ROW   epoch seq kind key payload
#   ANN   task status-line
#   SEC   section line
#   NOTE  line          (a drain notice that is not part of a known section)
#   ADV   line          (advisory Jev queue-triage line)
TAB=$(printf '\t')
PARSED="$WORK/parsed"
awk -F '\t' -v OFS='\t' '
  NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { print "ROW", $0; section = ""; next }
  /^wake annotation: / {
    line = $0
    if (match(line, /: [A-Za-z0-9._-]+\.status: /)) {
      head = substr(line, RSTART + 2, RLENGTH - 2)
      sub(/\.status: $/, "", head)
      print "ANN", head, substr(line, RSTART + RLENGTH)
    }
    next
  }
  /^JEV QUEUE TRIAGE/ { print "ADV", $0; next }
  /^UNREAD STATUS \(/ { section = "unread"; next }
  /^OPEN DECISIONS \(/ { section = "decisions"; next }
  /^OPEN DECISIONS: close one/ { next }
  /^OPEN DECISIONS: [0-9]+ more omitted/ { print "SEC", "decisions-omitted", $0; next }
  /^RECORD DIVERGENCE \(/ { section = "divergence"; next }
  /^RECORD DIVERGENCE: / { if ($0 ~ /more omitted/) print "SEC", "divergence", $0; next }
  /^STATUS OUTCOME BACKSTOP \(/ { section = "backstop"; next }
  /^STATUS OUTCOME BACKSTOP: [0-9]+ more omitted/ { print "SEC", "backstop", $0; next }
  /^UNFINISHED EXECUTION \(/ { section = "execution"; next }
  /^WAKE ROWS HELD BY SUPERVISION BRANCH/ { print "SEC", "branch-held", $0; section = ""; next }
  /^[A-Z][A-Z ]+[A-Z]( SKIPPED| INCOMPLETE)?:/ { print "NOTE", $0; section = ""; next }
  section != "" && $0 != "" { print "SEC", section, $0; next }
  $0 != "" { print "NOTE", $0 }
' "$OUT" > "$PARSED"

ACK_SEQ=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$ERR" | tail -n 1)
ACK_GEN=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$ERR" | tail -n 1)
ACK_LINE=$(grep '^WAKE_ACK_REQUIRED:' "$ERR" | tail -n 1 || true)
# Drain stderr beyond the acknowledgement line: guard banners and diagnostics.
# Decoration-only banner rules are dropped, and the guard's queued-wakes
# reminder is dropped because this very run is presenting those rows.
grep -v '^WAKE_ACK_REQUIRED:' "$ERR" \
  | sed 's/^[[:space:]]*●[[:space:]]*//' \
  | grep -v '^[[:space:]━─═=*-]*$' \
  | grep -v 'queued wakes pending - drain them with bin/fm-wake-drain.sh' > "$WORK/notices" || true

# --- per-task evidence caches (files, so bash 3.2 works) ---------------------
CACHE="$WORK/cache"
mkdir -p "$CACHE"

safe_id() { case "$1" in ''|*[!A-Za-z0-9._-]*|.|..) return 1 ;; esac; }

meta_get() {  # <task> <key>
  awk -F= -v key="$2" '$1 == key { v = substr($0, length(key) + 2) } END { print v }' \
    "$STATE/$1.meta" 2>/dev/null || true
}

crew_state() {  # <task> -> one crew-state line (cached)
  local task=$1 f tmp
  safe_id "$task" || { printf 'state: unknown · source: none · invalid task id\n'; return; }
  f="$CACHE/$task.crew"
  if [ ! -f "$f" ]; then
    # Named once: $BASHPID inside the pipeline below would be a pipeline subshell's.
    tmp="$f.${BASHPID:-$$}"
    fm_run_timed 20 "$CREW_STATE_BIN" "$task" 2>/dev/null | head -n 1 > "$tmp" || true
    [ -s "$tmp" ] || printf 'state: unknown · source: none · crew-state unavailable\n' > "$tmp"
    mv -f "$tmp" "$f"
  fi
  cat "$f"
}

crew_word() {  # <task> -> working|parked|done|blocked|paused|failed|unknown
  local line
  line=$(crew_state "$1")
  line=${line#state: }
  printf '%s' "${line%% *}"
}

captain_call_open() {  # <task>
  local task=$1 f
  safe_id "$task" || return 1
  f="$CACHE/$task.hold"
  if [ ! -f "$f" ]; then
    if fm_run_timed 10 "$CAPTAIN_HOLD_BIN" open "$task" >/dev/null 2>&1; then
      echo 0 > "$f"
    else
      echo 1 > "$f"
    fi
  fi
  [ "$(cat "$f")" = 0 ]
}

pane_tail() {  # <task> -> up to PANE_LINES last non-blank lines, indented
  local task=$1
  safe_id "$task" || return 0
  fm_run_timed 10 "$PEEK_BIN" "$task" 30 2>/dev/null \
    | LC_ALL=C tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n "$PANE_LINES" \
    | cut -c1-160 | sed 's/^/    pane: /' || true
}

open_decision_for() {  # <task> -> 0 when the drain listed an open decision for it
  awk -F '\t' -v t="$1" '$1 == "SEC" && $2 == "decisions" {
    split($3, w, " "); if (w[1] == t) found = 1 } END { exit !found }' "$PARSED"
}

# 0 when the drain's OPEN DECISIONS lists this exact decision line: the same
# task and decision key (the fold's unkeyed form for the default key). A line
# the fold rejected, such as a malformed key, is never deferred to it.
decision_listed() {  # <task> <status-line>
  local task=$1 line=$2 key verb
  key=$(_fm_decision_key "$line") || return 1
  status_line_verb "$line" verb
  if [ "$key" = default ]; then
    key="$task $verb:"
  else
    key="$task [key=$key] "
  fi
  awk -F '\t' -v p="$key" '$1 == "SEC" && $2 == "decisions" && index($3, p) == 1 { found = 1 }
    END { exit !found }' "$PARSED"
}

first_url() { printf '%s' "$1" | grep -oE 'https://[^[:space:]]+' | head -n 1 | sed 's/[),.;]*$//'; }
findings_file() { printf '%s' "$1" | grep -oE 'file=[^[:space:]]+' | head -n 1 | sed 's/^file=//'; }

cap() {  # <text> -> single line capped at LINE_CAP
  local s
  s=$(printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ')
  if [ "${#s}" -gt "$LINE_CAP" ]; then s="${s:0:$((LINE_CAP - 3))}..."; fi
  printf '%s' "$s"
}

# --- result accumulators -------------------------------------------------------
ACT="$WORK/act"          # task \t what \t next \t extra
ROUTINE="$WORK/routine"  # task \t why
AMBIG="$WORK/ambig"      # task \t kind \t status-line
SEEN_LINES="$WORK/seen-lines"
: > "$ACT"; : > "$ROUTINE"; : > "$AMBIG"; : > "$SEEN_LINES"

act() {  # <task> <what> <next> [<extra>]
  printf '%s\t%s\t%s\t%s\n' "$1" "$(cap "$2")" "$(cap "$3")" "${4:-}" >> "$ACT"
}
routine() { printf '%s\t%s\n' "$1" "$(cap "$2")" >> "$ROUTINE"; }

# The recorded task kind, empty when the record carries none.
task_kind() { meta_get "$1" kind; }

# The git common dir of <dir> as an absolute path, empty when it is not a repo.
repo_identity() {  # <dir>
  local d
  d=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  (cd "$d" 2>/dev/null && pwd -P)
}
FM_ROOT_REPO=$(repo_identity "$FM_ROOT" || true)
IN_MAIN_HOME=true
fm_root_is_secondmate_home "$FM_HOME" && IN_MAIN_HOME=false

# 0 when <task>'s free-text status may reach Jev under the payload policy in
# this file's header: main home, ship or scout kind, and a recorded project in
# this firstmate repository. Anything unestablished answers no.
jev_text_allowed() {  # <task>
  local task=$1 kind project
  [ "$IN_MAIN_HOME" = true ] && [ -n "$FM_ROOT_REPO" ] || return 1
  safe_id "$task" || return 1
  kind=$(task_kind "$task")
  case "$kind" in ship|scout) ;; *) return 1 ;; esac
  project=$(meta_get "$task" project)
  [ -n "$project" ] && [ -d "$project" ] || return 1
  [ "$(repo_identity "$project" || true)" = "$FM_ROOT_REPO" ]
}

# Structured facts about a status line, carrying none of its free text.
status_facts() {  # <status-line>
  local line=$1 verb yes_url=no yes_file=no yes_key=no len
  status_line_verb "$line" verb
  case "$verb" in ''|*[!a-z-]*) verb=other ;; esac
  [ "${#verb}" -le 20 ] || verb=other
  case "$line" in *https://*|*http://*) yes_url=yes ;; esac
  case "$line" in *file=*) yes_file=yes ;; esac
  case "$line" in *'[key='*|*corr=*) yes_key=yes ;; esac
  len=${#line}
  if [ "$len" -le 80 ]; then len=short; elif [ "$len" -le 240 ]; then len=medium; else len=long; fi
  printf 'verb=%s has_url=%s has_file_ref=%s has_key_or_corr=%s length=%s' \
    "$verb" "$yes_url" "$yes_file" "$yes_key" "$len"
}

# Every presented status line of <task>, oldest first: the drain's annotations
# (chronological per task), then any unread-surface or backstop line they did
# not already carry.
task_lines() {  # <task>
  awk -F '\t' -v t="$1" '
    function emit(l) { if (!(l in seen)) { seen[l] = 1; print l } }
    $1 == "ANN" && $2 == t { l = $0; sub(/^ANN\t[^\t]*\t/, "", l); emit(l); next }
    $1 == "SEC" && ($2 == "unread" || $2 == "backstop") && index($3, t " ") == 1 {
      l = $0; sub(/^SEC\t[^\t]*\t/, "", l); emit(substr(l, length(t) + 2))
    }
  ' "$PARSED"
}

# The newest of <task>'s presented lines whose verb is one of <verbs>.
task_last_line() {  # <task> <space-separated-verbs>
  local line verb last=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    status_line_verb "$line" verb
    case " $2 " in *" $verb "*) last=$line ;; esac
  done <<EOF
$(task_lines "$1")
EOF
  printf '%s' "$last"
}

# Classify one status line by its declared verb. Returns 0 when it produced an
# act-now item, 1 when routine, 2 when it was handed to the ambiguous set, and 3
# when the OPEN DECISIONS presentation owns it.
# A batch can carry a task's whole unread history, so only its newest done: or
# failed: line is act-now, and a needs-decision: or blocked: line defers to the
# drain's OPEN DECISIONS fold, which owns whether it is still open.
classify_status_line() {  # <task> <status-line> <origin>
  local task=$1 line=$2 origin=$3 verb url file kind
  if grep -qxF "$task$TAB$line" "$SEEN_LINES"; then
    return 1
  fi
  printf '%s\t%s\n' "$task" "$line" >> "$SEEN_LINES"
  status_line_verb "$line" verb
  url=$(first_url "$line")
  kind=$(task_kind "$task")
  case "$verb" in
    needs-decision|blocked)
      if decision_listed "$task" "$line"; then
        # The OPEN DECISIONS path presents it; nothing to add here.
        return 3
      fi
      if [ "$line" != "$(task_last_line "$task" "needs-decision blocked done failed working paused resolved captain-held note")" ]; then
        routine "$task" "earlier $verb line, since resolved or superseded"
        return 1
      fi
      ;;
    done|failed)
      if [ "$line" != "$(task_last_line "$task" "done failed")" ]; then
        routine "$task" "earlier $verb line, superseded by a later one"
        return 1
      fi
      ;;
  esac
  case "$verb" in
    needs-decision)
      file=$(findings_file "$line")
      act "$task" "needs a decision: $(status_line_note "$line")" \
        "decide or escalate (load ask-user-authority for review findings), then answer with bin/fm-send.sh $task --resolve-key <key>" \
        "${file:+findings: $file}"
      return 0 ;;
    blocked)
      act "$task" "blocked: $(status_line_note "$line")" "unblock or escalate, answering with bin/fm-send.sh $task --resolve-key <key>"
      return 0 ;;
    failed)
      act "$task" "failed: $(status_line_note "$line")" "inspect bin/fm-crew-state.sh $task and recover or report the failure"
      return 0 ;;
    done)
      if [ -n "$url" ]; then
        act "$task" "reports done with a PR" "run bin/fm-pr-check.sh $task $url, then give the captain the PR URL and outcome" "pr: $url"
        return 0
      fi
      if [ "$kind" = secondmate ]; then
        printf '%s\t%s\t%s\n' "$task" "${kind:-unknown}" "$line" >> "$AMBIG"
        return 2
      fi
      if [ "$kind" = scout ]; then
        act "$task" "scout reports done: $(status_line_note "$line")" "read data/$task/report.md and relay the findings"
      elif [ "$verb" = 'done' ] && crew_state "$task" | grep -q '^state: working · source: run-step'; then
        # Validation is already running on this work, so the line was handled.
        routine "$task" "done line already followed by a running validation"
        return 1
      else
        act "$task" "worker reports done: $(status_line_note "$line")" "verify the result and continue the selected delivery path"
      fi
      return 0 ;;
    working|paused|resolved|captain-held)
      [ "$origin" = batch ] || routine "$task" "$verb ($origin)"
      return 1 ;;
    *)
      printf '%s\t%s\t%s\n' "$task" "${kind:-unknown}" "$line" >> "$AMBIG"
      return 2 ;;
  esac
}

# crew_word, except that a secondmate whose remote endpoint reports alive reads
# as idle: crew-state names that endpoint healthy while its word stays unknown.
state_word() {  # <task>
  if [ "$(task_kind "$1")" = secondmate ]; then
    case "$(crew_state "$1")" in
      'state: unknown · source: remote-endpoint · alive on '*) printf idle; return ;;
    esac
  fi
  crew_word "$1"
}

# The verdict <task>'s current state alone gives, as one record separated by
# VERDICT_SEP: routine|act, subject prefix, detail, next action, and "pane"
# when the pane's last lines belong with it.
VERDICT_SEP=$(printf '\037')
state_verdict() {  # <task>
  local task=$1 state word pr sub=''
  verdict_record() { printf '%s\n' "$1$VERDICT_SEP$sub$VERDICT_SEP${2:-}$VERDICT_SEP${3:-}$VERDICT_SEP${4:-}"; }
  state=$(crew_state "$task")
  word=$(state_word "$task")
  if [ "$(task_kind "$task")" = secondmate ]; then
    sub='secondmate '
    case "$word" in
      working|paused|parked|done|idle) verdict_record routine ;;
      failed|blocked) verdict_record act "state reads $word" "inspect and recover (${state#state: })" ;;
      *) verdict_record act "state unknown" "inspect the pane below and reconcile the secondmate (${state#state: })" pane ;;
    esac
    return
  fi
  pr=$(meta_get "$task" pr)
  case "$word" in
    working) verdict_record routine "worker busy (${state#state: })" ;;
    paused) verdict_record routine "declared external wait" ;;
    *)
      if captain_call_open "$task"; then
        verdict_record routine "held for the captain"
      elif [ "$word" = 'done' ] && [ -n "$pr" ]; then
        verdict_record routine "finished, PR $pr awaiting merge"
      elif [ "$word" = parked ] && open_decision_for "$task"; then
        verdict_record routine "parked on an already-open decision"
      else
        case "$word" in
          done) verdict_record act "worker state reads done" "verify the result and continue the selected delivery path (${state#state: })" ;;
          parked) verdict_record act "worker parked at a validation gate" "have the worker follow the gate's help or escalate its findings (${state#state: })" ;;
          failed|blocked) verdict_record act "worker state reads $word" "inspect and recover (${state#state: })" ;;
          *) verdict_record act "state unknown" "inspect the pane below; recover through stuck-crewmate-recovery if it is stuck (${state#state: })" pane ;;
        esac
      fi
      ;;
  esac
}

# The state-based verdict for a worker whose wake carried no act-now status
# line: a bare turn-end, an idle alert, or a routine-only status batch.
classify_by_state() {  # <task> <what-happened>
  local task=$1 what=$2 verdict sub detail next pane
  first_sight "$task" || return 0
  IFS="$VERDICT_SEP" read -r verdict sub detail next pane <<EOF
$(state_verdict "$task")
EOF
  what="$sub$what${detail:+; $detail}"
  if [ "$verdict" = routine ]; then
    routine "$task" "$what"
    return
  fi
  act "$task" "$what" "$next"
  [ "$pane" != pane ] || pane_tail "$task" > "$CACHE/$task.pane"
}

# 0 when a presented line already settles <task> without its current state: a
# failed:, needs-decision:, or blocked: line, or a done: line carrying a URL.
settled_by_lines() {  # <task>
  local line verb
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    status_line_verb "$line" verb
    case "$verb" in
      failed|needs-decision|blocked) return 0 ;;
      done) case "$line" in *https://*) return 0 ;; esac ;;
    esac
  done <<EOF
$(task_lines "$1")
EOF
  return 1
}

# Read the current state of every worker whose classification will consume it,
# concurrently, so a batch costs one crew-state read of wall time rather than
# their sum. A task its presented lines already settle is never waited on.
prefetch_crew_states() {
  local tag epoch seq kind key payload task n=0 max=8 seen=' '
  while IFS="$TAB" read -r tag epoch seq kind key payload; do
    [ "$tag" = ROW ] || continue
    : "$epoch" "$seq" "$payload"
    case "$kind" in
      signal)
        task=${key%.status}; task=${task%.turn-ended}
        ! settled_by_lines "$task" || continue ;;
      stale) task=$(window_to_task "$key" "$STATE") ;;
      check) case "$key" in execution:*) task=${key#execution:} ;; *) continue ;; esac ;;
      *) continue ;;
    esac
    safe_id "$task" || continue
    case "$seen" in *" $task "*) continue ;; esac
    seen="$seen$task "
    ( crew_state "$task" >/dev/null ) &
    n=$((n + 1))
    if [ "$n" -ge "$max" ]; then wait; n=0; fi
  done < "$PARSED"
  wait
}

# --- walk the presented wake rows ----------------------------------------------
ROW_COUNT=0
EXECUTION_LINES=$(awk -F '\t' '$1 == "SEC" && $2 == "execution" { sub(/^SEC\texecution\t/, ""); print }' "$PARSED")

execution_line_for() {  # <task> -> "task \t owner \t action" from the drain
  printf '%s\n' "$EXECUTION_LINES" | awk -F '\t' -v t="$1" '$1 == t { print; exit }'
}

# A task's current state is judged once per batch however many rows name it. A
# row settles the task only once it produced an act-now item or read that
# state, so a later row still judges a task an earlier stateless verdict left.
HANDLED=' '
settled() { case "$HANDLED" in *" $1 "*) return 0 ;; esac; return 1; }
first_sight() {  # <task> -> 0 the first time this batch settles <task>
  settled "$1" && return 1
  HANDLED="$HANDLED$1 "
}

handle_signal_row() {  # <key> <payload>
  local key=$1 payload=$2 task line any_act=1 had_lines=1 rc
  task=${key%.status}
  task=${task%.turn-ended}
  safe_id "$task" || { act "$key" "signal for an unrecognized record: $payload" "inspect the full drain output"; return; }
  settled "$task" && return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    had_lines=0
    rc=0
    classify_status_line "$task" "$line" batch || rc=$?
    case "$rc" in 0|3) any_act=0 ;; esac
  done <<EOF
$(task_lines "$task")
EOF
  case "$payload" in
    needs-decision:*)
      if [ "$any_act" -ne 0 ]; then
        act "$task" "the watcher flagged a decision" "read bin/fm-crew-state.sh $task and the full drain output"
      fi
      first_sight "$task" || true
      return ;;
  esac
  if [ "$any_act" -eq 0 ]; then
    first_sight "$task" || true
    return
  fi
  rc=0
  awk -F '\t' -v t="$task" '$1 == t { found = 1 } END { exit !found }' "$AMBIG" && rc=1
  if [ "$rc" -eq 0 ]; then
    if [ "$had_lines" -eq 0 ]; then
      classify_by_state "$task" "status update"
    else
      classify_by_state "$task" "turn ended"
    fi
  fi
}

handle_stale_row() {  # <key> <payload>
  local win=$1 payload=$2 task
  local word pr
  task=$(window_to_task "$win" "$STATE")
  safe_id "$task" || task=$win
  # An alarm that names its own reason is judged even when a signal earlier in
  # this batch already summarized the task; only plain idle rechecks dedupe.
  case "$payload" in
    *"possible wedge"*|*demand-deep-inspection*)
      first_sight "$task" || true
      # Reconcile the current state first: a finished worker with a recorded
      # PR, or one parked on a decision already listed, is waiting on someone
      # else, not wedged.
      word=$(crew_word "$task")
      pr=$(meta_get "$task" pr)
      if [ "$word" = 'done' ] && [ -n "$pr" ]; then
        routine "$task" "possible-wedge alert; finished, PR $pr awaiting merge"
      elif [ "$word" = parked ] && open_decision_for "$task"; then
        routine "$task" "possible-wedge alert; parked on an already-open decision"
      else
        act "$task" "idle alert: ${payload#stale: }" "inspect the pane below and load stuck-crewmate-recovery ($(crew_state "$task"))"
        pane_tail "$task" > "$CACHE/$task.pane"
      fi ;;
    *"unread firstmate instruction"*|*"ladder bookkeeping unwritable"*)
      first_sight "$task" || true
      act "$task" "idle alert: ${payload#stale: }" "inspect the worker's inbox and pane; recover the worker" ;;
    *"agent dead"*|*"agent missing"*)
      first_sight "$task" || true
      act "$task" "idle alert: the worker's agent is gone" "reconcile the record and check for unlanded work before any cleanup" ;;
    *)
      settled "$task" && return 0
      handle_plain_stale "$task" "$payload" ;;
  esac
}

handle_plain_stale() {  # <task> <payload>
  local task=$1 payload=$2
  case "$payload" in
    *"captain-held, awaiting the captain"*)
      routine "$task" "idle while held for the captain" ;;
    *"writing its worktree"*)
      routine "$task" "idle pane but still writing its worktree" ;;
    *"declared wait"*|*"awaiting external"*)
      classify_by_state "$task" "declared-wait recheck" ;;
    *)
      classify_by_state "$task" "idle alert" ;;
  esac
}

handle_check_row() {  # <key> <payload>
  local key=$1 payload=$2 task line owner action word
  case "$key" in
    execution:*)
      task=${key#execution:}
      line=$(execution_line_for "$task")
      owner=$(printf '%s' "$line" | cut -f2)
      action=$(printf '%s' "$line" | cut -f3)
      word=$(crew_word "$task")
      if [ -z "$line" ]; then
        routine "$task" "execution reminder; obligation no longer listed"
      elif [ "$owner" != firstmate ]; then
        routine "$task" "execution reminder; owner is $owner ($action)"
      elif [ "$action" = verify-progress-not-launch-seed ] && [ "$word" = working ]; then
        routine "$task" "execution reminder; worker busy ($action)"
      elif [ "$action" = verify-idle-or-failed-owner-and-recover-or-escalate ] \
        && crew_state "$task" | grep -q '^state: working · source: run-step'; then
        routine "$task" "execution reminder; run validating ($action)"
      elif [ "$action" = verify-landing-with-configured-approval-authority ] && [ -n "$(meta_get "$task" pr)" ]; then
        routine "$task" "execution reminder; PR $(meta_get "$task" pr) awaits merge authority"
      else
        act "$task" "execution obligation: $action" "reconcile the evidence and take that action ($(crew_state "$task"))"
      fi
      return ;;
    inbox:*)
      act "${key#inbox:}" "$payload" "read bin/fm-inbox.sh drain, handle the note, then acknowledge it with --ack ${key#inbox:}" ;;
    procevent:*)
      task=${key#procevent:}
      act "${task%%:*}" "$payload" "load process-event-sources and read the durable result (board answers go through bin/fm-captain-hold.sh answers)" ;;
    execution-unavailable)
      act firstmate "$payload" "run bin/fm-task-execution.sh scan and repair the backlog read" ;;
    *)
      case "$payload" in
        *x-mention*|*x-mode-error*|*public-followup*)
          act "$key" "$payload" "load fmx-respond" ;;
        *startup-network*)
          act "$key" "$payload" "read bin/fm-startup-network.sh report" ;;
        *merged*|*MERGED*)
          act "$key" "$payload" "refresh the clone through bin/fm-fleet-sync.sh, then clean up the landed task" ;;
        *)
          act "$key" "$payload" "handle the named check result" ;;
      esac ;;
  esac
}

prefetch_crew_states
while IFS="$TAB" read -r tag epoch seq kind key payload; do
  [ "$tag" = ROW ] || continue
  : "$epoch" "$seq"
  ROW_COUNT=$((ROW_COUNT + 1))
  case "$kind" in
    signal) handle_signal_row "$key" "$payload" ;;
    stale) handle_stale_row "$key" "$payload" ;;
    check) handle_check_row "$key" "$payload" ;;
    heartbeat) act fleet "heartbeat: $payload" "review bin/fm-fleet-snapshot.sh and reconcile suspicious tasks" ;;
    *) act "$key" "$kind wake: $payload" "handle it per the supervision contract" ;;
  esac
done < "$PARSED"

# --- presentation sections ---------------------------------------------------------
while IFS="$TAB" read -r tag section line; do
  [ "$tag" = SEC ] || continue
  case "$section" in
    unread)
      classify_status_line "${line%% *}" "${line#* }" "unread status" || true ;;
    divergence)
      act "${line%% *}" "record divergence: $line" "load captain-hold-lifecycle and reconcile the two records" ;;
    backstop)
      # A recovered captain-facing status line: judged like any other line.
      classify_status_line "${line%% *}" "${line#* }" "recovered status" || true ;;
    decisions-omitted)
      act fleet "$line" "read the full drain output" ;;
  esac
done < "$PARSED"

# Status lines carried by annotations that no row consumed (a historical row).
while IFS="$TAB" read -r tag task line; do
  [ "$tag" = ANN ] || continue
  classify_status_line "$task" "$line" "status" || true
done < "$PARSED"

while IFS="$TAB" read -r tag line; do
  [ "$tag" = NOTE ] || continue
  act drain "notice: $line" "read the full drain output"
done < "$PARSED"
if [ -s "$WORK/notices" ]; then
  notice_more=$(( $(awk 'END { print NR }' "$WORK/notices") - 1 ))
  notice_what="drain notice: $(head -n 1 "$WORK/notices")"
  [ "$notice_more" -eq 0 ] || notice_what="$notice_what (+$notice_more more line(s))"
  act drain "$notice_what" "read the full drain output and follow the notice"
fi

# OPEN DECISIONS: act-now only when the set changed since the previous triage.
DECISIONS=$(awk -F '\t' '$1 == "SEC" && $2 == "decisions" { print $3 }' "$PARSED" | LC_ALL=C sort)
DECISIONS_CHANGED=false
if [ -n "$DECISIONS" ]; then
  if [ "$DECISIONS" != "$(cat "$DECISIONS_SEEN" 2>/dev/null || true)" ]; then
    DECISIONS_CHANGED=true
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      grep -qxF "$line" "$DECISIONS_SEEN" 2>/dev/null && continue
      # The same decision already arrived as this batch's needs-decision line.
      awk -F '\t' -v t="${line%% *}" '$1 == t && index($2, "needs a decision") == 1 { found = 1 }
        END { exit !found }' "$ACT" && continue
      key=$(printf '%s' "$line" | sed -n 's/^[^ ]* \[key=\([^]]*\)\].*/\1/p')
      act "${line%% *}" "open decision: ${line#* }" "decide or escalate (load ask-user-authority for review findings), then answer with bin/fm-send.sh ${line%% *} --resolve-key ${key:-<key>} '<answer>'" \
        "$(f=$(findings_file "$line"); printf '%s' "${f:+findings: $f}")"
    done <<EOF
$DECISIONS
EOF
  fi
fi

# A task whose status line waits on Jev is still judged against its current
# state: one its state alone calls act-now acts whatever Jev answers.
while IFS= read -r task; do
  safe_id "$task" || continue
  settled "$task" && continue
  [ "$(state_verdict "$task" | cut -d "$VERDICT_SEP" -f1)" = act ] \
    && classify_by_state "$task" "ambiguous status"
done <<EOF
$(cut -f1 "$AMBIG" | awk '!seen[$0]++')
EOF

# --- Jev for the leftover ambiguous lines ------------------------------------------
JEV_STATUS=off
jev_key_present() {
  [ -n "${TYPESAFE_API_KEY:-}" ] || [ -n "${OPENROUTER_API_KEY:-}" ] \
    || [ -n "$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")" ] \
    || [ -n "$(fmx_env_get OPENROUTER_API_KEY "$FM_HOME/.env")" ]
}

jev_resolve_ambiguous() {
  local n state='' questions='{}' i=0 task kind line clean response choice conf verdicts='[]' rc=0 timeout
  local text_lines=0
  n=$(awk 'END { print NR }' "$AMBIG")
  [ "$n" -gt 0 ] || return 0
  : > "$WORK/jev"
  if ! jev_key_present || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  while IFS="$TAB" read -r task kind line; do
    i=$((i + 1))
    if jev_text_allowed "$task"; then
      clean=$(fm_jev_compact_state "$line" 2>/dev/null) || clean=''
      state="${state}i$i: worker_kind=$kind status=$(cap "$clean")
"
      text_lines=$((text_lines + 1))
    else
      state="${state}i$i: worker_kind=$kind facts: $(status_facts "$line")
"
    fi
    questions=$(jq -c --arg q "i$i" '. + {($q): {type: "choice",
      instructions: ("Does status line " + $q + " need the supervisor to act now, or is it routine progress?"),
      criteria: {act_now: "Reports a finished deliverable, a PR, a decision, a blocker, a failure, a question, an answer, or anything a supervisor or the captain must act on.",
                 routine: "Routine progress, an acknowledgement, or bookkeeping that needs no action."}}}' <<<"$questions") || return 0
  done < "$AMBIG"
  state="Status lines from firstmate workers. Classify each independently.
$state"
  # A timeout configured in the environment or $FM_HOME/.env wins; the triage
  # bound applies only when none is.
  timeout=${JEV_TIMEOUT:-$(fmx_env_get JEV_TIMEOUT "$FM_HOME/.env")}
  [ -n "$timeout" ] || timeout=$TRIAGE_JEV_TIMEOUT
  # A file, not a command substitution, so FM_JEV_LAST_* survive for the log.
  JEV_TIMEOUT=$timeout fm_jev_decide "$state" "$questions" > "$WORK/jev-response" 2>/dev/null || rc=$?
  response=$(cat "$WORK/jev-response" 2>/dev/null || true)
  if [ "$rc" -eq 0 ]; then JEV_STATUS=answered; else JEV_STATUS=unavailable; fi
  i=0
  while IFS="$TAB" read -r task kind line; do
    i=$((i + 1))
    choice=''
    conf=''
    if [ "$rc" -eq 0 ]; then
      choice=$(jq -r --arg q "i$i" '.answers[$q].choice // empty' <<<"$response" 2>/dev/null)
      conf=$(jq -r --arg q "i$i" '.answers[$q].confidence // empty' <<<"$response" 2>/dev/null)
    fi
    if [ "$choice" = routine ] && fm_jev_choice_confidence_ok "$conf"; then
      printf '%s\troutine\n' "$i" >> "$WORK/jev"
      verdicts=$(jq -c '. + ["routine"]' <<<"$verdicts")
    else
      printf '%s\tact\n' "$i" >> "$WORK/jev"
      verdicts=$(jq -c --arg v "${choice:-none}" '. + [$v]' <<<"$verdicts")
    fi
  done < "$AMBIG"
  fm_jev_log_call "$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson n "$n" \
    --argjson rc "$rc" --argjson verdicts "$verdicts" --argjson text "$text_lines" --arg route "${FM_JEV_LAST_ROUTE:-}" \
    --arg http "${FM_JEV_LAST_HTTP:-}" --arg latency "${FM_JEV_LAST_LATENCY_MS:-}" \
    '{purpose: "wake-triage", ts: $ts, lines: $n, text_lines: $text, decide_code: $rc, verdicts: $verdicts,
      route: $route, http: $http, latency_ms: $latency}')" "$JEV_LOG" 2>/dev/null || true
}

jev_resolve_ambiguous
i=0
while IFS="$TAB" read -r task kind line; do
  i=$((i + 1))
  verdict=$(awk -F '\t' -v n="$i" '$1 == n { print $2 }' "$WORK/jev" 2>/dev/null)
  if [ "$verdict" = routine ]; then
    routine "$task" "status line judged routine by Jev"
  else
    case "$JEV_STATUS" in
      answered) reason='Jev did not confidently call it routine' ;;
      unavailable) reason='Jev unavailable' ;;
      *) reason='Jev off' ;;
    esac
    act "$task" "unclassified status: $line" "read it and decide ($reason)" "$(u=$(first_url "$line"); printf '%s' "${u:+pr: $u}")"
  fi
done < "$AMBIG"

# --- report ------------------------------------------------------------------------
ACT_COUNT=$(awk 'END { print NR }' "$ACT")
ROUTINE_COUNT=$(awk 'END { print NR }' "$ROUTINE")

printf 'WAKE TRIAGE: %s wake row(s); %s act-now, %s routine\n' "$ROW_COUNT" "$ACT_COUNT" "$ROUTINE_COUNT"
if [ "$ACT_COUNT" -gt 0 ]; then
  printf 'ACT NOW:\n'
  while IFS="$TAB" read -r task what next extra; do
    printf -- '- %s | %s | next: %s' "$task" "$what" "$next"
    [ -z "$extra" ] || printf ' | %s' "$extra"
    printf '\n'
    if [ -s "$CACHE/$task.pane" ]; then
      cat "$CACHE/$task.pane"
      rm -f -- "$CACHE/$task.pane"
    fi
  done < "$ACT"
fi
if [ "$ROUTINE_COUNT" -gt 0 ]; then
  printf 'ROUTINE: %s\n' "$(awk -F '\t' '
    { k = $1 "\t" $2; if (!(k in n)) order[++c] = k; n[k]++ }
    END {
      for (i = 1; i <= c; i++) {
        split(order[i], f, "\t")
        printf "%s%s (%s)%s", (i > 1 ? "; " : ""), f[1], f[2], (n[order[i]] > 1 ? " x" n[order[i]] : "")
      }
    }' "$ROUTINE")"
fi
if [ -n "$DECISIONS" ] && [ "$DECISIONS_CHANGED" = false ]; then
  printf 'OPEN DECISIONS unchanged since the last triage (%s): %s\n' \
    "$(printf '%s\n' "$DECISIONS" | awk 'END { print NR }')" \
    "$(printf '%s\n' "$DECISIONS" | awk '{ printf "%s%s", (NR > 1 ? "; " : ""), substr($0, 1, 80) }')"
fi
if [ -n "$EXECUTION_LINES" ]; then
  printf 'OBLIGATIONS: %s\n' "$(printf '%s\n' "$EXECUTION_LINES" | awk -F '\t' '{ printf "%s%s %s %s", (NR > 1 ? "; " : ""), $1, $2, $3 }')"
fi
awk -F '\t' '$1 == "ADV" { print "ADVISORY: " $2 }' "$PARSED"
awk -F '\t' '$1 == "SEC" && $2 == "branch-held" { print $3 }' "$PARSED"
printf 'FULL DRAIN OUTPUT: %s\n' "$LAST_OUT"

# Only now that the report is out is the open-decision set recorded as seen, so
# an interrupted run re-presents a changed set rather than calling it unchanged.
if [ -n "$DECISIONS" ]; then
  (umask 077; printf '%s\n' "$DECISIONS" > "$DECISIONS_SEEN") 2>/dev/null || true
else
  rm -f -- "$DECISIONS_SEEN" 2>/dev/null || true
fi

if [ -z "$ACK_LINE" ]; then
  exit 0
fi
if [ "$AUTO_ACK" = true ] && [ "$ACT_COUNT" -eq 0 ] && [ -n "$ACK_SEQ" ] && [ -n "$ACK_GEN" ]; then
  if ack_out=$("$DRAIN_BIN" --ack-through "$ACK_SEQ" --recovery-generation "$ACK_GEN" 2>&1); then
    printf 'WAKE_ACKED: every item was routine; acknowledged through %s\n' "$ACK_SEQ"
    [ -z "$ack_out" ] || printf '%s\n' "$ack_out"
    exit 0
  fi
  printf 'WAKE TRIAGE: auto-acknowledgement failed: %s\n' "$(cap "$ack_out")"
fi
if [ "$AUTO_ACK" = true ] && [ "$ACT_COUNT" -gt 0 ]; then
  printf 'WAKE TRIAGE: not auto-acknowledged - %s act-now item(s) need handling first.\n' "$ACT_COUNT"
fi
printf '%s\n' "$ACK_LINE"
exit 0
