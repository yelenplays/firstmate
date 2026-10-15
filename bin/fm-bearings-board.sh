#!/usr/bin/env bash
# fm-bearings-board.sh - build and arm the /bearings lavish fleet board.
#
# The board is the captain-facing interactive surface of /bearings lavish: the
# shipped template (.agents/skills/bearings/assets/board-template.html) plus one
# injected fm-bearings-board.v1 JSON payload. This script owns the mechanics so
# the invoking agent's per-run work stays "compose the JSON, run build" - the
# agent never authors board UI at invocation time.
#
# Usage:
#   fm-bearings-board.sh build <data.json>
#   fm-bearings-board.sh compose <bearings-snapshot.json>
#   fm-bearings-board.sh refresh [--if-due]
#   fm-bearings-board.sh path
#
# build      Validate the payload, drop the Captain's Call cards whose subject
#            already landed, give every surviving decision card the standard
#            reconcile choice, and inject the result into a fresh copy of the
#            shipped template at the stable board path. Establish the Lavish
#            session on that board and PROVE it is live BEFORE binding and
#            arming its answer source, so a registered poll can never race a
#            session that does not exist or attach to one that has ended.
#            Bind to the keyed-answer intake (bin/fm-captain-hold.sh) ALWAYS
#            precedes arm, so the board can never produce an answer that has
#            nowhere to go (captain-hold-lifecycle's ordering rule, enforced
#            here rather than left to agent memory). Output starts with
#            `board: <path>`, then includes lavish-axi's session output and
#            the remaining status:
#              session: live | reopened
#              served: <path>
#              bound: <source-id>
#              armed: <source-id>            (first registration)
#              already-armed: <source-id>    (registration already present)
#              listening: <owner>            (only when a replacement was needed)
#            Every dropped card is named on stderr as a `dropped-landed-card:`
#            line, so a rebuild states what it removed instead of quietly
#            shrinking Captain's Call.
# compose    Print the deterministic fm-bearings-board.v1 payload for one
#            `fm-bearings-snapshot.sh --json --fields holds` document. No
#            judgment and no agent-authored copy: every live captain hold
#            becomes a freeform-answer decision card titled by its task title
#            (with the hold reason as context and a contribution PR as
#            pr_url), and Underway, Recently Landed, and Charted Next are
#            projected row by row. Action-free notices - the main-inventory and
#            return-catchup gates and an unavailable secondmate home - become
#            warning rows. Snapshot rows whose id cannot be a payload key are
#            left out rather than invented.
# refresh    The automatic path that keeps an open board live with no
#            conversation turn. It acts only on a board an earlier build
#            published and whose Lavish session is listed open; otherwise it
#            prints `skipped: <why>` and exits 0. It gathers a fresh snapshot,
#            composes it, carries over the cards the last build's agent
#            authored (a decision or credential card while its key is still an
#            open call, a merge card while its task is still underway and not
#            landed - the authored order first, so the composer's ranking
#            survives), and applies the same landed-card drop and reconcile
#            choice as build. It republishes the board file only when the
#            page it would publish differs from the board in anything but
#            `generated` (so a template upgrade also reaches an open board),
#            and never when another publication replaced the board while the
#            snapshot ran. Lavish's own file watcher then
#            reloads every open review window, so the captain never reloads.
#            refresh never opens, reopens, binds, or arms anything: build owns
#            the session and the answer path, and the watcher's ordinary
#            reconcile repairs a missing listener. Output is one line:
#            `refreshed: <path>`, `unchanged: <path>`, `superseded: <path>`,
#            or `skipped: <why>`. Concurrent refreshes collapse into one.
#            --if-due first returns `skipped: not due` unless the main home's
#            backlog, a task meta, or a task status log changed since the last
#            refresh started, or FM_BEARINGS_BOARD_MAX_AGE seconds (default
#            300) passed, which is how bin/fm-watch.sh calls it on every poll.
#            Either way it waits until FM_BEARINGS_BOARD_MIN_INTERVAL seconds
#            (default 60) passed since the last refresh started, so a busy
#            fleet never runs the snapshot back to back.
#            FM_BEARINGS_BOARD_SNAPSHOT_TIMEOUT bounds the snapshot (default
#            300 seconds).
# path       Print the stable board path for this home.
#
# THE CAPTAIN'S WIP LIMIT. Build and refresh both stamp the effective payload
# with `wip_limit`, the most items that should wait on the captain at once;
# the board shows its Captain's Call count against it and flags the board when
# the count is over. The first line of $FM_HOME/config/captain-wip-limit sets
# it (a positive integer), FM_CAPTAIN_WIP_LIMIT overrides that, and the default
# is 3. The board only shows the limit; firstmate's conversation enforces it.
#
# A LIVE SESSION IS PROVED, NEVER ASSUMED. `lavish-axi <file>` exits 0 even
# when it refuses to reopen a session the captain ended from the browser,
# reporting `status: user-ended` with the same session id, so exit status alone
# cannot tell a live board from a dead one. build requires the server's fresh
# session listing to show the canonical board open and refuses rather than
# arming an ended session. After a reopen it retires the pre-reopen source
# generation through the guarded adapter path, arms a fresh registration, and
# accepts only the replacement listener as live. A registered board with no
# live owner also gets a replacement before build returns, because
# `already-armed` is not the same fact as `listening`.
#
# CAPTAIN'S CALL HYGIENE. A decision card is dropped when its work item, PR, or
# structured artifact/version subject appears among the payload's own landed
# rows, or when `bin/fm-captain-hold.sh open` reports the task is no longer an
# open captain call. A newer published version also supersedes a version card.
# A task whose state cannot be established is kept, because a call wrongly
# hidden is worse than a card wrongly shown. Cleanup is therefore a normal
# rebuild effect rather than a committed migration or direct state mutation.
#
# THE RECONCILE CHOICE. Every decision card carries the standard `reconcile`
# option, injected here so the guarantee does not depend on the composer's
# memory, and the payload validator reserves that value across every card type.
# The validator's reservation scope must equal the adapter's reconcile
# classification scope, which is all card types because the captured payload
# carries no card type. Its meaning, and the reason it can never reach the
# keyed-answer intake as a blind close, are owned by
# docs/captain-hold-lifecycle.md.
#
# Validation is fail-closed: the payload must be valid JSON with
# schema=fm-bearings-board.v1 and every renderer-consumed field must satisfy
# the fm-bearings-board.v1 types and item invariants below. Every fleet row and
# Captain's Call item explicitly carries `repo`; the composer fills it from the
# snapshot and task records wherever known, and uses null or an empty string
# only as the deliberate genuinely-no-repo marker. In that exceptional case
# the template may display the routing id. Anything else refuses before the
# existing board is touched.
#
# Every Underway row likewise carries a non-empty `name`: the durable task name
# when known, otherwise its durable identifier.
# A Charted Next row MAY carry `filed`, the durable filed date (YYYY-MM-DD, or
# that date with a UTC timestamp) the template orders the section by, newest
# first; a row with no comparable date keeps its payload order after every dated
# row. Anything else in that field refuses rather than sorting on garbage.
#
# The board path is stable - $FM_HOME/.lavish/bearings-board.html - so a
# re-invocation rebuilds the same file in place, which keeps the same Lavish
# session URL and the same canonical process-event source id. Injection escapes
# every `<` in the compact JSON as the \u003c string escape, so a payload string
# containing "</script>" can never terminate the data block early.
#
# FM_BEARINGS_BOARD_TEMPLATE overrides the shipped template path (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

TEMPLATE="${FM_BEARINGS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/board-template.html}"
DEFAULT_WIP_LIMIT=3
PLACEHOLDER='__FM_BEARINGS_BOARD_DATA__'
BOARD_SCHEMA=fm-bearings-board.v1

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-bearings-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/bearings-board.html\n' "$FM_HOME"; }
# The last agent-composed payload build accepted; refresh carries its cards.
authored_path() { printf '%s/bearings-board.authored.json\n' "$STATE"; }

validate_payload() {  # <data.json>
  jq -e --arg schema "$BOARD_SCHEMA" '
    def nonempty_string: type == "string" and length > 0;
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def repo_marker: has("repo") and (.repo == null or (.repo | type == "string"));
    def name_marker: has("name") and (.name | nonempty_string);
    def valid_filed:
      . as $filed
      | type == "string"
      and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$")
      and (if test("T")
        then try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $filed) catch false
        else try (((. + "T00:00:00Z") | fromdateiso8601 | strftime("%Y-%m-%d")) == $filed) catch false
        end);
    def optional_filed:
      (has("filed") | not) or (.filed == null) or (.filed | valid_filed);
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    def optional_https_url($name):
      (has($name) | not)
      or (.[$name]
        | type == "string"
          and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$"));
    def version: type == "string" and test("^(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})$");
    def optional_subject:
      (has("subject") | not)
      or (.subject
        | type == "object"
          and (keys | sort) == ["artifact", "version"]
          and (.artifact | slug(128))
          and (.version | version));
    def call_item:
      type == "object"
      and (.key | slug(128))
      and (.type == "decision" or .type == "merge" or .type == "credential")
      and repo_marker
      and (.title | nonempty_string)
      and (.options | type == "array")
      and ((.options | length) > 0 or .allow_freeform == true)
      and ([.options[]
        | type == "object"
          and (.value | slug(128))
          and (.label | nonempty_string)
          and optional_string("hint")] | all)
      and (optional_string("about"))
      and (optional_string("decide"))
      and (optional_string("detail"))
      and (optional_https_url("pr_url"))
      and optional_subject
      and (if has("subject") then .type == "decision" else true end)
      and (optional_string("freeform_hint"))
      and ((has("close") | not) or (.close == "done" or .close == "release"))
      and ((has("allow_freeform") | not) or (.allow_freeform | type == "boolean"))
      and ((has("recommend_value") | not)
        or ((.recommend_value | slug(128))
          and (.recommend_value as $recommend
            | ([.options[].value] | index($recommend) != null))))
      and ([.options[].value] | index("reconcile") == null)
      and (if .type == "merge" then (.risk | nonempty_string) else true end);
    def underway_item:
      type == "object" and repo_marker and name_marker and (.id | nonempty_string)
      and (.state | nonempty_string) and (.doing | nonempty_string) and (.kind | nonempty_string);
    def landed_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.what | nonempty_string) and (.owner | nonempty_string)
      and optional_https_url("pr_url")
      and optional_subject;
    def charted_item:
      type == "object" and repo_marker and (.id | slug(128))
      and (.title | nonempty_string) and (.reason | type == "string")
      and (.dispatchable | type == "boolean")
      and ((has("kind") | not) or (.kind == "queued" or .kind == "warning"))
      and optional_filed
      and (if .kind == "warning" then .dispatchable == false else true end);
    type == "object"
    and (.schema == $schema)
    and (.home | nonempty_string)
    and (.generated | nonempty_string)
    and (.prs_live | type == "boolean")
    and (.captains_call | type == "array")
    and (.underway | type == "array")
    and (.landed | type == "array")
    and (.charted | type == "array")
    and ((has("charted_more") | not)
      or ((.charted_more | type == "number") and (.charted_more >= 0) and (.charted_more | floor == .)))
    and ((has("charted_warning_more") | not)
      or ((.charted_warning_more | type == "number") and (.charted_warning_more >= 0) and (.charted_warning_more | floor == .)))
    and ((has("wip_limit") | not)
      or ((.wip_limit | type == "number") and (.wip_limit >= 1) and (.wip_limit | floor == .)))
    and ([.captains_call[] | call_item] | all)
    and ([.underway[] | underway_item] | all)
    and ([.landed[] | landed_item] | all)
    and ([.charted[] | charted_item] | all)
  ' "$1" >/dev/null
}

# --- Lavish session liveness -------------------------------------------------
# Verified against lavish-axi 0.1.61. `lavish-axi <file>` EXITS 0 even when it
# refuses to reopen a session the captain ended from the browser, reporting
# `status: user-ended` and the same session id, so an exit-code check alone
# cannot tell a live board from a dead one. The establish status is an initial
# signal only; the server's fresh session listing must also show the canonical
# board open before the build may bind or arm its source.

board_realpath() {  # <board>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

lavish_status_field() {  # <lavish-axi output>
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"'
}

# The server's own listing, keyed on the canonical artifact path. Rows are
# `<file>,<status>,"<url>",<pending>`, and only a live session is listed `open`.
lavish_session_listed_open() {  # <canonical-board-path>
  local listing
  listing=$(lavish-axi 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v path="$1" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, path ",") == 1 {
      rest = substr(line, length(path) + 2)
      split(rest, field, ",")
      if (field[1] == "open") { found = 1 }
    }
    END { exit found ? 0 : 1 }
  '
}

lavish_board_live() {  # <establish output> <canonical-board-path>
  lavish_session_listed_open "$2"
}

# Establish the board session and PROVE it is live before anything arms a poll
# on it. A session the captain ended is reopened once - the captain asked for
# this board, which is exactly the attention `--reopen` exists for - and a
# session that is still not live after that refuses the build rather than
# arming a poll that can never attach.
establish_board_session() {  # <board>
  local board=$1 real out status version
  BOARD_SESSION_REOPENED=0
  real=$(board_realpath "$board") || fail "cannot resolve the board path: $board"
  out=$(lavish-axi "$board") || fail "cannot establish the board Lavish session"
  printf '%s\n' "$out"
  if lavish_board_live "$out" "$real"; then
    printf 'session: live\n'
    return 0
  fi
  out=$(lavish-axi "$board" --reopen) || fail "cannot reopen the ended board Lavish session"
  printf '%s\n' "$out"
  if lavish_board_live "$out" "$real"; then
    BOARD_SESSION_REOPENED=1
    printf 'session: reopened\n'
    return 0
  fi
  status=$(lavish_status_field "$out")
  version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
  fail "the board Lavish session is not live after reopening it (lavish-axi ${version:-version-unknown} reported status ${status:-none}); refusing to arm a poll on an ended session"
}

# --- Captain's Call hygiene ---------------------------------------------------
# A held decision whose subject already shipped is not a live call, so it is
# dropped here instead of being carded again. All checks use exact structured
# identities; unknown subject state keeps the card.

decision_card_is_stale() {  # <task-id> <landed-0-or-1>
  local task=$1 landed=$2 rc=0
  if [ "$landed" = 1 ]; then
    printf 'structured subject already landed\n'
    return 0
  fi
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$task" --distinguish-absent >/dev/null 2>&1 || rc=$?
  # 1 is a definite "no longer an open captain call". 2 is "cannot tell", 3 is
  # absent from this backlog, and a call wrongly hidden is worse than a card
  # wrongly shown, so both uncertain and absent cards stay.
  if [ "$rc" -eq 1 ]; then
    printf 'no longer an open captain call\n'
    return 0
  fi
  return 1
}

# Drop every stale decision card, then give every surviving decision card the
# standard reconcile choice. Injecting it here is what makes "every decision
# card offers reconcile" a property of the board rather than of the composer's
# memory; the validator prevents duplicate decision options.
effective_payload() {  # <data.json> <dest.json>
  local data=$1 dest=$2 landed_keys key reason drop='' tmp landed=0 limit
  limit=$(wip_limit) || return 1
  landed_keys=$(jq -c '
    def version_parts: split(".") | map(tonumber);
    . as $payload
    | [$payload.captains_call[]
      | select(.type == "decision")
      | . as $card
      | select(
          ($payload.landed | any(.id == $card.key))
          or (($card.pr_url? != null) and ($payload.landed | any(.pr_url? == $card.pr_url)))
          or (($card.subject? != null) and ($payload.landed | any(
            (.subject? != null)
            and (.subject.artifact == $card.subject.artifact)
            and ((.subject.version | version_parts) >= ($card.subject.version | version_parts)))))
        )
      | .key]
  ' "$data") || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    landed=0
    if jq -e --arg key "$key" 'index($key) != null' <<< "$landed_keys" >/dev/null; then
      landed=1
    fi
    reason=$(decision_card_is_stale "$key" "$landed") || continue
    printf 'dropped-landed-card: %s (%s)\n' "$key" "$reason" >&2
    drop=$drop$key$'\n'
  done < <(jq -r '.captains_call[]? | select(.type == "decision") | .key' "$data")
  tmp=$(printf '%s' "$drop" | jq -R -s 'split("\n") | map(select(length > 0))') || return 1
  jq --argjson dropped "$tmp" --argjson limit "$limit" '
    .wip_limit = $limit
    | .captains_call = [
      .captains_call[]
      | . as $card
      | select($card.type != "decision" or (($dropped | index($card.key)) == null))
      | if .type == "decision"
        then .options += [{
          value: "reconcile",
          label: "Reconcile",
          hint: "Re-check the latest state, then close this with evidence or keep it open with a note"
        }]
        else . end
    ]' "$data" > "$dest" || return 1
}

wip_limit() {
  local value=${FM_CAPTAIN_WIP_LIMIT-}
  if [ -z "$value" ] && [ -f "$CONFIG/captain-wip-limit" ]; then
    IFS= read -r value < "$CONFIG/captain-wip-limit" || true
    value=${value//[[:space:]]/}
  fi
  case "$value" in
    '') value=$DEFAULT_WIP_LIMIT ;;
    *[!0-9]*|0*) printf 'fm-bearings-board: captain WIP limit is not a positive integer: %s\n' "$value" >&2; return 1 ;;
  esac
  printf '%s\n' "$value"
}

# Deterministic snapshot-to-payload projection. Everything here is structure
# copied from fm-bearings.v1; nothing is ranked, summarized, or invented.
compose_payload() {  # <bearings-snapshot.json>
  jq -e --arg schema "$BOARD_SCHEMA" '
    def is_slug: type == "string" and test("^[A-Za-z0-9._-]{1,128}$");
    def has_text: type == "string" and test("[^[:space:]]");
    def text_or($fallback): if has_text then . else $fallback end;
    def https_url:
      type == "string"
      and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$");
    def filed_or_null:
      if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$")
      then . else null end;
    def owner_note($owner): if $owner == "(main)" or $owner == null then "" else $owner + ": " end;
    def omitted_count($surface):
      [(.omitted // [])[] | .surface
        | capture("^" + $surface + " showing (?<shown>[0-9]+) of (?<total>[0-9]+)")?
        | (.total | tonumber) - (.shown | tonumber)] | add // 0;
    . as $s
    | ([($s.contributions.captain // [])[] | select((.hold | is_slug) and (.url | https_url))]) as $contrib
    | {
        schema: $schema,
        home: ($s.home | text_or("firstmate")),
        generated: ($s.generated | text_or("unknown")),
        prs_live: ($s | has("candidate_prs")),
        captains_call: [
          ($s.holds // [])[]
          | select(.key | is_slug)
          | . as $h
          | ([$contrib[] | select(.hold == $h.key and .owner == $h.owner) | .url][0]) as $pr
          | {key, type: "decision", repo: (.repo // null),
             title: (.title | text_or($h.key)),
             options: [], allow_freeform: true,
             freeform_hint: "Answer in your own words"}
          + (if (.reason | has_text) or $h.owner != "(main)"
             then {about: (owner_note($h.owner) + (.reason | text_or("captain decision pending")))}
             else {} end)
          + (if $pr != null then {pr_url: $pr} else {} end)
        ],
        underway: [
          ($s.in_flight // [])[]
          | select(.id | has_text)
          | . as $r
          | {id, repo: (.repo // null), name: (.name | text_or($r.id)),
             state: (.state | text_or("unknown")),
             doing: (.doing | text_or($r.state | text_or("in progress"))),
             kind: (.kind | text_or("task"))}
        ],
        landed: [
          ($s.landed // [])[]
          | select(.id | has_text)
          | . as $r
          | {id, repo: null, what: (.what | text_or($r.id)), owner: (.owner | text_or("(main)"))}
            + (if .artifact | https_url then {pr_url: .artifact} else {} end)
        ],
        charted: (
          [($s.gates // [])[]
           | . as $g
           | if .id == "(main-inventory)" or .id == "(return-catchup)" then
               {id: (.id | gsub("[()]"; "")), repo: null, title: (.title | text_or($g.id)),
                reason: (.reason | text_or("")), dispatchable: false, kind: "warning", filed: null}
             elif (.id | is_slug) then
               ([(if (.blocked_by | has_text) and .blocked_by != "-" then "blocked by " + .blocked_by else empty end),
                 (if (.reason | has_text) and .reason != "-" then .reason else empty end)] | join("; ")) as $why
               | {id, repo: null, title: (.title | text_or($g.id)),
                  reason: (if .owner == "(main)" or .owner == null then $why
                           elif $why == "" then .owner + " home"
                           else owner_note(.owner) + $why end),
                  dispatchable: (.owner == "(main)" and $why == ""),
                  filed: (.filed | filed_or_null)}
             else empty end]
          + [($s.secondmates // [])[]
             | select(.id | is_slug)
             | if .state == "unknown" then
                 {id: ("secondmate." + .id), repo: null,
                  title: ("Secondmate " + .id + " state unavailable"),
                  reason: (.doing | text_or("current home state unavailable")),
                  dispatchable: false, kind: "warning", filed: null}
               elif .state == "externally_held" then
                 {id: ("secondmate." + .id), repo: null,
                  title: ("Secondmate " + .id + " held externally"),
                  reason: (.doing | text_or("held")),
                  dispatchable: false, filed: null}
               else empty end]),
        charted_more: ($s | omitted_count("gates"))
      }
  ' "$1"
}

# Carry the last build's agent-authored Captain's Call cards onto a composed
# payload: a call card while its key is still a composed open call, a merge
# card while its task is still underway and not landed. Authored order first.
carry_authored() {  # <composed.json> <authored.json>
  jq --slurpfile authored "$2" '
    . as $c
    | ([$c.captains_call[].key]) as $open
    | ([$c.underway[].id]) as $live
    | ([$c.landed[].id]) as $landed
    | ([($authored[0].captains_call // [])[]
        | select(
            if .type == "merge" then
              (.key | ltrimstr("merge.")) as $task
              | ($live | index($task)) != null and ($landed | index($task)) == null
            else (.key as $k | $open | index($k)) != null end)]) as $carried
    | ([$carried[].key]) as $carried_keys
    | .captains_call = $carried + [$c.captains_call[] | select(.key as $k | $carried_keys | index($k) | not)]
  ' "$1"
}

# The payload a published board carries, read back from the page itself.
published_payload() {  # <board>
  sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$1" \
    | sed '1d;$d'
}

board_cksum() {  # <board>
  if [ -f "$1" ]; then cksum < "$1"; else printf 'absent\n'; fi
}

# Render <effective.json> into a fresh template copy at <out>, refusing a page
# whose injected payload would not read back.
render_board_page() {  # <effective.json> <out>
  local json
  json=$(jq -c . "$1") || { printf 'fm-bearings-board: cannot compact the board data\n' >&2; return 1; }
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$TEMPLATE" > "$2"; then
    printf 'fm-bearings-board: cannot inject the board data\n' >&2
    return 1
  fi
  if grep -qxF "$PLACEHOLDER" "$2"; then
    printf 'fm-bearings-board: the board data slot survived injection\n' >&2
    return 1
  fi
  # Round-trip the injected payload back out of the built page, so a board that
  # would fail to parse in the browser fails here instead.
  if ! published_payload "$2" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    printf 'fm-bearings-board: the built board does not carry a readable %s payload\n' "$BOARD_SCHEMA" >&2
    return 1
  fi
}

# Render <effective.json> and atomically replace the board. With
# <expect-cksum>, return 3 instead when the board changed since the caller read
# it, so an older snapshot never overwrites a newer publication.
publish_board() {  # <effective.json> [<expect-cksum>]
  local effective=$1 expect=${2-} board tmp
  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || { printf 'fm-bearings-board: cannot create %s\n' "${board%/*}" >&2; return 1; }
  tmp=$(umask 077; mktemp "${board%/*}/.board.XXXXXX") \
    || { printf 'fm-bearings-board: cannot stage the board\n' >&2; return 1; }
  render_board_page "$effective" "$tmp" || { rm -f -- "$tmp"; return 1; }
  if [ -n "$expect" ] && [ "$(board_cksum "$board")" != "$expect" ]; then
    rm -f -- "$tmp"
    return 3
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$tmp"
    printf 'fm-bearings-board: cannot publish the board\n' >&2
    return 1
  fi
}

load_refresh_libs() {
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-timeout-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
}

refresh_due() {  # <stamp>
  local stamp=$1 max_age=${FM_BEARINGS_BOARD_MAX_AGE:-300} min_interval=${FM_BEARINGS_BOARD_MIN_INTERVAL:-60}
  local now mtime age changed
  [ -f "$stamp" ] || return 0
  case "$max_age" in ''|*[!0-9]*) max_age=300 ;; esac
  case "$min_interval" in ''|*[!0-9]*) min_interval=60 ;; esac
  now=$(date +%s)
  if [ "$(uname)" = Darwin ]; then
    mtime=$(/usr/bin/stat -f %m "$stamp" 2>/dev/null || echo 0)
  else
    mtime=$(stat -c %Y "$stamp" 2>/dev/null || echo 0)
  fi
  age=$((now - mtime))
  # A busy fleet changes some status log nearly every poll; the floor keeps the
  # snapshot from running back to back on the captain's machine.
  [ "$age" -ge "$min_interval" ] || return 1
  [ "$age" -lt "$max_age" ] || return 0
  [ ! "$DATA/backlog.md" -nt "$stamp" ] || return 0
  changed=$(find "$STATE" -maxdepth 1 -type f \( -name '*.meta' -o -name '*.status' \) \
    -newer "$stamp" -print 2>/dev/null | head -n 1)
  [ -n "$changed" ]
}

command_compose() {
  local snapshot=${1-}
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$snapshot" ] || fail "bearings snapshot does not exist: $snapshot"
  jq -e '.schema == "fm-bearings.v1"' "$snapshot" >/dev/null 2>&1 \
    || fail "not an fm-bearings.v1 snapshot: $snapshot"
  compose_payload "$snapshot" || fail "cannot compose the board payload from $snapshot"
}

REFRESH_LOCK_HELD=0
REFRESH_TMP=''
# shellcheck disable=SC2329 # Invoked by the EXIT trap command_refresh installs.
refresh_cleanup() {
  [ -z "$REFRESH_TMP" ] || rm -rf -- "$REFRESH_TMP"
  [ "$REFRESH_LOCK_HELD" = 0 ] || fm_lock_release "$STATE/.bearings-board-refresh.lock" || true
}

command_refresh() {
  local if_due=0 board stamp before composed effective timeout current rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --if-due) if_due=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  board=$(board_path)
  stamp="$STATE/.bearings-board-refresh.stamp"
  [ -f "$board" ] || { printf 'skipped: no board has been built\n'; return 0; }
  if [ "$if_due" = 1 ] && ! refresh_due "$stamp"; then
    printf 'skipped: not due\n'
    return 0
  fi
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  load_refresh_libs
  trap refresh_cleanup EXIT
  fm_lock_try_acquire "$STATE/.bearings-board-refresh.lock" \
    || { printf 'skipped: a refresh is already running\n'; return 0; }
  REFRESH_LOCK_HELD=1
  # Stamped before the snapshot, so a change landing while it runs is newer
  # than the stamp and makes the next poll due again.
  touch "$stamp" || fail "cannot stamp the refresh: $stamp"
  if ! command -v lavish-axi >/dev/null 2>&1 \
    || ! lavish_session_listed_open "$(board_realpath "$board")"; then
    printf 'skipped: the board Lavish session is not open\n'
    return 0
  fi
  before=$(board_cksum "$board")
  REFRESH_TMP=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-bearings-refresh.XXXXXX") \
    || fail "cannot stage the refresh"
  timeout=${FM_BEARINGS_BOARD_SNAPSHOT_TIMEOUT:-300}
  # Every live call must reach the board, or its WIP count would undercount.
  if ! FM_BEARINGS_DECISIONS=${FM_BEARINGS_BOARD_DECISIONS:-500} \
    fm_run_timed "$timeout" "$SCRIPT_DIR/fm-bearings-snapshot.sh" --json --fields holds \
    > "$REFRESH_TMP/snapshot.json" 2> "$REFRESH_TMP/snapshot.err"; then
    fail "cannot gather the bearings snapshot: $(tail -n 3 "$REFRESH_TMP/snapshot.err" | tr '\n' ' ')"
  fi
  composed="$REFRESH_TMP/composed.json"
  compose_payload "$REFRESH_TMP/snapshot.json" > "$composed" \
    || fail "cannot compose the board payload"
  if [ -f "$(authored_path)" ] && jq empty "$(authored_path)" 2>/dev/null; then
    carry_authored "$composed" "$(authored_path)" > "$REFRESH_TMP/carried.json" \
      || fail "cannot carry the authored cards"
    composed="$REFRESH_TMP/carried.json"
  fi
  validate_payload "$composed" || fail "the composed payload does not satisfy $BOARD_SCHEMA"
  effective="$REFRESH_TMP/effective.json"
  effective_payload "$composed" "$effective" \
    || fail "cannot reconcile the board payload against landed work"
  # Unchanged means the page this refresh would publish, rendered with the
  # published `generated`, is byte-identical to the board, so a template
  # upgrade still reaches an open board even when the fleet is quiet.
  current=$(published_payload "$board" | jq -r '.generated // empty' 2>/dev/null || true)
  if [ -n "$current" ] \
    && jq --arg generated "$current" '.generated = $generated' "$effective" > "$REFRESH_TMP/same.json" \
    && render_board_page "$REFRESH_TMP/same.json" "$REFRESH_TMP/same.html" 2>/dev/null \
    && cmp -s "$REFRESH_TMP/same.html" "$board"; then
    printf 'unchanged: %s\n' "$board"
    return 0
  fi
  publish_board "$effective" "$before" || rc=$?
  case "$rc" in
    0) printf 'refreshed: %s\n' "$board" ;;
    3) printf 'superseded: %s\n' "$board" ;;
    *) fail "cannot publish the refreshed board" ;;
  esac
}

# The OWNER column bin/fm-procevent.sh already publishes: live, none,
# orphaned, or uncertain. Empty means the source is not registered at all.
source_owner() {  # <source-id>
  "$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$1" 'NR > 1 && $1 == id { print $3 }'
}

# A replacement listener is started detached, so it claims the source shortly
# after reconcile returns. Wait for that claim rather than reporting the race.
await_source_owner() {  # <source-id>
  local owner i=0
  while [ "$i" -lt 50 ]; do
    owner=$(source_owner "$1")
    [ "$owner" != live ] || { printf '%s\n' "$owner"; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "${owner:-none}"
}

command_build() {
  local data=${1-} board sid effective owner version pre_reopen_owner
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  validate_payload "$data" || fail "board data does not satisfy $BOARD_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not carry exactly one data slot: $TEMPLATE"

  effective=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-payload.XXXXXX") \
    || fail "cannot stage the board payload"
  if ! effective_payload "$data" "$effective"; then
    rm -f -- "$effective"
    fail "cannot reconcile the board payload against landed work"
  fi
  if ! publish_board "$effective"; then
    rm -f -- "$effective"
    fail "cannot publish the board"
  fi
  rm -f -- "$effective"
  board=$(board_path)
  # refresh carries this agent-authored copy's cards while their calls stay open.
  (umask 077; mkdir -p "$STATE" && cp -f -- "$data" "$(authored_path)") \
    || fail "cannot record the authored payload for refresh"
  printf 'board: %s\n' "$board"

  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || fail "cannot derive the board source id"
  pre_reopen_owner=$(source_owner "$sid")
  establish_board_session "$board"
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" retire "$board" >/dev/null \
      || fail "cannot retire the pre-reopen source generation (observed owner: ${pre_reopen_owner:-none})"
  fi
  if ! lavish_session_listed_open "$(board_realpath "$board")"; then
    version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
    fail "the board Lavish session is not listed open immediately before arming (lavish-axi ${version:-version-unknown}); refusing to arm a poll on observed state not-open"
  fi
  printf 'served: %s\n' "$board"

  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$sid" >/dev/null \
    || fail "cannot bind the board source to the keyed-answer intake"
  printf 'bound: %s\n' "$sid"

  owner=$(source_owner "$sid")
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm a fresh board source after reopening"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  elif [ -n "$owner" ]; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm the board as a process-event source"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  fi
  # Registered is not listening. A board whose source has no live owner gets a
  # replacement started now rather than at the next supervision cycle, which is
  # what keeps a rebuilt board from sitting silent behind `already-armed`.
  if [ "$owner" != live ]; then
    "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
    owner=$(await_source_owner "$sid")
    if [ "$owner" != live ]; then
      fail "source $sid is not listening after reconcile (observed owner: ${owner:-none})"
    fi
    printf 'listening: live\n'
  fi
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  compose) shift; command_compose "$@" ;;
  refresh) shift; command_refresh "$@" ;;
  path) board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
