#!/usr/bin/env bash
# Drain durable wakes and auto-acknowledge only rows whose task is verifiably
# working, has no open decision, and is not held for the captain.
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

usage() { sed -n '1,3p' "$0"; }
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) echo "usage: fm-wake-triage.sh [-h|--help]" >&2; exit 2 ;;
esac

ACTOR=$(fm_lease_actor) || exit 2
[ "$ACTOR" = main ] || exec "$SCRIPT_DIR/fm-wake-drain.sh"
mkdir -p "$STATE" || exit 1
shopt -s nullglob
recovered=("$STATE"/.wake-triage.pending.*)
recovered_count=${#recovered[@]}
for f in "${recovered[@]}"; do [ -f "$f" ] && [ ! -L "$f" ] || { echo "wake triage: unsafe recovered output" >&2; exit 1; }; done

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
ack_required_count=$(grep -c '^WAKE_ACK_REQUIRED:' "$out" || true)
cutoff=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$out" | tail -1)
generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\).*$/\1/p' "$out" | tail -1)

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
# explicitly eligible wake shapes remains ACT NOW.
ids="$work/ids"
awk -F '\t' '
function routine_shape(kind,key,payload,id) {
  if (kind == "signal" && key == id ".status" && payload ~ /^signal:/ && payload !~ /^needs-decision:/) return 1
  if (kind == "stale" && payload == "stale: " key) return 1
  if (kind == "check" && key == "execution:" id && payload == "check: execution " id) return 1
  return 0
}
NF < 5 { print "!"; next }
{ kind=$3; key=$4; payload=$5; for (i=6;i<=NF;i++) payload=payload FS $i; id="";
  if (kind=="signal" && key ~ /\.status$/) { id=key; sub(/\.status$/, "", id) }
  else if (kind=="check" && key ~ /^execution:[A-Za-z0-9._-]+$/) { id=substr(key,11) }
  else if (kind=="stale" && payload == "stale: " key) { print "?" key; next }
  if (id != "") { if (routine_shape(kind,key,payload,id)) print id; else print "!" id; next }
  print "!"
}' "$rows" | LC_ALL=C sort -u > "$ids"

# Resolve stale handles only by exact meta-field matches. Metadata must identify
# one ship/scout task; remote and secondmate records are never candidates.
meta_for_stale() {
  local key=$1 f value match='' count=0
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    value=$(awk -F= -v k="$key" '$1=="window" || $1=="terminal" { if ($2==k) found=1 } END { if (found) print "yes" }' "$f" 2>/dev/null)
    [ "$value" = yes ] || continue
    match=${f##*/}; match=${match%.meta}; count=$((count+1))
  done
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$match"
}

act_file="$work/act"
routine_file="$work/routine"
: > "$act_file"; : > "$routine_file"
all_routine=1
task_count=0
while IFS= read -r tagged; do
  [ -n "$tagged" ] || continue
  id=$tagged
  reason='C2 identity is not exact'
  case "$tagged" in
    '!'*) id=${tagged#!}; reason='C1 row shape is not eligible' ;;
    '?'*) key=${tagged#?}; id=$(meta_for_stale "$key" 2>/dev/null || true); reason='C2 stale identity is not exact' ;;
  esac
  [ -n "$id" ] || { printf '%s\t%s\n' '-' "$reason" >> "$act_file"; all_routine=0; continue; }
  case "$id" in *[!A-Za-z0-9._-]*|'') printf '%s\t%s\n' '-' 'C2 invalid task identity' >> "$act_file"; all_routine=0; continue ;; esac
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ -r "$meta" ] && [ ! -L "$meta" ] || { printf '%s\t%s\n' "$id" 'C2 metadata missing or unreadable' >> "$act_file"; all_routine=0; continue; }
  kind=$(awk -F= '$1=="kind" {print $2; exit}' "$meta")
  [ "$kind" = ship ] || [ "$kind" = scout ] || { printf '%s\t%s\n' "$id" 'C2 task kind is not ship/scout' >> "$act_file"; all_routine=0; continue; }
  task_count=$((task_count+1))
  if [ "$LOCK_FAILED" -eq 1 ]; then reason='queue lock unavailable';
  elif [ -s "$STATE/$id.status" ] && [ -n "$(status_open_decisions "$STATE/$id.status" "$kind")" ]; then reason='C4 open decision';
  else
    current=$(status_current_line "$STATE/$id.status" "$kind" 2>/dev/null || true)
    if [ ! -f "$STATE/$id.status" ] || [ ! -r "$STATE/$id.status" ] || [ -L "$STATE/$id.status" ] || [ -z "$current" ]; then reason='C7 latest task status missing';
    elif status_is_paused_or_captain_held "$current"; then reason='C5 paused/captain-held status';
    elif status_is_captain_relevant "$current"; then reason='C7 latest status is captain-relevant';
    elif [ "$(grep -Ec "^${id}[[:space:]].*(done:|needs-decision:|blocked:|failed:|note:)" "$out" || true)" -gt 0 ]; then reason='C7 task has terminal or unread status';
    elif [ "$(grep -F "wake annotation:" "$out" | grep -F "$id.status: " | awk '!/: working:/ { count++ } END { print count + 0 }')" -gt 0 ]; then reason='C7 presented status event is not working';
    elif awk -F '\t' -v id="$id" '$3 == "signal" && $4 == id ".status" { found=1 } END { exit !found }' "$rows" \
      && ! grep -F "wake annotation:" "$out" | grep -F "$id.status: working:" >/dev/null; then reason='C7 signal has no current working annotation';
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
    all_routine=0
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
    all_routine=0
  fi
  if [ "$recovered_count" -gt 0 ]; then
    printf 'RECOVERED DRAIN OUTPUT (an earlier triage was interrupted; act on all of it):\n'
    for f in "${recovered[@]}"; do cat "$f"; done
    all_routine=0
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
cat "$rendered" || exit 1
mv -f -- "$pending" "$STATE/.wake-triage.last" || { echo 'wake triage: could not commit drain output' >&2; exit 1; }
out="$STATE/.wake-triage.last"
for f in "${recovered[@]}"; do rm -f -- "$f" || exit 1; done

if [ "$DRAIN_CODE" -ne 0 ]; then exit "$DRAIN_CODE"; fi
if [ "$all_routine" -eq 1 ] && [ -s "$rows" ] && [ "$recovered_count" -eq 0 ] \
  && [ -z "$(grep -E '^(WAKE ROWS HELD|STATUS PRESENTATION (SKIPPED|INCOMPLETE)|WAKE DRAIN SKIPPED|UNREAD STATUS|OPEN DECISIONS|STATUS OUTCOME BACKSTOP|RECORD DIVERGENCE|UNFINISHED EXECUTION: reconciliation unavailable|wake drain:|watcher:|firstmate watcher|WARNING:|●)' "$out" | grep -Ev '^WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else[.]' || true)" ] \
  && [ "$ack_required_count" -eq 1 ] \
  && [ -n "$cutoff" ] && [ "$cutoff" -gt 0 ] && [ -n "$generation" ] \
  && [ ! -e "$STATE/.afk" ]; then
  ack=$("$SCRIPT_DIR/fm-wake-drain.sh" --ack-through "$cutoff" --recovery-generation "$generation" 2>&1) || { printf '%s\n' "$ack"; exit 1; }
  printf 'WAKE_ACKED: every row was routine; acknowledged through %s\n' "$cutoff"
  printf '%s\n' "$ack"
else
  sed -n '/^WAKE_ACK_REQUIRED:/p' "$STATE/.wake-triage.last" | tail -1
fi
exit 0
