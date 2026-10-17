# shellcheck shell=bash
# fm-effort-cap-lib.sh - shared effort envelope for spawn and reviewer planning.
# docs/configuration.md "Effort caps for concrete launches" owns profile
# matching, envelope composition, defaults, and consumer policy.
# This header owns the API:
#
#   fm_effort_caps_load <config-dir>
#     Reads <config-dir>/crew-dispatch.json into FM_EFFORT_RANGE_JSON.
#     Returns 0 with an empty profile list when the file is absent.
#     On a read or validation failure, returns 1 with FM_EFFORT_RANGE_ERROR;
#     callers must not treat failure as an empty policy.
#     FM_EFFORT_RANGE_FILE names the successfully loaded file, else is empty.
#     Requires jq when a file is present.
#   fm_effort_range_for <harness> [<model>]
#     After a successful load, prints `min max default` for the matching
#     envelope, or nothing when no profile matches. The default field is `-`
#     when no matching effort or floor supplies one. Requires jq even when
#     the loaded profile list is empty.
#   fm_effort_rank <level>
#     Prints the zero-based FM_EFFORT_LADDER rank; fails for unknown levels.
#   fm_effort_clamp <desired|''> <min> <max>
#     Prints the desired level when inside the range, otherwise the nearest
#     level inside it. An empty desired, an unknown level, or an inverted
#     range prints nothing and returns 1; only an inverted range sets
#     FM_EFFORT_RANGE_ERROR. The caller owns undeclared-effort fallback.
#   FM_EFFORT_LADDER
#     Whitespace-separated effort levels, shared for callers' messages.

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
  # Include every declaration, not just the rule selected for this task.
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
    # Keep model normalization and variant matching shared by all consumers;
    # the operator contract above owns which spellings share an envelope.
    def norm: . as $x | (($x // "") | ascii_downcase) as $l
      | if $l == "" or $l == "default" then null else $l end;
    def claude_alias($x): $x == "opus" or $x == "sonnet" or $x == "haiku" or $x == "fable";
    def variant($d; $c):
      ($d == $c)
      or (($d | test("^claude-(opus|sonnet|haiku|fable)-[0-9]"))
          and ($c | test("^claude-(opus|sonnet|haiku|fable)-[0-9]"))
          and (($c | startswith($d + "-")) or ($d | startswith($c + "-"))))
      or ((claude_alias($d) and ($c | startswith("claude-" + $d + "-")))
          or (claude_alias($c) and ($d | startswith("claude-" + $c + "-"))));
    .profiles
    | map(select((.harness == $h)
        and (
          (($m | norm) == null
             and ((.model // null | norm) == null
                  or ($h == "claude"
                      and (.model // null | norm) != null
                      and variant((.model // null | norm); "opus"))))
          or ((.model // null | norm) != null
              and (($m | norm) != null)
              and variant((.model // null | norm); ($m | norm)))
        )))
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
