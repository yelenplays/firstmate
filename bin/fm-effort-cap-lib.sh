# shellcheck shell=bash
# fm-effort-cap-lib.sh - the shared effort-range source for homes that cap a
# model's reasoning effort, reused by bin/fm-spawn.sh (launch refusal) and
# bin/fm-cross-review.sh (reviewer effort clamp) so the two checks cannot
# drift, and mirroring the ranges bin/fm-dispatch-resolve.sh clamps dispatch
# answers into (docs/configuration.md "Firstmate retains the dispatch
# decision").
#
# The source of truth is the home's config/crew-dispatch.json, the same rules
# and default the dispatch resolver reads: a profile declares effort_min..
# effort_max around its declared effort (a bare effort is a one-level range;
# a profile without effort allows low..xhigh), with effort_floor raising the
# lower bound. A consumer caps a concrete harness/model pair at the envelope
# over the matching profiles: the union of the upper bounds the home declares
# for that pair (so a home narrows a model by declaring narrower profiles),
# and takes the most capable declared default when a consumer needs an effort
# nobody declared for that pair.
#
# The top-level declaration list and every consumer read the same envelope, so
# they cannot drift.
#
# docs/configuration.md "Effort caps for concrete launches" owns the operator
# contract. This header owns the API:
#
#   fm_effort_caps_load <config-dir>
#     Reads <config-dir>/crew-dispatch.json into FM_EFFORT_RANGE_JSON.
#     An absent file loads no ranges and returns 0, so nothing changes for a
#     home without dispatch rules. A present file that is unreadable, not a
#     regular file, malformed, or declares an effort bound outside the
#     low..ultra ladder or a floor above its own upper bound returns 1 with
#     FM_EFFORT_RANGE_ERROR set; callers refuse or escalate rather than
#     select around the home's own declaration. Requires jq only when the
#     file is present (bootstrap already requires it for homes with dispatch
#     rules).
#   fm_effort_range_for <harness> [<model>]
#     After a load: prints `min max default` for the envelope over every
#     matching profile, or prints nothing when no profile matches. A profile
#     matches when its harness equals <harness> and its model equals <model>,
#     or, for a modelless profile, when both are modelless: a modelless
#     profile governs only modelless spawns of its harness, never a concrete
#     model. The envelope is the union of the declarations, not their
#     intersection: its upper bound is the highest profile upper bound
#     (effort_max, else effort, else xhigh) so a model stays launchable
#     wherever any declaration allows it, its lower bound the lowest profile
#     lower bound (effort_min/floor-raised), and the default the most capable
#     declared default (a profile's declared effort raised to effort_floor
#     when floor outranks it), for consumers that need an effort nobody else
#     declared. A stricter home thus narrows a model by declaring tighter
#     profiles.
#   fm_effort_rank <level>
#     Prints the effort-ladder rank 0..5 (low..ultra); fails for anything
#     else.
#   fm_effort_clamp <desired|''> <min> <max>
#     Prints the non-empty desired level when it lies inside the range; the
#     nearest ladder level inside the range otherwise, the lower one on a tie
#     (the resolver's tie rule). An empty desired, an unknown level, or an
#     inverted range prints nothing and fails with FM_EFFORT_RANGE_ERROR, so
#     the caller decides its own undeclared-effort fallback.
#   FM_EFFORT_LADDER
#     whitespace-separated effort ladder (low..ultra), shared for callers'
#     messages.

FM_EFFORT_LADDER='low medium high xhigh max ultra'
FM_EFFORT_RANGE_JSON=${FM_EFFORT_RANGE_JSON:-'{"profiles":[]}'}
FM_EFFORT_RANGE_FILE=${FM_EFFORT_RANGE_FILE:-}
FM_EFFORT_RANGE_ERROR=''

fm_effort_rank() {
  local i lvl
  i=0
  for lvl in $FM_EFFORT_LADDER; do
    [ "$lvl" = "$1" ] && { printf '%s\n' "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}

fm_effort_clamp() {
  local desired=$1 lo=$2 hi=$3 lo_rk hi_rk de_rk lvl best='' best_d=0 d
  [ -n "$desired" ] || return 1
  lo_rk=$(fm_effort_rank "$lo") || return 1
  hi_rk=$(fm_effort_rank "$hi") || return 1
  [ "$lo_rk" -le "$hi_rk" ] || {
    FM_EFFORT_RANGE_ERROR="effort range inverts its own bounds: $lo is not $hi or below"
    return 1
  }
  de_rk=$(fm_effort_rank "$desired") || return 1
  for lvl in 0 1 2 3 4 5; do
    [ "$lvl" -ge "$lo_rk" ] && [ "$lvl" -le "$hi_rk" ] || continue
    d=$((lvl - de_rk))
    [ "$d" -ge 0 ] || d=$((0 - d))
    if [ -z "$best" ] || [ "$d" -lt "$best_d" ]; then
      best=$lvl
      best_d=$d
    fi
  done
  local n=0 word
  for word in $FM_EFFORT_LADDER; do
    [ "$n" -eq "$best" ] && { printf '%s\n' "$word"; return 0; }
    n=$((n + 1))
  done
  return 1
}

fm_effort_caps_load() {
  local config_dir=$1 file
  FM_EFFORT_RANGE_JSON='{"profiles":[]}'
  FM_EFFORT_RANGE_ERROR=''
  FM_EFFORT_RANGE_FILE=''
  if [ ! -d "$config_dir" ]; then
    return 0
  fi
  file=$config_dir/crew-dispatch.json
  [ ! -e "$file" ] || [ -f "$file" ] || {
    FM_EFFORT_RANGE_ERROR="effort-cap rules file is not a regular file: $file"
    return 1
  }
  [ ! -e "$file" ] || [ -r "$file" ] || {
    FM_EFFORT_RANGE_ERROR="effort-cap rules file is not readable: $file"
    return 1
  }
  [ -e "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || {
    FM_EFFORT_RANGE_ERROR='jq is required to read the effort-cap rules file; install jq or remove config/crew-dispatch.json'
    return 1
  }
  # Flatten every profile (each rule's use plus the default) onto one list and
  # fail closed on a shape or bound the resolver would reject.
  if ! FM_EFFORT_RANGE_JSON=$(jq -e -c '
    def effort_rank($e): (["low","medium","high","xhigh","max","ultra"] | index($e));
    def bound_ok($e): ($e == null) or (effort_rank($e) != null);
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    [(.rules[]? | profiles(.use)[])] as $rule_profiles
    | [($rule_profiles | .[]?), (profiles(.default))[]] as $all
    | if type == "object"
       and ([$all[] | select((bound_ok(.effort) | not)
          or (bound_ok(.effort_min) | not) or (bound_ok(.effort_max) | not)
          or ((.effort_floor // null) as $f
              | $f != null and (effort_rank($f)
                  > effort_rank(.effort_max // .effort // "xhigh"))))] | length) == 0
      then
        {profiles: [$all[] | {effort: (.effort // null), effort_min: (.effort_min // null),
          effort_max: (.effort_max // null), effort_floor: (.effort_floor // null),
          harness: .harness, model: .model}]}
      else false end
  ' "$file" 2>/dev/null); then
    # shellcheck disable=SC2034 # Read by sourcing callers after the check returns.
    FM_EFFORT_RANGE_ERROR="malformed effort-cap rules file, or one declares an effort outside the low..ultra ladder: $file"
    return 1
  fi
  FM_EFFORT_RANGE_FILE=$file
  return 0
}

fm_effort_range_for() {
  jq -r --arg h "$1" --arg m "${2-}" '
    def L: ["low","medium","high","xhigh","max","ultra"];
    def rk($e): if $e == null then null else (L | index($e)) end;
    .profiles
    | map(select((.harness == $h)
        and (($m == "" and (.model // null) == null)
             or ($m != "" and .model == $m))))
    | map({
        max_rk: rk(.effort_max // .effort // "xhigh"),
        min_rk: ([(.effort_min // .effort // "low"), (.effort_floor // null)]
                 | map(select(. != null)) | map(rk(.)) | max // 0),
        def: (if (.effort_floor // null) != null
              and ((.effort // null) == null or rk(.effort) < rk(.effort_floor))
              then .effort_floor else .effort end),
        def_rk: (if (.effort_floor // null) != null
              and ((.effort // null) == null or rk(.effort) < rk(.effort_floor))
              then rk(.effort_floor) else rk(.effort) end)
      })
    | if length > 0
      then
        {min_rk: (map(.min_rk) | min),
         max_rk: (map(.max_rk) | max),
         def: (map(select(.def != null)) | sort_by(.def_rk) | last | .def)}
        | if .min_rk > .max_rk then .min_rk = .max_rk else . end
        | "\((L[.min_rk] // "low")) \((L[.max_rk] // "xhigh")) \(.def // "-")"
      else empty end
  ' <<<"$FM_EFFORT_RANGE_JSON"
}
