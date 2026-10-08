#!/usr/bin/env bash
# fm-slack-bridge.sh - the captain's Slack channel to and from this firstmate home.
#
# Usage:
#   fm-slack-bridge.sh post <kind> --title <line> [--project <name>] [--context <line>]...
#                      [--option <key>=<text>]... [--recommend <key>]
#                      [--url <https-url>]
#   fm-slack-bridge.sh post report|decision [--url <https-url>] [--] <text>...
#   fm-slack-bridge.sh post report|decision [--url <https-url>] -   (text from stdin)
#   fm-slack-bridge.sh check
#   fm-slack-bridge.sh arm
#   fm-slack-bridge.sh disarm
#   fm-slack-bridge.sh send-reply <note-id>
#   fm-slack-bridge.sh verify    (manual setup only; never run by the watcher)
#   fm-slack-bridge.sh manifest [--name <app-name>] [--private-channels] [--link]
#   fm-slack-bridge.sh --help
#
# Two transports. Without `bot-keychain-service` in the config the bridge posts
# and reads as whichever account slack-axi is logged in as. With it, the home
# has its own Slack app (for example "Yelen's Firstmate"): bin/fm-slack-bot.mjs
# posts and reads as that bot, with the bot token read from the macOS Keychain
# item of that service name, and the person can also DM the bot.
#
# Out: `post` sends one captain-facing message to the decisions channel for
# `decision` (one decision; options require a recommendation), or to the report channel
# for `ready` (a PR ready for review or a merge ask), `merged` (a merge result),
# and `report` (anything else), through slack-axi (draft, then `draft send`) or
# the bot. The structured form (--title and its companions) is what firstmate
# sends: one item per post, laid out by bin/fm-slack-render.mjs, which owns the
# layouts and their limits (at most two --context lines). The bot posts it as
# Block Kit with a plain-text fallback; slack-axi posts the fallback, which is
# Slack mrkdwn with the same layout. The free-text form (report or decision
# with positional or stdin text) stays for old callers. --url becomes a
# labelled link (GitHub PRs as "PR #<n>"), never a raw URL.
# `post` appends the posted channel id and message ts
# to state/slack-bridge/posts, which is the only set of threads `check` reads.
# Every post is top-level. Without a bot the bridge never replies inside a
# thread, because it posts as the logged-in account, and that account's thread
# replies are what counts as captain input; a bot's own messages never count.
#
# In: `check` reads the replies in the threads of bridge posts from the last
# `watch-days` days, plus new top-level messages in the handoff channel, through
# bin/fm-slack-read.mjs (or the bot), which returns each author's Slack user id.
# With a bot it also reads new top-level messages in the bot's DM with
# `captain-user`, and new messages in the report and decisions channels that
# mention the bot (`@bot ...`), top-level or in a thread, with that mention
# removed from the delivered text; untagged channel chat is never read as
# input. A thread reply, DM, or mention becomes captain input only when its
# author id equals `captain-user` exactly; anyone else's message, and every bot
# message, including another person's bot, is ignored. A handoff-channel message from
# anyone but the captain becomes a request note that names its sender and says
# it is not captain authority. Each accepted message is delivered exactly once
# through `fm-inbox.sh note --request-id slack-<channel>-<ts>` (source
# slack-captain or slack-request), which writes the durable note and its single
# `check` wake; a replay of the same request id never adds a second note or
# wake, so a crash between delivery and the local delivered record is healed by
# the next poll rather than duplicated. A poll that delivered anything prints
# one line so the watcher wakes firstmate; a failing poll prints one line only
# when its diagnostic changed; otherwise `check` is silent. Each delivered
# captain message also records its reply route (channel and thread) in
# state/slack-bridge/routes.
#
# Back: `send-reply <note-id>` posts the reply that `fm-inbox.sh reply` recorded
# for a slack-captain note back through the bot, into the same thread, into the
# DM for a DM note, or into a thread under the captain's message for a
# top-level mention, exactly once (state/slack-bridge/replied).
# `fm-inbox.sh reply` runs it itself; without a bot it does nothing and prints
# nothing, so the reply stays local as before.
#
# `verify` is only for a human to invoke explicitly during setup; `check`,
# `arm`, the watcher, and other automation never call it. It checks the token,
# posts one clearly labeled setup test to each configured channel, and DMs
# `captain-user` a labeled setup test to answer; the posts can be ignored or
# deleted. `manifest` prints the Slack app manifest a person pastes into "Create
# an app -> From a manifest", with the app and bot named by --name and only the
# scopes the bot transport uses; `manifest --link` prints the same manifest as
# one https://api.slack.com/apps?new_app=1&manifest_json=... link that opens
# Slack's create-app dialog prefilled.
#
# Slack text is input like a typed captain message and nothing more: it never
# bypasses merge guards, holds, or the destructive and security boundaries.
#
# `arm` writes state/slack-bridge.check.sh and binds its bytes with
# fm-check-register.sh, so the watcher runs `check` on its slow-check cadence,
# and starts the handoff channel, and with a bot the DM and channel mentions, at
# "now" so old history is not replayed.
# `disarm` removes the shim and its trust binding and keeps the records.
#
# The bridge is off while config/slack-bridge is absent: `post` prints one
# `slack bridge off` line and exits 0, and `check` is silent. docs/configuration.md
# "Slack bridge" owns the config schema. The bridge never prints, stores, or
# logs a token: the slack-axi transport never reads one, and the bot transport
# reads the bot token from the Keychain only inside bin/fm-slack-bot.mjs.
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
DM_CURSOR="$BRIDGE_STATE/dm-cursor"
MENTION_CURSOR="$BRIDGE_STATE/mention-cursor"
ROUTES="$BRIDGE_STATE/routes"
REPLIED="$BRIDGE_STATE/replied"
INBOX_DIR="$STATE/inbox"
REPORT_RECORD="$BRIDGE_STATE/last-report"
SEND_REPLY_LOCK=
CHECK_ID=slack-bridge
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
CHECK_EVERY="$STATE/$CHECK_ID.check-every"
READER="$SCRIPT_DIR/fm-slack-read.mjs"
BOT="$SCRIPT_DIR/fm-slack-bot.mjs"
RENDERER="$SCRIPT_DIR/fm-slack-render.mjs"
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
  fm-slack-bridge.sh post <kind> --title <line> [--project <name>] [--context <line>]...
                     [--option <key>=<text>]... [--recommend <key>]
                     [--url <https-url>]
                               post one item laid out for scanning; kind is decision (decisions
                               channel), ready (PR ready or merge ask), merged, or report;
                               decisions with options need --recommend; at most two --context lines
  fm-slack-bridge.sh post report|decision [--url <https-url>] [--] <text>...
                               free-text form for old callers (- reads the text from stdin)
  fm-slack-bridge.sh check     deliver new captain thread replies, bot DMs and mentions, and handoff requests to the captain inbox
  fm-slack-bridge.sh arm       write and register state/slack-bridge.check.sh
  fm-slack-bridge.sh disarm    remove the check shim and its trust binding
  fm-slack-bridge.sh send-reply <note-id>   post the recorded reply to a slack-captain note back through the bot
  fm-slack-bridge.sh verify    manual setup only; posts labeled setup tests (never run by automation)
  fm-slack-bridge.sh manifest [--name <app-name>] [--private-channels] [--link]
                               print the Slack app manifest for a bot, or with --link a prefilled create-app link
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
CFG_BOT=
CFG_WATCH_DAYS=7
CFG_POLL_SECONDS=
CFG_POLL_SEEN=0
CFG_ERROR=

valid_channel_id() {
  [[ "$1" =~ ^[CG][A-Z0-9]{2,}$ ]]
}

valid_channel_ref() {
  valid_channel_id "$1" || [[ "$1" =~ ^#[a-z0-9][a-z0-9._-]{0,79}$ ]]
}

# Returns 1 when the bridge is off (no config file); 0 otherwise, with
# CFG_ERROR naming the first invalid or missing value when the file is unusable.
config_load() {
  local line key value
  [ -f "$CONFIG_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    # Comments are whole lines only, because channel names start with "#".
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *=*) ;;
      *) CFG_ERROR="config/slack-bridge line is not key=value: $line"; return 0 ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    key=${key%"${key##*[![:space:]]}"}
    case "$key" in
      report-channel) value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}; CFG_REPORT=$value ;;
      decisions-channel) value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}; CFG_DECISIONS=$value ;;
      handoff-channel) value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}; CFG_HANDOFF=$value ;;
      captain-user) value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}; CFG_CAPTAIN=$value ;;
      bot-keychain-service)
        value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}
        [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
          || { CFG_ERROR="config/slack-bridge bot-keychain-service must be a Keychain service name (letters, digits, dot, dash, underscore)"; return 0; }
        CFG_BOT=$value
        ;;
      watch-days) value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}; CFG_WATCH_DAYS=$value ;;
      poll-seconds)
        [ "$CFG_POLL_SEEN" -eq 0 ] || { CFG_ERROR="config/slack-bridge poll-seconds must appear only once"; return 0; }
        CFG_POLL_SEEN=1
        CFG_POLL_SECONDS=$value
        ;;
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
  elif [ -n "$CFG_BOT" ] && { ! valid_channel_id "$CFG_REPORT" || ! valid_channel_id "$CFG_DECISIONS" \
    || { [ -n "$CFG_HANDOFF" ] && ! valid_channel_id "$CFG_HANDOFF"; }; }; then
    CFG_ERROR="config/slack-bridge with a bot needs every channel as a channel id (C...), because the bot has no scope to look up #names"
  elif ! [[ "$CFG_WATCH_DAYS" =~ ^[0-9]+$ ]] || [ "$CFG_WATCH_DAYS" -lt 1 ] || [ "$CFG_WATCH_DAYS" -gt 30 ]; then
    CFG_ERROR="config/slack-bridge watch-days must be a whole number from 1 to 30"
  elif [ "$CFG_POLL_SEEN" -eq 1 ] \
    && { ! [[ "$CFG_POLL_SECONDS" =~ ^[1-9][0-9]*$ ]] \
      || [ "${#CFG_POLL_SECONDS}" -gt 4 ] \
      || [ "$CFG_POLL_SECONDS" -lt 10 ] || [ "$CFG_POLL_SECONDS" -gt 3600 ]; }; then
    CFG_ERROR="config/slack-bridge poll-seconds must be a whole number from 10 to 3600 without padding"
  fi
  return 0
}

state_prepare() {
  mkdir -p "$STATE" || return 1
  [ -d "$BRIDGE_STATE" ] || (umask 077; mkdir -p "$BRIDGE_STATE") || return 1
  [ ! -L "$BRIDGE_STATE" ]
}

check_every_sync() {
  local tmp
  if [ "$CFG_POLL_SEEN" -eq 0 ]; then
    rm -f -- "$CHECK_EVERY"
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.slack-bridge.check-every.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$CFG_POLL_SECONDS" > "$tmp" || ! mv -f -- "$tmp" "$CHECK_EVERY"; then
    rm -f -- "$tmp"
    return 1
  fi
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

# ------------------------------------------------------------------ bot

b64_line() { printf '%s' "$1" | base64 | tr -d '\n'; }

# Run one bin/fm-slack-bot.mjs action on a JSON request. 0 with its stdout in
# BOT_OUT; otherwise 1 with the helper's one-line reason in BOT_ERROR, which
# never carries a token because the helper reports bare Slack error codes only.
BOT_OUT=
BOT_ERROR=
bot_run() {  # <seconds> <action> <request-json>
  local errf rc=0
  BOT_OUT=
  BOT_ERROR=
  command -v node >/dev/null 2>&1 || { BOT_ERROR="node is not installed, so the Slack bot transport is off"; return 1; }
  errf=$(umask 077; mktemp "$BRIDGE_STATE/.bot-err.XXXXXX" 2>/dev/null) \
    || { BOT_ERROR="cannot create a scratch file in $BRIDGE_STATE"; return 1; }
  BOT_OUT=$(printf '%s' "$3" | fm_run_timed "$1" node "$BOT" "$2" 2>"$errf") || rc=$?
  BOT_ERROR=$(sed -n 's/^fm-slack-bot: //p' "$errf" | sed -n 1p)
  rm -f -- "$errf"
  if [ "$rc" -eq 124 ]; then
    BOT_ERROR="the Slack bot call did not finish within ${1}s"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    BOT_ERROR=${BOT_ERROR:-the Slack bot call failed (rc=$rc)}
    return 1
  fi
  BOT_ERROR=
  return 0
}

# Post as the bot.
BOT_CHANNEL=
BOT_TS=
bot_post() {  # <channel-id> <text> [thread-ts] [blocks-b64]
  local thread=${3:-} blocks=${4:--} request posted
  BOT_CHANNEL=
  BOT_TS=
  request="{\"keychain\":\"$CFG_BOT\",\"channel\":\"$1\",\"text_b64\":\"$(b64_line "$2")\""
  [ -z "$thread" ] || request="$request,\"thread\":\"$thread\""
  [ "$blocks" = - ] || request="$request,\"blocks_b64\":\"$blocks\""
  bot_run 30 post "$request}" || return 1
  posted=$(printf '%s\n' "$BOT_OUT" | sed -n 's/^posted \([CGD][A-Z0-9]*\) \([0-9]\{10\}\.[0-9]\{6\}\)$/\1 \2/p' | sed -n 1p)
  if [ -z "$posted" ]; then
    BOT_ERROR="the Slack bot did not confirm the post"
    return 1
  fi
  BOT_CHANNEL=${posted%% *}
  BOT_TS=${posted#* }
}

record_post() {  # <channel-id> <ts> <kind> <text>
  printf 'v1\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(now_epoch)" "$(one_line "$4" 100)" >> "$POSTS"
}

# ----------------------------------------------------------------- post

# slack-axi draft drops every argument that starts with "-", so a text that
# would begin with a dash gets a leading zero-width space to stay one intact
# positional argument.
ZWSP=$'\xe2\x80\x8b'

# Render one post through bin/fm-slack-render.mjs, the single owner of the
# layouts. 0 with RENDER_TEXT (decoded) and RENDER_BLOCKS_B64 ("-" for none);
# otherwise exits 2 with the renderer's reason.
RENDER_TEXT=
RENDER_BLOCKS_B64=
render_post() {  # <spec-json>
  local out rc=0 text_b64
  command -v node >/dev/null 2>&1 || die "node is not installed, so posts cannot be rendered"
  out=$(printf '%s' "$1" | node "$RENDERER" lines 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | sed -n 's/^fm-slack-render: /fm-slack-bridge: /p' | sed -n 1p >&2
    exit 2
  fi
  text_b64=$(printf '%s\n' "$out" | sed -n 's/^text \([A-Za-z0-9+/=]*\)$/\1/p' | sed -n 1p)
  RENDER_BLOCKS_B64=$(printf '%s\n' "$out" | sed -n 's/^blocks \([A-Za-z0-9+/=-]*\)$/\1/p' | sed -n 1p)
  [ -n "$text_b64" ] && [ -n "$RENDER_BLOCKS_B64" ] || die "the renderer returned no message"
  RENDER_TEXT=$(b64_decode "$text_b64"; printf .)
  RENDER_TEXT=${RENDER_TEXT%.}
}

json_b64() { printf '"%s"' "$(b64_line "$1")"; }

action_post() {
  local kind=${1:-} url="" title="" project="" text="" recommend=""
  local spec summary channel out draft channel_id sent ts rc item key
  local -a contexts=() option_keys=() option_texts=()
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  case "$kind" in
    report|decision|ready|merged) ;;
    *) printf 'fm-slack-bridge: post kind must be report, decision, ready, or merged\n' >&2; exit 2 ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --url|--title|--project|--context|--option|--recommend)
        [ "$#" -ge 2 ] || { printf 'fm-slack-bridge: %s needs a value\n' "$1" >&2; exit 2; }
        case "$1" in
          --url)
            url=$2
            [[ "$url" =~ ^https://[^[:space:]]+$ ]] || { printf 'fm-slack-bridge: --url must be one https:// URL\n' >&2; exit 2; }
            ;;
          --title) title=$2 ;;
          --project) project=$2 ;;
          --context) contexts+=("$2") ;;
          --option)
            case "$2" in
              *=*) ;;
              *) printf 'fm-slack-bridge: --option must be <key>=<text>\n' >&2; exit 2 ;;
            esac
            key=${2%%=*}
            [[ "$key" =~ ^[a-z0-9][a-z0-9-]{0,15}$ ]] \
              || { printf 'fm-slack-bridge: an --option key must be 1-16 lowercase letters, digits, or dashes\n' >&2; exit 2; }
            option_keys+=("$key")
            option_texts+=("${2#*=}")
            ;;
          --recommend)
            recommend=$2
            [[ "$recommend" =~ ^[a-z0-9][a-z0-9-]{0,15}$ ]] \
              || { printf 'fm-slack-bridge: --recommend must name an option key\n' >&2; exit 2; }
            ;;
        esac
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
  # The structured form is any post with a title; everything else is the
  # free-text form old callers use.
  if [ -n "$title" ]; then
    [ -z "${text//[[:space:]]/}" ] \
      || { printf 'fm-slack-bridge: a post with --title takes no free text; put details in --context\n' >&2; exit 2; }
    spec="{\"kind\":\"$kind\",\"title_b64\":$(json_b64 "$title")"
    [ -z "$project" ] || spec="$spec,\"project_b64\":$(json_b64 "$project")"
    if [ "${#contexts[@]}" -gt 0 ]; then
      spec="$spec,\"context_b64\":["
      for item in "${!contexts[@]}"; do
        [ "$item" -eq 0 ] || spec="$spec,"
        spec="$spec$(json_b64 "${contexts[$item]}")"
      done
      spec="$spec]"
    fi
    if [ "$kind" = decision ] && [ "${#option_keys[@]}" -gt 0 ] && [ -z "$recommend" ]; then
      printf 'fm-slack-bridge: a decision with options needs --recommend\n' >&2
      exit 2
    fi
    if [ "${#option_keys[@]}" -gt 0 ]; then
      spec="$spec,\"options\":["
      for item in "${!option_keys[@]}"; do
        [ "$item" -eq 0 ] || spec="$spec,"
        spec="$spec{\"key\":\"${option_keys[$item]}\",\"text_b64\":$(json_b64 "${option_texts[$item]}")}"
      done
      spec="$spec]"
    fi
    [ -z "$recommend" ] || spec="$spec,\"recommend\":\"$recommend\""
  else
    case "$kind" in
      ready|merged) printf 'fm-slack-bridge: a %s post needs --title\n' "$kind" >&2; exit 2 ;;
    esac
    [ -z "$project" ] && [ "${#contexts[@]}" -eq 0 ] && [ "${#option_keys[@]}" -eq 0 ] && [ -z "$recommend" ] \
      || { printf 'fm-slack-bridge: --project, --context, --option, and --recommend need --title\n' >&2; exit 2; }
    [ -n "${text//[[:space:]]/}" ] || { printf 'fm-slack-bridge: refusing to post an empty message\n' >&2; exit 2; }
    spec="{\"kind\":\"$kind\",\"text_b64\":$(json_b64 "$text")"
  fi
  # The posts record names a structured post by project and title, which is
  # how a delivered thread reply says what it answers.
  if [ -n "$title" ]; then summary="${project:+$project: }$title"; else summary=$text; fi
  [ -z "$url" ] || spec="$spec,\"url_b64\":$(json_b64 "$url")"
  spec="$spec}"
  if ! config_load; then
    printf 'slack bridge off: no config/slack-bridge\n'
    return 0
  fi
  [ -z "$CFG_ERROR" ] || die "$CFG_ERROR"
  [ -n "$CFG_BOT" ] || command -v slack-axi >/dev/null 2>&1 || die "slack-axi is not installed on PATH"
  state_prepare || die "cannot prepare $BRIDGE_STATE"
  render_post "$spec"
  text=$RENDER_TEXT
  if [ "$kind" = decision ]; then channel=$CFG_DECISIONS; else channel=$CFG_REPORT; fi
  if [ -n "$CFG_BOT" ]; then
    bot_post "$channel" "$text" "" "$RENDER_BLOCKS_B64" || die "the Slack bot could not post to $channel: $BOT_ERROR"
    record_post "$BOT_CHANNEL" "$BOT_TS" "$kind" "$summary" \
      || die "posted $BOT_CHANNEL $BOT_TS but could not record it in $POSTS"
    printf 'posted %s %s %s\n' "$kind" "$BOT_CHANNEL" "$BOT_TS"
    return 0
  fi
  # slack-axi posts text only, so it sends the renderer's mrkdwn fallback,
  # which carries the same layout.
  case "$text" in -*) text="$ZWSP$text" ;; esac

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
  record_post "$channel_id" "$ts" "$kind" "$summary" \
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

# Remember where a delivered captain message came from, so `send-reply` can
# answer in the same DM or thread. One line per request id.
route_record() {  # <request-id> <channel> <thread-ts|->
  if [ -f "$ROUTES" ] && awk -F '\t' -v r="$1" '$1 == "v1" && $2 == r { f = 1 } END { exit !f }' "$ROUTES"; then
    return 0
  fi
  printf 'v1\t%s\t%s\t%s\n' "$1" "$2" "$3" >> "$ROUTES"
}

# A captain message is routed first, then delivered, so a delivered note
# always has its reply route. 0 delivered, 1 not delivered yet.
deliver_captain() {  # <request-id> <channel> <thread-ts|-> <body>
  route_record "$1" "$2" "$3" || return 1
  deliver "$1" slack-captain "$4"
}

action_check() {
  local now window_start budget request handoff_id cursor dm_cursor rc out line errf reader prefix
  local kind channel parent ts user bot subtype text_b64 name_b64 text name summary rid body
  local captain=0 requests=0 failed=0 max_handoff='' max_dm='' mention_cursor mention_mark='' mention_channels
  config_load || { rm -f -- "$CHECK_EVERY"; return 0; }
  state_prepare || { report_problem "cannot prepare $BRIDGE_STATE"; return 0; }
  if [ -n "$CFG_ERROR" ]; then
    rm -f -- "$CHECK_EVERY"
    report_problem "$CFG_ERROR"
    return 0
  fi
  check_every_sync || { report_problem "cannot update $CHECK_EVERY"; return 0; }
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

  dm_cursor=
  mention_cursor=
  if [ -n "$CFG_BOT" ]; then
    [ -f "$DM_CURSOR" ] && dm_cursor=$(sed -n 1p "$DM_CURSOR")
    if ! [[ "$dm_cursor" =~ ^[0-9]{10}\.[0-9]{6}$ ]]; then
      # First poll without an armed DM cursor: start at now, never replay history.
      printf '%s.000000\n' "$now" > "$DM_CURSOR" || true
      dm_cursor=
    fi
    [ -f "$MENTION_CURSOR" ] && mention_cursor=$(sed -n 1p "$MENTION_CURSOR")
    if ! [[ "$mention_cursor" =~ ^[0-9]{10}\.[0-9]{6}$ ]]; then
      # Mentions start at now the same way.
      printf '%s.000000\n' "$now" > "$MENTION_CURSOR" || true
      mention_cursor=
    fi
  fi
  mention_channels=$CFG_REPORT
  [ "$CFG_DECISIONS" = "$CFG_REPORT" ] || mention_channels="$mention_channels $CFG_DECISIONS"

  [ -n "$thread_lines" ] || [ -n "$handoff_id" ] || [ -n "$dm_cursor" ] || [ -n "$mention_cursor" ] \
    || { report_write "" || true; return 0; }

  request=$(
    printf '{"threads":['
    printf '%s\n' "$thread_lines" | awk 'NF >= 2 {
      printf "%s{\"channel\":\"%s\",\"parents\":[", (n++ ? "," : ""), $1
      for (i = 2; i <= NF; i++) printf "%s\"%s\"", (i > 2 ? "," : ""), $i
      printf "]}"
    }'
    printf '],"history":['
    [ -z "$handoff_id" ] || printf '{"channel":"%s","oldest":"%s"}' "$handoff_id" "$cursor"
    printf ']'
    if [ -n "$CFG_BOT" ]; then
      printf ',"keychain":"%s"' "$CFG_BOT"
      [ -z "$dm_cursor" ] || printf ',"dm":{"user":"%s","oldest":"%s"}' "$CFG_CAPTAIN" "$dm_cursor"
      # Threads under any message from the watch window are read for mentions.
      [ -z "$mention_cursor" ] || printf ',"mentions":{"channels":["%s"],"oldest":"%s","since":"%s.000000"}' \
        "${mention_channels// /\",\"}" "$mention_cursor" "$window_start"
    fi
    printf '}\n'
  )
  if [ -n "$CFG_BOT" ]; then
    reader=("$BOT" read)
    prefix=fm-slack-bot
  else
    reader=("$READER")
    prefix=fm-slack-read
  fi
  budget=$(budget_secs)
  errf=$(umask 077; mktemp "$BRIDGE_STATE/.read-err.XXXXXX") || { report_problem "cannot create a scratch file in $BRIDGE_STATE"; return 0; }
  rc=0
  out=$(printf '%s' "$request" | fm_run_timed "$budget" node "${reader[@]}" 2>"$errf") || rc=$?
  line=$(sed -n "s/^$prefix: //p" "$errf" | sed -n 1p)
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
    if [ "$kind" = mark ]; then
      [[ "$channel" =~ ^[0-9]{10}\.[0-9]{6}$ ]] && mention_mark=$channel
      continue
    fi
    case "$kind" in reply|message|dm|mention) ;; *) continue ;; esac
    [[ "$ts" =~ ^[0-9]{10}\.[0-9]{6}$ ]] || continue
    [[ "$channel" =~ ^[CGD][A-Z0-9]{2,}$ ]] || continue
    if [ "$kind" = message ]; then
      if [ -z "$max_handoff" ] || [ "$(ts_int "$ts")" -gt "$(ts_int "$max_handoff")" ]; then
        max_handoff=$ts
      fi
    elif [ "$kind" = dm ]; then
      if [ -z "$max_dm" ] || [ "$(ts_int "$ts")" -gt "$(ts_int "$max_dm")" ]; then
        max_dm=$ts
      fi
    fi
    # Only human messages count; joins, renames, and bot posts (this home's
    # own bot and anyone else's) never do.
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
      if deliver_captain "$rid" "$channel" "$parent" "$body"; then
        printf '%s\t%s\n' "$channel" "$ts" >> "$DELIVERED"
        captain=$((captain + 1))
      else
        failed=$((failed + 1))
      fi
    elif [ "$kind" = mention ]; then
      [ "$user" = "$CFG_CAPTAIN" ] || continue
      [ "$parent" = - ] || [[ "$parent" =~ ^[0-9]{10}\.[0-9]{6}$ ]] || continue
      if [ "$parent" = - ]; then
        body="[slack] captain mention of this home's bot in channel $channel (ts $ts):"$'\n'"$text"
        # The answer goes into a thread under the captain's own message.
        parent=$ts
      else
        body="[slack] captain mention of this home's bot in a thread of channel $channel (thread $parent, reply ts $ts):"$'\n'"$text"
      fi
      if deliver_captain "$rid" "$channel" "$parent" "$body"; then
        printf '%s\t%s\n' "$channel" "$ts" >> "$DELIVERED"
        captain=$((captain + 1))
      else
        failed=$((failed + 1))
      fi
    elif [ "$kind" = dm ]; then
      [ "$user" = "$CFG_CAPTAIN" ] || continue
      body="[slack] captain DM to this home's bot (channel $channel, ts $ts):"$'\n'"$text"
      if deliver_captain "$rid" "$channel" - "$body"; then
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
  if [ -n "$dm_cursor" ] && [ "$failed" -eq 0 ] && [ -n "$max_dm" ]; then
    printf '%s\n' "$max_dm" > "$DM_CURSOR" || true
  fi
  if [ -n "$mention_cursor" ] && [ "$failed" -eq 0 ] && [ -n "$mention_mark" ]; then
    printf '%s\n' "$mention_mark" > "$MENTION_CURSOR" || true
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

# ---------------------------------------------------------- send-reply

note_header() {  # <note-file> <key>
  sed -n "/^--\$/q; s/^$2=//p" "$1" | sed -n 1p
}

action_send_reply() {
  local id=${1:-} note rid source route channel thread reply body done_line oldest
  [ "$#" -eq 1 ] || { printf 'fm-slack-bridge: usage: send-reply <note-id>\n' >&2; exit 2; }
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$id" != *..* ]] || { printf 'fm-slack-bridge: invalid note id\n' >&2; exit 2; }
  # Without a bot the reply stays local, exactly as before the bot existed.
  config_load || return 0
  [ -z "$CFG_ERROR" ] || die "$CFG_ERROR"
  [ -n "$CFG_BOT" ] || return 0
  state_prepare || die "cannot prepare $BRIDGE_STATE"
  if [ -f "$INBOX_DIR/$id.note" ]; then
    note=$INBOX_DIR/$id.note
  elif [ -f "$INBOX_DIR/handled/$id.note" ]; then
    note=$INBOX_DIR/handled/$id.note
  else
    die "no such note: $id"
  fi
  source=$(note_header "$note" source)
  [ "$source" = slack-captain ] || die "note $id did not come from the captain on Slack (source ${source:-unknown})"
  rid=$(note_header "$note" request_id)
  route=
  [ -f "$ROUTES" ] && route=$(awk -F '\t' -v r="$rid" '$1 == "v1" && $2 == r { print $3 "\t" $4; exit }' "$ROUTES")
  [ -n "$rid" ] && [ -n "$route" ] || die "no Slack reply route is recorded for note $id"
  channel=${route%%$'\t'*}
  thread=${route#*$'\t'}
  [[ "$channel" =~ ^[CGD][A-Z0-9]{2,}$ ]] || die "the Slack reply route for note $id is malformed"
  [ "$thread" = - ] || [[ "$thread" =~ ^[0-9]{10}\.[0-9]{6}$ ]] || die "the Slack reply route for note $id is malformed"
  if [ "$thread" = - ]; then
    thread=
    [[ "$channel" == D* ]] && [[ "$rid" =~ ^slack-${channel}-([0-9]{10}\.[0-9]{6})$ ]] \
      || die "the DM reply route for note $id is malformed"
    oldest=${BASH_REMATCH[1]}
  else
    oldest=$thread
  fi
  reply=$INBOX_DIR/.replies/$id
  [ -f "$reply" ] || die "no reply is recorded for note $id; record it with fm-inbox.sh reply"
  body=$(awk 'found { print; next } /^--$/ { found = 1 }' "$reply")
  [ -n "${body//[[:space:]]/}" ] || die "the recorded reply for note $id is empty"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  SEND_REPLY_LOCK="$BRIDGE_STATE/.send-reply-$id.lock"
  fm_lock_acquire_wait "$SEND_REPLY_LOCK" || die "could not acquire the Slack reply lock for note $id"
  trap 'fm_lock_release "$SEND_REPLY_LOCK"' EXIT
  if [ -f "$REPLIED" ]; then
    done_line=$(awk -F '\t' -v n="$id" '$1 == "v1" && $2 == n { print $3 " " $4; exit }' "$REPLIED")
    if [ -n "$done_line" ]; then
      printf 'slack: reply to %s already posted (%s)\n' "$id" "$done_line"
      return 0
    fi
  fi
  local marker="[fm-reply:$id]" found
  bot_run 30 find-reply "{\"keychain\":\"$CFG_BOT\",\"channel\":\"$channel\",\"thread\":\"${thread:--}\",\"oldest\":\"$oldest\",\"marker_b64\":\"$(b64_line "$marker")\"}" || die "the Slack bot could not check for an existing reply to $id: $BOT_ERROR"
  found=$(printf '%s\n' "$BOT_OUT" | sed -n 's/^found \([CGD][A-Z0-9]*\) \([0-9]\{10\}\.[0-9]\{6\}\)$/\1 \2/p' | sed -n 1p)
  if [ -n "$found" ]; then
    printf 'v1\t%s\t%s\t%s\n' "$id" "${found%% *}" "${found#* }" >> "$REPLIED" \
      || die "found the reply to $id but could not record it in $REPLIED"
    printf 'slack: reply to %s already posted (%s)\n' "$id" "$found"
    return 0
  fi
  bot_post "$channel" "$body $marker" "$thread" || die "the Slack bot could not post the reply to $id: $BOT_ERROR"
  printf 'v1\t%s\t%s\t%s\n' "$id" "$BOT_CHANNEL" "$BOT_TS" >> "$REPLIED" \
    || die "posted the reply to $id as $BOT_CHANNEL $BOT_TS but could not record it in $REPLIED"
  # A top-level DM answer is a new thread the captain may reply in.
  [ -n "$thread" ] || record_post "$BOT_CHANNEL" "$BOT_TS" reply "$body" || true
  printf 'slack: reply to %s posted %s %s\n' "$id" "$BOT_CHANNEL" "$BOT_TS"
}

# -------------------------------------------------------- verify/manifest

action_verify() {
  local fields bot_user team dm channel
  config_load || die "config/slack-bridge is absent; write it first (docs/configuration.md \"Slack bridge\")"
  [ -z "$CFG_ERROR" ] || die "$CFG_ERROR"
  [ -n "$CFG_BOT" ] || die "verify checks a bot, and config/slack-bridge names none (bot-keychain-service)"
  state_prepare || die "cannot prepare $BRIDGE_STATE"
  bot_run 30 verify "{\"keychain\":\"$CFG_BOT\",\"user\":\"$CFG_CAPTAIN\"}" || die "$BOT_ERROR"
  fields=$(printf '%s\n' "$BOT_OUT" | sed -n 's/^bot\t//p' | sed -n 1p)
  IFS=$'\t' read -r bot_user team dm <<EOF
$fields
EOF
  [[ "${dm:-}" =~ ^D[A-Z0-9]{2,}$ ]] || die "the Slack bot did not return a DM channel with $CFG_CAPTAIN"
  printf 'bot: %s in team %s\n' "$bot_user" "$team"
  # A DM cursor that starts now means the greeting's answer is the first new DM.
  [ -s "$DM_CURSOR" ] || printf '%s.000000\n' "$(now_epoch)" > "$DM_CURSOR" || die "cannot write $DM_CURSOR"
  for channel in "$CFG_REPORT" "$CFG_DECISIONS"; do
    bot_post "$channel" "Setup test from firstmate: bot channel check (one-time setup test; ignore or delete)." \
      || die "the Slack bot could not post to $channel: $BOT_ERROR (invite the bot to the channel)"
    printf 'posted test %s %s\n' "$BOT_CHANNEL" "$BOT_TS"
  done
  bot_post "$dm" "Setup test from firstmate: reply to this one-time setup test to confirm the DM round trip; ignore or delete afterward." \
    || die "the Slack bot could not DM $CFG_CAPTAIN: $BOT_ERROR"
  record_post "$BOT_CHANNEL" "$BOT_TS" verify "Setup test from firstmate: DM round trip" || true
  printf 'posted dm %s %s\n' "$BOT_CHANNEL" "$BOT_TS"
}

# YAML double-quoted scalar.
yaml_quote() {
  local v=${1//\\/\\\\}
  printf '"%s"' "${v//\"/\\\"}"
}

# JSON string, for a name already limited to printable characters.
json_quote() {
  local v=${1//\\/\\\\}
  printf '"%s"' "${v//\"/\\\"}"
}

# Percent-encode every byte outside the URL-safe set.
url_encode() {
  local s=$1 out='' c i
  local LC_ALL=C
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [A-Za-z0-9._~-]) out+=$c ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s\n' "$out"
}

action_manifest() {
  local name="Firstmate" private=0 link=0 bot_name json scopes
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name)
        [ "$#" -ge 2 ] || { printf 'fm-slack-bridge: --name needs a value\n' >&2; exit 2; }
        name=$2
        shift 2
        ;;
      --private-channels) private=1; shift ;;
      --link) link=1; shift ;;
      *) printf 'fm-slack-bridge: unknown manifest option: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  # Slack caps an app name at 35 characters.
  if [ "${#name}" -lt 1 ] || [ "${#name}" -gt 35 ] || [[ "$name" =~ [[:cntrl:]] ]] \
    || [ -z "${name//[[:space:]]/}" ]; then
    printf 'fm-slack-bridge: --name must be 1 to 35 printable characters\n' >&2
    exit 2
  fi
  if [ "$link" -eq 1 ]; then
    # Slack's create-app dialog takes the same manifest as JSON in the URL.
    bot_name=$(json_quote "$name")
    scopes='"chat:write","channels:history"'
    [ "$private" -eq 0 ] || scopes="$scopes"',"groups:history"'
    scopes="$scopes"',"im:history","im:write"'
    json='{"display_information":{"name":'"$bot_name"',"description":"Firstmate reports, decisions, and replies for one person'"'"'s home"},'
    json+='"features":{"app_home":{"home_tab_enabled":false,"messages_tab_enabled":true,"messages_tab_read_only_enabled":false},'
    json+='"bot_user":{"display_name":'"$bot_name"',"always_online":false}},'
    json+='"oauth_config":{"scopes":{"bot":['"$scopes"']}},'
    json+='"settings":{"org_deploy_enabled":false,"socket_mode_enabled":false,"token_rotation_enabled":false}}'
    printf 'https://api.slack.com/apps?new_app=1&manifest_json=%s\n' "$(url_encode "$json")"
    return 0
  fi
  bot_name=$(yaml_quote "$name")
  cat <<EOF
# Slack app manifest for one firstmate home's bot (bin/fm-slack-bridge.sh manifest).
# Paste into https://api.slack.com/apps -> Create New App -> From a manifest.
display_information:
  name: $bot_name
  description: "Firstmate reports, decisions, and replies for one person's home"
features:
  app_home:
    home_tab_enabled: false
    messages_tab_enabled: true
    messages_tab_read_only_enabled: false
  bot_user:
    display_name: $bot_name
    always_online: false
oauth_config:
  scopes:
    bot:
      - chat:write
      - channels:history
EOF
  [ "$private" -eq 0 ] || printf '      - groups:history\n'
  cat <<'EOF'
      - im:history
      - im:write
settings:
  org_deploy_enabled: false
  socket_mode_enabled: false
  token_rotation_enabled: false
EOF
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
  if [ -n "$CFG_ERROR" ]; then
    rm -f -- "$CHECK_EVERY"
    die "$CFG_ERROR"
  fi
  state_prepare || die "cannot prepare $BRIDGE_STATE"
  check_every_sync || die "cannot update $CHECK_EVERY"
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "cannot resolve FM_HOME $FM_HOME" ;;
  esac
  if [ -n "$CFG_HANDOFF" ] && [ ! -s "$HANDOFF_CURSOR" ]; then
    printf '%s.000000\n' "$(now_epoch)" > "$HANDOFF_CURSOR" || die "cannot write $HANDOFF_CURSOR"
  fi
  if [ -n "$CFG_BOT" ] && [ ! -s "$DM_CURSOR" ]; then
    printf '%s.000000\n' "$(now_epoch)" > "$DM_CURSOR" || die "cannot write $DM_CURSOR"
  fi
  if [ -n "$CFG_BOT" ] && [ ! -s "$MENTION_CURSOR" ]; then
    printf '%s.000000\n' "$(now_epoch)" > "$MENTION_CURSOR" || die "cannot write $MENTION_CURSOR"
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
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$CHECK_EVERY"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-}" in
  post) shift; action_post "$@" ;;
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  send-reply) shift; action_send_reply "$@" ;;
  verify) action_verify ;;
  manifest) shift; action_manifest "$@" ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) printf 'fm-slack-bridge: unknown action: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
