# shellcheck shell=bash
# FM_PRIVATE_GUARD_WHY is this library's output; its callers read it.
# shellcheck disable=SC2034
# fm-private-guard-lib.sh - the hard private-material guard for dispatch
# profiles that config/crew-dispatch.json marks "private_ok": false.
#
# docs/configuration.md "Private-material guard (config/private-markers)" owns
#   the operator contract. This library is the one owner of loading and
#   matching; bin/fm-dispatch-resolve.sh (eligibility) and bin/fm-spawn.sh
#   (launch refusal) both call it, so the two checks cannot drift.
#
# config/private-markers is read locally and never leaves the machine: no
#   caller passes a marker to Jev, a remote model, a log, or an error message.
#   A match is named only by the checked source and the list line number.
#
# Matching: each non-blank line not starting with # is one literal marker.
#   The marker and the checked text are both lowercased, and every run of
#   whitespace, '-', or '_' counts as one space, so "Lay Distribution" also
#   matches the project lay-distribution-site. A marker matches anywhere in
#   the checked text.
#
# fm_private_guard_home_names <home-dir>
#   Prints the home's names, one per line: the directory basename and, for a
#   secondmate home, the id in its .fm-secondmate-home marker.
#
# fm_private_guard_check <config-dir> <project> <brief-file|''> <home-dir|''> [<home-name>...]
#   Returns 0 only when the task is provably non-private: the list exists, is
#   a readable regular file, the brief (when named) is readable, and no marker
#   matches the project, the home's names (fm_private_guard_home_names plus
#   any extra names given), or the whole brief text. Otherwise
#   returns 1 and sets FM_PRIVATE_GUARD_WHY. It fails closed: an absent or
#   unusable list, or an unreadable brief, is never treated as non-private.
#
# fm_private_guard_restricted <rules-file> <harness> <model|''> [<model>...]
#   Returns 0 when the launch is a profile the rules file marks
#   "private_ok": false in any rule's use or the default, 1 when it is not, and
#   0 with FM_PRIVATE_GUARD_WHY set when an existing rules file cannot be
#   read as JSON (fail closed). A profile with a model matches any launch of
#   that model id, case-insensitively, whatever the harness; a profile with no
#   model matches a launch of its harness with no model.

FM_PRIVATE_MARKERS_NAME='private-markers'
FM_PRIVATE_GUARD_WHY=''

# Lowercase, and fold every run of whitespace, '-', or '_' into one space.
_fm_private_guard_normalize() {
  jq -Rrs 'ascii_downcase | gsub("[\\s_-]+"; " ")'
}

fm_private_guard_home_names() {
  local home=${1:-} marker id
  [ -n "$home" ] || return 0
  home=${home%/}
  printf '%s\n' "${home##*/}"
  marker="$home/.fm-secondmate-home"
  if [ -f "$marker" ] && [ ! -L "$marker" ] && id=$(head -n 1 "$marker" 2>/dev/null) && [ -n "$id" ]; then
    printf '%s\n' "$id"
  fi
}

# _fm_private_guard_match <markers-normalized> <source> <text>: 0 on a match,
# with FM_PRIVATE_GUARD_WHY naming the source and line number only.
_fm_private_guard_match() {
  local markers=$1 source=$2 text=$3 marker n=0 rc
  [ -n "$text" ] || return 1
  while IFS= read -r marker; do
    n=$((n + 1))
    marker=${marker# }
    marker=${marker% }
    case "$marker" in
      '' | '#'*) continue ;;
    esac
    grep -qiF -e "$marker" <<<"$text" 2>/dev/null
    rc=$?
    case "$rc" in
      0)
        FM_PRIVATE_GUARD_WHY="$source matches config/$FM_PRIVATE_MARKERS_NAME line $n"
        return 0
        ;;
      1) ;;
      *)
        FM_PRIVATE_GUARD_WHY="could not check the $source against config/$FM_PRIVATE_MARKERS_NAME line $n"
        return 0
        ;;
    esac
  done <<<"$markers"
  return 1
}

fm_private_guard_check() {
  local dir=${1:-} project=${2:-} brief=${3:-} home=${4:-} list markers text name names
  shift 4 2>/dev/null || shift $#
  FM_PRIVATE_GUARD_WHY=''
  list="$dir/$FM_PRIVATE_MARKERS_NAME"
  if [ -z "$dir" ] || { [ ! -e "$list" ] && [ ! -L "$list" ]; }; then
    FM_PRIVATE_GUARD_WHY="no config/$FM_PRIVATE_MARKERS_NAME list proves the task non-private"
    return 1
  fi
  if ! { [ -f "$list" ] && [ -r "$list" ]; }; then
    FM_PRIVATE_GUARD_WHY="config/$FM_PRIVATE_MARKERS_NAME is not a readable regular file"
    return 1
  fi
  # Comments are recognized before normalization so a '#' stays a comment
  # marker; normalization keeps one line per list line, so line numbers hold.
  markers=$(jq -Rr 'if test("^\\s*#") then "#" else ascii_downcase | gsub("[\\s_-]+"; " ") end' "$list" 2>/dev/null) || {
    FM_PRIVATE_GUARD_WHY="could not read config/$FM_PRIVATE_MARKERS_NAME"
    return 1
  }
  if [ -n "$project" ]; then
    text=$(printf '%s' "$project" | _fm_private_guard_normalize) || text=$project
    _fm_private_guard_match "$markers" project "$text" && return 1
  fi
  names=$(fm_private_guard_home_names "$home")
  for name in "$@"; do
    names="$names"$'\n'"$name"
  done
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    text=$(printf '%s' "$name" | _fm_private_guard_normalize) || text=$name
    _fm_private_guard_match "$markers" 'home name' "$text" && return 1
  done <<<"$names"
  if [ -n "$brief" ]; then
    if ! { [ -f "$brief" ] && [ -r "$brief" ]; }; then
      FM_PRIVATE_GUARD_WHY='the brief is not readable, so it cannot be proven non-private'
      return 1
    fi
    text=$(_fm_private_guard_normalize < "$brief") || {
      FM_PRIVATE_GUARD_WHY='could not read the brief to check it'
      return 1
    }
    _fm_private_guard_match "$markers" brief "$text" && return 1
  fi
  return 0
}

fm_private_guard_restricted() {
  local rules=${1:-} harness=${2:-} model=${3:-} ids hit
  shift 3 2>/dev/null || shift $#
  FM_PRIVATE_GUARD_WHY=''
  [ -n "$rules" ] || return 1
  [ -e "$rules" ] || [ -L "$rules" ] || return 1
  [ "$model" != default ] || model=''
  ids=$(jq -nc '$ARGS.positional | map(select(. != "" and . != "default") | ascii_downcase) | unique' --args ${model:+"$model"} "$@") || ids='[]'
  hit=$(jq -r --arg harness "$harness" --argjson ids "$ids" '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    [((.rules // [])[] | profiles(.use)[]), profiles(.default // null)[]
      | select(type == "object" and .private_ok == false)]
    | any(.[];
        if (.model // "") != "" then (.model | ascii_downcase) as $m | any($ids[]; . == $m)
        else .harness == $harness and ($ids | length) == 0 end)' "$rules" 2>/dev/null) || {
    FM_PRIVATE_GUARD_WHY="$rules is not readable JSON, so the launch cannot be proven to be a private-capable profile"
    return 0
  }
  [ "$hit" = true ]
}
