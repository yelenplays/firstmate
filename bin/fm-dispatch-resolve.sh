#!/usr/bin/env bash
# fm-dispatch-resolve.sh - resolve one concrete crewmate or scout dispatch
# profile from a task brief: a typed Jev call (typesafe.ai's System One model),
# then a backup judge, then the configured default. It always answers.
#
# Usage:
#   fm-dispatch-resolve.sh <brief-file> [--project <name>] [--typed-only]
#
# The chain: whenever config/crew-dispatch.json parses and declares at least
#   one rule or a default, every run prints a `profile:` line, except a
#   captain-approval rule, which is an authority gate and escalates with none.
#   1. typed    - the Jev call below. A clear or picked answer decides.
#   2. backup   - when the typed call is skipped (no key, never-send match,
#                 unbuildable request), errors, cannot be reached, or stays
#                 ambiguous, bin/fm-backup-judge-lib.sh asks the same rule and
#                 effort questions on the SAME state through the local claude
#                 CLI (Haiku 5.5 by default) with schema-validated output. A
#                 never-send match skips the backup too.
#   3. default  - when the backup fails or is disabled, the configured
#                 `default` profiles (rule_1 when no default is declared).
#   Each stage settles through the same gates below. A stage whose rule
#   leaves no rankable candidate (floors, quota, ties, missing quota
#   evidence) takes a last resort inside that rule: the best-ranked eligible
#   candidate, else the first eligible, else the first declared, in declared
#   order on a tie, disclosed on a `last_resort:` line. A request that cannot
#   reach any stage falls to the first default profile (status fallback,
#   `decided: static by default`). Only a usage or configuration error exits 2.
#   --typed-only (implied by --replay) runs the typed stage alone with the
#   historical outcomes and exit codes: off, ambiguous, escalate, error.
#
# Typed-call keys: TYPESAFE_API_KEY or OPENROUTER_API_KEY non-empty in this
#   process environment, else the same names in $FM_HOME/.env read with
#   fmx_env_get, the same accessor as FMX_PAIRING_TOKEN (bin/fm-env-lib.sh).
#   The environment wins. Absent in both: the typed stage is skipped (under
#   --typed-only, one "dispatch-resolve: off" line on stderr, nothing on
#   stdout, exit 0, no network call). Keys reach curl only through
#   bin/fm-jev-lib.sh as an Authorization header read from a file descriptor,
#   never on argv, and never reach the backup judge; nothing logs or writes
#   them.
#
# The typed call: one POST through bin/fm-jev-lib.sh (TypeSafe /v1/systemone,
#   or OpenRouter /api/alpha/decisions when OPENROUTER_API_KEY is set and
#   TYPESAFE_API_KEY is not, or when JEV_ROUTE=openrouter) with the project
#   name plus either the brief's `## Captain's intent` and `## Firstmate spec`
#   sections, tagged when it is a scout brief (the whole brief when it has
#   neither section), or a compact intent summary as state, and a Choice
#   question whose options are every rule's `when` plus one fixed generic none
#   option. Optional rule precedence follows the owner contract in
#   docs/configuration.md "Crew dispatch profiles". Jev returns the matched
#   rule, a probability per option, and a confidence. The same response
#   carries a second typed Choice classifying the reasoning effort the brief
#   itself needs (low|medium|high|xhigh|max). Everything after that is jq: a
#   rule's declared `min_confidence` on that rule's probability (falling to
#   the most probable other option that clears its own floor, 0.6 when it
#   declares none), otherwise the top-2 margin gate, the rule's declared
#   `approval` and `floor`, each profile's declared `provider` and `floor`,
#   the quota rows from ONE quota-axi --json snapshot (schema 5 or 6; each
#   candidate binds to one row through quota_row in bin/fm-quota-axi-lib.sh,
#   so a Pi lane such as openai-codex-work/... reads its own account's row
#   and an expanded provider with no row for the candidate is unmeasured,
#   never blocked; a failed read leaves every candidate unranked), the spend
#   ledger's predicted burn for the assessed class (bin/fm-spend-ledger.py
#   predict), and the spendPriority argmax over the eligible candidates after
#   applying the overflow contract owned by docs/configuration.md "Overflow
#   profiles". Neither judge sees quota, catalogs, approvals, confidence
#   floors, `why`, or `use`. docs/configuration.md "Crew dispatch profiles"
#   owns the declared fields and "Typed dispatch resolution" owns this tool's
#   operator contract.
#
# Effort is a range: a profile's `effort` is the range default, optional
#   `effort_min` and `effort_max` widen it, a bare `effort` is a one-level
#   range, and an undeclared effort allows low..xhigh (max always needs an
#   explicit declaration). An `effort_floor` raises the range's lower bound
#   and its default, never exceeding its upper bound. The assessed class
#   (Jev's at confidence >= 0.5, or the backup's) is clamped into the range
#   and then moved to the nearest level the harness supports, the lower one
#   on a tie; a clamp is shown as `[clamped from <class>]` and logged, never
#   refused. A missing, malformed, or low-confidence effort answer falls back
#   to the range default and says so. A candidate whose predicted burn exceeds
#   the tightest applicable remaining percent or usable runway is refused
#   with the prediction named in the reason. Missing ledger evidence never
#   fabricates a limit: the candidate keeps today's rank and its line shows
#   pred=unknown.
#   FM_SPEND_LEDGER overrides the ledger path (tests).
#
# Runoff on ambiguous: the picked option and the top two by probability each
#   settle as though they had cleared (same gates, same spendPriority argmax).
#   When every contender settles on a concrete profile, contenders that share
#   one profile collapse, a single remaining profile is taken with no call, and
#   otherwise one more POST asks a typed `pick` Choice keyed by rule and worded
#   with the same criteria the rule Choice sent, on the same state. The pick
#   clears on the same top-2 margin gate, or on an option's strictest declared
#   min_confidence instead, and makes the answer `picked`. Any
#   contender that would not clear (captain approval, unverifiable floor,
#   nothing rankable, tie) skips the runoff, and a narrow, non-winning,
#   malformed, failed, or never-send-withheld pick leaves the typed stage
#   ambiguous, so the backup decides.
#
# Never-send check: when the optional $FM_HOME/config/dispatch-never-send list
#   exists, every string value of the built request is checked against it
#   before the POST. Each non-blank, non-# line is a literal matched
#   case-insensitively, with surrounding whitespace trimmed and every run of
#   whitespace, on both sides, treated as one space. A match, or a list that
#   is not a readable regular file, sends nothing to either judge and the
#   default stage answers; the reason names at most the list line number,
#   never its value. Under --typed-only it prints one
#   "dispatch-resolve: off (...; nothing sent)" line on stderr, nothing on
#   stdout, and exits 0 with no network or quota call. The runoff request is
#   checked the same way; a match there sends nothing and leaves the typed
#   stage ambiguous with a `pick: skipped` line.
#
# Output (stdout, TOON-style block):
#   dispatch-resolve:
#     status: clear | picked | backup | fallback | ambiguous | escalate | error
#     decided: <rule> by typed|backup|default             (chain only)
#     typed: <why the typed stage did not decide>         (chain only)
#     backup: <rule> effort=<e> (<model>, <ms> ms) | failed (<why>) | skipped (<why>)
#     model/latency_ms/tokens, rule (when excerpt) and confidence, probabilities
#     effort: <assessed class> (jev confidence=.. | backup judge | declared | declared fallback (classifier <why>))
#     fallback: <runner-up rule taken when the picked rule missed its own declared floor>
#     reason: <why the status is not clear; an all-refused escalate names the predicted burn>
#     note: <quota or floor context>
#     pick: <rule> (<rules>) over <rules> by jev runoff   p=.. margin=..  (picked)
#           <rules> settle on the same profile (no runoff call)           (picked)
#           skipped|undecided|error (<why>)                               (ambiguous)
#     candidate: <harness>:<model> provider=.. effort=<class>(range <range>) [clamped from <class>]
#       scope=.. remaining=..% spendPriority=.. runway=.. pred=~<tokens>tok/<seconds>s | pred=unknown
#       -> eligible | eligible, unranked: <reason> | not eligible: <reason>
#     last_resort: <why the stage's own ranking could not choose>
#     profile: --harness <h> [--model <m>] [--effort <e>]
#   clear     -> the typed call decided; pass the profile line to fm-spawn.sh (AGENTS.md section 4 owns the only overrides)
#   picked    -> the typed rule answer was ambiguous and the runoff settled it; pass the profile line the same way
#   backup    -> the backup judge decided; pass the profile line the same way
#   fallback  -> the default stage or a last resort decided; pass the profile line the same way
#   escalate  -> the rule requires captain approval (no profile); under --typed-only also no rankable candidate or a tie
#   ambiguous, error -> --typed-only only; decide as today
#   Every outcome exits 0 so an intake is never blocked by this tool.
#   Exit 2 only for a usage or configuration error (unreadable brief, an
#   existing unreadable rules file, malformed rules, an invalid
#   FM_JEV_DISPATCH_MARGIN, or missing jq), which is
#   actionable, never selected around.
#   Chain runs append one metadata-only record per answer (status, stage,
#   rule, effort and clamp, profile, reasons; never the brief) to
#   $FM_HOME/state/dispatch-resolve.jsonl.
#
# Environment:
#   TYPESAFE_API_KEY and/or OPENROUTER_API_KEY enable the typed stage.
#   JEV_ROUTE, JEV_MODEL, JEV_URL, JEV_BASE, and JEV_TIMEOUT follow
#   docs/configuration.md "Typed dispatch resolution" (env then .env).
#   JEV_ROUTE=openrouter selects OpenRouter even when a TypeSafe key is also
#   present. FM_JEV_DISPATCH_SHADOW=1 or config/jev-dispatch-shadow logs the
#   Jev pick to state/jev-dispatch-shadow.jsonl and does not add spawn
#   authority beyond today's optional clear-profile use.
#   FM_JEV_DISPATCH_EXTRA=1 adds log-only home and deliverable questions.
#   FM_JEV_DISPATCH_MARGIN configures the clear gate; docs/configuration.md
#   "Typed dispatch resolution" owns its source, range, default, and calibration.
#   FM_JEV_DISPATCH_COMPACT is read from the process environment first, else
#   from $FM_HOME/.env via fmx_env_get; the environment wins. A truthy value
#   sends a 400-800 character intent summary instead of the whole brief
#   (default on for the OpenRouter route when both are unset).
#   FM_BACKUP_JUDGE, FM_BACKUP_JUDGE_CMD, FM_BACKUP_JUDGE_MODEL, and
#   FM_BACKUP_JUDGE_TIMEOUT configure the backup judge
#   (bin/fm-backup-judge-lib.sh owns them; FM_BACKUP_JUDGE=off disables it).
#
# Authority: this tool never replaces the captain-approval gate or fm-spawn.sh
#   validation; it publishes one inspectable answer plus every candidate's
#   evidence, in code.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
OPENROUTER_API_KEY_PRIVATE=${OPENROUTER_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY OPENROUTER_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"
# shellcheck source=bin/fm-never-send-lib.sh
. "$SCRIPT_DIR/fm-never-send-lib.sh"
# shellcheck source=bin/fm-backup-judge-lib.sh
. "$SCRIPT_DIR/fm-backup-judge-lib.sh"

DEFAULT_MARGIN=0.4
# Below this confidence the effort answer is not trusted and each profile's
# declared effort (its range default) applies instead.
EFFORT_CONFIDENCE_FLOOR=0.5
# Only the floor an undeclared runner-up must clear when a rule's own declared
# min_confidence sends the pick to it; the top-2 margin gates the model's pick.
CONFIDENCE_FLOOR=0.6
DEFAULT_WHEN="No listed rule applies to this task."
DISPATCH_HOMES="main agency lay frontend zimmer"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
no_rules() {
  printf 'dispatch-resolve:\n  status: escalate\n  reason: no rules to match\n'
  exit 0
}
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fm_dispatch_truthy() {
  case "$1" in 1|on|true|yes) return 0 ;; *) return 1 ;; esac
}

fm_dispatch_shadow_on() {
  local v=${FM_JEV_DISPATCH_SHADOW:-}
  if [ -n "$v" ]; then
    fm_dispatch_truthy "$v"
    return
  fi
  [ -e "$CONFIG/jev-dispatch-shadow" ]
}

fm_dispatch_route() {
  local route
  route=$(_fm_jev_cfg JEV_ROUTE)
  case "$route" in
    openrouter) printf 'openrouter' ;;
    typesafe) printf 'typesafe' ;;
    '')
      if [ -n "$TYPESAFE_API_KEY_PRIVATE" ]; then
        printf 'typesafe'
      else
        printf 'openrouter'
      fi
      ;;
    *) printf '%s' "$route" ;;
  esac
}

fm_dispatch_compact_on() {
  local v=${FM_JEV_DISPATCH_COMPACT:-}
  if [ -n "$v" ]; then
    fm_dispatch_truthy "$v"
    return
  fi
  v=$(fmx_env_get FM_JEV_DISPATCH_COMPACT "$FM_HOME/.env")
  if [ -n "$v" ]; then
    fm_dispatch_truthy "$v"
    return
  fi
  [ "$(fm_dispatch_route)" = openrouter ]
}

fm_dispatch_margin() {
  local v=${FM_JEV_DISPATCH_MARGIN:-}
  if [ -z "$v" ]; then
    v=$(fmx_env_get FM_JEV_DISPATCH_MARGIN "$FM_HOME/.env")
  fi
  if [ -z "$v" ]; then
    printf '%s' "$DEFAULT_MARGIN"
    return 0
  fi
  awk -v m="$v" 'BEGIN { exit !(m ~ /^(0|1)?(\.[0-9]+)?$/ && m ~ /[0-9]/ && m+0 > 0 && m+0 <= 1) }' || return 1
  case "$v" in .*) v="0$v" ;; esac
  printf '%s' "$v"
}

fm_dispatch_flatten_truncate() {
  local n=${2:-800}
  printf '%s' "$1" | awk -v n="$n" '
    {
      if (NR > 1) buf = buf " "
      buf = buf $0
    }
    END {
      gsub(/[ \t\r\n]+/, " ", buf)
      sub(/^ /, "", buf)
      sub(/ $/, "", buf)
      if (n > 0 && length(buf) > n) buf = substr(buf, 1, n)
      printf "%s", buf
    }'
}

fm_dispatch_intent_summary() {
  local brief=$1 text
  text=$(awk '
    /^## Captain'\''s intent([[:space:]]|$)/ { grab=1; next }
    /^## / { if (grab) exit }
    grab { print }
  ' "$brief")
  if [ -z "$text" ]; then
    text=$(cat "$brief")
  fi
  fm_dispatch_flatten_truncate "$text" 800
}

fm_dispatch_home_criteria() {
  local reg="$FM_HOME/data/secondmates.md" id scope fallback json='{}'
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
  for id in $DISPATCH_HOMES; do
    if [ "$id" = main ]; then
      fallback='The main firstmate home; work that no registered secondmate scope covers.'
    else
      fallback="The ${id} secondmate home."
    fi
    scope=''
    if [ -f "$reg" ] && [ ! -L "$reg" ]; then
      scope=$(secondmate_registry_field "$reg" "$id" scope 2>/dev/null) || scope=''
    fi
    if [ -z "$scope" ]; then
      scope=$fallback
    fi
    scope=$(fm_dispatch_flatten_truncate "$scope" 200)
    json=$(jq -c --arg id "$id" --arg scope "$scope" '. + {($id): $scope}' <<<"$json")
  done
  printf '%s' "$json"
}

BRIEF='' PROJECT='' RULES_PATH="$CONFIG/crew-dispatch.json" RULES='' REPLAY=0 TYPED_ONLY=0
NEVER_SEND_PATH="$CONFIG/dispatch-never-send"
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || die "--project needs a value"; PROJECT=$2; shift 2 ;;
    --replay) REPLAY=1; TYPED_ONLY=1; shift ;;
    --typed-only) TYPED_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$BRIEF" ] || die "one brief file only"; BRIEF=$1; shift ;;
  esac
done

# ---- opt-in gate ---------------------------------------------------------------
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
fi
if [ -z "$OPENROUTER_API_KEY_PRIVATE" ]; then
  OPENROUTER_API_KEY_PRIVATE=$(fmx_env_get OPENROUTER_API_KEY "$FM_HOME/.env")
fi
TYPED_SKIP=''
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ] && [ -z "$OPENROUTER_API_KEY_PRIVATE" ]; then
  if [ "$TYPED_ONLY" -eq 1 ]; then
    echo "dispatch-resolve: off (TYPESAFE_API_KEY and OPENROUTER_API_KEY absent from the environment and $FM_HOME/.env)" >&2
    exit 0
  fi
  TYPED_SKIP='no typed-call key configured'
fi

# ---- inputs --------------------------------------------------------------------
[ -n "$BRIEF" ] || die "brief file required (see --help)"
MARGIN=$(fm_dispatch_margin) || die "FM_JEV_DISPATCH_MARGIN must be a number in (0, 1]"
[ -r "$BRIEF" ] || die "brief file not readable: $BRIEF"
[ -e "$RULES_PATH" ] || [ -L "$RULES_PATH" ] || no_rules
[ -r "$RULES_PATH" ] || die "rules file not readable: $RULES_PATH"
command -v jq >/dev/null 2>&1 || die "jq required"
RULES=$(mktemp) || die "mktemp failed"
trap 'rm -f "$RULES"' EXIT
cp "$RULES_PATH" "$RULES" || die "could not snapshot rules file: $RULES_PATH"
chmod 400 "$RULES" || die "could not protect rules snapshot"
VERIFIED_HARNESSES=$(fm_control_harnesses | jq -Rsc 'split("\n") | map(select(length > 0))')

# The fields this tool consumes must be well formed; bootstrap owns the wider
# schema diagnostic, but an intake never selects around a malformed file.
rules_err=$(jq -r --argjson verified_harnesses "$VERIFIED_HARNESSES" --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
  def verified($h): $verified_harnesses | index($h);
  def provider_id($p): ($p | type) == "string" and ($p | test($provider_re));
  def effort_ok($h; $m; $e):
    if $e == null then true
    elif ($e | type) != "string" then false
    elif $e == "ultra" then (($h == "pi" or $h == "pi-signed") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
    elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "codex" then ((["low","medium","high","xhigh"] | index($e)) != null or ($e == "max" and $m == "gpt-5.6-luna"))
    elif $h == "grok" or $h == "agy" then (["low","medium","high"] | index($e)) != null
    elif $h == "pi" or $h == "pi-signed" or $h == "omp" or $h == "muse" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "rovo" then (["low","medium","high","max"] | index($e)) != null
    elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
    else true end;
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def floor_bad($f; $need_provider):
    ($f | type) != "object"
    or (($f.scope | type) != "string") or (($f.scope | length) == 0)
    or (($f.min_percent | type) != "number") or ($f.min_percent < 0) or ($f.min_percent > 100)
    or (if $need_provider
        then (provider_id($f.provider) | not)
        else ($f | has("provider"))
        end);
  def profile_bad($p):
    ($p | type) != "object"
    or (($p.harness | type) != "string") or (($p.harness | length) == 0)
    or ($p | has("model") and ((.model | type) != "string" or (.model | length) == 0))
    or ($p | has("effort") and ((.effort | type) != "string" or (.effort | length) == 0))
    or ($p | has("effort_min") and ((.effort_min | type) != "string" or (.effort_min | length) == 0))
    or ($p | has("effort_max") and ((.effort_max | type) != "string" or (.effort_max | length) == 0))
    or ($p | has("provider") and (provider_id(.provider) | not))
    or ($p | has("floor") and floor_bad(.floor; false));
  def overflow_bad($p): ($p | type) == "object" and ($p | has("overflow")) and (($p.overflow | type) != "boolean");
  def effort_floor_bad($p):
    ($p | type) == "object" and ($p | has("effort_floor")) and
    (($p.effort_floor | type) != "string"
     or (["low","medium","high","xhigh","max"] | index($p.effort_floor)) == null
     or (["claude","codex","grok","agy","pi","pi-signed","omp","muse","rovo"] | index($p.harness)) == null
     or (effort_ok($p.harness; $p.model; $p.effort_floor) | not)
     or ((["low","medium","high","xhigh","max"] | index($p.effort_floor))
         > (["low","medium","high","xhigh","max","ultra"] | index($p.effort_max // $p.effort // "xhigh"))));
  # An effort range is effort_min..effort_max around the declared effort, which
  # is the range default and must lie inside it; a bare effort is a one-level
  # range. Ranks follow the effort ladder, ultra last.
  def effort_rank($e): (["low","medium","high","xhigh","max","ultra"] | index($e));
  def range_bad($p):
    ($p | has("effort_min") or has("effort_max")) and (
      ($p | has("effort") | not)
      or effort_rank($p.effort) == null
      or effort_rank($p.effort_min // $p.effort) == null
      or effort_rank($p.effort_max // $p.effort) == null
      or effort_rank($p.effort_min // $p.effort) > effort_rank($p.effort)
      or effort_rank($p.effort) > effort_rank($p.effort_max // $p.effort));
  def range_effort_ok($p):
    effort_ok($p.harness; $p.model; ($p.effort_min // null)) and effort_ok($p.harness; $p.model; ($p.effort_max // null));
  def beats_bad($self; $count):
    (type != "array") or (length == 0)
    or any(.[]; (type != "object")
      or ((.rule | type) != "number") or (.rule != (.rule | floor))
      or (.rule < 1) or (.rule > $count) or (.rule == $self)
      or (has("when") and ((.when | type) != "string" or (.when | length) == 0)))
    or ((map(.rule) | length) != (map(.rule) | unique | length));
  def mutual_unconditional($rs):
    [range(0; $rs | length) as $i | ($rs[$i].beats // [])[] | select(has("when") | not) | [$i + 1, .rule]] as $e
    | any($e[]; . as [$w, $l] | ($e | index([[$l, $w]])) != null);
  def beats_edges($rs):
    [range(0; $rs | length) as $i
      | ($rs[$i] | if type == "object" then (.beats // []) else [] end)
      | if type == "array" then .[] else empty end
      | select(type == "object" and (.rule | type) == "number" and .rule == (.rule | floor))
      | [$i + 1, .rule]];
  def visit_beats($edges; $state; $node):
    ($state | .seen += [$node] | .active += [$node]) as $entered
    | reduce ([$edges[] | select(.[0] == $node) | .[1]] | unique | sort)[] as $next
        ($entered;
         if .cycle != null then .
         else
           (.active | index($next)) as $active_index
           | if $active_index != null then
               if (.active | length) - $active_index >= 3 then
                 .cycle = (.active[$active_index:] + [$next])
               else . end
             elif (.seen | index($next)) != null then .
             else visit_beats($edges; .; $next)
             end
         end)
    | .active = .active[:-1];
  def beats_cycle($rs):
    if ($rs | type) != "array" then null
    else
      beats_edges($rs) as $edges
      | reduce range(1; ($rs | length) + 1) as $node
          ({seen: [], active: [], cycle: null};
           if .cycle != null or (.seen | index($node)) != null then .
           else visit_beats($edges; .; $node)
           end)
      | .cycle
    end;
  def beats_cycle_error($rs):
    beats_cycle($rs) as $cycle
    | if $cycle == null then null
      else "beats must not form a cycle of three or more rules: "
        + ($cycle | map("rule_\(.)") | join(" -> "))
      end;
  def duplicate_profiles($items):
    ($items | map([.harness, (.model // null), (.effort // null)] | @json)) as $keys
    | ($keys | length) != ($keys | unique | length);
  beats_cycle_error(.rules // []) as $beats_cycle_error
  | if type != "object" then "top-level value must be an object"
  elif has("rules") and (.rules | type) != "array" then "rules must be an array"
  elif any((.rules // [])[]; type != "object") then "each rule must be an object"
  elif any((.rules // [])[]; (.when | type) != "string" or (.when | length) == 0) then "each rule needs non-empty when"
  elif any((.rules // [])[]; (profiles(.use) | length) == 0) then "each rule needs at least one use profile"
  elif any((.rules // [])[]; has("approval") and .approval != "captain") then "approval must be \"captain\" when present"
  elif any((.rules // [])[]; has("min_confidence") and ((.min_confidence | type) != "number" or .min_confidence < 0 or .min_confidence > 1)) then "min_confidence must be a number from 0 through 1 when present"
  elif any((.rules // [])[]; has("select") and ((.select | type) != "string" or (.select | length) == 0)) then "select must be a non-empty string"
  elif any((.rules // [])[]; has("select") and .select != "quota-balanced") then
    "unknown select: " + ([.rules[] | select(has("select") and .select != "quota-balanced") | .select] | unique | join(", "))
  elif any((.rules // [])[]; has("floor") and floor_bad(.floor; true)) then "rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\\z"
  elif (.rules // []) as $rs | any(range(0; $rs | length); . as $i | $rs[$i] | has("beats") and (.beats | beats_bad($i + 1; $rs | length))) then "beats must be a non-empty array of {rule, when?} naming other rules by 1-based number, each at most once, with when a non-empty string when present"
  elif mutual_unconditional(.rules // []) then "two rules must not beat each other unconditionally; give at least one of the pair a when condition"
  elif $beats_cycle_error != null then $beats_cycle_error
  elif any((.rules // [])[] | profiles(.use)[]; profile_bad(.)) then "each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif any(((.rules // [])[] | profiles(.use)[]), profiles(.default)[]; overflow_bad(.)) then "profile overflow must be true or false when present"
  elif any(((.rules // [])[] | profiles(.use)[]), profiles(.default)[]; effort_floor_bad(.)) then "profile effort_floor must be low, medium, high, xhigh, or max and not above the profile effort, supported by an effort-capable harness and model"
  elif any((.rules // [])[]; duplicate_profiles(profiles(.use))) then "each rule use must not contain duplicate harness, model, and effort profiles"
  elif any((.rules // [])[] | profiles(.use)[]; (verified(.harness) | not)) then "each use profile must name a verified harness"
  elif any((.rules // [])[] | profiles(.use)[]; (effort_ok(.harness; .model; .effort) | not)) then "each use profile effort must be supported by its harness and model"
  elif any((.rules // [])[] | profiles(.use)[]; range_bad(.)) then "each use profile effort_min and effort_max need effort, and effort_min <= effort <= effort_max on low < medium < high < xhigh < max < ultra"
  elif any((.rules // [])[] | profiles(.use)[]; (range_effort_ok(.) | not)) then "each use profile effort_min and effort_max must be supported by its harness and model"
  elif has("default") and (profiles(.default) | length) == 0 then "default must be a profile object or non-empty profile array"
  elif has("default") and any(profiles(.default)[]; profile_bad(.)) then "each default profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif has("default") and duplicate_profiles(profiles(.default)) then "default must not contain duplicate harness, model, and effort profiles"
  elif has("default") and any(profiles(.default)[]; (verified(.harness) | not)) then "each default profile must name a verified harness"
  elif has("default") and any(profiles(.default)[]; (effort_ok(.harness; .model; .effort) | not)) then "each default profile effort must be supported by its harness and model"
  elif has("default") and any(profiles(.default)[]; range_bad(.)) then "each default profile effort_min and effort_max need effort, and effort_min <= effort <= effort_max on low < medium < high < xhigh < max < ultra"
  elif has("default") and any(profiles(.default)[]; (range_effort_ok(.) | not)) then "each default profile effort_min and effort_max must be supported by its harness and model"
  else empty end
' "$RULES" 2>/dev/null) || die "malformed rules file: $RULES_PATH (not JSON)"
[ -z "$rules_err" ] || die "malformed rules file: $RULES_PATH - $rules_err"

missing_provider=$(jq -r '
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  ((.rules // [])[] | profiles(.use)[] | select(has("provider") | not) | "use\t\(.harness)"),
  (profiles(.default // null)[] | select(has("provider") | not) | "default\t\(.harness)")
' "$RULES" | while IFS=$'\t' read -r location harness; do
  if ! fm_quota_single_provider_for_harness "$harness" >/dev/null; then
    printf '%s\t%s\n' "$location" "$harness"
  fi
done)
if [ -n "$missing_provider" ]; then
  missing_provider_detail=''
  while IFS=$'\t' read -r location harness; do
    missing_provider_detail="${missing_provider_detail:+$missing_provider_detail; }$location profiles whose harness lacks one authoritative provider family require provider: $harness"
  done <<< "$missing_provider"
  die "malformed rules file: $RULES_PATH - $missing_provider_detail"
fi

# ---- harness -> provider map, from the single owner in fm-quota-axi-lib.sh -----
PMAP='{}'
while IFS= read -r h; do
  [ -n "$h" ] || continue
  p=$(fm_quota_single_provider_for_harness "$h" 2>/dev/null) || p=''
  PMAP=$(jq -c --arg h "$h" --arg p "$p" '. + {($h): (if $p == "" then null else $p end)}' <<<"$PMAP")
done < <(jq -r '
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  ([((.rules // [])[]) | profiles(.use)[]] + profiles(.default // null))
  | map(.harness) | unique | .[]' "$RULES")

RULE_COUNT=$(jq -r '(.rules // []) | length' "$RULES")
HAS_DEFAULT=$(jq -r 'has("default")' "$RULES")

# Without --typed-only the resolver always answers: a failure anywhere past the
# rules check falls to the static last resort below instead of to no answer.
emit_error() {
  local reason=$1
  echo "dispatch-resolve: error ($reason)" >&2
  if [ "$TYPED_ONLY" -eq 0 ]; then
    static_fallback "$reason"
  fi
  printf 'dispatch-resolve:\n  status: error\n  reason: %s\n' "$reason"
  exit 0
}

# The last resort when even the staged chain cannot run: the first declared
# default profile, else the first profile of the first rule that needs no
# captain approval, with its declared effort, read from the validated rules
# snapshot alone. Only a file whose every profile sits behind approval leaves
# no profile, because approval is an authority gate, not uncertainty.
static_fallback() {
  local reason=$1 line
  line=$(jq -r '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    def shell_arg: tostring | gsub("[\t\r\n]"; " ") | @sh;
    (profiles(.default // null) + [(.rules // [])[] | select((.approval // "") != "captain") | profiles(.use)[]])
    | first // empty
    | . as $c
    | if $c.effort_floor != null and ($c.effort == null or
        ((["low","medium","high","xhigh","max","ultra"] | index($c.effort)) <
         (["low","medium","high","xhigh","max","ultra"] | index($c.effort_floor))))
      then .effort = $c.effort_floor else . end
    | "--harness \(.harness | shell_arg)"
      + (if .model then " --model \(.model | shell_arg)" else "" end)
      + (if .effort then " --effort \(.effort | shell_arg)" else "" end)' "$RULES" 2>/dev/null) || line=''
  [ -n "$line" ] || return 0
  printf 'dispatch-resolve:\n  status: fallback\n  decided: static by default\n  reason: %s; static last resort: first declared profile\n  profile: %s\n' \
    "$(printf '%s' "$reason" | tr '\t\r\n' '   ')" "$line"
  dispatch_log "$(jq -nc --arg reason "$reason" --arg profile "$line" '{status: "fallback", decided_by: "default", rule: "static", reason: $reason, profile_line: $profile}')"
  exit 0
}

# One metadata-only line per chained run: which stage decided, the rule, the
# effort, and the profile, never the brief or the request text.
DISPATCH_LOG="$FM_HOME/state/dispatch-resolve.jsonl"
dispatch_log() {
  [ "$TYPED_ONLY" -eq 0 ] || return 0
  [ ! -L "$DISPATCH_LOG" ] || return 0
  mkdir -p "$FM_HOME/state" 2>/dev/null || return 0
  fm_jev_log_call "$(jq -c --arg at "$(fm_jev_iso_now)" --arg project "$PROJECT" '{timestamp: $at, project: $project} + .' <<<"$1")" "$DISPATCH_LOG" >/dev/null 2>&1 || true
}

if [ "$RULE_COUNT" -eq 0 ] && { [ "$TYPED_ONLY" -eq 1 ] || [ "$HAS_DEFAULT" != true ]; }; then
  no_rules
fi

RESP_FILE=$(mktemp) || die "mktemp failed"
QUOTA=$(mktemp) || { rm -f "$RESP_FILE"; die "mktemp failed"; }
TASK_TEXT=$(mktemp) || { rm -f "$RESP_FILE" "$QUOTA"; die "mktemp failed"; }
PREDICT_FILE=$(mktemp) || { rm -f "$RESP_FILE" "$QUOTA" "$TASK_TEXT"; die "mktemp failed"; }
PICK_FILE=$(mktemp) || { rm -f "$RESP_FILE" "$QUOTA" "$TASK_TEXT" "$PREDICT_FILE"; die "mktemp failed"; }
BACKUP_FILE=$(mktemp) || { rm -f "$RESP_FILE" "$QUOTA" "$TASK_TEXT" "$PREDICT_FILE" "$PICK_FILE"; die "mktemp failed"; }
trap 'rm -f "$RULES" "$RESP_FILE" "$QUOTA" "$TASK_TEXT" "$PREDICT_FILE" "$PICK_FILE" "$BACKUP_FILE"' EXIT

# A never-send match sends nothing to any judge: --typed-only reports the
# historical off line, and the chain goes straight to the default stage.
NEVER_SEND_BLOCKED=0
never_send_off() {
  echo "dispatch-resolve: off ($1; nothing sent)" >&2
  if [ "$TYPED_ONLY" -eq 1 ]; then
    exit 0
  fi
  NEVER_SEND_BLOCKED=1
  TYPED_SKIP="$1; nothing sent"
}

# Use the same final-request screening as advisory model proposals.
NEVER_SEND_WHY=''
never_send_scan() {
  NEVER_SEND_WHY=''
  if fm_never_send_check "$NEVER_SEND_PATH" "$1" "brief text"; then
    return 0
  fi
  NEVER_SEND_WHY=$FM_NEVER_SEND_ERROR
  return 1
}

# Send Jev only the task-specific sections bin/fm-brief.sh scaffolds, plus a
# scout tag from the scout contract line; the rest of a scaffolded brief is
# standard boilerplate whose safety language reads as high stakes on every task.
# A brief with neither section goes whole. Ship delivery mode is deliberately
# not sent: live runs showed it pushing routine ship briefs to the top tier.
brief_kind() {
  if grep -qxF 'This is a SCOUT task: the deliverable is a written report, not a PR.' "$BRIEF"; then
    printf 'Brief kind: scout (report only)\n\n'
  fi
}
task_sections() {
  local heading
  for heading in "## Captain's intent" "## Firstmate spec"; do
    fm_brief_task_heading_present "$BRIEF" "$heading" || continue
    printf '%s\n%s\n\n' "$heading" "$(fm_brief_task_heading_body "$BRIEF" "$heading")"
  done
}
SECTIONS=$(task_sections)
if [ -n "$SECTIONS" ]; then
  { brief_kind; printf '%s\n' "$SECTIONS"; } > "$TASK_TEXT" || die "could not read brief: $BRIEF"
else
  cp "$BRIEF" "$TASK_TEXT" || die "could not read brief: $BRIEF"
fi
LAT_MS=null
EXTRA_LOG=null
STATE='' QUESTIONS='' REQUEST=''
# A request that cannot be built cannot reach any judge: --typed-only reports
# it as the historical error, and the chain goes to the default stage.
state_fail() {
  [ "$TYPED_ONLY" -eq 0 ] || emit_error "$1"
  TYPED_SKIP=$1
  STATE=''
}
EXTRA=0
if fm_dispatch_truthy "${FM_JEV_DISPATCH_EXTRA:-}"; then
  EXTRA=1
fi
build_request() {
  # --typed-only keeps the historical order: no curl is reported before any
  # request work.
  if [ "$TYPED_ONLY" -eq 1 ] && ! command -v curl >/dev/null 2>&1; then
    emit_error "curl not installed"
  fi
  if [ "$EXTRA" -eq 1 ]; then
    HOME_CRITERIA=$(fm_dispatch_home_criteria)
  else
    HOME_CRITERIA='{}'
  fi
  if fm_dispatch_compact_on; then
    BRIEF_TEXT=$(fm_dispatch_intent_summary "$BRIEF")
  else
    BRIEF_TEXT=$(cat "$TASK_TEXT")
  fi
  BRIEF_TEXT=$(fm_jev_compact_state "$BRIEF_TEXT") || { state_fail "state exceeds size limit"; return; }
  STATE=$(jq -nc --arg project "$PROJECT" --arg brief "$BRIEF_TEXT" '{task:{project:$project, brief:$brief}}') \
    || { state_fail "could not build state"; return; }
  QUESTIONS=$(jq -nc --arg none_criterion "$DEFAULT_WHEN" --argjson extra "$EXTRA" --argjson homes "$HOME_CRITERIA" --slurpfile rules "$RULES" '
    ($rules[0].rules) as $rs |
    ([range(0; $rs | length) as $i | ($rs[$i].beats // [])[] | {w: ($i + 1), l: .rule, c: (.when // null)}]) as $edges |
    def cond($e): if $e.c == null then "" else " and \($e.c)" end;
    ($rs | to_entries | map((.key + 1) as $n | {
      key: "rule_\($n)",
      value: (.value.when
        + ([$edges[] | select(.w == $n) | " Tie-break: when rule_\(.l) also fits\(cond(.)), choose this option over rule_\(.l)."] | join(""))
        + ([$edges[] | select(.l == $n) | " Tie-break: when rule_\(.w) also fits\(cond(.)), choose rule_\(.w) over this option."] | join("")))
    }) | from_entries) as $criteria |
    {
      rule: {
        type: "choice",
        instructions: ("Which ONE dispatch rule best fits `task` (read `task.brief` and `task.project`)? Each option is the rule'"'"'s own matching condition; pick `default` when no rule'"'"'s condition is met, including when a rule'"'"'s own exemption text excludes this task."
          + (if ($edges | length) > 0 then " When more than one option fits, follow the Tie-break sentences at the end of the options; any rule whose condition fits wins over `default`." else "" end)),
        criteria: ($criteria + {default: $none_criterion})
      },
      effort: {
        type: "choice",
        instructions: "What reasoning effort does `task` itself need? Judge the work'"'"'s intrinsic difficulty from task.brief, independently of any dispatch rule. `max` is reserved: choose it only when the task text itself explicitly demands maximum effort; otherwise never.",
        criteria: {
          low: "Trivial mechanical work: a rote rename, formatting sweep, targeted typo fix, or single-file gathering.",
          medium: "Contained work needing ordinary care: a small feature, a narrow bug fix, or a bounded question.",
          high: "Big or ambiguous multi-file work: a feature across several files, a risky refactor, or many moving parts.",
          xhigh: "Deep-deliberation work: safety-critical, subtle, or highly ambiguous tasks where mistakes are costly.",
          max: "Maximum effort. Choose only when the task text itself explicitly demands maximum effort; otherwise never."
        }
      }
    } + (if $extra == 1 then {
      home: {
        type: "choice",
        instructions: "Which Firstmate home should own this work? This answer is log-only and must not route the task.",
        criteria: $homes
      },
      deliverable: {
        type: "choice",
        instructions: "Should this work ship a change, produce a scout report, or neither? This answer is log-only.",
        criteria: {
          ship: "A project change through the selected delivery path.",
          scout: "A knowledge-only report, not a PR.",
          neither: "Neither a ship nor a scout."
        }
      }
    } else {} end)
  ') || { state_fail "could not build questions"; return; }
  REQUEST=$(jq -nc --argjson state "$STATE" --argjson questions "$QUESTIONS" '{state: $state, questions: $questions}') \
    || { state_fail "could not build request"; return; }
  never_send_scan "$REQUEST" || never_send_off "$NEVER_SEND_WHY"
}
if [ "$RULE_COUNT" -gt 0 ]; then
  build_request
else
  TYPED_SKIP='no rules to match'
fi

# ---- typed stage: one Jev call through bin/fm-jev-lib.sh -------------------------
# Returns 0 with a validated rule answer in RESP_FILE and EFFORT_JSON set, or 1
# with the reason in TYPED_REASON. --typed-only turns every failure into the
# historical error outcome instead.
TYPED_REASON=''
typed_fail() {
  [ "$TYPED_ONLY" -eq 0 ] || emit_error "$1"
  TYPED_REASON=$1
  return 1
}
typed_call() {
  local decide_err=0 http
  if [ -n "$TYPED_SKIP" ] || [ -z "$STATE" ]; then
    TYPED_REASON="skipped (${TYPED_SKIP:-no request})"
    return 1
  fi
  command -v curl >/dev/null 2>&1 || { typed_fail "curl not installed"; return 1; }
  [ -n "$TYPESAFE_API_KEY_PRIVATE" ] && TYPESAFE_API_KEY=$TYPESAFE_API_KEY_PRIVATE
  [ -n "$OPENROUTER_API_KEY_PRIVATE" ] && OPENROUTER_API_KEY=$OPENROUTER_API_KEY_PRIVATE
  fm_jev_decide "$STATE" "$QUESTIONS" > "$RESP_FILE" || decide_err=$?
  LAT_MS=${FM_JEV_LAST_LATENCY_MS:-0}
  http=${FM_JEV_LAST_HTTP:-000}
  unset TYPESAFE_API_KEY OPENROUTER_API_KEY
  if [ "$decide_err" -ne 0 ]; then
    if [ -n "$http" ] && [ "$http" != 200 ]; then
      typed_fail "http $http after ${LAT_MS} ms"
    else
      typed_fail "jev caller failed"
    fi
    return 1
  fi
  if [ "$EXTRA" -eq 1 ]; then
    EXTRA_LOG=$(jq -c '{
      home: (.answers.home.choice // null),
      deliverable: (.answers.deliverable.choice // null),
      home_confidence: (.answers.home.confidence // null),
      deliverable_confidence: (.answers.deliverable.confidence // null)
    }' "$RESP_FILE") || EXTRA_LOG='{}'
  fi
  jq -e --slurpfile rules "$RULES" '
      (($rules[0].rules | to_entries | map("rule_" + ((.key + 1) | tostring))) + ["default"] | sort) as $choices |
      .answers.rule.type == "choice" and
      (.answers.rule.choice | type) == "string" and
      (.answers.rule.confidence | type) == "number" and
      .answers.rule.confidence >= 0 and .answers.rule.confidence <= 1 and
      (.answers.rule.probabilities | type) == "object" and
      ((.answers.rule.probabilities | keys | sort) == $choices) and
      all(.answers.rule.probabilities[]; type == "number" and . >= 0 and . <= 1) and
      ((.answers.rule.probabilities | [.[]] | add) as $total | $total >= 0.99 and $total <= 1.01) and
      ((has("usage") | not) or
        ((.usage | type) == "object" and
         (.usage.input_tokens | type) == "number" and
         (.usage.output_tokens | type) == "number"))' \
    "$RESP_FILE" >/dev/null 2>&1 || { typed_fail "response is not a rule Choice answer"; } || return 1
  # The effort answer is a second typed Choice in the same response. It is
  # validated separately and softly: a missing, malformed, or low-confidence
  # effort answer falls back to the profile's declared effort with the
  # fallback disclosed in the output, while a confident well-formed answer
  # becomes the assessed reasoning class.
  EFFORT_JSON=$(jq -c --argjson floor "$EFFORT_CONFIDENCE_FLOOR" '
    (["low","medium","high","xhigh","max"]) as $classes |
    (.answers.effort // null) as $a |
    if $a == null then {choice: null, source: "absent"}
    elif (($a.choice | type) == "string") and ($classes | index($a.choice) != null) and
         (($a.confidence | type) == "number") and ($a.confidence >= 0) and ($a.confidence <= 1) and
         (($a.probabilities | type) == "object") and (($a.probabilities | keys | sort) == ($classes | sort)) and
         (all($a.probabilities[]; type == "number" and . >= 0 and . <= 1)) and
         (($a.probabilities | [.[]] | add) >= 0.99) and (($a.probabilities | [.[]] | add) <= 1.01)
      then (if $a.confidence < $floor then {choice: null, confidence: $a.confidence, source: "low-confidence"}
            else {choice: $a.choice, confidence: $a.confidence, source: "jev"} end)
      else {choice: null, source: "malformed"}
      end' "$RESP_FILE" 2>/dev/null) || EFFORT_JSON='{"choice":null,"source":"malformed"}'
  return 0
}
EFFORT_JSON='{"choice":null,"source":"absent"}'
TYPED_OK=0
if typed_call; then
  TYPED_OK=1
fi

# ---- quota evidence: one quota-axi --json snapshot -----------------------------
# Without --typed-only a missing or failed snapshot is disclosed and every
# candidate becomes unranked, so the chain still answers.
QUOTA_NOTE=''
quota_unavailable() {
  [ "$TYPED_ONLY" -eq 0 ] || emit_error "$1"
  QUOTA_NOTE="$1: every candidate unranked"
  printf '{"schemaVersion":5,"generatedAt":"1970-01-01T00:00:00Z","providers":[]}\n' > "$QUOTA"
}
if ! command -v quota-axi >/dev/null 2>&1; then
  quota_unavailable "quota-axi not installed"
elif ! quota-axi --json > "$QUOTA" 2>/dev/null; then
  quota_unavailable "quota-axi --json failed"
elif ! fm_quota_json_valid < "$QUOTA"; then
  quota_unavailable "quota-axi --json returned an invalid snapshot"
fi

# ---- spend prediction: one ledger pass over the same quota snapshot ----------
# bin/fm-spend-ledger.py owns the measurement; absent or unreadable output
# leaves every burn gate inert and shows pred=unknown on the candidate lines.

SPEND_LEDGER=${FM_SPEND_LEDGER:-$SCRIPT_DIR/fm-spend-ledger.py}
if [ -x "$SPEND_LEDGER" ]; then
  FM_HOME="$FM_HOME" "$SPEND_LEDGER" predict --quota "$QUOTA" > "$PREDICT_FILE" 2>/dev/null \
    || printf '{"status":"unavailable"}\n' > "$PREDICT_FILE"
else
  printf '{"status":"unavailable"}\n' > "$PREDICT_FILE"
fi
jq -e 'type == "object"' "$PREDICT_FILE" >/dev/null 2>&1 \
  || printf '{"status":"unavailable"}\n' > "$PREDICT_FILE"

# ---- resolution: declared gates + quota evidence + argmax, all in jq ------------
IS_SCOUT=false
[ -z "$(brief_kind)" ] || IS_SCOUT=true
# shellcheck disable=SC2016  # A jq program; $names are jq variables.
RESOLVE_JQ="$FM_QUOTA_ROW_JQ"'
  '"$FM_JEV_CHOICE_TOP2_JQ"'
  ($resp[0]) as $r | ($rules[0]) as $cfg | ($quota[0]) as $q | ($r.answers.rule) as $a |
  ($a.probabilities | jev_choice_top2) as $top2 |
  ($predict[0] // {status:"unavailable"}) as $pd | ($effort.choice) as $jev_effort |
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def prov($p; $lane): quota_row($q; $p; $lane);
  def rows($p; $lane): (prov($p; $lane) | .quotaSemantics.effectiveAvailability // []);
  def bare($m): ($m | split("/") | last);
  def effort_rank($e): (["low","medium","high","xhigh","max","ultra"] | index($e));
  def effort_ok($h; $m; $e):
    if $e == null then true
    elif ($e | type) != "string" then false
    elif $e == "ultra" then (($h == "pi" or $h == "pi-signed") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
    elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "codex" then ((["low","medium","high","xhigh"] | index($e)) != null or ($e == "max" and $m == "gpt-5.6-luna"))
    elif $h == "grok" or $h == "agy" then (["low","medium","high"] | index($e)) != null
    elif $h == "pi" or $h == "pi-signed" or $h == "omp" or $h == "muse" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "rovo" then (["low","medium","high","max"] | index($e)) != null
    elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
    else true end;
  def fmt_tokens($t): if $t >= 1000000 then "\(($t / 100000) | round / 10)M" elif $t >= 1000 then "\(($t / 100) | round / 10)k" else "\($t)" end;
  def median_burn($p; $e):
    if $p == null then null
    elif $e == null then (($pd.median[$p].all // $pd.anyProvider.all) // null)
    else (($pd.median[$p][$e] // $pd.median[$p].all // $pd.anyProvider[$e] // $pd.anyProvider.all) // null)
    end;
  def provider_of($c): ($c.provider // $pmap[$c.harness] // null);
  def lane_of($c): quota_lane($c.harness; $c.model);
  def measured($p; $lane):
    (prov($p; $lane) != null and (["known", "partial"] | index(prov($p; $lane).quotaSemantics.status)) != null);
  def applicable($p; $lane; $m):
    (bare($m)) as $bare |
    [rows($p; $lane)[] | select(
      .scope == "all_models" or .scope == "all_products" or
      ($m != "" and (.scope == ("model:" + $bare) or .scope == ("product:" + $bare)))
    )];
  def floor_state($f; $p; $lane):
    if $f == null then "none"
    elif prov($p; $lane) == null or (measured($p; $lane) | not) then "unknown"
    else [rows($p; $lane)[] | select(.scope == $f.scope)] as $matches
      | if ($matches | length) == 0 or any($matches[]; .status != "known") then "unknown"
        elif any($matches[]; .effectivePercentRemaining < $f.min_percent) then "below"
        else "ok"
        end
    end;
  def evidence($rows):
    $rows | map({scope, status, pct: (.effectivePercentRemaining // null), runway: (.runway.status // null), runwaySeconds: (.runway.usableRunwaySeconds // null), spendPriority: (.selection.spendPriority // null)});
  def evaluate($c):
    (provider_of($c)) as $p | (lane_of($c)) as $lane |
    if $p == null then {profile: $c, eligible: false, reason: "no provider family for harness \($c.harness); declare provider on the profile"}
    elif prov($p; $lane) == null then
      {profile: $c, provider: $p, eligible: true, unranked: true,
       reason: (if any($q.providers[]; .provider == $p)
                then "provider \($p) has no quota row for account \(if $lane == "" then "default" else $lane end)"
                else "provider \($p) not in the quota snapshot" end)}
    else
      (applicable($p; $lane; ($c.model // ""))) as $rows |
      (evidence($rows)) as $bounds |
      (floor_state($c.floor; $p; $lane)) as $profile_floor_state |
      if any($rows[]; (.runway.status // "") == "exhausted_now") then
        ($rows | map(select((.runway.status // "") == "exhausted_now")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: ($bad.effectivePercentRemaining // null), runway: $bad.runway.status, eligible: false, rejection_kind: "quota", reason: "runway exhausted_now at \($bad.scope)"}
      elif any($rows[]; .status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0) then
        ($rows | map(select(.status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0)) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: false, rejection_kind: "quota", reason: "0% remaining at \($bad.scope)"}
      elif $profile_floor_state == "below" then
        ([rows($p; $lane)[] | select(
          .scope == $c.floor.scope and
          .effectivePercentRemaining < $c.floor.min_percent
        )] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, scope: ($floor_row.scope // $c.floor.scope), pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: false, reason: "profile floor \($c.floor.scope) below \($c.floor.min_percent)%"}
      elif (measured($p; $lane) | not) then
        ($rows | first) as $row |
        {profile: $c, provider: $p, bounds: $bounds, scope: ($row.scope // null), pct: ($row.effectivePercentRemaining // null), runway: ($row.runway.status // null), eligible: true, unranked: true, unknown: true, reason: "provider \($p) unmeasured (\(prov($p; $lane).quotaSemantics.status))"}
      elif ($rows | length) == 0 then
        {profile: $c, provider: $p, bounds: $bounds, eligible: true, unranked: true, unknown: true, reason: "no applicable quota row for provider \($p)"}
      elif $profile_floor_state == "unknown" then
        ([rows($p; $lane)[] | select(.scope == $c.floor.scope)] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, scope: $c.floor.scope, pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: true, unranked: true, unknown: true, reason: "profile floor \($c.floor.scope) is unverifiable: not rankable"}
      elif any($rows[]; .status != "known") then
        ($rows | map(select(.status != "known")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, eligible: true, unranked: true, unknown: true, reason: "quota row \($bad.scope) unknown: not rankable"}
      elif any($rows[]; (.selection.spendPriority | type) != "number") then
        ($rows | map(select((.selection.spendPriority | type) != "number")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: true, unranked: true, reason: "spendPriority missing or non-numeric at \($bad.scope): not rankable"}
      else
        ($rows | min_by(.selection.spendPriority)) as $limiting |
        {profile: $c, provider: $p, bounds: $bounds, scope: $limiting.scope, pct: $limiting.effectivePercentRemaining,
         spendPriority: $limiting.selection.spendPriority, runway: $limiting.runway.status, eligible: true, reason: "ok"}
      end
    end;
  # A profile allows effort_min..effort_max around its declared effort, which
  # is the range default; a bare effort is a one-level range. An undeclared
  # effort allows low..xhigh with no default, so max and ultra always need an
  # explicit declaration. The assessed class is clamped into the range and then
  # moved to the nearest level inside it that the harness supports (the lower
  # one on a tie), so an assessment never refuses a candidate.
  def effort_range($c):
    ($c.effort // null) as $d |
    ($c.effort_floor // null) as $floor |
    ($c.effort_min // $d // "low") as $min |
    {min: (if $floor != null and effort_rank($floor) > effort_rank($min) then $floor else $min end),
     max: ($c.effort_max // $d // "xhigh"),
     default: (if $floor != null and ($d == null or effort_rank($d) < effort_rank($floor)) then $floor else $d end)};
  def range_text($r): if $r.min == $r.max then $r.min else "\($r.min)..\($r.max)" end;
  def resolve_effort($c):
    (effort_range($c)) as $r |
    if $jev_effort == null then {effort: $r.default, range: $r, source: "declared"}
    else
      (effort_rank($jev_effort)) as $x |
      (if $x < effort_rank($r.min) then $r.min elif $x > effort_rank($r.max) then $r.max else $jev_effort end) as $clamped |
      ([["low","medium","high","xhigh","max","ultra"][]
        | select(effort_rank(.) >= effort_rank($r.min) and effort_rank(.) <= effort_rank($r.max))
        | select(effort_ok($c.harness; $c.model; .))]) as $fit |
      (if ($fit | length) == 0 then $clamped
       else ($fit | min_by([((effort_rank(.) - effort_rank($clamped)) | if . < 0 then -. else . end), effort_rank(.)])) end) as $e |
      {effort: $e, range: $r, source: "assessed"}
      + (if $e != $jev_effort then {clamped: $jev_effort} else {} end)
    end;
  # Burn gates bind only where the ledger produced evidence: a median burn for
  # this provider/effort ladder, a calibrated tokens-per-point for the current
  # provider window, and finite quota bounds. Missing evidence stays
  # disclosed (pred=unknown) and never fabricates a limit.
  def burn_gate($ev):
    if ($ev.eligible != true) then $ev
    else
      (median_burn($ev.provider; $ev.effort)) as $med |
      if $med == null or ($med.tokens | type) != "number" then $ev + {pred: null}
      else
        ($med.tokens) as $pt | ($med.seconds // null) as $ps |
        (if $ev.provider == null then null else ($pd.providers[$ev.provider].tokensPerPoint // null) end) as $tpp |
        (if $tpp != null then $pt / $tpp else null end) as $pred_pct |
        ([($ev.bounds // [])[] | select((.pct | type) == "number")] ) as $b |
        (if ($b | length) > 0 then ($b | min_by(.pct)) else null end) as $limit |
        ([($ev.bounds // [])[] | select((.runwaySeconds | type) == "number") | .runwaySeconds] | if length > 0 then min else null end) as $min_runway |
        ($ev + {pred: {tokens: $pt, seconds: $ps, pct: $pred_pct}}) as $evp |
        if $pred_pct != null and $limit != null and $pred_pct > $limit.pct then
          $evp + {eligible: false,
                  reason: "predicted burn ~\(fmt_tokens($pt)) tokens (~\($pred_pct | round)%) exceeds remaining \($limit.pct)% at \($limit.scope)"}
        elif $ps != null and $min_runway != null and $ps > $min_runway then
          ($evp.bounds // [] | map(select((.runwaySeconds | type) == "number")) | min_by(.runwaySeconds)) as $lr |
          $evp + {eligible: false,
                  reason: "predicted duration ~\(($ps | round))s exceeds usable runway \(($min_runway | round))s at \($lr.scope)"}
        else $evp
        end
      end
    end;
  def assess($c):
    (resolve_effort($c)) as $er |
    ({effort: $er.effort, range: (range_text($er.range)), effort_source: $er.source}
      + (if $er.clamped then {clamped: $er.clamped} else {} end)) as $ef |
    if $er.effort != null and (effort_ok($c.harness; $c.model; $er.effort) | not) then
      if (effort_ok($c.harness; $c.model; "low") | not) then
        # The harness carries no effort knob at all (cursor, kimi, opencode):
        # the assessed class is disclosed on the line but cannot gate, and
        # the emitted profile stays effort-free exactly as today.
        (evaluate($c) + $ef + {effort_emit: false, effort_note: "effort unenforceable on \($c.harness)"}) | burn_gate(.)
      else
        {profile: $c, eligible: false} + $ef + {reason: "harness \($c.harness) cannot supply effort \($er.effort)"}
      end
    else
      (evaluate($c) + $ef) | burn_gate(.)
    end;
  def is_overflow($c): ($c.profile.overflow // false) == true;
  def runs_short($c):
    $c.provider == "claude"
    and ($c.eligible or $c.rejection_kind == "quota")
    and any(($c.bounds // [])[];
      .runway == "projected_exhaustion" or .runway == "exhausted_now"
      or (.status == "known" and (.pct | type) == "number" and .pct <= 0));
  def held_back($c; $why): $c + {eligible: false, unranked: false, reason: $why};
  def apply_overflow($cands):
    ([$cands[] | select(is_overflow(.) | not)]) as $prim |
    ([$cands[] | select(is_overflow(.))]) as $spill |
    if ($spill | length) == 0 then $cands
    elif $scout then
      $cands | map(if is_overflow(.) and .eligible then held_back(.; "overflow only: a scout brief never overflows") else . end)
    elif ($prim | length) == 0 or any($prim[]; runs_short(.) | not) then
      $cands | map(if is_overflow(.) and .eligible then held_back(.; "overflow only: not every primary has concrete Claude quota-shortfall evidence") else . end)
    elif any($spill[]; .eligible and ((.unranked // false) | not)) then
      $cands | map(if (is_overflow(.) | not) and .eligible
        then held_back(.; "overflowed: quota projected to run out before reset" + (if .scope then " at \(.scope)" else "" end))
        else . end)
    else $cands end;
  def rule_at($c):
    if ($c | test("^rule_[1-9][0-9]*$")) then
      ($c | ltrimstr("rule_") | tonumber) as $n |
      if $n <= (($cfg.rules // []) | length) then $cfg.rules[$n - 1] else null end
    else null end;
  def declared_confidence($c): rule_at($c) as $x | $x != null and ($x | has("min_confidence"));
  def confidence_floor($c): if declared_confidence($c) then rule_at($c).min_confidence else ($floor | tonumber) end;
  ($a.choice) as $picked |
  (confidence_floor($picked)) as $picked_floor |
  # A declared floor is checked against the probability of that option whether
  # it is the pick or a runner-up, so a runner-up never needs weaker support
  # than it would as the pick; an undeclared runner-up must clear $floor. Only
  # a rule that declares its own floor falls through to a runner-up, so a file
  # with no declared floors keeps the top-2 margin gates below exactly.
  (if declared_confidence($picked) | not then {below: false}
   elif $a.probabilities[$picked] >= $picked_floor then {below: false}
   else
     ([$a.probabilities | to_entries[] | select(.key != $picked and .value >= confidence_floor(.key))]
       | sort_by(-.value)) as $ok |
     if ($ok | length) == 0 then {below: true, why: "no other option clears its own floor"}
     elif ($ok | length) > 1 and $ok[1].value == $ok[0].value then {below: true, why: "runner-up tie"}
     else {below: true, to: $ok[0].key, p: $ok[0].value, to_floor: confidence_floor($ok[0].key)} end
   end) as $fb |
  (if $fb.to then $fb.to else $picked end) as $choice |
  def answer_use($c):
    if $c != "default" and rule_at($c) == null then []
    elif rule_at($c) == null then profiles($cfg.default // null)
    else profiles(rule_at($c).use)
    end;
  def selection($c):
    (rule_at($c)) as $rule |
    (if $rule == null then "none" else floor_state($rule.floor; $rule.floor.provider; "") end) as $rule_floor_state |
    if $c != "default" and $rule == null then {invalid: "rule \($c) is not in the rules file"}
    elif $rule == null then {source: "default", use: profiles($cfg.default // null), note: "no rule matched"}
    elif ($rule.approval // "") == "captain" then {source: $c, approval: true, escalate: "rule requires the captain'"'"'s explicit approval before dispatch"}
    elif $rule_floor_state == "unknown" then {source: $c, escalate: "rule \($c) floor \($rule.floor.provider)/\($rule.floor.scope) is unverifiable"}
    elif $rule_floor_state == "below"
      then {source: "default", use: profiles($cfg.default // null), note: "rule \($c) floor \($rule.floor.scope) below \($rule.floor.min_percent)%: fall through to default"}
    else {source: $c, use: profiles($rule.use), note: "rule matched"} end;
  # What the gates and the spendPriority argmax make of one rule answer, as
  # though it had cleared the rule gate. The main answer and every runoff
  # contender go through this one definition.
  def settle($c):
    (selection($c)) as $sel |
    if $sel.invalid then {status: "error", reason: $sel.invalid}
    elif $sel.escalate then {status: "escalate", reason: $sel.escalate, candidates: (answer_use($c) | map(assess(.)))}
      + (if $sel.approval then {approval: true} else {} end)
    elif ($sel.use | length) == 0 then {status: "escalate", reason: "no profiles configured for \($sel.source)", note: $sel.note, candidates: []}
    else
      ($sel.use | map(assess(.)) | apply_overflow(.)) as $cands |
      ([$cands[] | select(.eligible and ((.unranked // false) | not))]) as $elig |
      ([$cands[] | select(.unranked)]) as $unranked |
      ([$cands[] | select(.pred != null) | .pred.tokens] | if length > 0 then min else null end) as $min_pred |
      if ($elig | length) == 0 then
        {status: "escalate",
         reason: ("no rankable eligible candidate" +
           (if $min_pred != null then " (predicted burn ~\(fmt_tokens($min_pred)) tokens at \($jev_effort // "declared") effort)" else "" end)),
         note: $sel.note, candidates: $cands}
      else
        ($elig | max_by(.spendPriority)) as $best |
        ([$elig[] | select(.spendPriority == $best.spendPriority)] | length) as $ties |
        if $ties > 1 then {status: "escalate", reason: "genuine spendPriority tie", note: $sel.note, candidates: $cands}
        else {status: "clear", note: $sel.note, candidates: $cands, chosen: $best}
          + (if ($unranked | length) > 0 then
               {unranked_note: "\($unranked | length) eligible candidate(s) unranked (\([$unranked[].provider] | unique | join(", ")))"}
             else {} end)
        end
      end
    end;
  def emitted_effort($c):
    if $c.effort_emit == false then ($c.profile.effort // null)
    else ($c.effort // $c.profile.effort // null) end;
  # The runoff for an ambiguous answer: the picked option and the top two by
  # probability each settle on their own quota-ranked profile. Any contender
  # that would not clear (a captain-approval rule, an unverifiable floor,
  # nothing rankable, a tie) leaves the decision with firstmate; contenders
  # that land on the same concrete profile collapse into one option, which
  # carries the strictest min_confidence its rules declare as its `floor`.
  def runoff:
    (reduce ([$picked, $top2.first, $top2.second][] | select(. != null)) as $x
      ([]; if any(.[]; . == $x) then . else . + [$x] end)) as $cs |
    [$cs[] | {option: ., settled: settle(.)}] as $rows |
    ([$rows[] | select(.settled.status != "clear")] | first) as $bad |
    if $bad != null then
      {state: "skipped", reason: "\($bad.option) would not clear: \($bad.settled.reason // $bad.settled.status)"}
    else
      (reduce $rows[] as $r ([];
        ([$r.settled.chosen.profile.harness, ($r.settled.chosen.profile.model // null), emitted_effort($r.settled.chosen)]) as $k |
        (map(.k == $k) | index(true)) as $i |
        (if declared_confidence($r.option) then [rule_at($r.option).min_confidence] else [] end) as $f |
        if $i == null then . + [{k: $k, key: $r.option, rules: [$r.option], floors: $f, settled: $r.settled}]
        else .[$i].rules += [$r.option] | .[$i].floors += $f end)) as $groups |
      ($groups | map(del(.k) | .floor = (.floors | max) | del(.floors))) as $options |
      if ($options | length) == 1 then {state: "agreed", options: $options}
      else {state: "ask", options: $options} end
    end;
  def when_of($c): (if rule_at($c) == null then $none_criterion else rule_at($c).when end | .[0:60]);
  {
    model: $r.model, latency_ms: $lat, tokens: ($r.usage // null),
    rule: $picked,
    rule_when: when_of($picked),
    confidence: $a.confidence, probabilities: $a.probabilities,
    effort: {choice: $jev_effort, confidence: $effort.confidence, source: $effort.source}
  }
  + {decided_rule: $choice}
  + (if $fb.to then {fallback: "\($choice) (\(when_of($choice))) probability \($fb.p) clears its floor \($fb.to_floor); \($picked) probability \($a.probabilities[$picked]) is below its floor \($picked_floor)"} else {} end)
  as $ev |
  (settle($choice)) as $settled |
  (answer_use($choice) | map(assess(.))) as $answer_cands |
  if $settled.status == "error" then $ev + $settled
  elif $fb.below and ($fb.to | not) then
    $ev + {status: "ambiguous", reason: "\($picked) probability \($a.probabilities[$picked]) below its floor \($picked_floor); \($fb.why)", candidates: $answer_cands, runoff: runoff}
  # A declared min_confidence replaces the top-2 gates for its own rule,
  # exactly as it replaces the global floor upstream, so they judge only a pick
  # that declares no floor of its own.
  elif (declared_confidence($picked) | not) and $choice != $top2.first then
    $ev + {status: "ambiguous", reason: "choice \($choice) is not the most probable option \($top2.first)", candidates: $answer_cands, runoff: runoff}
  # The 1e-9 tolerance is intentional: two-decimal gaps such as 0.7 - 0.3 compute just below the threshold in binary floating point.
  elif (declared_confidence($picked) | not) and ($top2.raw_margin + 1e-9) < ($margin | tonumber) then
    $ev + {status: "ambiguous", reason: "top-2 margin \($top2.margin) below \($margin) (\($top2.first) vs \($top2.second))", candidates: $answer_cands, runoff: runoff}
  else $ev + $settled
  end'
resolve_response() {  # <response-file> <effort-json> <latency-json>: sets RESULT
  RESULT=$(jq -n --argjson scout "$IS_SCOUT" --arg margin "$MARGIN" --arg floor "$CONFIDENCE_FLOOR" --argjson lat "$3" --arg none_criterion "$DEFAULT_WHEN" --argjson pmap "$PMAP" --argjson effort "$2" \
    --slurpfile resp "$1" --slurpfile rules "$RULES" --slurpfile quota "$QUOTA" --slurpfile predict "$PREDICT_FILE" "$RESOLVE_JQ") \
    || emit_error "resolution failed"
}

# A one-hot answer for a choice the backup or the default stage made, in the
# typed response shape, so it settles through the same gates as a typed answer.
one_hot_response() {  # <choice> <model-label> <path>
  jq -n --arg choice "$1" --arg model "$2" --slurpfile rules "$RULES" '
    ((($rules[0].rules // []) | to_entries | map("rule_" + ((.key + 1) | tostring))) + ["default"]) as $keys
    | {model: $model, answers: {rule: {type: "choice", choice: $choice, confidence: 1,
        probabilities: ($keys | map({key: ., value: (if . == $choice then 1 else 0 end)}) | from_entries)}}}' > "$3" \
    || emit_error "could not build the $2 answer"
}

# The last resort inside a decided rule whose settle did not clear for a quota
# reason (nothing rankable, a genuine tie, an unverifiable rule floor, every
# candidate refused): the best-ranked eligible candidate in declared order,
# else the first eligible one, else the first declared one. Approval never
# reaches here.
last_resort() {  # sets RESULT status fallback with a chosen candidate, or returns 1
  local next
  next=$(jq -c '
    (.candidates // []) as $c |
    ([$c[] | select(.eligible == true and ((.unranked // false) | not) and (.spendPriority | type) == "number")]) as $ranked |
    ([$c[] | select(.eligible == true)]) as $eligible |
    (if ($ranked | length) > 0 then
       ($ranked | max_by(.spendPriority).spendPriority) as $best
       | {pick: ([$ranked[] | select(.spendPriority == $best)] | first), why: "best-ranked eligible candidate, first in declared order on a tie"}
     elif ($eligible | length) > 0 then {pick: $eligible[0], why: "first eligible candidate in declared order"}
     elif ($c | length) > 0 then {pick: $c[0], why: "every candidate refused; first declared candidate"}
     else null end) as $lr |
    if $lr == null then error("no candidate")
    else . + {status: "fallback", chosen: $lr.pick, last_resort: "\(.reason // .status): \($lr.why)"} end' <<<"$RESULT" 2>/dev/null) || return 1
  RESULT=$next
}

# Settles RESULT for a stage that has decided a rule. Returns 0 when RESULT now
# carries a final answer (a profile, or a captain-approval escalate), 1 when it
# has no candidate at all.
settle_stage() {  # <ok-status>
  local status approval
  status=$(jq -r '.status' <<<"$RESULT")
  approval=$(jq -r '.approval // false' <<<"$RESULT")
  case "$status" in
    clear|picked)
      [ "$1" = clear ] || RESULT=$(jq -c --arg s "$1" '.status = $s' <<<"$RESULT")
      return 0
      ;;
  esac
  if [ "$status" = escalate ] && [ "$approval" = true ]; then
    return 0
  fi
  last_resort
}

# ---- the chain: typed, then the backup judge, then the default stage ----------
DECIDED_BY='' TYPED_LINE='' BACKUP_LINE=''
if [ "$TYPED_OK" -eq 1 ]; then
  resolve_response "$RESP_FILE" "$EFFORT_JSON" "$LAT_MS"
  # ---- runoff: one typed Jev pick among the contenders of an ambiguous answer ----
  # The question offers only contenders that each settled on a concrete profile
  # above, keyed by rule and worded with the same criteria the rule Choice sent,
  # so the model still never sees `use`, `why`, quota, or approvals. Code gates
  # the answer on the same top-2 margin, or on an option's declared floor;
  # anything short of that leaves the answer ambiguous and the decision with
  # firstmate.
  runoff_note() {  # <pick-json>: merge a non-settling outcome into RESULT
    RESULT=$(jq -c --argjson pick "$1" '. + {pick: $pick} | del(.runoff)' <<<"$RESULT") || emit_error "runoff merge failed"
  }
  runoff_settle() {  # <option-key> <pick-json>: the chosen contender becomes the answer
    RESULT=$(jq -c --arg key "$1" --argjson pick "$2" '
      (.runoff.options[] | select(.key == $key) | .settled) as $s
      | (.runoff.options[] | select(.key == $key) | .rules) as $rules
      | del(.runoff) + {status: "picked", decided_rule: $key, pick: ($pick + {rules: $rules}), candidates: $s.candidates, chosen: $s.chosen}
        + (if $s.note then {note: $s.note} else {} end)
        + (if $s.unranked_note then {unranked_note: $s.unranked_note} else {} end)' <<<"$RESULT") \
      || emit_error "runoff merge failed"
  }
  RUNOFF_STATE=$(jq -r 'if .status == "ambiguous" then (.runoff.state // "") else "" end' <<<"$RESULT") || RUNOFF_STATE=''
  if [ -n "$RUNOFF_STATE" ] && [ "$REPLAY" -eq 1 ]; then
    RESULT=$(jq -c 'del(.runoff)' <<<"$RESULT") || emit_error "runoff merge failed"
    RUNOFF_STATE=''
  fi
  case "$RUNOFF_STATE" in
    skipped)
      runoff_note "$(jq -c '{state: "skipped", reason: .runoff.reason}' <<<"$RESULT")"
      ;;
    agreed)
      runoff_settle "$(jq -r '.runoff.options[0].key' <<<"$RESULT")" \
        "$(jq -c '{state: "agreed", rules: .runoff.options[0].rules}' <<<"$RESULT")"
      ;;
    ask)
      PICK_QUESTIONS=$(jq -nc --argjson result "$RESULT" --argjson questions "$QUESTIONS" '
        {pick: {
          type: "choice",
          instructions: "More than one dispatch rule plausibly fits `task` (read `task.brief` and `task.project`). Which ONE option fits it best? Each option is the matching condition of one or more rules; pick the option whose condition the task meets most directly, following any Tie-break sentences.",
          criteria: ($result.runoff.options | map({key: .key, value: ([.rules[] as $r | $questions.rule.criteria[$r]] | join(" Or: "))}) | from_entries)
        }}') || emit_error "could not build runoff question"
      PICK_REQUEST=$(jq -nc --argjson state "$STATE" --argjson questions "$PICK_QUESTIONS" '{state: $state, questions: $questions}') \
        || emit_error "could not build runoff request"
      if ! never_send_scan "$PICK_REQUEST"; then
        runoff_note "$(jq -nc --arg why "$NEVER_SEND_WHY" '{state: "skipped", reason: ($why + "; nothing sent")}')"
      else
        [ -n "$TYPESAFE_API_KEY_PRIVATE" ] && TYPESAFE_API_KEY=$TYPESAFE_API_KEY_PRIVATE
        [ -n "$OPENROUTER_API_KEY_PRIVATE" ] && OPENROUTER_API_KEY=$OPENROUTER_API_KEY_PRIVATE
        PICK_ERR=0
        fm_jev_decide "$STATE" "$PICK_QUESTIONS" > "$PICK_FILE" || PICK_ERR=$?
        unset TYPESAFE_API_KEY OPENROUTER_API_KEY
        PICK_LAT=${FM_JEV_LAST_LATENCY_MS:-0}
        PICK_HTTP=${FM_JEV_LAST_HTTP:-000}
        if [ "$PICK_ERR" -ne 0 ]; then
          if [ -n "$PICK_HTTP" ] && [ "$PICK_HTTP" != 200 ]; then
            runoff_note "$(jq -nc --arg why "http $PICK_HTTP after ${PICK_LAT} ms" '{state: "error", reason: $why}')"
          else
            runoff_note '{"state":"error","reason":"jev caller failed"}'
          fi
        else
          PICK=$(jq -c --argjson questions "$PICK_QUESTIONS" --argjson result "$RESULT" --arg margin "$MARGIN" --argjson lat "$PICK_LAT" "$FM_JEV_CHOICE_TOP2_JQ"'
            ($questions.pick.criteria | keys | sort) as $keys |
            (.answers.pick // null) as $p |
            if ($p | type) == "object" and $p.type == "choice" and ($p.choice | type) == "string" and ($keys | index($p.choice)) != null and
               (($p.confidence | type) == "number") and ($p.confidence >= 0) and ($p.confidence <= 1) and
               (($p.probabilities | type) == "object") and (($p.probabilities | keys | sort) == $keys) and
               all($p.probabilities[]; type == "number" and . >= 0 and . <= 1) and
               (($p.probabilities | [.[]] | add) as $t | $t >= 0.99 and $t <= 1.01)
            then
              ($p.probabilities | jev_choice_top2) as $t2 |
              ([$result.runoff.options[] | select(.key == $p.choice) | .floor] | first) as $floor |
              {choice: $p.choice, probabilities: $p.probabilities, margin: $t2.margin, latency_ms: $lat}
              # A declared min_confidence replaces the top-2 gates for its own
              # option, exactly as it does for the rule answer.
              + (if $floor != null then
                   (if $p.probabilities[$p.choice] >= $floor then {state: "settled", over: [$keys[] | select(. != $p.choice)]}
                    else {state: "undecided", reason: "runoff choice \($p.choice) probability \($p.probabilities[$p.choice]) below its floor \($floor)"} end)
                 elif $p.choice != $t2.first then {state: "undecided", reason: "runoff choice \($p.choice) is not the most probable option \($t2.first)"}
                 elif ($t2.raw_margin + 1e-9) < ($margin | tonumber) then {state: "undecided", reason: "runoff margin \($t2.margin) below \($margin) (\($t2.first) vs \($t2.second))"}
                 else {state: "settled", over: [$keys[] | select(. != $p.choice)]} end)
            else {state: "error", reason: "response is not a runoff Choice answer"} end' "$PICK_FILE" 2>/dev/null) \
            || PICK='{"state":"error","reason":"response is not a runoff Choice answer"}'
          if [ "$(jq -r .state <<<"$PICK")" = settled ]; then
            runoff_settle "$(jq -r .choice <<<"$PICK")" "$PICK"
          else
            runoff_note "$PICK"
          fi
        fi
      fi
      ;;
  esac
  if [ "$TYPED_ONLY" -eq 0 ]; then
    TYPED_STATUS=$(jq -r '.status' <<<"$RESULT")
    case "$TYPED_STATUS" in
      ambiguous|error)
        TYPED_REASON="$TYPED_STATUS: $(jq -r '.reason // "-"' <<<"$RESULT")"
        ;;
      *)
        if settle_stage clear; then
          DECIDED_BY=typed
        else
          TYPED_REASON="$TYPED_STATUS: $(jq -r '.reason // "-"' <<<"$RESULT")"
        fi
        ;;
    esac
  fi
fi

if [ "$TYPED_ONLY" -eq 0 ] && [ -z "$DECIDED_BY" ]; then
  TYPED_LINE=${TYPED_REASON:-skipped}
  # The backup judge gets the same state and the same rule and effort
  # questions the typed call was allowed to send, already never-send checked.
  if [ -n "$STATE" ] && [ "$NEVER_SEND_BLOCKED" -eq 0 ]; then
    BACKUP_QUESTIONS=$(jq -c '{rule: .rule, effort: .effort}' <<<"$QUESTIONS") || BACKUP_QUESTIONS=''
    if [ -z "$BACKUP_QUESTIONS" ]; then
      BACKUP_LINE='failed (could not build the backup questions)'
    elif fm_backup_judge "$STATE" "$BACKUP_QUESTIONS" "$BACKUP_FILE"; then
      BACKUP_MODEL=${FM_BACKUP_JUDGE_MODEL_USED:-${FM_BACKUP_JUDGE_MODEL:-$FM_BACKUP_JUDGE_DEFAULT_MODEL}}
      BACKUP_RULE=$(jq -r '.rule' "$BACKUP_FILE")
      BACKUP_EFFORT=$(jq -r '.effort' "$BACKUP_FILE")
      BACKUP_LINE="$BACKUP_RULE effort=$BACKUP_EFFORT ($BACKUP_MODEL, ${FM_BACKUP_JUDGE_LATENCY_MS} ms)"
      BACKUP_RESP=$(mktemp) || emit_error "mktemp failed"
      one_hot_response "$BACKUP_RULE" "backup:$BACKUP_MODEL" "$BACKUP_RESP"
      BACKUP_EFFORT_JSON=$(jq -nc --arg e "$BACKUP_EFFORT" '{choice: $e, confidence: 1, source: "backup"}')
      resolve_response "$BACKUP_RESP" "$BACKUP_EFFORT_JSON" "${FM_BACKUP_JUDGE_LATENCY_MS:-0}"
      rm -f "$BACKUP_RESP"
      if settle_stage backup; then
        DECIDED_BY=backup
      else
        BACKUP_LINE="$BACKUP_LINE; $BACKUP_RULE has no candidate"
      fi
    else
      BACKUP_LINE="failed ($FM_BACKUP_JUDGE_WHY)"
    fi
  else
    BACKUP_LINE="skipped (${TYPED_SKIP:-no request})"
  fi
fi

if [ "$TYPED_ONLY" -eq 0 ] && [ -z "$DECIDED_BY" ]; then
  # The default stage: the configured default profiles, else the first rule,
  # with the best effort assessment any stage made.
  if [ "$HAS_DEFAULT" = true ]; then
    DEFAULT_CHOICE=default
  else
    DEFAULT_CHOICE=rule_1
  fi
  DEFAULT_EFFORT_JSON=$EFFORT_JSON
  if [ "$(jq -r '.source' <<<"$EFFORT_JSON")" != jev ] && [ -n "${BACKUP_EFFORT:-}" ]; then
    DEFAULT_EFFORT_JSON=$(jq -nc --arg e "$BACKUP_EFFORT" '{choice: $e, confidence: 1, source: "backup"}')
  fi
  DEFAULT_RESP=$(mktemp) || emit_error "mktemp failed"
  one_hot_response "$DEFAULT_CHOICE" default "$DEFAULT_RESP"
  resolve_response "$DEFAULT_RESP" "$DEFAULT_EFFORT_JSON" 0
  rm -f "$DEFAULT_RESP"
  settle_stage fallback || emit_error "no candidate in the default stage"
  DECIDED_BY=default
fi

if [ "$TYPED_ONLY" -eq 0 ]; then
  RESULT=$(jq -c --arg by "$DECIDED_BY" --arg typed "$TYPED_LINE" --arg backup "$BACKUP_LINE" --arg quota "$QUOTA_NOTE" '
    .chain = ({decided_by: $by}
      + (if $typed != "" then {typed: $typed} else {} end)
      + (if $backup != "" then {backup: $backup} else {} end))
    | if $quota != "" then .quota_note = $quota else . end' <<<"$RESULT") || emit_error "chain merge failed"
fi

TEXT=$(jq -r '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($value): ($value // "-") | flat;
  def shell_arg: flat | @sh;
  "dispatch-resolve:",
  "  status: \(.status | flat)",
  (if .chain then "  decided: \((.decided_rule // .rule) | flat) by \(.chain.decided_by | flat)" else empty end),
  (if .chain.typed then "  typed: \(.chain.typed | flat)" else empty end),
  (if .chain.backup then "  backup: \(.chain.backup | flat)" else empty end),
  "  model: \(show(.model))   latency_ms: \(show(.latency_ms))   tokens: \(show(.tokens.input_tokens))/\(show(.tokens.output_tokens))",
  "  rule: \(.rule | flat) (\(.rule_when | flat))   confidence: \(.confidence | flat)",
  "  probabilities: \([.probabilities | to_entries[] | "\(.key | flat)=\(.value | flat)"] | join(" "))",
  "  effort: \(show(.effort.choice)) (\(if .effort.source == "jev" then "jev confidence=\(show(.effort.confidence))" elif .effort.source == "declared" then "declared" elif .effort.source == "backup" then "backup judge" else "declared fallback (classifier \(.effort.source))" end))",
  (if .fallback then "  fallback: \(.fallback | flat)" else empty end),
  (if .reason then "  reason: \(.reason | flat)" else empty end),
  (if .pick == null then empty
   elif .pick.state == "settled" then "  pick: \(.pick.choice | flat) (\(.pick.rules | map(flat) | join("+"))) over \(.pick.over | map(flat) | join(", ")) by jev runoff   p=\(.pick.probabilities[.pick.choice] | flat) margin=\(.pick.margin | flat)"
   elif .pick.state == "agreed" then "  pick: \(.pick.rules | map(flat) | join(", ")) settle on the same profile (no runoff call)"
   else "  pick: \(.pick.state | flat) (\(show(.pick.reason)))" end),
  (if .note then "  note: \(.note | flat)" else empty end),
  (if .unranked_note then "  note: \(.unranked_note | flat)" else empty end),
  (if .quota_note then "  note: \(.quota_note | flat)" else empty end),
  (if .last_resort then "  last_resort: \(.last_resort | flat)" else empty end),
  (.candidates[]? | "  candidate: \(.profile.harness | flat):\(show(.profile.model))"
      + (if .provider then "  provider=\(.provider | flat)" else "" end)
      + (if .effort then "  effort=\(.effort | flat)" + (if .range then "(range \(.range | flat))" else "" end) + (if .clamped then " [clamped from \(.clamped | flat)]" else "" end) + (if .effort_note then " [\(.effort_note | flat)]" else "" end) else "" end)
      + (if .scope then "  scope=\(.scope | flat)  remaining=\(show(.pct))%  spendPriority=\(show(.spendPriority))  runway=\(show(.runway))" else "" end)
      + (if .pred then "  pred=~\(.pred.tokens | flat)tok/\(show(.pred.seconds))s" elif has("pred") then "  pred=unknown" else "" end)
      + (if (.bounds // [] | length) > 1 then "  bounds=" + ([.bounds[] | "\(.scope | flat):\(show(.pct))%/\((.runway // .status) | flat)"] | join(",")) else "" end)
      + "  -> " + (if .unranked then "eligible, unranked: \(.reason | flat): disclosed uncertainty" elif .eligible then "eligible" else "not eligible: \(.reason | flat)" end)),
  (if .chosen then "  profile: --harness \(.chosen.profile.harness | shell_arg)"
      + (if .chosen.profile.model then " --model \(.chosen.profile.model | shell_arg)" else "" end)
      + (if .chosen.effort_emit == false then
           (if .chosen.profile.effort then " --effort \(.chosen.profile.effort | shell_arg)" else "" end)
         elif .chosen.effort then " --effort \(.chosen.effort | shell_arg)"
         elif .chosen.profile.effort then " --effort \(.chosen.profile.effort | shell_arg)" else "" end) else empty end)' <<<"$RESULT") || emit_error "output rendering failed"
if fm_dispatch_shadow_on; then
  SHADOW_PATH="$FM_HOME/state/jev-dispatch-shadow.jsonl"
  SHADOW=$(jq -nc --argjson result "$RESULT" --arg route "${FM_JEV_LAST_ROUTE:-}" \
    --arg url "${FM_JEV_LAST_URL:-}" --arg model "${FM_JEV_LAST_MODEL:-}" \
    --arg response_model "$(fm_jev_response_model "$(cat "$RESP_FILE" 2>/dev/null)")" \
    --arg project "$PROJECT" --argjson extra "$EXTRA_LOG" \
    --arg compact "$(if fm_dispatch_compact_on; then printf 1; else printf 0; fi)" '{
      purpose: "dispatch-shadow",
      route: $route,
      url: $url,
      model: $model,
      response_model: (if $response_model == "" then null else $response_model end),
      project: $project,
      compact: ($compact == "1"),
      status: $result.status,
      decided_by: ($result.chain.decided_by // null),
      rule: $result.rule,
      confidence: $result.confidence,
      probabilities: $result.probabilities,
      profile: (if $result.chosen then $result.chosen.profile else null end),
      pick: (if $result.pick then ($result.pick | {state, rules, choice, probabilities, margin, reason} | with_entries(select(.value != null))) else null end),
      extra: $extra
    }') || SHADOW=''
  if [ -n "$SHADOW" ]; then
    fm_jev_log_call "$SHADOW" "$SHADOW_PATH" || true
  fi
fi
dispatch_log "$(jq -c '{
    status, decided_by: (.chain.decided_by // null), rule: (.decided_rule // .rule),
    typed: (.chain.typed // null), backup: (.chain.backup // null),
    effort: {assessed: (.effort.choice // null), source: (.effort.source // null),
             emitted: (if .chosen then (if .chosen.effort_emit == false then (.chosen.profile.effort // null) else (.chosen.effort // .chosen.profile.effort // null) end) else null end),
             clamped_from: (.chosen.clamped // null)},
    profile: (if .chosen then .chosen.profile | {harness, model, provider} | with_entries(select(.value != null)) else null end),
    reason: (.last_resort // .reason // null)
  }' <<<"$RESULT" 2>/dev/null || printf '{}')"
printf '%s\n' "$TEXT"
exit 0
