#!/usr/bin/env bash
# fm-decision-record.sh - own the structured decision record at its source.
#
# The Captain's Call section of /bearings renders every open decision "with its
# options from the structured decision record" (.agents/skills/bearings/SKILL.md),
# and bin/fm-bearings-board.sh validates each call item against a typed schema.
# Nothing produced that record: the board's own contract is authoritative, but the
# options reaching it were re-derived from a stopping crewmate's prose by whichever
# agent composed the board payload. Re-deriving structure from prose is exactly
# where an option quietly disappears, a recommendation drifts to something the
# options never offered, or a safe preview is lost.
#
# This script owns the record instead. Whoever stops on the decision states the
# question, the options, and the recommendation ONCE, as data, at the moment it
# stops; the board consumes it verbatim and never re-invents it.
#
# Records live per-home at state/decisions/<key>.call.json, one validated
# fm-bearings-board.v1 call item each. Validation mirrors the board's own
# call_item predicate field for field, so a record that lands here is a record
# the board accepts. `list` prints the array ready to splice into a board
# payload's `calls`, so composing the board stays a copy, not a rewrite.
#
# This deliberately does NOT build on bin/fm-decision-hold.sh: that is a
# transitional shim over bin/fm-captain-hold.sh and is scheduled for removal.
# Holding a task for the captain and describing the choice are separate jobs;
# this script only does the second and never mints or closes a hold.
#
# Usage:
#   fm-decision-record.sh record <key> --title <text> [field...]
#   fm-decision-record.sh status-line <key>
#   fm-decision-record.sh list
#   fm-decision-record.sh get <key>
#   fm-decision-record.sh clear <key>
#
# record fields:
#   --title <text>          required, the one-line choice being put to the captain
#   --type <t>              decision (default), merge, or credential
#   --option <value> <label>  repeatable, the offered choices (at least one,
#                             unless --allow-freeform)
#   --hint <value> <text>   attach a hint to an option already declared
#   --recommend <value>     must name one of the declared options
#   --about <text>          what this is about
#   --decide <text>         what the captain is actually deciding
#   --detail <text>         longer safe-to-render detail (the old safe_preview)
#   --pr-url <https url>    related PR, full URL
#   --risk <text>           required when --type merge
#   --repo <name>           owning repo, empty string for none
#   --allow-freeform        accept an answer outside the options
#   --freeform-hint <text>  prompt shown for a freeform answer
#   --close <done|release>  how answering closes the held task
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD_DIR="$STATE/decisions"

fail() { printf 'fm-decision-record: %s\n' "$1" >&2; exit 2; }

usage() {
  sed -n '28,52p' "$0" | sed 's/^# \{0,1\}//'
}

need_jq() {
  command -v jq >/dev/null 2>&1 || fail "jq is required"
}

# Mirrors the board's slug($max) predicate: ^[A-Za-z0-9._-]{1,max}$
validate_slug() {  # <label> <value> <max>
  case "$2" in
    ''|*[!A-Za-z0-9._-]*) fail "$1 must be a non-empty privacy-safe slug: $2" ;;
  esac
  [ "${#2}" -le "$3" ] || fail "$1 must be at most $3 characters"
}

record_path() {  # <key>
  printf '%s/%s.call.json' "$RECORD_DIR" "$1"
}

command_record() {
  need_jq
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  local key=$1; shift
  validate_slug key "$key" 128

  local type=decision title='' recommend='' about='' decide='' detail=''
  local pr_url='' risk='' repo='' freeform_hint='' close=''
  local allow_freeform=false has_repo=false
  local options='[]'

  while [ "$#" -gt 0 ]; do
    case $1 in
      --title) shift; title=${1:-} ;;
      --type) shift; type=${1:-} ;;
      --option)
        shift; local ov=${1:-}; shift; local ol=${1:-}
        validate_slug "option value" "$ov" 128
        [ -n "$ol" ] || fail "option $ov needs a non-empty label"
        printf '%s' "$options" | jq -e --arg v "$ov" 'any(.[]; .value == $v)' >/dev/null 2>&1 \
          && fail "option $ov declared twice"
        options=$(printf '%s' "$options" | jq -c --arg v "$ov" --arg l "$ol" '. + [{value:$v,label:$l}]') \
          || fail "could not add option $ov"
        ;;
      --hint)
        shift; local hv=${1:-}; shift; local ht=${1:-}
        printf '%s' "$options" | jq -e --arg v "$hv" 'any(.[]; .value == $v)' >/dev/null 2>&1 \
          || fail "--hint names an option that was not declared: $hv"
        options=$(printf '%s' "$options" | jq -c --arg v "$hv" --arg h "$ht" \
          'map(if .value == $v then . + {hint:$h} else . end)') || fail "could not hint $hv"
        ;;
      --recommend) shift; recommend=${1:-} ;;
      --about) shift; about=${1:-} ;;
      --decide) shift; decide=${1:-} ;;
      --detail) shift; detail=${1:-} ;;
      --pr-url) shift; pr_url=${1:-} ;;
      --risk) shift; risk=${1:-} ;;
      --repo) shift; repo=${1:-}; has_repo=true ;;
      --allow-freeform) allow_freeform=true ;;
      --freeform-hint) shift; freeform_hint=${1:-} ;;
      --close) shift; close=${1:-} ;;
      *) fail "unknown field: $1" ;;
    esac
    shift || true
  done

  [ -n "$title" ] || fail "--title is required"
  case $type in
    decision|merge|credential) ;;
    *) fail "--type must be decision, merge, or credential" ;;
  esac

  local count
  count=$(printf '%s' "$options" | jq -r 'length')
  if [ "$count" -eq 0 ] && [ "$allow_freeform" != true ]; then
    fail "declare at least one --option, or pass --allow-freeform"
  fi

  if [ -n "$recommend" ]; then
    validate_slug "--recommend" "$recommend" 128
    printf '%s' "$options" | jq -e --arg v "$recommend" 'any(.[]; .value == $v)' >/dev/null 2>&1 \
      || fail "--recommend must name one of the declared options: $recommend"
  fi

  [ "$type" != merge ] || [ -n "$risk" ] || fail "--type merge requires --risk"

  if [ -n "$pr_url" ]; then
    case $pr_url in
      https://*) ;;
      *) fail "--pr-url must be an https URL" ;;
    esac
    case $pr_url in
      *[[:space:]]*) fail "--pr-url must not contain whitespace" ;;
    esac
  fi

  if [ -n "$close" ]; then
    case $close in
      done|release) ;;
      *) fail "--close must be done or release" ;;
    esac
  fi

  # `repo` is required by the board's repo_marker predicate, and null is a legal
  # value there, so an unspecified repo is recorded as null rather than omitted.
  local repo_arg='null'
  if [ "$has_repo" = true ] && [ -n "$repo" ]; then repo_arg=$repo; fi

  local out
  out=$(jq -cn \
    --arg key "$key" --arg type "$type" --arg title "$title" \
    --argjson options "$options" \
    --arg recommend "$recommend" --arg about "$about" --arg decide "$decide" \
    --arg detail "$detail" --arg pr_url "$pr_url" --arg risk "$risk" \
    --arg freeform_hint "$freeform_hint" --arg close "$close" \
    --argjson allow_freeform "$allow_freeform" \
    --arg repo "$repo_arg" --argjson has_repo "$has_repo" '
      {key:$key, type:$type, title:$title, options:$options,
       repo: (if ($has_repo and $repo != "null") then $repo else null end)}
      + (if $recommend == "" then {} else {recommend_value:$recommend} end)
      + (if $about == "" then {} else {about:$about} end)
      + (if $decide == "" then {} else {decide:$decide} end)
      + (if $detail == "" then {} else {detail:$detail} end)
      + (if $pr_url == "" then {} else {pr_url:$pr_url} end)
      + (if $risk == "" then {} else {risk:$risk} end)
      + (if $freeform_hint == "" then {} else {freeform_hint:$freeform_hint} end)
      + (if $close == "" then {} else {close:$close} end)
      + (if $allow_freeform then {allow_freeform:true} else {} end)
    ') || fail "could not compose the record"

  mkdir -p "$RECORD_DIR" || fail "could not create $RECORD_DIR"
  local path tmp
  path=$(record_path "$key")
  tmp="$path.$$.tmp"
  printf '%s\n' "$out" > "$tmp" || fail "could not write $tmp"
  mv -f "$tmp" "$path" || { rm -f "$tmp"; fail "could not publish $path"; }
  printf 'record: %s\n' "$path"
}

command_status_line() {  # <key>
  need_jq
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  local path; path=$(record_path "$1")
  [ -f "$path" ] || fail "no record for key: $1"
  jq -r --arg key "$1" '
    "needs-decision [key=" + $key + "]: " + .title
    + " {options=" + ([.options[].value] | join(",")) + "}"
    + (if has("recommend_value") then " {recommend=" + .recommend_value + "}" else "" end)
    + " {record=state/decisions/" + $key + ".call.json}"
  ' "$path"
}

command_list() {
  need_jq
  [ -d "$RECORD_DIR" ] || { printf '[]\n'; return 0; }
  # Sorted by key so a board rebuilt from the same records is byte-identical.
  find "$RECORD_DIR" -maxdepth 1 -name '*.call.json' -print0 2>/dev/null \
    | sort -z \
    | xargs -0 -r jq -s -c '.' 2>/dev/null \
    || printf '[]\n'
}

command_get() {  # <key>
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  local path; path=$(record_path "$1")
  [ -f "$path" ] || fail "no record for key: $1"
  cat "$path"
}

command_clear() {  # <key>
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug key "$1" 128
  local path; path=$(record_path "$1")
  [ -f "$path" ] || { printf 'already-clear: %s\n' "$1"; return 0; }
  rm -f "$path" || fail "could not remove $path"
  printf 'cleared: %s\n' "$1"
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
case $1 in
  record) shift; command_record "$@" ;;
  status-line) shift; command_status_line "$@" ;;
  list) shift; command_list "$@" ;;
  get) shift; command_get "$@" ;;
  clear) shift; command_clear "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
