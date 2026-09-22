#!/usr/bin/env bash
# fm-jev-intake-match.sh - match a free-text captain reference to its record.
#
# Usage:
#   fm-jev-intake-match.sh <reference text...>
#   fm-jev-intake-match.sh -          reads the reference on stdin
#
# Resolves a loose reference such as "the wiki plan I had in one prompt" to
# the backlog items and task records it most likely means, so intake does not
# have to grep the backlog and every data/<id>/ record by hand. Advisory only:
# it never opens, dispatches, transitions, or edits anything.
#
# Candidates (no model call): this home's backlog ids and titles from
# `fm-tasks-axi.sh list` and `list --state done` (five-second timeout each),
# plus every data/<id>/ directory holding report.md or brief.md, titled by that
# file's first `# ` heading (report.md wins; a brief's generic scaffold heading
# such as "Task" leaves the record titled by its backlog entry or id alone).
# One id seen in both places is one candidate. Each candidate gets a keyword
# score: the number of distinct reference words (three or more characters,
# common English and German filler dropped) found in its lowercased id plus
# title. The bounded list is the 24 best by score, most recent record first
# on ties, topped up with the most recent unscored candidates when fewer than
# 24 score.
#
# What Jev sees (one Choice call through bin/fm-jev-lib.sh): the reference
# text, then candidate ids as choices with their title and backlog state as
# criteria, plus `none`. Titles are sanitized by fm_jev_compact_state and cut
# to 80 characters; an id that sanitization would change is dropped. File
# bodies never leave the machine: only ids, titles, and backlog states do.
# JEV_TIMEOUT defaults to 5 seconds here when unset.
#
# Ranking: when the chosen id is an offered candidate at or above the library
# confidence floor (JEV_CONFIDENCE_FLOOR, default 0.7), candidates are ranked
# by the Choice probabilities, or the single pick when probabilities are
# absent or malformed. Otherwise - no key, a failed call, `none`, or low
# confidence - the output says so and falls back to the keyword ranking.
#
# Output (stdout), at most five candidates:
#   jev-intake-match:
#     ranking: jev | keyword
#     fallback: none | off | error | low-confidence | no-match | no-candidates |
#               jq-missing
#     confidence: <Jev's confidence in its pick, or empty>
#     candidates:
#       1. <id> confidence=<p> state=<backlog state or -> record=<path or -> title=<title>
# The keyword ranking prints score=<matched>/<reference words> in place of
# confidence and lists only candidates that matched; `candidates: none` when
# nothing did. Exit 0 except usage (exit 2), so intake is never blocked.
#
# Log: one JSONL object per attempted Jev call appended to
# ${FM_STATE_OVERRIDE:-$FM_HOME/state}/jev-intake-match.jsonl with
# purpose=intake-match, advisory=true, the reference, offered ids, choice,
# confidence, ranked ids, ranking, fallback, route, http, latency_ms,
# decide_code, and ts. Secrets follow fm_jev_log_call redaction.
#
# Environment: FM_HOME, FM_DATA_OVERRIDE (the data directory, as
# bin/fm-tasks-axi.sh resolves it), FM_STATE_OVERRIDE, plus the Jev library
# keys and JEV_* settings documented in bin/fm-jev-lib.sh. This script does
# not roll its own HTTP.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'jev-intake-match: %s\n' "$1" >&2
  exit 2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') die "usage: fm-jev-intake-match.sh <reference text...> | -" ;;
  -) [ $# -eq 1 ] || die "unexpected argument after -"; REFERENCE=$(cat) ;;
  -*) die "unknown option: $1" ;;
  *) REFERENCE="$*" ;;
esac
REFERENCE=$(printf '%s' "$REFERENCE" | tr '\n\t' '  ')
[ -n "${REFERENCE// /}" ] || die "empty reference"

DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG_PATH="$STATE_DIR/jev-intake-match.jsonl"
CANDIDATE_MAX=24
SHOW_MAX=5
TITLE_MAX=80
LIST_TIMEOUT=5
JEV_TIMEOUT=${JEV_TIMEOUT:-$(fmx_env_get JEV_TIMEOUT "$FM_HOME/.env")}
JEV_TIMEOUT=${JEV_TIMEOUT:-5}
export JEV_TIMEOUT

# Reference words: lowercase ASCII runs of three or more characters, filler
# dropped, each word once.
reference_words() {
  printf '%s' "$REFERENCE" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c '[:lower:][:digit:]' '\n' | awk '
    BEGIN {
      n = split("the and for with that this which what our had have has was were you your can could " \
        "get got let one two into from about some any all out its are not but did does please " \
        "der die das und ein eine mit von fuer auf ist wir unser unsere hatte haben", w, " ")
      for (i = 1; i <= n; i++) stop[w[i]] = 1
    }
    length($0) >= 3 && !($0 in stop) && !seen[$0]++ { print }
  '
}

# Backlog rows as id<TAB>state<TAB>title, open items first, then Done.
backlog_rows() {
  local out state_args
  for state_args in '' '--state done'; do
    # shellcheck disable=SC2086 # state_args is a fixed flag pair or empty
    out=$(fm_run_timed "$LIST_TIMEOUT" "$SCRIPT_DIR/fm-tasks-axi.sh" list $state_args 2>/dev/null) || continue
    printf '%s\n' "$out" | awk '
      /^tasks\[/ { p = 1; next }
      p && /^[[:space:]]/ {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        n = split(line, parts, ",")
        if (n < 5) next
        title = parts[5]
        for (i = 6; i <= n; i++) title = title "," parts[i]
        sub(/\\n.*$/, "", title)
        gsub(/^"|"$/, "", title)
        printf "%s\t%s\t%s\n", parts[1], parts[2], title
        next
      }
      p { p = 0 }
    '
  done
}

# Task records as id<TAB>path<TAB>heading, most recently changed first. One awk
# pass reads each file only up to its first heading.
record_rows() {
  local id paths=()
  [ -d "$DATA_DIR" ] || return 0
  # shellcheck disable=SC2012 # ls -t is the portable mtime order; ids are plain
  while IFS= read -r id; do
    if [ -f "$DATA_DIR/$id/report.md" ]; then
      paths+=("$DATA_DIR/$id/report.md")
    elif [ -f "$DATA_DIR/$id/brief.md" ]; then
      paths+=("$DATA_DIR/$id/brief.md")
    fi
  done < <(ls -t "$DATA_DIR" 2>/dev/null)
  [ "${#paths[@]}" -gt 0 ] || return 0
  awk '
    function emit(file, h,    id) {
      id = file
      sub(/\/[^\/]*$/, "", id)
      sub(/^.*\//, "", id)
      printf "%s\t%s\t%s\n", id, file, h
    }
    FNR == 1 {
      if (prev != "" && !found) emit(prev, "")
      prev = FILENAME
      found = 0
    }
    /^# / {
      h = $0
      sub(/^# +/, "", h)
      if (h ~ /^(Task|Current worker role contract|Setup|Brief)$/) h = ""
      emit(FILENAME, h)
      found = 1
      nextfile
    }
    END { if (prev != "" && !found) emit(prev, "") }
  ' "${paths[@]}" 2>/dev/null
}

# Merge both sources and score: prints score<TAB>order<TAB>id<TAB>state<TAB>path<TAB>title
# for every candidate, best first.
scored_candidates() {
  local words=$1
  {
    backlog_rows | awk '{ print "B\t" $0 }'
    record_rows | awk '{ print "R\t" $0 }'
  } | awk -F '\t' -v words="$(printf '%s' "$words" | tr '\n' ' ')" '
    BEGIN { nw = split(words, w, " ") }
    {
      id = $2
      if (id == "" || id !~ /^[A-Za-z0-9._-]+$/) next
      if (!(id in order)) { order[id] = ++n; ids[n] = id; state[id] = "-"; path[id] = "-"; title[id] = "" }
      if ($1 == "B") {
        if (state[id] == "-") state[id] = $3
        if (btitle[id] == "") btitle[id] = $4
      } else {
        path[id] = $3
        if ($4 != "") title[id] = $4
      }
    }
    END {
      for (k = 1; k <= n; k++) {
        id = ids[k]
        t = (title[id] != "") ? title[id] : btitle[id]
        hay = tolower(id " " t)
        s = 0
        for (i = 1; i <= nw; i++) if (w[i] != "" && index(hay, w[i]) > 0) s++
        printf "%d\t%d\t%s\t%s\t%s\t%s\n", s, k, id, state[id], path[id], t
      }
    }
  ' | sort -t "$(printf '\t')" -k1,1nr -k2,2n
}

emit_header() {
  printf 'jev-intake-match:\n  ranking: %s\n  fallback: %s\n  confidence: %s\n' "$1" "$2" "$3"
}

# Keyword ranking over the scored candidates: only matched ones, best first.
emit_keyword() {
  local fallback=$1 confidence=$2 nwords rows
  nwords=$(printf '%s\n' "$WORDS" | grep -c .)
  rows=$(printf '%s\n' "$SCORED" | awk -F '\t' '$1 > 0' | head -n "$SHOW_MAX")
  emit_header keyword "$fallback" "$confidence"
  if [ -z "$rows" ]; then
    printf '  candidates: none\n'
    return 0
  fi
  printf '  candidates:\n'
  printf '%s\n' "$rows" | awk -F '\t' -v nw="$nwords" \
    '{ printf "    %d. %s score=%d/%d state=%s record=%s title=%s\n", NR, $3, $1, nw, $4, $5, $6 }'
}

WORDS=$(reference_words)
SCORED=$(scored_candidates "$WORDS")

if ! command -v jq >/dev/null 2>&1; then
  emit_keyword jq-missing ''
  exit 0
fi

if [ -z "$SCORED" ]; then
  emit_keyword no-candidates ''
  exit 0
fi
if ! fm_jev_key_configured; then
  emit_keyword off ''
  exit 0
fi

# The bounded offer: best-scored first, topped up by recency, sanitized ids and
# titles only. offered is a JSON array of {id, state, path, title}.
offered='[]'
while IFS=$(printf '\t') read -r _score _order id state path title; do
  [ -n "$id" ] || continue
  clean_id=$(fm_jev_compact_state "$id") || continue
  [ "$clean_id" = "$id" ] || continue
  title=$(fm_jev_compact_state "$title") || title=''
  title=${title:0:$TITLE_MAX}
  offered=$(jq -c --arg id "$id" --arg state "$state" --arg path "$path" --arg title "$title" \
    '. + [{id: $id, state: $state, path: $path, title: $title}]' <<<"$offered") || continue
  [ "$(jq 'length' <<<"$offered")" -lt "$CANDIDATE_MAX" ] || break
done <<EOF
$SCORED
EOF

state=$(fm_jev_compact_state "$(printf "Captain reference: %s\nCandidates are this Firstmate home's backlog items and task records, offered by id and title only." "$REFERENCE")") || {
  emit_keyword error ''
  exit 0
}
criteria=$(jq -c '
  (map({key: .id, value: ((if .title == "" then .id else .title end) + " (backlog: " + .state + ")")}) | from_entries)
  + {none: "No candidate is the record the captain means."}
' <<<"$offered") || { emit_keyword error ''; exit 0; }
questions=$(jq -nc --argjson c "$criteria" '{
  match: {
    type: "choice",
    instructions: "Pick the backlog item or task record the captain reference most likely means. Judge by id and title only. Pick none when no candidate fits.",
    criteria: $c
  }
}') || { emit_keyword error ''; exit 0; }

decide_code=0
mkdir -p "$STATE_DIR" 2>/dev/null || true
response=$(fm_jev_decide "$state" "$questions") || decide_code=$?

choice=
confidence=
ranked='[]'
ranking=keyword
fallback=error
if [ "$decide_code" -eq 0 ] && [ -n "$response" ]; then
  choice=$(jq -r '.answers.match.choice // empty' <<<"$response" 2>/dev/null)
  confidence=$(jq -r '.answers.match.confidence | select(type == "number") // empty' <<<"$response" 2>/dev/null)
  if [ -z "$choice" ] || [ "$choice" = none ]; then
    fallback=no-match
  elif ! jq -e --arg id "$choice" 'any(.[]; .id == $id)' <<<"$offered" >/dev/null 2>&1; then
    fallback=error
  elif [ -z "$confidence" ] || ! fm_jev_choice_confidence_ok "$confidence"; then
    fallback=low-confidence
  else
    ranking=jev
    fallback=none
    probs=$(jq -c '.answers.match.probabilities // empty' <<<"$response" 2>/dev/null)
    if [ -n "$probs" ] && fm_jev_probabilities_sum_ok "$probs"; then
      ranked=$(jq -c --argjson p "$probs" --arg choice "$choice" --arg conf "$confidence" '
        map(. + {confidence: (if .id == $choice then ($conf | tonumber) else ($p[.id] // 0) end)})
        | map(select(.confidence > 0))
        | sort_by(-.confidence)
      ' <<<"$offered")
    else
      ranked=$(jq -c --arg choice "$choice" --arg conf "$confidence" \
        'map(select(.id == $choice) | . + {confidence: ($conf | tonumber)})' <<<"$offered")
    fi
  fi
fi

payload=$(jq -nc \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf unknown)" \
  --arg reference "$REFERENCE" \
  --arg choice "$choice" \
  --arg confidence "$confidence" \
  --arg ranking "$ranking" \
  --arg fallback "$fallback" \
  --arg route "${FM_JEV_LAST_ROUTE:-}" \
  --arg http "${FM_JEV_LAST_HTTP:-}" \
  --arg latency "${FM_JEV_LAST_LATENCY_MS:-}" \
  --argjson offered "$(jq -c '[.[].id]' <<<"$offered")" \
  --argjson ranked "$(jq -c '[.[:5][].id]' <<<"$ranked")" \
  --argjson decide_code "$decide_code" \
  '{
    purpose: "intake-match",
    advisory: true,
    reference: $reference,
    offered_ids: $offered,
    choice: (if $choice == "" then null else $choice end),
    confidence: (try ($confidence | tonumber) catch null),
    ranked_ids: $ranked,
    ranking: $ranking,
    fallback: $fallback,
    route: $route,
    http: $http,
    latency_ms: (try ($latency | tonumber) catch null),
    decide_code: $decide_code,
    ts: $ts
  }' 2>/dev/null) && fm_jev_log_call "$payload" "$LOG_PATH" || true

if [ "$ranking" != jev ]; then
  emit_keyword "$fallback" "$confidence"
  exit 0
fi
emit_header jev none "$confidence"
printf '  candidates:\n'
jq -r --argjson max "$SHOW_MAX" '
  .[:$max] | to_entries[]
  | "    \(.key + 1). \(.value.id) confidence=\(.value.confidence) state=\(.value.state) record=\(.value.path) title=\(.value.title)"
' <<<"$ranked"
exit 0
