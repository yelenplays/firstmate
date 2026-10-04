#!/usr/bin/env bash
# fm-slack-bridge.sh - the captain's Slack channel to and from this firstmate home.
#
# Usage:
#   fm-slack-bridge.sh post report   [--url <https-url>] [--] <text>...
#   fm-slack-bridge.sh post decision [--url <https-url>] [--] <text>...
#   fm-slack-bridge.sh post <kind> [--url <https-url>] -        (text from stdin)
#   fm-slack-bridge.sh check
#   fm-slack-bridge.sh arm
#   fm-slack-bridge.sh disarm
#   fm-slack-bridge.sh --help
#
# Out: `post` sends one captain-facing message through slack-axi (draft, then
# `draft send`), to the report channel for `report` (finished PRs, merge asks,
# merge results) or the decisions channel for `decision` (a decision with its
# recommendation). It appends the posted channel id and message ts to
# state/slack-bridge/posts, which is the only set of threads `check` reads.
# Every post is top-level: the bridge never replies inside a thread, because it
# posts as the logged-in account, and that account's thread replies are what
# counts as captain input.
#
# In: `check` reads the replies in the threads of bridge posts from the last
# `watch-days` days, plus new top-level messages in the handoff channel, through
# bin/fm-slack-read.mjs, which returns each author's Slack user id. A thread
# reply becomes captain input only when its author id equals `captain-user`
# exactly; replies from anyone else are ignored. A handoff-channel message from
# anyone but the captain becomes a request note that names its sender and says
# it is not captain authority. Each accepted message is delivered exactly once
# through `fm-inbox.sh note --request-id slack-<channel>-<ts>` (source
# slack-captain or slack-request), which writes the durable note and its single
# `check` wake; a replay of the same request id never adds a second note or
# wake, so a crash between delivery and the local delivered record is healed by
# the next poll rather than duplicated. A poll that delivered anything prints
# one line so the watcher wakes firstmate; a failing poll prints one line only
# when its diagnostic changed; otherwise `check` is silent.
#
# Slack text is input like a typed captain message and nothing more: it never
# bypasses merge guards, holds, or the destructive and security boundaries.
#
# `arm` writes state/slack-bridge.check.sh and binds its bytes with
# fm-check-register.sh, so the watcher runs `check` on its slow-check cadence,
# and starts the handoff channel at "now" so old history is not replayed.
# `disarm` removes the shim and its trust binding and keeps the records.
#
# The bridge is off while config/slack-bridge is absent: `post` prints one
# `slack bridge off` line and exits 0, and `check` is silent. docs/configuration.md
# "Slack bridge" owns the config schema. The bridge uses whichever account
# slack-axi is logged in as and never reads, prints, stores, or logs a token.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_CHECK_TIMEOUT
# (default 30, the watcher's per-check bound), FM_SLACK_BRIDGE_BUDGET (default
# 20, valid 5..25, cut to fit FM_CHECK_TIMEOUT), FM_SLACK_BRIDGE_NOW (epoch
# override for tests).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG_DIR/slack-bridge"
BRIDGE_STATE="$STATE/slack-bridge"
POSTS="$BRIDGE_STATE/posts"
DELIVERED="$BRIDGE_STATE/delivered"
HANDOFF_CURSOR="$BRIDGE_STATE/handoff-cursor"
REPORT_RECORD="$BRIDGE_STATE/last-report"
CHECK_ID=slack-bridge
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
READER="$SCRIPT_DIR/fm-slack-read.mjs"
INBOX_BIN="$SCRIPT_DIR/fm-inbox.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
MAX_LINE=240

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-slack-bridge.sh post report   [--url <https-url>] [--] <text>...   post a PR, merge ask, or result
  fm-slack-bridge.sh post decision [--url <https-url>] [--] <text>...   post a decision with its recommendation
  fm-slack-bridge.sh post <kind> [--url <https-url>] -                   text from stdin
  fm-slack-bridge.sh check     deliver new captain thread replies and handoff requests to the captain inbox
  fm-slack-bridge.sh arm       write and register state/slack-bridge.check.sh
  fm-slack-bridge.sh disarm    remove the check shim and its trust binding
  fm-slack-bridge.sh --help    print this help

Configuration: config/slack-bridge (docs/configuration.md "Slack bridge").
EOF
}

die() { printf 'fm-slack-bridge: %s\n' "$*" >&2; exit 1; }

now_epoch() {
  case "${FM_SLACK_BRIDGE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_SLACK_BRIDGE_NOW" ;;
  esac
}

# --------------------------------------------------------------- config

CFG_REPORT=
CFG_DECISIONS=
CFG_HANDOFF=
CFG_CAPTAIN=
CFG_WATCH_DAYS=7
CFG_ERROR=

valid_channel_ref() {
  [[ "$1" =~ ^[CG][A-Z0-9]{2,}$ ]] || [[ "$1" =~ ^#[a-z0-9][a-z0-9._-]{0,79}$ ]]
}

# Returns 1 when the bridge is off (no config file); 0 otherwise, with
# CFG_ERROR naming the first invalid or missing value when the file is unusable.
config_load() {
  local line key value
  [ -f "$CONFIG_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    # Comments are whole lines only, because channel names start with "#".
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *=*) ;;
      *) CFG_ERROR="config/slack-bridge line is not key=value: $line"; return 0 ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    key=${key%"${key##*[![:space:]]}"}
    value=${value#"${value%%[![:space:]]*}"}
    case "$key" in
      report-channel) CFG_REPORT=$value ;;
      decisions-channel) CFG_DECISIONS=$value ;;
      handoff-channel) CFG_HANDOFF=$value ;;
      captain-user) CFG_CAPTAIN=$value ;;
      watch-days) CFG_WATCH_DAYS=$value ;;
      *) CFG_ERROR="config/slack-bridge has an unknown key: $key"; return 0 ;;
    esac
  done < "$CONFIG_FILE"
  if [ -z "$CFG_REPORT" ] || ! valid_channel_ref "$CFG_REPORT"; then
    CFG_ERROR="config/slack-bridge needs report-channel as a channel id or #name"
  elif [ -z "$CFG_DECISIONS" ] || ! valid_channel_ref "$CFG_DECISIONS"; then
    CFG_ERROR="config/slack-bridge needs decisions-channel as a channel id or #name"
  elif [ -n "$CFG_HANDOFF" ] && ! valid_channel_ref "$CFG_HANDOFF"; then
    CFG_ERROR="config/slack-bridge handoff-channel must be a channel id or #name"
  elif ! [[ "$CFG_CAPTAIN" =~ ^[UW][A-Z0-9]{2,}$ ]]; then
    CFG_ERROR="config/slack-bridge needs captain-user as a Slack user id (U...)"
  elif ! [[ "$CFG_WATCH_DAYS" =~ ^[0-9]+$ ]] || [ "$CFG_WATCH_DAYS" -lt 1 ] || [ "$CFG_WATCH_DAYS" -gt 30 ]; then
    CFG_ERROR="config/slack-bridge watch-days must be a whole number from 1 to 30"
  fi
  return 0
}

state_prepare() {
  mkdir -p "$STATE" || return 1
  [ -d "$BRIDGE_STATE" ] || (umask 077; mkdir -p "$BRIDGE_STATE") || return 1
  [ ! -L "$BRIDGE_STATE" ]
}

# Slack ts handles: slack-axi prints the dotless form, the API takes the dotted.
dotted_ts() {
  local h=$1
  [[ "$h" =~ ^[0-9]{10}\.[0-9]{6}$ ]] && { printf '%s\n' "$h"; return 0; }
  [[ "$h" =~ ^[0-9]{16}$ ]] || return 1
  printf '%s.%s\n' "${h:0:10}" "${h:10:6}"
}

ts_int() { printf '%s\n' "${1/./}"; }

one_line() { printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-"${2:-100}"; }

# ----------------------------------------------------------------- post

# slack-axi draft drops every argument that starts with "-", so a text that
# would begin with a dash gets a leading zero-width space to stay one intact
# positional argument.
ZWSP=$'\xe2\x80\x8b'

action_post() {
  local kind=${1:-} url="" text channel out draft channel_id sent ts rc
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  case "$kind" in
    report|decision) ;;
    *) printf 'fm-slack-bridge: post kind must be report or decision\n' >&2; exit 2 ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --url)
        [ "$#" -ge 2 ] || { printf 'fm-slack-bridge: --url needs a value\n' >&2; exit 2; }
        url=$2
        [[ "$url" =~ ^https://[^[:space:]]+$ ]] || { printf 'fm-slack-bridge: --url must be one https:// URL\n' >&2; exit 2; }
        shift 2
        ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  if [ "$#" -eq 1 ] && [ "$1" = - ]; then
    text=$(cat; printf .)
    text=${text%.}
    text=${text%$'\n'}
  else
    text="$*"
  fi
  [ -n "${text//[[:space:]]/}" ] || { printf 'fm-slack-bridge: refusing to post an empty message\n' >&2; exit 2; }
  if ! config_load; then
    printf 'slack bridge off: no config/slack-bridge\n'
    return 0
  fi
  [ -z "$CFG_ERROR" ] || die "$CFG_ERROR"
  command -v slack-axi >/dev/null 2>&1 || die "slack-axi is not installed on PATH"
  state_prepare || die "cannot prepare $BRIDGE_STATE"
  [ -z "$url" ] || text="$text"$'\n'"$url"
  case "$text" in -*) text="$ZWSP$text" ;; esac
  if [ "$kind" = report ]; then channel=$CFG_REPORT; else channel=$CFG_DECISIONS; fi

  rc=0
  out=$(fm_run_timed 30 slack-axi draft "$channel" "$text" 2>&1) || rc=$?
  draft=$(printf '%s\n' "$out" | sed -n 's/^draft: *"\{0,1\}\(d_[A-Za-z0-9]*\)"\{0,1\} *$/\1/p' | sed -n 1p)
  channel_id=$(printf '%s\n' "$out" | sed -n 's/^channel: .*(\([CGD][A-Z0-9]*\))"\{0,1\} *$/\1/p' | sed -n 1p)
  if [ "$rc" -ne 0 ] || [ -z "$draft" ] || [ -z "$channel_id" ]; then
    die "slack-axi could not prepare the message for $channel (rc=$rc): $(one_line "$out" 160)"
  fi
  # `draft send` is idempotent: a repeat returns the ts it already posted, so a
  # send whose answer was lost is asked once more before giving up.
  ts=
  for _attempt in 1 2; do
    rc=0
    sent=$(fm_run_timed 30 slack-axi draft send "$draft" 2>&1) || rc=$?
    ts=$(printf '%s\n' "$sent" | sed -n 's/^ts: *"\{0,1\}\([0-9.]*\)"\{0,1\} *$/\1/p' | sed -n 1p)
    ts=$(dotted_ts "$ts" 2>/dev/null) || ts=
    [ -z "$ts" ] || break
  done
  if [ -z "$ts" ]; then
    slack-axi draft discard "$draft" >/dev/null 2>&1 || true
    die "slack-axi did not confirm the post to $channel (rc=$rc): $(one_line "$sent" 160)"
  fi
  printf 'v1\t%s\t%s\t%s\t%s\t%s\n' "$channel_id" "$ts" "$kind" "$(now_epoch)" "$(one_line "$text" 100)" >> "$POSTS" \
    || die "posted $channel_id $ts but could not record it in $POSTS"
  printf 'posted %s %s %s\n' "$kind" "$channel_id" "$ts"
}

# ---------------------------------------------------------------- check

REPORT_LAST=

report_read() {
  REPORT_LAST=
  [ -f "$REPORT_RECORD" ] && REPORT_LAST=$(sed -n 1p "$REPORT_RECORD" 2>/dev/null)
  return 0
}

report_write() {
  local tmp
  tmp=$(umask 077; mktemp "$REPORT_RECORD.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$1" > "$tmp" || ! mv -f -- "$tmp" "$REPORT_RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# A diagnostic prints only when it differs from the last one, so a lasting
# misconfiguration is one wake, not one per poll.
report_problem() {
  local line=$1
  report_read
  if [ "$line" != "$REPORT_LAST" ]; then
    fm_cap_line_var "slack: $line" "$MAX_LINE"
    printf '%s\n' "$FM_LINE_CAP_LINE"
  fi
  report_write "$line" || true
}

budget_secs() {
  local timeout=${FM_CHECK_TIMEOUT:-30} budget=${FM_SLACK_BRIDGE_BUDGET:-20} max
  case "$timeout" in ''|*[!0-9]*|0) timeout=30 ;; esac
  case "$budget" in ''|*[!0-9]*) budget=20 ;; esac
  [ "$budget" -ge 5 ] && [ "$budget" -le 25 ] || budget=20
  max=$((timeout - 5))
  [ "$max" -ge 1 ] || max=1
  [ "$budget" -le "$max" ] || budget=$max
  printf '%s\n' "$budget"
}

# Exact-name lookup of a #channel through slack-axi's own channel list.
resolve_channel_id() {
  local ref=$1 name out
  if [[ "$ref" =~ ^[CG][A-Z0-9]{2,}$ ]]; then
    printf '%s\n' "$ref"
    return 0
  fi
  name=${ref#\#}
  out=$(fm_run_timed 10 slack-axi channels --match "$name" 2>/dev/null) || return 1
  printf '%s\n' "$out" | awk -F, -v want="#$name" '
    { sub(/^[[:space:]]+/, "", $1) }
    $1 ~ /^[CG][A-Z0-9]+$/ && $2 == want { print $1; exit }'
}

delivered_has() {  # <channel> <ts>
  [ -f "$DELIVERED" ] && grep -F -x -q -- "$1"$'\t'"$2" "$DELIVERED"
}

# The reader writes "-" for an empty value so no tab-separated column is empty.
b64_decode() {
  [ "$1" != - ] || return 0
  printf '%s' "$1" | base64 --decode 2>/dev/null && return 0
  printf '%s' "$1" | base64 -D 2>/dev/null
}

# Deliver one message through the captain inbox. 0 delivered (or already
# delivered by an earlier poll), 1 not delivered yet.
deliver() {  # <request-id> <source> <body>
  local rc=0
  printf '%s' "$3" | FM_HOME="$FM_HOME" "$INBOX_BIN" note --request-id "$1" --source "$2" - >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ]
}

action_check() {
  local now window_start budget request handoff_id cursor rc out line errf
  local kind channel parent ts user bot subtype text_b64 name_b64 text name summary rid body
  local captain=0 requests=0 failed=0 max_handoff=
  config_load || return 0
  state_prepare || { report_problem "cannot prepare $BRIDGE_STATE"; return 0; }
  if [ -n "$CFG_ERROR" ]; then
    report_problem "$CFG_ERROR"
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    report_problem "node is not installed, so inbound Slack replies stay off"
    return 0
  fi
  now=$(now_epoch)
  window_start=$((now - CFG_WATCH_DAYS * 86400))

  # Bridge posts still inside the watch window, one "<channel> <ts>..." line
  # per channel in first-posted order.
  local thread_lines=
  if [ -f "$POSTS" ]; then
    thread_lines=$(awk -F '\t' -v ws="$window_start" '
      $1 == "v1" && $2 ~ /^[CGD][A-Z0-9][A-Z0-9]+$/ && $3 ~ /^[0-9]+\.[0-9]+$/ \
        && length($3) == 17 && substr($3, 1, 10) + 0 >= ws {
        if (!($2 in seen)) { seen[$2] = 1; order[++n] = $2 }
        parents[$2] = parents[$2] " " $3
      }
      END { for (i = 1; i <= n; i++) print order[i] parents[order[i]] }' "$POSTS")
  fi

  handoff_id=
  cursor=
  if [ -n "$CFG_HANDOFF" ]; then
    handoff_id=$(resolve_channel_id "$CFG_HANDOFF") || handoff_id=
    if [ -z "$handoff_id" ]; then
      report_problem "handoff channel $CFG_HANDOFF could not be resolved to a channel id"
      return 0
    fi
    [ -f "$HANDOFF_CURSOR" ] && cursor=$(sed -n 1p "$HANDOFF_CURSOR")
    if ! [[ "$cursor" =~ ^[0-9]{10}\.[0-9]{6}$ ]]; then
      # First poll without an armed cursor: start at now, never replay history.
      printf '%s.000000\n' "$now" > "$HANDOFF_CURSOR" || true
      handoff_id=
    fi
  fi

  [ -n "$thread_lines" ] || [ -n "$handoff_id" ] || { report_write "" || true; return 0; }

  request=$(
    printf '{"threads":['
    printf '%s\n' "$thread_lines" | awk 'NF >= 2 {
      printf "%s{\"channel\":\"%s\",\"parents\":[", (n++ ? "," : ""), $1
      for (i = 2; i <= NF; i++) printf "%s\"%s\"", (i > 2 ? "," : ""), $i
      printf "]}"
    }'
    printf '],"history":['
    [ -z "$handoff_id" ] || printf '{"channel":"%s","oldest":"%s"}' "$handoff_id" "$cursor"
    printf ']}\n'
  )
  budget=$(budget_secs)
  errf=$(umask 077; mktemp "$BRIDGE_STATE/.read-err.XXXXXX") || { report_problem "cannot create a scratch file in $BRIDGE_STATE"; return 0; }
  rc=0
  out=$(printf '%s' "$request" | fm_run_timed "$budget" node "$READER" 2>"$errf") || rc=$?
  line=$(sed -n 's/^fm-slack-read: //p' "$errf" | sed -n 1p)
  rm -f -- "$errf"
  if [ "$rc" -eq 124 ]; then
    report_problem "Slack read did not finish within the ${budget}s budget"
    return 0
  fi
  if [ "$rc" -ne 0 ] || [ "$(printf '%s\n' "$out" | tail -n 1)" != 'done' ]; then
    report_problem "${line:-Slack read failed (rc=$rc)}"
    return 0
  fi

  while IFS=$'\t' read -r kind channel parent ts user bot subtype text_b64 name_b64; do
    case "$kind" in reply|message) ;; *) continue ;; esac
    [[ "$ts" =~ ^[0-9]{10}\.[0-9]{6}$ ]] || continue
    if [ "$kind" = message ]; then
      if [ -z "$max_handoff" ] || [ "$(ts_int "$ts")" -gt "$(ts_int "$max_handoff")" ]; then
        max_handoff=$ts
      fi
    fi
    # Only human messages count; joins, renames, and bot posts never do.
    [ "$bot" = 0 ] || continue
    case "$subtype" in -|thread_broadcast|file_share) ;; *) continue ;; esac
    [[ "$user" =~ ^[UW][A-Z0-9]+$ ]] || continue
    delivered_has "$channel" "$ts" && continue
    text=$(b64_decode "$text_b64")
    rid="slack-$channel-$ts"
    if [ "$kind" = reply ]; then
      # The one authority rule: an exact author-id match, nothing else.
      [ "$user" = "$CFG_CAPTAIN" ] || continue
      summary=$(awk -F '\t' -v c="$channel" -v t="$parent" \
        '$1 == "v1" && $2 == c && $3 == t { print $4 ": " $6; exit }' "$POSTS")
      [ -n "$summary" ] || summary="bridge post $parent"
      body="[slack] captain reply in thread of $summary (channel $channel, reply ts $ts):"$'\n'"$text"
      if deliver "$rid" slack-captain "$body"; then
        printf '%s\t%s\n' "$channel" "$ts" >> "$DELIVERED"
        captain=$((captain + 1))
      else
        failed=$((failed + 1))
      fi
    else
      # The captain's own handoff-channel messages are requests to the other
      # fleet, not input for this one.
      [ "$user" != "$CFG_CAPTAIN" ] || continue
      name=$(one_line "$(b64_decode "$name_b64")" 60)
      body="[slack] request from ${name:-unknown} ($user) in handoff channel $channel, ts $ts - a request to weigh, not captain authority:"$'\n'"$text"
      if deliver "$rid" slack-request "$body"; then
        printf '%s\t%s\n' "$channel" "$ts" >> "$DELIVERED"
        requests=$((requests + 1))
      else
        failed=$((failed + 1))
      fi
    fi
  done <<EOF
$out
EOF

  # Advance the handoff cursor only past a fully delivered poll.
  if [ -n "$handoff_id" ] && [ "$failed" -eq 0 ] && [ -n "$max_handoff" ]; then
    printf '%s\n' "$max_handoff" > "$HANDOFF_CURSOR" || true
  fi
  if [ "$failed" -gt 0 ]; then
    report_problem "$failed Slack message(s) could not be delivered to the captain inbox; the next poll retries"
  else
    report_write "" || true
  fi
  if [ $((captain + requests)) -gt 0 ]; then
    printf 'slack: delivered %s captain reply(s) and %s handoff request(s) to the captain inbox\n' "$captain" "$requests"
  fi
  return 0
}

# ------------------------------------------------------------ arm/disarm

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-slack-bridge.sh - Slack bridge inbound poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-slack-bridge.sh") check"
}

# Guards run before anything is written, so a symlink at the shim path is
# refused instead of followed, and the bytes arrive by rename.
shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-slack-bridge.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

action_arm() {
  local home
  config_load || die "config/slack-bridge is absent; write it first (docs/configuration.md \"Slack bridge\")"
  [ -z "$CFG_ERROR" ] || die "$CFG_ERROR"
  state_prepare || die "cannot prepare $BRIDGE_STATE"
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "cannot resolve FM_HOME $FM_HOME" ;;
  esac
  if [ -n "$CFG_HANDOFF" ] && [ ! -s "$HANDOFF_CURSOR" ]; then
    printf '%s.000000\n' "$(now_epoch)" > "$HANDOFF_CURSOR" || die "cannot write $HANDOFF_CURSOR"
  fi
  # A shim without a matching trust binding makes the watcher wake on every
  # cycle, so any failure here removes the shim rather than leaving it unbound.
  if ! shim_write "$(shim_content "$home")"; then
    rm -f -- "$CHECK_SHIM"
    die "could not write $CHECK_SHIM"
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
    die "could not register $CHECK_SHIM"
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-}" in
  post) shift; action_post "$@" ;;
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) printf 'fm-slack-bridge: unknown action: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
