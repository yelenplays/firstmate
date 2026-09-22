#!/usr/bin/env bash
# fm-dispatch-replay.sh - calibrate typed dispatch resolution against known
# cases: replay labeled briefs through bin/fm-dispatch-resolve.sh, and score
# recorded rule answers under the clear gate.
#
# Usage:
#   fm-dispatch-replay.sh run --cases <file> --out <jsonl> --max-calls <n>
#       [--rules <crew-dispatch.json>]
#   fm-dispatch-replay.sh score [--margin <t>[,<t>...]] [--rows] <jsonl>...
#
# run: one bin/fm-dispatch-resolve.sh call per case, in file order, stopping
#   before the call that would exceed --max-calls, and appends one JSON line per
#   call to --out: {case, brief, project, expected, status, rule, confidence,
#   probabilities, reason}. Every call spends one live Jev request under the
#   resolver's own opt-in gate and settings; the resolver's shadow log is
#   forced off so a replay never writes $FM_HOME/state/jev-dispatch-shadow.jsonl.
#   --rules replays a candidate rules file without touching the home's
#   config/crew-dispatch.json (it becomes the only file in a private
#   FM_CONFIG_OVERRIDE directory). Screen briefs before replaying them: the
#   resolver sends the brief text, so never list a brief that carries secrets
#   or private personal data.
#   Cases file: one case per line, tab-separated
#     <case-id> <brief-path> <project or -> <expected rules, |-separated, or ->
#   Blank lines and lines starting with # are skipped. A relative brief path
#   resolves against the cases file's directory.
#
# score: reads JSON lines that carry a rule-answer `probabilities` object -
#   the resolver's shadow log and `run` output both qualify - and, for each
#   threshold, prints how many rows the top-2 margin gate would pass or hold
#   as ambiguous next to the fixed 0.6 derived-confidence gate the resolver
#   used before the margin gate. Rows with an `expected` label also count
#   `wrong`: rows that pass the gate with a top pick outside the label. The
#   margin arithmetic is bin/fm-jev-lib.sh's jev_choice_top2, the same
#   definition the resolver gates on. Default threshold: the resolver's
#   effective FM_JEV_DISPATCH_MARGIN. --rows prints one line per row.
#   Rows without a probabilities object (error outcomes) are counted as
#   skipped. score makes no network call.
#
# Output (stdout, TOON-style):
#   run:   replay-run: calls=<n> written=<n> stopped=<budget|none>
#   score: replay-score: rows=<n> labeled=<n> skipped=<n>
#            gate: confidence>=0.6 ambiguous=<n> pass=<n> wrong=<n>
#            gate: margin>=<t> ambiguous=<n> pass=<n> wrong=<n>
#          --rows adds per row:
#            row: <case> first=<rule> second=<rule> margin=<m> confidence=<c>
#              expected=<labels|-> margin-gate=<pass|ambiguous> <ok|wrong|->
# Exit: 0 on success, 2 on usage error, unreadable input, or missing jq.
# docs/configuration.md "Typed dispatch resolution" owns the calibration
# contract this tool supports.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
RESOLVER="${FM_DISPATCH_RESOLVER:-$SCRIPT_DIR/fm-dispatch-resolve.sh}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

command -v jq >/dev/null 2>&1 || die "jq required"

replay_default_margin() {
  local v=${FM_JEV_DISPATCH_MARGIN:-}
  [ -n "$v" ] || v=$(fmx_env_get FM_JEV_DISPATCH_MARGIN "$FM_HOME/.env")
  [ -n "$v" ] || v=$(awk -F= '/^DEFAULT_MARGIN=/ { print $2; exit }' "$RESOLVER")
  printf '%s' "$v"
}

replay_run() {
  local cases='' out='' max='' rules='' cfg_dir='' cases_dir calls=0 written=0 stopped=none
  local id brief project expected text line status rule confidence probs reason
  while [ $# -gt 0 ]; do
    case "$1" in
      --cases) [ $# -ge 2 ] || die "--cases needs a value"; cases=$2; shift 2 ;;
      --out) [ $# -ge 2 ] || die "--out needs a value"; out=$2; shift 2 ;;
      --max-calls) [ $# -ge 2 ] || die "--max-calls needs a value"; max=$2; shift 2 ;;
      --rules) [ $# -ge 2 ] || die "--rules needs a value"; rules=$2; shift 2 ;;
      *) die "unknown run argument: $1" ;;
    esac
  done
  [ -n "$cases" ] || die "run needs --cases"
  [ -n "$out" ] || die "run needs --out"
  case "$max" in ''|*[!0-9]*) die "run needs --max-calls <non-negative integer>" ;; esac
  [ -r "$cases" ] || die "cases file not readable: $cases"
  cases_dir=$(cd "$(dirname "$cases")" && pwd)
  if [ -n "$rules" ]; then
    [ -r "$rules" ] || die "rules file not readable: $rules"
    cfg_dir=$(mktemp -d) || die "mktemp failed"
    # shellcheck disable=SC2064
    trap "rm -rf '$cfg_dir'" EXIT
    cp "$rules" "$cfg_dir/crew-dispatch.json" || die "could not stage rules file"
  fi
  while IFS=$'\t' read -r id brief project expected || [ -n "$id" ]; do
    case "$id" in ''|'#'*) continue ;; esac
    [ -n "$brief" ] || die "case $id has no brief path"
    case "$brief" in /*) ;; *) brief="$cases_dir/$brief" ;; esac
    [ -r "$brief" ] || die "case $id brief not readable: $brief"
    [ "$project" = - ] && project=''
    [ "${expected:--}" = - ] && expected=''
    if [ "$calls" -ge "$max" ]; then
      stopped=budget
      break
    fi
    calls=$((calls + 1))
    if [ -n "$cfg_dir" ]; then
      text=$(FM_HOME="$FM_HOME" FM_JEV_DISPATCH_SHADOW=0 FM_CONFIG_OVERRIDE="$cfg_dir" "$RESOLVER" "$brief" --project "$project" 2>/dev/null)
    else
      text=$(FM_HOME="$FM_HOME" FM_JEV_DISPATCH_SHADOW=0 "$RESOLVER" "$brief" --project "$project" 2>/dev/null)
    fi
    status=$(awk '/^  status: / { print $2; exit }' <<<"$text")
    rule=$(awk '/^  rule: / { print $2; exit }' <<<"$text")
    confidence=$(awk '/^  rule: / { print $NF; exit }' <<<"$text")
    reason=$(awk '/^  reason: / { sub(/^  reason: /, ""); print; exit }' <<<"$text")
    line=$(awk '/^  probabilities: / { sub(/^  probabilities: /, ""); print; exit }' <<<"$text")
    probs=$(printf '%s' "$line" | jq -Rc 'split(" ") | map(select(length > 0) | split("=") | {key: .[0], value: (.[1] | tonumber? // null)}) | if length > 0 then from_entries else null end' 2>/dev/null) || probs=null
    [ -n "$probs" ] || probs=null
    jq -nc --arg case "$id" --arg brief "$brief" --arg project "$project" --arg expected "$expected" \
      --arg status "${status:-error}" --arg rule "$rule" --arg confidence "$confidence" \
      --argjson probabilities "$probs" --arg reason "$reason" '{
        case: $case, brief: $brief, project: $project,
        expected: (if $expected == "" then null else ($expected | split("|")) end),
        status: $status, rule: (if $rule == "" then null else $rule end),
        confidence: ($confidence | tonumber? // null),
        probabilities: $probabilities,
        reason: (if $reason == "" then null else $reason end)
      }' >> "$out" || die "could not append to $out"
    written=$((written + 1))
    printf 'case %s: %s %s\n' "$id" "${status:-error}" "${rule:--}" >&2
  done < "$cases"
  printf 'replay-run: calls=%s written=%s stopped=%s\n' "$calls" "$written" "$stopped"
}

replay_score() {
  local margins='' rows=0 files=() f
  while [ $# -gt 0 ]; do
    case "$1" in
      --margin) [ $# -ge 2 ] || die "--margin needs a value"; margins=$2; shift 2 ;;
      --rows) rows=1; shift ;;
      -*) die "unknown score flag: $1" ;;
      *) files+=("$1"); shift ;;
    esac
  done
  [ "${#files[@]}" -gt 0 ] || die "score needs at least one JSONL file"
  for f in "${files[@]}"; do
    [ -r "$f" ] || die "input not readable: $f"
  done
  [ -n "$margins" ] || margins=$(replay_default_margin)
  printf '%s' "$margins" | awk -F, '{ for (i = 1; i <= NF; i++) if (!($i ~ /^(0|1)?(\.[0-9]+)?$/ && $i ~ /[0-9]/ && $i + 0 > 0 && $i + 0 <= 1)) exit 1 }' \
    || die "--margin needs comma-separated numbers in (0, 1]"
  cat "${files[@]}" | jq -rs --arg margins "$margins" --argjson rows "$rows" "$FM_JEV_CHOICE_TOP2_JQ"'
    def valid: (.probabilities | type) == "object" and (.probabilities | length) > 0
      and all(.probabilities[]; type == "number");
    def verdict($row; $pass):
      if ($row.expected | type) != "array" then "-"
      elif ($pass | not) then "-"
      elif ($row.expected | index($row.top.first)) != null then "ok"
      else "wrong" end;
    def tally($rs; $label; pass_fn):
      ($rs | map(. as $r | $r + {pass: ($r | pass_fn)})) as $g
      | "  gate: \($label) ambiguous=\([$g[] | select(.pass | not)] | length) pass=\([$g[] | select(.pass)] | length) wrong=\([$g[] | select(verdict(.; .pass) == "wrong")] | length)";
    (map(select(valid)) | to_entries | map(.value + {top: (.value.probabilities | jev_choice_top2), idx: (.key + 1)})) as $rs
    | ($margins | split(",") | map(tonumber)) as $ts
    | "replay-score: rows=\($rs | length) labeled=\([$rs[] | select((.expected | type) == "array")] | length) skipped=\(length - ($rs | length))",
      tally($rs; "confidence>=0.6"; (.confidence // 0) >= 0.6),
      ($ts[] as $t | tally($rs; "margin>=\($t)"; .top.margin >= $t)),
      (if $rows == 1 then
         ($rs[] | . as $r | ($r.top.margin >= $ts[0]) as $p
          | "  row: \($r.case // "#\($r.idx)") first=\($r.top.first) second=\($r.top.second // "-") margin=\($r.top.margin) confidence=\($r.confidence // "-") expected=\(if ($r.expected | type) == "array" then ($r.expected | join("|")) else "-" end) margin-gate=\(if $p then "pass" else "ambiguous" end) \(verdict($r; $p))")
       else empty end)
  ' || die "could not score input (not JSON lines?)"
}

[ $# -gt 0 ] || { usage; exit 2; }
case "$1" in
  run) shift; replay_run "$@" ;;
  score) shift; replay_score "$@" ;;
  -h|--help) usage ;;
  *) die "unknown command: $1 (see --help)" ;;
esac
