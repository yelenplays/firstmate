#!/usr/bin/env bash
# fm-theme.sh - resolve and render the optional theme pack for a Firstmate home.
#
# A theme pack changes only what the captain sees: the voice of private captain
# chat, the names used there, a session-start banner, and display-only status
# words in human views. It never changes status files, protocol prefixes,
# script interfaces, skill names, or any safety rule. docs/configuration.md
# "Theme pack (config/theme)" owns the setting, the pack format, and the
# chat-only boundary; this header owns the mechanics.
#
# SELECTION: the one-line, gitignored $FM_HOME/config/theme names a pack
# (FM_CONFIG_OVERRIDE selects the config directory directly, as elsewhere).
# Packs are tracked under <code root>/themes/<name>/ next to this script, so a
# pack ships with the code that renders it. An absent or empty setting, or
# `off`, selects the built-in nautical behavior, which renders
# nothing here, so every caller's default output stays byte-identical to a home
# with no theme support at all.
#
# FALLBACK: a name that is not a safe pack name ([a-z0-9][a-z0-9-]*, at most 64
# characters) or that has no themes/<name>/theme.conf falls back to the
# built-in default and prints exactly one warning line on stderr. The `digest`
# subcommand also puts that one line on stdout so the session-start digest
# shows it. Every render path exits 0 on fallback; only `set` with a bad name
# and usage errors exit nonzero.
#
# PACK FORMAT (themes/<name>/):
#   theme.conf  required. `key = value` lines; blank lines and `#` comments are
#               ignored, unknown keys are ignored, and values are trimmed and
#               stripped of control characters. Keys:
#                 description      one line shown in the digest
#                 address          the word that replaces "captain" in chat
#                 noop_reply       the exact reply for a true no-op
#                 banner_sgr       optional SGR parameters (digits and `;`) used
#                                  to color the banner on a TTY only
#                 term.<name>      chat vocabulary, e.g. term.captain = the OG
#                 status.<state>   display word for one canonical worker state:
#                                  working, done, needs-decision, blocked,
#                                  paused, or failed
#   voice.md    optional. Voice guidance for private captain chat.
#   banner.txt  optional. Plain-text banner for a fresh session start.
#
# Usage:
#   fm-theme.sh current            resolved pack name, or `nautical`
#   fm-theme.sh list               the built-in default and every tracked pack
#   fm-theme.sh set <name>|off     validate and write config/theme (`off`
#                                  removes it)
#   fm-theme.sh banner             the banner (colored only on a TTY without
#                                  NO_COLOR); nothing for the default
#   fm-theme.sh status <state>     display word for a canonical state
#   fm-theme.sh status-map         JSON object of state -> display word ({} for
#                                  the default)
#   fm-theme.sh digest [--banner]  the session-start THEME section body;
#                                  nothing for the default
#   fm-theme.sh show               the full pack as the digest prints it
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEMES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/themes"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
THEME_FILE="$CONFIG/theme"

STATUS_STATES='working done needs-decision blocked paused failed'

usage() {
  sed -n '/^# Usage:$/,/^set -u$/p' "$SCRIPT_DIR/fm-theme.sh" | sed 's/^# \{0,1\}//; $d'
}

builtin_name() {
  case "$1" in
    '') return 0 ;;
  esac
  return 1
}

valid_name() {
  [ "${#1}" -le 64 ] || return 1
  case "$1" in
    [a-z0-9]*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!a-z0-9-]*) return 1 ;;
  esac
  return 0
}

pack_present() {
  valid_name "$1" && [ -f "$THEMES_DIR/$1/theme.conf" ]
}

# configured_name: the trimmed first line of config/theme, or empty.
configured_name() {
  local line=
  [ -f "$THEME_FILE" ] || return 0
  IFS= read -r line < "$THEME_FILE" || true
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  printf '%s' "$line"
}

# resolve: sets THEME to the active pack name, or empty for the built-in
# default, and WARNING to the one fallback line when the setting is unusable.
resolve() {
  local name
  THEME=
  WARNING=
  name=$(configured_name)
  { [ "$name" = off ] || builtin_name "$name"; } && return 0
  if pack_present "$name"; then
    THEME=$name
    return 0
  fi
  WARNING="fm-theme: unknown theme '$(printf '%s' "$name" | tr -cd '[:print:]' | cut -c1-64)' in config/theme; using the built-in nautical default"
}

warn_once() {
  [ -z "$WARNING" ] || printf '%s\n' "$WARNING" >&2
}

# conf_get <key>: the value of <key> in the active pack's theme.conf.
conf_get() {
  local want=$1 key value line
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | tr -d '\000-\010\013-\037\177')
    case "$line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *) continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    key=$(printf '%s' "$key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ "$key" = "$want" ] || continue
    printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
    return 0
  done < "$THEMES_DIR/$THEME/theme.conf"
  return 1
}

# conf_prefixed <prefix>: "<suffix>\t<value>" for every key under <prefix>, in
# file order.
conf_prefixed() {
  local prefix=$1 key value line
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | tr -d '\000-\010\013-\037\177')
    case "$line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *) continue ;;
    esac
    key=$(printf '%s' "${line%%=*}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    value=$(printf '%s' "${line#*=}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$key" in
      "$prefix"?*) [ -n "$value" ] && printf '%s\t%s\n' "${key#"$prefix"}" "$value" ;;
    esac
  done < "$THEMES_DIR/$THEME/theme.conf"
}

status_word() {  # <state>
  local state=$1 word=
  if [ -n "$THEME" ]; then
    case " $STATUS_STATES " in
      *" $state "*) word=$(conf_get "status.$state" || true) ;;
    esac
  fi
  printf '%s\n' "${word:-$state}"
}

status_map_json() {
  local state word first=1
  printf '{'
  if [ -n "$THEME" ]; then
    for state in $STATUS_STATES; do
      word=$(conf_get "status.$state" || true)
      [ -n "$word" ] || continue
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '"%s":"%s"' "$state" "$(printf '%s' "$word" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    done
  fi
  printf '}\n'
}

print_banner() {  # <colorize: 0|1>
  local colorize=$1 sgr file
  [ -n "$THEME" ] || return 0
  file="$THEMES_DIR/$THEME/banner.txt"
  [ -s "$file" ] || return 0
  sgr=$(conf_get banner_sgr || true)
  case "$sgr" in
    *[!0-9\;]*) sgr= ;;
  esac
  if [ "$colorize" -eq 1 ] && [ -n "$sgr" ]; then
    printf '\033[%sm' "$sgr"
    tr -d '\033' < "$file"
    printf '\033[0m'
  else
    tr -d '\033' < "$file"
  fi
}

print_digest() {  # <with-banner: 0|1>
  local with_banner=$1 value suffix word
  if [ -n "$WARNING" ]; then
    printf '%s\n' "$WARNING"
    return 0
  fi
  [ -n "$THEME" ] || return 0
  printf 'Theme pack: %s' "$THEME"
  value=$(conf_get description || true)
  [ -z "$value" ] || printf ' - %s' "$value"
  printf '\n'
  cat <<EOF
This pack restyles private captain chat only, as AGENTS.md's opening address
rules and docs/configuration.md "Theme pack (config/theme)" bound it. Every rule
keeps its substance; public replies, Slack posts, and non-chat artifacts keep the
default.
It is printed in full here; do not re-read themes/$THEME/ this session.
EOF
  if [ "$with_banner" -eq 1 ] && [ -s "$THEMES_DIR/$THEME/banner.txt" ]; then
    printf '\nBanner - open your first captain-facing reply of this fresh session with it, in a code block:\n'
    print_banner 0
  fi
  value=$(conf_get address || true)
  [ -z "$value" ] || printf '\nAddress word (replaces "captain" in chat): %s\n' "$value"
  value=$(conf_get noop_reply || true)
  [ -z "$value" ] || printf 'Exact no-op reply (replaces "Captain, shipshape."): %s\n' "$value"
  value=$(conf_prefixed term.)
  if [ -n "$value" ]; then
    printf '\nNames used in chat:\n'
    printf '%s\n' "$value" | while IFS="$(printf '\t')" read -r suffix word; do
      printf '  %s -> %s\n' "$suffix" "$word"
    done
  fi
  value=$(conf_prefixed status.)
  if [ -n "$value" ]; then
    printf '\nStatus words (display and chat only; status files, prefixes, and scripts keep the canonical word):\n'
    printf '%s\n' "$value" | while IFS="$(printf '\t')" read -r suffix word; do
      case " $STATUS_STATES " in
        *" $suffix "*) printf '  %s -> %s\n' "$suffix" "$word" ;;
      esac
    done
  fi
  if [ -s "$THEMES_DIR/$THEME/voice.md" ]; then
    printf '\nVoice:\n'
    cat "$THEMES_DIR/$THEME/voice.md"
  fi
}

list_packs() {
  local dir name desc
  printf 'nautical (built-in default)\n'
  for dir in "$THEMES_DIR"/*/; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    pack_present "$name" || continue
    desc=$(THEME=$name conf_get description || true)
    if [ -n "$desc" ]; then
      printf '%s - %s\n' "$name" "$desc"
    else
      printf '%s\n' "$name"
    fi
  done
}

set_theme() {  # <name>
  local name=$1 tmp
  if [ "$name" = off ] || builtin_name "$name"; then
    rm -f "$THEME_FILE" || { printf 'fm-theme: cannot remove %s\n' "$THEME_FILE" >&2; return 1; }
    printf 'theme: nautical (built-in default)\n'
    return 0
  fi
  if ! pack_present "$name"; then
    printf "fm-theme: unknown theme '%s'; run fm-theme.sh list\n" "$(printf '%s' "$name" | tr -cd '[:print:]' | cut -c1-64)" >&2
    return 2
  fi
  mkdir -p "$CONFIG" || return 1
  tmp=$(mktemp "$CONFIG/.theme.XXXXXX") || return 1
  if printf '%s\n' "$name" > "$tmp" && mv -f "$tmp" "$THEME_FILE"; then
    printf 'theme: %s\n' "$name"
    return 0
  fi
  rm -f "$tmp"
  printf 'fm-theme: cannot write %s\n' "$THEME_FILE" >&2
  return 1
}

cmd=${1:-}
[ "$#" -eq 0 ] || shift
case "$cmd" in
  -h|--help|help) usage; exit 0 ;;
  current)
    resolve; warn_once
    printf '%s\n' "${THEME:-nautical}"
    ;;
  list)
    list_packs
    ;;
  set)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    set_theme "$1"; exit $?
    ;;
  banner)
    resolve; warn_once
    colorize=0
    [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && colorize=1
    print_banner "$colorize"
    ;;
  status)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    resolve; warn_once
    status_word "$1"
    ;;
  status-map)
    resolve; warn_once
    status_map_json
    ;;
  digest)
    with_banner=0
    case "${1:-}" in
      --banner) with_banner=1 ;;
      '') ;;
      *) usage >&2; exit 2 ;;
    esac
    resolve; warn_once
    print_digest "$with_banner"
    ;;
  show)
    resolve; warn_once
    print_digest 1
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
exit 0
