#!/usr/bin/env bash
# Shared outbound check for dispatch and model proposals.
# Usage: . bin/fm-never-send-lib.sh
#   fm_never_send_check <list-path> <request-json> <description>
# Returns 0 when allowed (including an absent list), or 1 on a match or check
# failure, with a value-free diagnostic in FM_NEVER_SEND_ERROR.
# docs/configuration.md "Never-send list" owns the list and matching contract.
# Checker stderr is discarded because jq/grep errors can expose private text
# or the literal pattern; callers choose their own refusal outcome.

fm_never_send_check() {
  local list_path=$1 request=$2 description=$3
  local normalized_request list value n=0 rc
  FM_NEVER_SEND_ERROR=''
  [ -e "$list_path" ] || [ -L "$list_path" ] || return 0
  if ! { [ -f "$list_path" ] && [ -r "$list_path" ]; }; then
    FM_NEVER_SEND_ERROR="$list_path is not a readable regular file"
    return 1
  fi
  normalized_request=$(jq -r '.. | strings | gsub("\\s+"; " ")' <<<"$request" 2>/dev/null) || {
    FM_NEVER_SEND_ERROR="could not extract the request text to check"
    return 1
  }
  list=$(jq -Rr 'gsub("\\s+"; " ")' "$list_path" 2>/dev/null) || {
    FM_NEVER_SEND_ERROR="could not read $list_path"
    return 1
  }
  while IFS= read -r value; do
    n=$((n + 1))
    value=${value# }
    value=${value% }
    case "$value" in
      ''|'#'*) continue ;;
    esac
    grep -qiF -e "$value" <<<"$normalized_request" 2>/dev/null
    rc=$?
    case "$rc" in
      0)
        FM_NEVER_SEND_ERROR="$description matches $list_path line $n"
        return 1
        ;;
      1) ;;
      *)
        # shellcheck disable=SC2034 # Read by sourcing callers after the check returns.
        FM_NEVER_SEND_ERROR="could not check the request text against $list_path line $n"
        return 1
        ;;
    esac
  done <<<"$list"
  return 0
}
