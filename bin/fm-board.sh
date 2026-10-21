#!/usr/bin/env bash
# fm-board.sh - the captain's "what needs me" board, computed from stored state.
#
# Usage: fm-board.sh [--json] [--all] [--home-only] [--skip-done]
#
# Every run recomputes the board from durable records only, so nothing on it
# depends on a one-shot signal having been relayed: a finished ship whose done
# line nobody read is still ready to approve, and a merge whose live check is
# pending is still visible after its worker is gone.
# bin/fm-board-lib.sh owns the grouping rules and their sources for one home.
# This command adds registered secondmate homes' boards from their published
# state/home-summary.json (a local ledger or the parent's cached copy of a
# remote one, read through `fm-fleet-snapshot.sh --secondmate-current-cached`).
# That reader's header and help own the registry and home-count bounds.
# A published board is bounded per group; the rows a home left out still count
# in the totals and print as a PARTIAL line.
# A secondmate ledger written before boards were published contributes its
# open decisions, active children, queued rows, and landed rows instead.
# It makes no network call, probes no pane, takes no session lock, and changes
# no task state. It uses temporary files, and the snapshot reader may create
# its cache directory. The session-start digest can print it and any session
# can run it on demand.
#
# Groups print in the order they need the captain: NEEDS YOU, READY TO
# APPROVE, WORKING, QUEUED, then the after-merge columns MERGED (NOT LIVE YET)
# and LIVE CONFIRMED, then DONE. Secondmate rows are named <home>/<task-id>.
# Text output shows every needs-you, ready, and merged row and bounds the rest
# (FM_BOARD_SHOW, default 8 per group), naming how many rows it left out; --all
# shows every available row, but cannot recover rows omitted by a secondmate's
# publisher. Run the board in that home to see those rows.
#
#   --json       print the fm-board.v1 object instead of text
#   --all        show every available row in every group
#   --home-only  skip secondmate homes
#   --skip-done  leave DONE rows out of the text (the header still counts
#                them); the session-start digest omits done rows everywhere
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SHOW=${FM_BOARD_SHOW:-8}
case "$SHOW" in ''|*[!0-9]*|0) SHOW=8 ;; esac

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; }

JSON=0
ALL=0
HOME_ONLY=0
SKIP_DONE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --all) ALL=1 ;;
    --home-only) HOME_ONLY=1 ;;
    --skip-done) SKIP_DONE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
command -v jq >/dev/null 2>&1 || { echo "fm-board: jq not found" >&2; exit 1; }

# shellcheck source=bin/fm-board-lib.sh
. "$SCRIPT_DIR/fm-board-lib.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-board.XXXXXX") || { echo "fm-board: temporary directory failed" >&2; exit 1; }
trap 'rm -rf -- "$TMP"' EXIT

"$SCRIPT_DIR/fm-fleet-snapshot.sh" --backlog-json > "$TMP/backlog.json" \
  || { echo "fm-board: backlog read failed" >&2; exit 1; }
fm_board_home_json "$STATE" "$TMP/backlog.json" > "$TMP/home.json" \
  || { echo "fm-board: board derivation failed" >&2; exit 1; }
if [ "$HOME_ONLY" = 1 ]; then
  printf '{"records":[]}\n' > "$TMP/secondmates.json"
elif ! "$SCRIPT_DIR/fm-fleet-snapshot.sh" --secondmate-current-cached > "$TMP/secondmates.json" 2> "$TMP/secondmates.err"; then
  jq -n --arg err "$(head -c 300 "$TMP/secondmates.err")" \
    '{records:[],error:("secondmate ledgers unavailable: " + $err)}' > "$TMP/secondmates.json"
fi

jq -n --slurpfile home "$TMP/home.json" --slurpfile mates "$TMP/secondmates.json" \
  --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FM_BOARD_JQ_DEFS"'
  def legacy_items:
    [ (.decisions_open // [])[]
      | {group:"needs_you", id, title:((.summary // .id) | trunc(90)), kind:null, repo:null,
         since:null, at:null, url:null,
         reason:(if (.verb // "captain-hold") == "captain-hold" then "decision" else .verb end),
         detail:((.reason // .summary // "") | trunc(160))} ]
    + [ (.active_children // [])[]
        | {group:"working", id, title:((.name // .id) | trunc(90)), kind:(.kind // null), repo:(.repo // null),
           since:null, at:null, url:null, reason:(.state // "working"), detail:((.doing // "") | trunc(160))} ]
    + [ (.queued // [])[] | select(.captain_actionable != true) | queued_item ]
    + [ (.landed // [])[] | done_item(null) ];
  ($mates[0]) as $mates
  | ([ $home[0].items[] | . + {home:null} ]
     + [ $mates.records[]? | select(.provenance.selected == "structured-home") as $m
         | (if ($m.board.schema // null) == "fm-board-home.v1" then $m.board.items else ($m | legacy_items) end)[]
         | . + {home:$m.id, id:($m.id + "/" + .id)} ]) as $items
  | [ $mates.records[]? | select(.provenance.selected == "structured-home") as $m
      | ($m.board.omitted // {}) | to_entries[] | {home:$m.id, group:.key, count:.value} ] as $partial
  | ["needs_you","ready","working","queued","merged","live","done"] as $order
  | {schema:"fm-board.v1", generated:$generated,
     counts:(reduce $order[] as $g ({}; . + {($g):(([$items[] | select(.group == $g)] | length)
                                                  + ([$partial[] | select(.group == $g) | .count] | add // 0))})),
     partial:$partial,
     groups:(reduce $order[] as $g ({};
       . + {($g):([$items[] | select(.group == $g)]
         | if $g == "needs_you" then sort_by(if .reason == "decision" then 1 else 0 end, -(.at // 0))
           elif $g == "ready" then sort_by(-(.at // 0))
           elif $g == "queued" then sort_by(if .reason == "queued" then 0 elif .reason == "blocked-by" then 1 else 2 end)
           else . end)})),
     unavailable:([ $mates.records[]? | select(.provenance.selected != "structured-home")
                    | {home:.id, reason:(.current.reason // "ledger unavailable")} ]
                  + (if $mates.error then [{home:null, reason:$mates.error}] else [] end))}' \
  > "$TMP/board.json" || { echo "fm-board: board render failed" >&2; exit 1; }

if [ "$JSON" = 1 ]; then
  cat "$TMP/board.json"
  exit $?
fi

jq -r --argjson all "$ALL" --argjson show "$SHOW" --argjson skip_done "$SKIP_DONE" '
  def group_label: {needs_you:"NEEDS YOU", ready:"READY TO APPROVE", working:"WORKING", queued:"QUEUED",
              merged:"MERGED (NOT LIVE YET)", live:"LIVE CONFIRMED", done:"DONE"}[.];
  def unbounded: . == "needs_you" or . == "ready" or . == "merged";
  def row:
    "- " + .id
    + (if .reason then " [" + .reason + "]" else "" end)
    + (if .url then " " + .url else "" end)
    + " " + (.title // "")
    + (if .detail and .detail != .url then " - " + .detail else "" end);
  .counts as $c
  | "BOARD " + .generated + ": "
    + ([ "\($c.needs_you) need you", "\($c.ready) ready to approve", "\($c.working) working",
         "\($c.queued) queued", "\($c.merged) merged, not live yet", "\($c.live) live confirmed",
         "\($c.done) done" ] | join(" · ")),
    (.groups | to_entries[] | select((.value | length) > 0) | select($skip_done == 0 or .key != "done")
     | .key as $g | (.value | length) as $n
     | (if $all == 1 or ($g | unbounded) or $n <= $show then $n else $show end) as $k
     | (($g | group_label) + " (" + ($n | tostring)
        + (if $k < $n then ", showing \($k); fm-board.sh --all shows every row" else "" end) + ")"),
       (.value[:$k][] | row)),
    (.partial[] | "PARTIAL: " + .home + " published \(.count) fewer \(.group | group_label) rows than it holds; its own fm-board.sh shows them"),
    (.unavailable[] | "UNAVAILABLE: " + (.home // "secondmates") + " - " + .reason)
' "$TMP/board.json"
