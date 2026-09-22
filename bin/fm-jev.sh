#!/usr/bin/env bash
# fm-jev.sh - the one Jev judgment command for firstmate and every worker.
#
# A lean CLI over bin/fm-jev-lib.sh, which stays the single owner of the HTTP
# call, route and key resolution, secret stripping, and call logging. This
# script owns only the typed argv/stdin interface, the privacy refusal, the
# escalation floor, and the one-line-per-answer output. bin/fm-dod-lib.sh's
# fm_jev_first_rule names this command to every worker; `--help` (usage below)
# is the only schema an agent ever loads, so keep it under 15 lines.
#
# Key discovery uses TYPESAFE_API_KEY from the environment, else the first
# candidate .env among $FM_HOME, this checkout, and its main worktree. The
# chosen home becomes FM_HOME for the library call. The key never reaches argv,
# stdout, stderr, or the log. This command always uses the TypeSafe route.
#
# Privacy: the state plus every question and option text is refused, never
# sent, when the state exceeds FM_JEV_CLI_STATE_MAX bytes (4096) or when
# fm_jev_compact_state would strip anything from the combined text (its
# secret patterns are the single owner of what looks like a secret), or when it
# contains the live key value itself.
#
# Escalation floor: a verdict whose confidence is below the floor prints
# ESCALATE. The default floor follows the confidence source: 0.5 for the
# confidence TypeSafe reports on choice and score answers, 0.4 for a yes/no
# answer, whose confidence is estimated here as 2*|p-0.5|, and for a choice or
# score answer with no reported confidence, estimated as top minus runner-up
# probability.
#
# Log: every attempted call appends one metadata-only record (purpose
# worker-cli, route, model, http, latency, usage in/out token counts - named
# so fm_jev_log_call's token-key redaction leaves them readable - question count,
# escalations, exit code, cwd; never the state or question text) through
# fm_jev_log_call to the chosen home's state/jev-calls.jsonl. A log failure
# never changes the result.
#
# Exit: 0 every question answered, 2 at least one escalation, 1 any error
# (usage, privacy refusal, missing key, transport, malformed response) with a
# one-line reason on stderr.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_JEV_CLI_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_JEV_CLI_STATE_MAX=4096

usage() {
  cat <<'EOF'
fm-jev.sh - one typed Jev judgment (TypeSafe) with one output line per question.
  fm-jev.sh pick  "<state>" "<question>" optA optB ...   pick one option (opt or label=meaning)
  fm-jev.sh yes   "<state>" "<question>"                 yes/no with probability p of yes
  fm-jev.sh score "<state>" "<question>" lvl1 lvl2 ...   ordered levels, lowest first
  fm-jev.sh batch < {"state":"..","questions":[{"id":"x","type":"pick|yes|score","q":"..","opts":[..]}]}
    Several questions on one state in one call; opts is an array of label or label=meaning strings.
Flags follow the command: --json (raw response); --help prints this interface.
Output: "pick: answer p=0.96 conf=0.94"; a batch uses its question id; escalation prints "ESCALATE conf=0.31 prior=X -> decide yourself".
Exit: 0 answered, 2 any escalation, 1 error with a one-line reason; on 1 or 2 use your own judgment, never block.
State: minimal facts only, at most 4096 bytes; secrets, keys, tokens, wiki page bodies, private-vault text: never.
Key: TYPESAFE_API_KEY from the environment or firstmate home .env; no OpenRouter route.
EOF
}

die() {
  printf 'fm-jev: %s\n' "$1" >&2
  exit 1
}

# Candidate homes, in order, one per line: $FM_HOME, this checkout, and the
# checkout's main worktree when this checkout is a linked worktree.
candidate_homes() {
  local common
  [ -n "${FM_HOME:-}" ] && printf '%s\n' "$FM_HOME"
  printf '%s\n' "$FM_JEV_CLI_ROOT"
  common=$(git -C "$FM_JEV_CLI_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  case "$common" in
    */.git) printf '%s\n' "${common%/.git}" ;;
  esac
}

# Set FM_HOME to the first candidate whose .env holds a TypeSafe key, unless the
# environment already carries one. Leaves FM_HOME unchanged when nothing
# matches so the library reports its own missing-key diagnostic.
select_home() {
  local home
  if [ -n "${TYPESAFE_API_KEY:-}" ]; then
    return 0
  fi
  while IFS= read -r home; do
    [ -f "$home/.env" ] || continue
    if [ -n "$(fmx_env_get TYPESAFE_API_KEY "$home/.env")" ]; then
      FM_HOME=$home
      return 0
    fi
  done < <(candidate_homes)
}

# Succeeds when <text> contains the live TypeSafe key from the environment or
# the selected home's .env. The key stays in a function-local variable.
contains_live_key() {
  local text=$1 key=${TYPESAFE_API_KEY:-} home=${FM_HOME:-$FM_JEV_CLI_ROOT}
  if [ -z "$key" ] && [ -f "$home/.env" ]; then
    key=$(fmx_env_get TYPESAFE_API_KEY "$home/.env")
  fi
  [ -n "$key" ] || return 1
  case "$text" in
    *"$key"*) return 0 ;;
  esac
  return 1
}

# --- argv ------------------------------------------------------------------
JSON=0
parse_flags() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) JSON=1; FLAG_SHIFT=$((FLAG_SHIFT + 1)); shift ;;
      -h|--help) usage; exit 0 ;;
      *) return 0 ;;
    esac
  done
}

FLAG_SHIFT=0
[ $# -gt 0 ] || { usage >&2; exit 1; }
SUB=$1
shift
FLAG_SHIFT=0
parse_flags "$@"
shift "$FLAG_SHIFT"

command -v jq >/dev/null 2>&1 || die "jq required"

# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"

# Build the normalized spec {state, questions:[{id,type,q,opts}]} on stdout.
case "$SUB" in
  pick|score)
    [ $# -ge 4 ] || die "$SUB needs <state> <question> and at least two options"
    SPEC=$(jq -n --arg id "$SUB" --arg type "$SUB" --arg state "$1" --arg q "$2" \
      '{state: $state, questions: [{id: $id, type: $type, q: $q, opts: $ARGS.positional}]}' \
      --args "${@:3}") || die "could not build the question"
    ;;
  yes)
    [ $# -eq 2 ] || die "yes needs exactly <state> <question>"
    SPEC=$(jq -n --arg id "$SUB" --arg state "$1" --arg q "$2" \
      '{state: $state, questions: [{id: $id, type: "yes", q: $q}]}') || die "could not build the question"
    ;;
  batch)
    [ $# -eq 0 ] || die "batch reads its JSON from stdin and takes no arguments"
    SPEC=$(jq -cs 'if length == 1 then .[0] else error("x") end' 2>/dev/null) \
      || die "batch input must be exactly one JSON object"
    ;;
  *)
    die "unknown command '$SUB' (want pick, yes, score, or batch; --help)"
    ;;
esac

# Validate and normalize: opts becomes an ordered [[label, meaning]] list.
NORM=$(printf '%s' "$SPEC" | jq -c '
  def fail(m): error(m);
  if type != "object" then fail("input must be a JSON object") else . end
  | if (.state | type) != "string" or .state == "" then fail("state must be a non-empty string") else . end
  | if (.questions | type) != "array" or (.questions | length) == 0 then fail("questions must be a non-empty array") else . end
  | .questions |= [ to_entries[] | .key as $i | .value
      | if type != "object" then fail("question \($i + 1) must be an object") else . end
      | .id = (.id // "q\($i + 1)")
      | if (.id | type) != "string" or (.id | test("^[A-Za-z0-9_-]{1,64}$") | not)
        then fail("question id must match [A-Za-z0-9_-]{1,64}") else . end
      | if (.q | type) != "string" or .q == "" then fail("question \(.id): q must be a non-empty string") else . end
      | if (.type | IN("pick", "yes", "score") | not) then fail("question \(.id): type must be pick, yes, or score") else . end
      | if .type == "yes" then .opts = []
        else
          .opts = (if (.opts | type) == "array" then
                     [ .opts[] | if type != "string" or . == "" then fail("question \(.id): options must be non-empty strings") else . end
                       | if test("=") then [(split("=")[0]), (split("=")[1:] | join("="))] else [., .] end
                       | if .[0] == "" then fail("question \(.id): empty option label") else . end
                       | if .[1] == "" then .[1] = .[0] else . end ]
                   else fail("question \(.id): opts must be an array of strings") end)
          | if (.opts | length) < 2 then fail("question \(.id): needs at least two options") else . end
          | if ([.opts[][0]] | unique | length) != (.opts | length) then fail("question \(.id): option labels must be unique") else . end
          | if .type == "score" and (.opts | length) > 10 then fail("question \(.id): score takes at most 10 levels") else . end
        end
      | {id, type, q, opts} ]
  | if ([.questions[].id] | unique | length) != (.questions | length) then fail("question ids must be unique") else . end
  | {state, questions}
' 2>&1) || die "$(printf '%s' "$NORM" | sed -n 's/^jq: error ([^)]*): //p' | head -n 1)"

STATE_TEXT=$(printf '%s' "$NORM" | jq -r '.state')
ALL_TEXT=$(printf '%s' "$NORM" | jq -r '.state, (.questions[] | .q, (.opts[][]))')

# --- privacy guard -----------------------------------------------------------
STATE_BYTES=$(printf '%s' "$STATE_TEXT" | wc -c)
STATE_BYTES=${STATE_BYTES// /}
[ "$STATE_BYTES" -le "$FM_JEV_CLI_STATE_MAX" ] \
  || die "state is $STATE_BYTES bytes, over the $FM_JEV_CLI_STATE_MAX-byte cap; pass only the facts the judgment needs"
COMPACT=$(JEV_STATE_MAX_BYTES=1048576 fm_jev_compact_state "$ALL_TEXT" 2>/dev/null) \
  || die "could not screen the input for secrets"
[ "$COMPACT" = "$ALL_TEXT" ] \
  || die "input looks like it carries a secret (key, token, or credential); refused, nothing sent"

select_home
if contains_live_key "$ALL_TEXT"; then
  die "input carries the Jev API key itself; refused, nothing sent"
fi

# --- the call ------------------------------------------------------------------
QUESTIONS=$(printf '%s' "$NORM" | jq -c '
  [ .questions[]
    | { key: .id,
        value: (if .type == "yes" then {type: "noul", instructions: .q}
                elif .type == "pick" then {type: "choice", instructions: .q, criteria: (.opts | map({(.[0]): .[1]}) | add)}
                else {type: "score", instructions: .q, criteria: [.opts[][1]]} end) } ]
  | from_entries')

log_call() {
  local exit_code=$1 response=${2:-} escalated=${3:-0} payload
  payload=$(jq -nc \
    --arg route "${FM_JEV_LAST_ROUTE:-}" \
    --arg model "${FM_JEV_LAST_MODEL:-}" \
    --arg http "${FM_JEV_LAST_HTTP:-}" \
    --arg latency "${FM_JEV_LAST_LATENCY_MS:-}" \
    --arg cwd "$PWD" \
    --argjson questions "$(printf '%s' "$NORM" | jq '.questions | length')" \
    --argjson escalated "$escalated" \
    --argjson exit "$exit_code" \
    --arg response "$response" \
    '{
      purpose: "worker-cli",
      route: $route,
      model: $model,
      http: $http,
      latency_ms: (try ($latency | tonumber) catch null),
      usage: {
        in: (try ($response | fromjson | .usage.input_tokens) catch null),
        out: (try ($response | fromjson | .usage.output_tokens) catch null)
      },
      questions: $questions,
      escalated: $escalated,
      exit: $exit,
      cwd: $cwd
    }' 2>/dev/null) || return 0
  fm_jev_log_call "$payload" >/dev/null 2>&1 || true
}

# fm_jev_decide runs in this shell, not a command substitution, so the
# FM_JEV_LAST_* globals it sets reach the log record.
OUT_FILE=$(mktemp) || die "mktemp failed"
ERR_FILE=$(mktemp) || { rm -f "$OUT_FILE"; die "mktemp failed"; }
trap 'rm -f "$OUT_FILE" "$ERR_FILE"' EXIT
if ! JEV_ROUTE=typesafe fm_jev_decide "$STATE_TEXT" "$QUESTIONS" >"$OUT_FILE" 2>"$ERR_FILE"; then
  log_call 1
  reason=$(sed -e 's/^jev: //' "$ERR_FILE" | head -n 1)
  die "${reason:-Jev call failed} -> decide yourself"
fi
RESPONSE=$(cat "$OUT_FILE")

# --- output --------------------------------------------------------------------
# Emits "A<TAB>line" per answered question and "E<TAB>line" per escalation, or
# fails with a one-line reason when an answer is missing or mistyped.
LINES=$(jq -rn --argjson spec "$NORM" --argjson resp "$RESPONSE" '
  def r2: (. * 100 | round) / 100;
  def estimate(p): (p | [.[]] | sort | reverse) as $s | (($s[0] // 0) - ($s[1] // 0));
  ($resp.answers // error("response has no answers")) as $answers
  | $spec.questions[]
  | . as $q
  | ($answers[$q.id] // error("response missing answer for \($q.id)")) as $a
  | if $q.type == "yes" then
      (($a.noul | numbers) // error("answer \($q.id) has no probability")) as $p
      | { answer: (if $p >= 0.5 then "yes" else "no" end), p: $p,
          conf: ((($p - 0.5) | fabs) * 2), floor: 0.4 }
    elif $q.type == "pick" then
      (($a.choice | strings) // error("answer \($q.id) has no choice")) as $c
      | if ($q.opts | map(.[0]) | index($c)) == null then
          error("answer \($q.id) chose an unoffered option")
        else
          { answer: $c, p: ($a.probabilities[$c] // null),
            conf: ($a.confidence // (if $a.probabilities then estimate($a.probabilities) else null end)),
            floor: (if $a.confidence then 0.5 else 0.4 end) }
        end
    else
      (($a.score | numbers) // error("answer \($q.id) has no score")) as $s
      | ($q.opts | length) as $n
      | (if ($a.probabilities | type) == "object" and ($a.probabilities | length) > 0
         then ($a.probabilities | keys | map(tonumber)) as $indices
         | if any($indices[]; . < 0 or . >= $n or . != floor) then
             error("answer \($q.id) has an out-of-range score index")
           else
             ($a.probabilities | to_entries | max_by(.value) | {i: (.key | tonumber), p: .value})
           end
         else {i: ([[($s | round), 0] | max, $n - 1] | min), p: null} end) as $top
      | if $top.i < 0 or $top.i >= $n or $top.i != ($top.i | floor) then
          error("answer \($q.id) has an out-of-range score index")
        else
          { answer: $q.opts[$top.i][0], p: $top.p, s: $s,
            conf: ($a.confidence // (if $a.probabilities then estimate($a.probabilities) else null end)),
            floor: (if $a.confidence then 0.5 else 0.4 end) }
        end
    end
  | if .conf == null or .conf < .floor then
      "E\t\($q.id): ESCALATE conf=\(if .conf == null then "na" else (.conf | r2) end) prior=\(.answer) -> decide yourself"
    else
      "A\t\($q.id): \(.answer)\(if .s != null then " s=\(.s | r2)" else "" end)\(if .p != null then " p=\(.p | r2)" else "" end) conf=\(.conf | r2)"
    end
' 2>&1) || {
  reason=$(printf '%s' "$LINES" | sed -n 's/^jq: error ([^)]*): //p' | head -n 1)
  log_call 1 "$RESPONSE"
  die "${reason:-malformed Jev response} -> decide yourself"
}

ESCALATED=$(printf '%s\n' "$LINES" | grep -c '^E' || true)
if [ "$ESCALATED" -gt 0 ]; then CODE=2; else CODE=0; fi
log_call "$CODE" "$RESPONSE" "$ESCALATED"

if [ "$JSON" -eq 1 ]; then
  printf '%s\n' "$RESPONSE"
else
  printf '%s\n' "$LINES" | cut -f2-
fi
exit "$CODE"
