#!/usr/bin/env bash
# fm-witness-login.sh - type a witness's browser logins by name, and keep their
# values out of everything the witness reads.
#
# A post-merge witness (bin/fm-post-merge.sh witness-task) uses the deployed
# product through chrome-devtools-axi, and some products need a login. The
# logins live in a local, uncommitted file that only this script reads; the
# witness knows only their names. Adapted from korallis/agent-stack (Apache-2.0,
# https://github.com/korallis/agent-stack, docs/REFERENCE.md "Test
# credentials"), where the Playwright MCP's --secrets file does the same; see
# NOTICE.
#
# Usage:
#   fm-witness-login.sh names
#   fm-witness-login.sh fill @<uid> <NAME>
#   fm-witness-login.sh run <chrome-devtools-axi arguments>...
#
# names   Print each configured login name, one per line, never a value.
# fill    Fill the field <uid> with the value of <NAME> through
#         `chrome-devtools-axi fill`.
# run     Run any chrome-devtools-axi command.
# Both fill and run replace every configured value in the browser tool's
# output, stdout and stderr alike, with <secret>NAME</secret> before printing
# it, keep the tool's exit status, and refuse an argument that already contains
# a configured value, so a value typed by hand is refused instead of sent.
#
# The file is config/witness-logins.env under the active home (FM_HOME, or
# FM_CONFIG_OVERRIDE), one NAME=value per line, where NAME is upper case
# letters, digits, and underscores starting with a letter; blank lines and
# lines starting with # are ignored. It must be a regular file owned by the
# current user with mode 0600, and anything else is refused. An absent file
# means no logins: names prints nothing and fill refuses.
#
# Limits, stated plainly: the value is passed to chrome-devtools-axi as an
# argument, so it is briefly visible to other processes of the same user; and
# redaction covers only output that passes through this script, so a witness
# must route every browser command through `run` once a login is used.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
LOGINS="$CONFIG/witness-logins.env"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; }
die() { echo "error: $*" >&2; exit 2; }

NAMES=()
VALUES=()

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

load_logins() {
  local line name value
  [ -e "$LOGINS" ] || [ -L "$LOGINS" ] || return 0
  [ -f "$LOGINS" ] && [ ! -L "$LOGINS" ] || die "$LOGINS is not a regular file"
  [ -O "$LOGINS" ] || die "$LOGINS is not owned by the current user"
  [ "$(file_mode "$LOGINS")" = 600 ] || die "$LOGINS must have mode 0600"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    name=${line%%=*}
    value=${line#*=}
    [ "$name" != "$line" ] || die "$LOGINS has a line that is not NAME=value"
    [[ "$name" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "$LOGINS has an invalid login name '$name'"
    [ -n "$value" ] || continue
    NAMES+=("$name")
    VALUES+=("$value")
  done < "$LOGINS"
}

# Replace every configured value in $1 with <secret>NAME</secret>, longest value
# first so a value that contains another is never partly revealed.
redact() {
  local text=$1 i j order=() swap
  for i in "${!VALUES[@]}"; do order+=("$i"); done
  for ((i = 0; i < ${#order[@]}; i++)); do
    for ((j = i + 1; j < ${#order[@]}; j++)); do
      if [ "${#VALUES[${order[j]}]}" -gt "${#VALUES[${order[i]}]}" ]; then
        swap=${order[i]}
        order[i]=${order[j]}
        order[j]=$swap
      fi
    done
  done
  for i in "${order[@]+"${order[@]}"}"; do
    text=${text//"${VALUES[i]}"/<secret>${NAMES[i]}</secret>}
  done
  printf '%s' "$text"
}

refuse_literal_values() {
  local arg i
  for arg in "$@"; do
    for i in "${!VALUES[@]}"; do
      case "$arg" in
        *"${VALUES[i]}"*) die "an argument contains the value of login ${NAMES[i]}; pass the name to fill instead" ;;
      esac
    done
  done
}

run_browser() {
  local out err status=0 errfile
  command -v chrome-devtools-axi >/dev/null 2>&1 || die "chrome-devtools-axi is not on PATH"
  errfile=$(mktemp "${TMPDIR:-/tmp}/fm-witness-login.XXXXXX") || die "could not create a temporary file"
  out=$(chrome-devtools-axi "$@" 2>"$errfile") || status=$?
  err=$(cat "$errfile")
  rm -f -- "$errfile"
  [ -z "$out" ] || printf '%s\n' "$(redact "$out")"
  [ -z "$err" ] || printf '%s\n' "$(redact "$err")" >&2
  return "$status"
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  names)
    [ "$#" -eq 1 ] || die "names takes no arguments"
    load_logins
    for name in "${NAMES[@]+"${NAMES[@]}"}"; do
      printf '%s\n' "$name"
    done
    ;;
  fill)
    [ "$#" -eq 3 ] || die "usage: fm-witness-login.sh fill @<uid> <NAME>"
    load_logins
    case "$2" in @*) ;; *) die "fill needs an element ref such as @g1:3" ;; esac
    refuse_literal_values "$2"
    for i in "${!NAMES[@]}"; do
      if [ "${NAMES[i]}" = "$3" ]; then
        run_browser fill "$2" "${VALUES[i]}"
        exit $?
      fi
    done
    die "no login named '$3' is configured; ask firstmate for it rather than guessing"
    ;;
  run)
    shift
    [ "$#" -ge 1 ] || die "usage: fm-witness-login.sh run <chrome-devtools-axi arguments>"
    load_logins
    refuse_literal_values "$@"
    run_browser "$@"
    exit $?
    ;;
  *) usage >&2; exit 2 ;;
esac
