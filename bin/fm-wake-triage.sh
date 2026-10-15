#!/usr/bin/env bash
# Drain durable wakes and classify rows as routine only when the task is
# verifiably working, has no open decision, and is not held for the captain.
#
# Usage: fm-wake-triage.sh [--absorb]
#
# Without --absorb, acknowledgement stays manual: the output ends with the
# drain's WAKE_ACK_REQUIRED command for the handling turn to run.
# --absorb is the Claude Stop hook's mode (bin/fm-claude-stop-autoarm.sh), and
# acknowledges for it:
#   - exit 0, the wake is absorbed: every row is routine and the drain presented
#     nothing else that needs firstmate, so triage acknowledges the whole batch
#     and prints one WAKE_ACKED line after the presentation;
#   - exit 10, the wake needs firstmate: triage acknowledges only the routine
#     rows (fm-wake-drain.sh --ack-rows) while other rows remain queued, and
#     ends the presentation with the WAKE_ACK_REQUIRED command for the rest;
#   - any other status is a failure that leaves the wake to the handling turn.
# While state/.afk exists the away daemon owns triage, so --absorb acknowledges
# nothing.
# "Nothing else" is a whitelist, absorbable_drain_output below, so a drain line
# it does not recognize always keeps the wake: queue rows, working status
# annotations of routine tasks, the acknowledgement line, the queued-wakes
# warning, the persistent OPEN DECISIONS list (never one naming new or changed
# decisions), and the persistent UNFINISHED EXECUTION obligations, whose owners
# get their own queued wake whenever their evidence changes.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-lease-lib.sh"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
ABSORB=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --absorb) [ "$#" -eq 1 ] || { echo "usage: fm-wake-triage.sh [--absorb]" >&2; exit 2; }; ABSORB=1 ;;
  '') ;;
  *) echo "usage: fm-wake-triage.sh [--absorb]" >&2; exit 2 ;;
esac

# The leading verb of a status event as bin/fm-classify-lib.sh's
# status_line_verb reads it: the text before the first colon, cut at the first
# "[" (the [at=...] and [key=...] stamps), with correlation tokens dropped.
EVENT_VERB_AWK='
function event_verb(s,    w, n, i, out) {
  sub(/:.*/, "", s); sub(/\[.*/, "", s)
  n = split(s, w, /[ \t]+/); out = ""
  for (i = 1; i <= n; i++) {
    if (w[i] == "") continue
    if (out != "" && length(w[i]) == 21 && w[i] ~ /^corr=[0-9A-Fa-f]+$/) continue
    out = (out == "" ? w[i] : out " " w[i])
  }
  return out
}'

ACTOR=$(fm_lease_actor) || exit 2
[ "$ACTOR" = main ] || exec "$SCRIPT_DIR/fm-wake-drain.sh"
mkdir -p "$STATE" || exit 1
shopt -s nullglob
recovered=("$STATE"/.wake-triage.pending.*)
recovered_count=${#recovered[@]}
# Under `set -u`, bash 3.2 (the stock macOS /bin/bash) treats "${recovered[@]}" on an empty array as an unbound-variable error.
# Every expansion of `recovered` in this script therefore uses the ${recovered[@]+...} guard.
for f in ${recovered[@]+"${recovered[@]}"}; do
  [ -f "$f" ] && [ ! -L "$f" ] || { echo "wake triage: unsafe recovered output" >&2; exit 1; }
done

pending="$STATE/.wake-triage.pending.$(date +%s).$$"
[ ! -e "$pending" ] && [ ! -L "$pending" ] || { echo "wake triage: pending output collision" >&2; exit 1; }
"$SCRIPT_DIR/fm-wake-drain.sh" >"$pending" 2>&1
DRAIN_CODE=$?
chmod 0600 "$pending" || { cat "$pending"; exit 1; }

work=$(mktemp -d "$STATE/.wake-triage.work.XXXXXX") || { cat "$pending"; exit 1; }
chmod 0700 "$work" || { cat "$pending"; rm -rf "$work"; exit 1; }
trap 'rm -rf "$work"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
out="$pending"
cutoff=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$out" | tail -1)
# Capture all rows hidden by the drain's presentation dedupe, under its queue lock.
rows="$work/rows"
if [ -n "$cutoff" ] && fm_lock_acquire_wait_bounded "$FM_WAKE_QUEUE_LOCK" 5; then
  if [ -r "$FM_WAKE_QUEUE" ]; then
    awk -F '\t' -v n="$cutoff" '$2 ~ /^[0-9]+$/ && $2 <= n { print }' "$FM_WAKE_QUEUE" > "$rows"
  else
    : > "$rows"
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
else
  : > "$rows"
  LOCK_FAILED=1
fi
LOCK_FAILED=${LOCK_FAILED:-0}

# Each row is classified by task; anything malformed or outside the three
# explicitly eligible wake shapes remains ACT NOW. row_tags keeps each row's
# sequence beside its tag, so --absorb can name the routine rows it retires.
ids="$work/ids"
row_tags="$work/row-tags"
awk -F '\t' '
function routine_shape(kind,key,payload,id) {
  if (kind == "signal" && key == id ".status" && payload ~ /^signal:/ && payload !~ /^needs-decision:/) return 1
  if (kind == "stale" && payload == "stale: " key) return 1
  if (kind == "check" && key == "execution:" id && payload == "check: execution " id) return 1
  return 0
}
NF < 5 { print "-\t!"; next }
{ kind=$3; key=$4; payload=$5; for (i=6;i<=NF;i++) payload=payload FS $i; id=""; seq=($2 ~ /^[0-9]+$/ ? $2 : "-");
  if (kind=="signal" && key ~ /\.status$/) { id=key; sub(/\.status$/, "", id) }
  else if (kind=="check" && key ~ /^execution:[A-Za-z0-9._-]+$/) { id=substr(key,11) }
  else if (kind=="stale" && payload == "stale: " key) { print seq "\t?" key; next }
  if (id != "") { if (routine_shape(kind,key,payload,id)) print seq "\t" id; else print seq "\t!" id; next }
  print seq "\t!"
}' "$rows" > "$row_tags"
cut -f2- "$row_tags" | LC_ALL=C sort -u > "$ids"

# Resolve stale handles only by exact meta-field matches. Metadata must identify
# one ship/scout task; remote and secondmate records are never candidates.
meta_for_stale() {
  local key=$1 f value match='' count=0
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    value=$(awk -F= -v k="$key" '
      $1 == "window" { windows++; if (NF != 2 || $2 == "") invalid=1; if ($2 == k) found=1 }
      $1 == "terminal" { terminals++; if (NF != 2 || $2 == "") invalid=1; if ($2 == k) found=1 }
      END { if (!invalid && windows <= 1 && terminals <= 1 && found) print "yes" }
    ' "$f" 2>/dev/null)
    [ "$value" = yes ] || continue
    match=${f##*/}; match=${match%.meta}; count=$((count+1))
  done
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$match"
}

act_file="$work/act"
routine_file="$work/routine"
: > "$act_file"; : > "$routine_file"
task_count=0
while IFS= read -r tagged; do
  [ -n "$tagged" ] || continue
  id=$tagged
  reason='C2 identity is not exact'
  shape_ineligible=0
  case "$tagged" in
    '!'*) id=${tagged#!}; reason='C1 row shape is not eligible'; shape_ineligible=1 ;;
    '?'*) key=${tagged#?}; id=$(meta_for_stale "$key" 2>/dev/null || true); reason='C2 stale identity is not exact' ;;
  esac
  [ -n "$id" ] || { printf '%s\t%s\n' '-' "$reason" >> "$act_file"; continue; }
  case "$id" in *[!A-Za-z0-9._-]*|'') printf '%s\t%s\n' '-' 'C2 invalid task identity' >> "$act_file"; continue ;; esac
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ -r "$meta" ] && [ ! -L "$meta" ] || { printf '%s\t%s\n' "$id" 'C2 metadata missing or unreadable' >> "$act_file"; continue; }
  kind=$(awk -F= '$1 == "kind" { count++; if (NF != 2 || $2 == "") invalid=1; value=$2 } END { if (count == 1 && !invalid) print value }' "$meta")
  [ "$kind" = ship ] || [ "$kind" = scout ] || { printf '%s\t%s\n' "$id" 'C2 task kind is not ship/scout' >> "$act_file"; continue; }
  task_count=$((task_count+1))
  # An ineligible row shape stays ACT NOW whatever its task's state.
  if [ "$shape_ineligible" -eq 1 ]; then reason='C1 row shape is not eligible';
  elif [ "$LOCK_FAILED" -eq 1 ]; then reason='queue lock unavailable';
  elif [ -s "$STATE/$id.status" ] && [ -n "$(status_open_decisions "$STATE/$id.status" "$kind")" ]; then reason='C4 open decision';
  else
    current=$(status_current_line "$STATE/$id.status" "$kind" 2>/dev/null || true)
    if [ ! -f "$STATE/$id.status" ] || [ ! -r "$STATE/$id.status" ] || [ -L "$STATE/$id.status" ] || [ -z "$current" ]; then reason='C7 latest task status missing';
    elif status_is_paused_or_captain_held "$current"; then reason='C5 paused/captain-held status';
    elif status_is_captain_relevant "$current"; then reason='C7 latest status is captain-relevant';
    elif [ "$(awk -F ': ' -v key="$id.status" "$EVENT_VERB_AWK"'
      $1 == "wake annotation" && $3 == key { verb=event_verb($4); if (verb == "done" || verb == "needs-decision" || verb == "blocked" || verb == "failed" || verb == "note") n++ } END { print n+0 }' "$out")" -gt 0 ]; then reason='C7 task has terminal or unread status';
    elif [ "$(awk -F ': ' -v key="$id.status" "$EVENT_VERB_AWK"'
      $1 == "wake annotation" && $3 == key { verb=event_verb($4); if (verb != "working") n++ } END { print n+0 }' "$out")" -gt 0 ]; then reason='C7 presented status event is not working';
    elif awk -F '\t' -v id="$id" '$3 == "signal" && $4 == id ".status" { found=1 } END { exit !found }' "$rows" \
      && [ "$(awk -F ': ' -v key="$id.status" "$EVENT_VERB_AWK"'
      $1 == "wake annotation" && $3 == key { verb=event_verb($4); if (verb == "working") found=1 } END { print found+0 }' "$out")" -eq 0 ]; then reason='C7 signal has no current working annotation';
    else
      owner_lines=$(awk -F '\t' -v id="$id" 'index($0,"UNFINISHED EXECUTION") { section=1; next } section && /^[A-Z][A-Z ]+ \(/ { section=0 } section && $1 == id {print}' "$out")
      owner_bad=$(printf '%s\n' "$owner_lines" | awk -F '\t' 'NF && $2 != "worker" {print; exit}')
      if [ -n "$owner_bad" ]; then reason='C8 execution belongs to firstmate';
      elif awk -F '\t' -v id="$id" '$3 == "check" && $4 == "execution:" id && $5 == "check: execution " id { found=1 } END { exit !found }' "$rows" \
        && [ -z "$owner_lines" ]; then reason='C8 execution obligation missing';
      else
        reason=''
      fi
    fi
  fi
  if [ -z "$reason" ]; then
    crew=$(FM_STATE_OVERRIDE="$STATE" "$FM_CREW_STATE_BIN" "$id" 2>/dev/null || true)
    class=$(crew_absorb_class "$id" "$crew" 1 2>/dev/null || true)
    if [ "$class" != working ]; then reason='C3 crew not working'; fi
    hold_code=0
    FM_STATE_OVERRIDE="$STATE" "${FM_CAPTAIN_HOLD_BIN:-$SCRIPT_DIR/fm-captain-hold.sh}" open "$id" --distinguish-absent >/dev/null 2>&1 || hold_code=$?
    if [ "$hold_code" -ne 1 ] && [ "$hold_code" -ne 3 ]; then reason='C6 captain hold or unavailable'; fi
  else
    crew='not read (failed earlier clause)'
  fi
  if [ -n "$reason" ]; then
    printf '%s\t%s\t%s\n' "$id" "$reason" "${crew:-not read}" >> "$act_file"
  else
    printf '%s\t%s\n' "$id" "$crew" >> "$routine_file"
  fi
done < "$ids"
task_count=$(awk -F '\t' '$1 != "-" { seen[$1]=1 } END { for (id in seen) count++; print count+0 }' "$act_file" "$routine_file")
act_count=$(awk -F '\t' '$1 != "-" { seen[$1]=1 } END { for (id in seen) count++; print count+0 }' "$act_file")
routine_count=$(awk -F '\t' '{ seen[$1]=1 } END { for (id in seen) count++; print count+0 }' "$routine_file")

# Build the complete presentation before writing to the terminal. A closed
# output pipe leaves the durable pending file in place and cannot reach ack.
rendered="$work/rendered"
{
  printf 'WAKE TRIAGE: %s row(s), %s task(s): %s act now, %s routine\n' \
    "$(awk 'END{print NR+0}' "$rows")" "$task_count" \
    "$act_count" "$routine_count"
  printf 'FULL DRAIN OUTPUT: %s/.wake-triage.last\n' "$STATE"
  if grep -q '^wake drain: retired ' "$out"; then
    printf 'ACT NOW: drain retired malformed queue rows; review the drain output above.\n'
  fi
  if [ "$recovered_count" -gt 0 ]; then
    printf 'RECOVERED DRAIN OUTPUT (an earlier triage was interrupted; act on all of it):\n'
    for f in ${recovered[@]+"${recovered[@]}"}; do cat "$f"; done
  fi
  printf 'DRAIN OUTPUT (verbatim, except acknowledgement instruction moved to the end):\n'
  sed '/^WAKE_ACK_REQUIRED:/d' "$out"
  if [ -s "$rows" ]; then
    hidden=0
    while IFS= read -r raw_row; do
      if ! grep -Fqx -- "$raw_row" "$out"; then
        if [ "$hidden" -eq 0 ]; then printf 'HIDDEN QUEUE ROWS (preserved despite drain deduplication):\n'; fi
        printf '%s\n' "$raw_row"
        hidden=1
      fi
    done < "$rows"
  fi
  if [ -s "$act_file" ]; then
    printf 'ACT NOW:\n'
    while IFS="$(printf '\t')" read -r id reason crew; do printf '%s - %s\n  crew: %s\n' "$id" "$reason" "$crew"; done < "$act_file"
  fi
  if [ -s "$routine_file" ]; then
    printf 'ROUTINE (worker verifiably working, no open decision, no hold):\n'
    while IFS="$(printf '\t')" read -r id crew; do printf '%s - crew: %s\n' "$id" "$crew"; done < "$routine_file"
  fi
} > "$rendered" || { cat "$pending"; exit 1; }
ack_line=$(sed -n '/^WAKE_ACK_REQUIRED:/p' "$out" | tail -1)

# The drain has already spent its one-shot presentations, so the pending and
# recovered output is the only copy until the presentation reaches its reader.
# Commit it only after delivery; a failed handoff leaves it for the next
# triage to replay, and a replay never absorbs.
commit_drain_output() {
  mv -f -- "$pending" "$STATE/.wake-triage.last" || { echo 'wake triage: could not commit drain output' >&2; return 1; }
  out="$STATE/.wake-triage.last"
  for f in ${recovered[@]+"${recovered[@]}"}; do rm -f -- "$f" || return 1; done
}

if [ "$ABSORB" -eq 0 ]; then
  cat "$rendered" || exit 1
  commit_drain_output || exit 1
  if [ "$DRAIN_CODE" -ne 0 ]; then exit "$DRAIN_CODE"; fi
  printf '%s\n' "$ack_line"
  exit 0
fi

# --- --absorb (header) ---------------------------------------------------------
# True when every line the drain printed is one the whitelist knows to need
# nothing from firstmate (header); any unrecognized line keeps the wake.
absorbable_drain_output() {  # <routine-ids-file>
  awk -v rows="$rows" -v ids="$1" "$EVENT_VERB_AWK"'
    BEGIN {
      while ((getline line < rows) > 0) row[line] = 1
      while ((getline line < ids) > 0) routine[line] = 1
    }
    ($0 in row) { section = ""; next }
    /^WAKE_ACK_REQUIRED: / { section = ""; next }
    /^WARNING: queued wakes pending - drain them with bin\/fm-wake-drain\.sh before anything else\.$/ { next }
    /^wake annotation: / {
      n = split($0, part, ": ")
      task = part[3]
      if (n < 4 || sub(/\.status$/, "", task) != 1 || !(task in routine)) exit 1
      if (event_verb(part[4]) != "working") exit 1
      section = ""; next
    }
    /^OPEN DECISIONS \(still open, folded from the durable status logs/ { section = "decisions"; next }
    /^OPEN DECISIONS: [0-9]+ still open, none new or changed since the last presentation/ { section = ""; next }
    section == "decisions" && /^OPEN DECISIONS: [0-9]+ more omitted \(byte cap\)$/ { next }
    section == "decisions" && /^OPEN DECISIONS: close one by answering it: / { section = ""; next }
    section == "decisions" && /^[A-Za-z0-9._-]+( \[key=[^]]*\])? (needs-decision|blocked): / { next }
    /^UNFINISHED EXECUTION \(task, accountable owner, next action/ { section = "execution"; next }
    section == "execution" && split($0, cell, "\t") == 3 && cell[1] ~ /^[A-Za-z0-9._-]+$/ { next }
    { exit 1 }
  ' "$out"
}

act_ids="$work/act-ids"
routine_ids="$work/routine-ids"
cut -f1 "$act_file" | LC_ALL=C sort -u > "$act_ids"
cut -f1 "$routine_file" | LC_ALL=C sort -u | LC_ALL=C comm -23 - "$act_ids" > "$routine_ids"
ack_generation=$(printf '%s\n' "$ack_line" | sed -n 's/.* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p')

absorbed=0
ack_out=
if [ "$DRAIN_CODE" -eq 0 ] && [ "$LOCK_FAILED" -eq 0 ] && [ "$recovered_count" -eq 0 ] \
  && [ ! -e "$STATE/.afk" ] && [ -n "$cutoff" ] && [ -n "$ack_generation" ] && [ ! -s "$act_file" ] \
  && absorbable_drain_output "$routine_ids"; then
  ack_out=$("$SCRIPT_DIR/fm-wake-drain.sh" --ack-through "$cutoff" --recovery-generation "$ack_generation" 2>&1)
  ack_code=$?
  if [ "$ack_code" -eq 0 ] && ! printf '%s\n' "$ack_out" | grep -q '^wake drain: nothing was acknowledged'; then
    absorbed=1
  fi
fi

if [ "$absorbed" -eq 1 ]; then
  # Absorbed output is all routine and already acknowledged; there is nothing
  # left to replay, so it commits whether or not the presentation arrives.
  commit_drain_output || exit 1
  cat "$rendered" || exit 0
  printf 'WAKE_ACKED: triage acknowledged every row through %s; nothing needs firstmate\n' "$cutoff"
  [ -z "$ack_out" ] || printf '%s\n' "$ack_out"
  exit 0
fi

# The wake needs firstmate. Retire its routine rows now when another row stays
# queued for the handling turn's own acknowledgement.
partial_note=
routine_seqs=$(while IFS="$(printf '\t')" read -r seq tagged; do
  case "$seq" in (''|*[!0-9]*) continue ;; esac
  case "$tagged" in
    ('!'*) continue ;;
    ('?'*) tagged=$(meta_for_stale "${tagged#?}" 2>/dev/null) || continue ;;
  esac
  grep -Fqx -- "$tagged" "$routine_ids" && printf '%s\n' "$seq"
done < "$row_tags" | LC_ALL=C sort -nu | paste -sd, -)
if [ "$DRAIN_CODE" -eq 0 ] && [ "$LOCK_FAILED" -eq 0 ] && [ ! -e "$STATE/.afk" ] && [ -n "$routine_seqs" ] && [ -n "$ack_generation" ] \
  && [ "$(printf '%s\n' "$routine_seqs" | tr ',' '\n' | awk 'END { print NR }')" -lt "$(awk 'END { print NR }' "$rows")" ]; then
  if partial_out=$("$SCRIPT_DIR/fm-wake-drain.sh" --ack-rows "$routine_seqs" --recovery-generation "$ack_generation" 2>&1); then
    partial_note="ROUTINE ROWS ACKNOWLEDGED BY TRIAGE: $routine_seqs (the WAKE_ACK_REQUIRED command below retires the rest)"
  else
    partial_note="ROUTINE ROWS NOT ACKNOWLEDGED: triage could not retire rows $routine_seqs; the WAKE_ACK_REQUIRED command below retires them with the rest"
  fi
  [ -z "$partial_out" ] || partial_note="$partial_note
$partial_out"
fi
cat "$rendered" || exit 1
[ -z "$partial_note" ] || printf '%s\n' "$partial_note" || exit 1
[ -z "$ack_line" ] || printf '%s\n' "$ack_line" || exit 1
commit_drain_output || exit 1
if [ "$DRAIN_CODE" -ne 0 ]; then
  [ "$DRAIN_CODE" -ne 10 ] || exit 1
  exit "$DRAIN_CODE"
fi
exit 10
