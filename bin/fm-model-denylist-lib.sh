# shellcheck shell=bash
# Never-use model list: the one owner of loading config/model-denylist.json,
# matching a model against it, finding model pins in text, and the captain
# model-rules summary every model-choosing Jev call carries.
# Usage: . bin/fm-model-denylist-lib.sh
#
# docs/configuration.md "Never-use model list" owns the file format, the
# matching rules, and where firstmate enforces it. This header owns the API:
#
#   fm_model_denylist_load <config-dir>
#     Reads <config-dir>/model-denylist.json into FM_MODEL_DENYLIST_JSON and
#     FM_MODEL_DENYLIST_FILE. An absent file loads an empty list and returns 0,
#     so nothing changes. A present file that is unreadable, not a regular
#     file, or malformed returns 1 with FM_MODEL_DENYLIST_ERROR set; callers
#     refuse rather than choose a model unchecked.
#   fm_model_denylist_check <what> <model-id>...
#     Returns 1 on the first id that matches a rule, with FM_MODEL_DENYLIST_ERROR
#     naming <what>, the id, the rule's pattern, and its reason. Empty ids and
#     the literal "default" are skipped. Requires a prior successful load.
#   fm_model_denylist_check_launch <what> <harness> [<model>]
#     Checks the model, harness/model, and, with no model, the bare harness
#     name, which then stands for that harness's own default model.
#   fm_model_denylist_text_pins <text>
#     Prints one model id per line for every `--model <id>` or `--model=<id>`
#     pin in the text.
#   fm_model_denylist_yaml_pins <file>
#     Prints one model id per line for every model a no-mistakes config pins:
#     `--model` argument lists (block or inline) and `model:` keys.
#   fm_model_denylist_check_pins <what> <pins>
#     Checks each newline-separated pin from the two helpers above.
#   fm_model_denylist_check_nm_config [<file>]
#     Checks every model the no-mistakes global config pins for its pipeline
#     agents (default ${NM_HOME:-$HOME/.no-mistakes}/config.yaml); an absent
#     file passes.
#   fm_model_rules_summary
#     Prints the captain model-rules summary for a Jev state, at most
#     FM_MODEL_RULES_SUMMARY_MAX bytes, or nothing when the list is empty.
#   fm_model_option_looks_like_model <text>
#     Succeeds when the text names a model: it matches a never-use rule or
#     carries a known model-family token.
#   FM_MODEL_DENYLIST_JQ
#     jq definitions for callers that filter inside jq: model_ban($list; $id)
#     returns the first matching rule object or null, and model_banned_any(
#     $list; $ids) does the same over an array of ids.

FM_MODEL_DENYLIST_NAME='model-denylist.json'
FM_MODEL_DENYLIST_JSON=${FM_MODEL_DENYLIST_JSON:-'{"never":[],"rules":[]}'}
FM_MODEL_DENYLIST_FILE=${FM_MODEL_DENYLIST_FILE:-}
FM_MODEL_DENYLIST_ERROR=''
FM_MODEL_RULES_SUMMARY_MAX=${FM_MODEL_RULES_SUMMARY_MAX:-700}
# A pattern matches the whole id or any "/"-separated suffix of it, ignoring
# case, so `gpt-*-luna*` also catches openai-codex/gpt-6-luna.
# shellcheck disable=SC2016 # jq program text, not shell expansions.
FM_MODEL_DENYLIST_JQ='
  def model_glob_re:
    ascii_downcase
    | gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)")
    | gsub("\\*"; ".*") | gsub("\\?"; ".")
    | "^" + . + "$";
  def model_subjects:
    ascii_downcase | split("/") as $p
    | [range(0; $p | length) as $i | $p[$i:] | join("/")];
  def model_ban($list; $id):
    if ($id | type) != "string" or $id == "" or $id == "default" then null
    else ($id | model_subjects) as $s
      | first((($list.never // [])[] | . as $r
          | ($r.pattern | model_glob_re) as $re
          | select(any($s[]; test($re))) | $r), null)
    end;
  def model_banned_any($list; $ids):
    first(($ids[] | . as $id | model_ban($list; $id) | select(. != null) | . + {id: $id}), null);
'
# Family tokens that mark a Jev option as a model even when no rule names it.
FM_MODEL_FAMILY_RE='(^|[^a-z0-9])((claude|opus|sonnet|haiku|fable|gpt-?[0-9o]|o[0-9]-|codex|gemini|grok|glm|qwen|deepseek|kimi|moonshot|mimo|minimax|mistral|llama|devin|swe-[0-9]|space-bunny|openai|anthropic|openrouter|opencode)|(sol|luna)([^a-z]|$))'

fm_model_denylist_load() {
  local dir=${1:-} file err
  FM_MODEL_DENYLIST_ERROR=''
  FM_MODEL_DENYLIST_JSON='{"never":[],"rules":[]}'
  FM_MODEL_DENYLIST_FILE=''
  [ -n "$dir" ] || return 0
  file="$dir/$FM_MODEL_DENYLIST_NAME"
  FM_MODEL_DENYLIST_FILE=$file
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if ! { [ -f "$file" ] && [ -r "$file" ]; }; then
    FM_MODEL_DENYLIST_ERROR="$file is not a readable regular file"
    return 1
  fi
  err=$(jq -r '
    def text: type == "string" and (gsub("\\s"; "") | length) > 0;
    def clean: type == "string" and ([explode[] | select(. < 32 or . == 127)] | length) == 0;
    if type != "object" then "the file is not a JSON object"
    elif (.never | type) != "array" then "never must be an array"
    elif any(.never[]; type != "object") then "every never entry must be an object"
    elif any(.never[]; (.pattern | text | not) or (.pattern | clean | not) or (.pattern | test("\\s"))) then "every never entry needs a pattern without whitespace"
    elif any(.never[]; .pattern | test("^[*?]+$")) then "a pattern must name something; * alone would ban every model"
    elif any(.never[]; (.reason | text | not) or (.reason | clean | not) or (.reason | length) > 200) then "every never entry needs a one-line reason of at most 200 characters"
    elif has("rules") and ((.rules | type) != "array" or any(.rules[]; (text | not) or (clean | not) or length > 300)) then "rules must be an array of one-line strings of at most 300 characters"
    else empty end
  ' "$file" 2>/dev/null) || {
    FM_MODEL_DENYLIST_ERROR="$file is not valid JSON"
    return 1
  }
  if [ -n "$err" ]; then
    FM_MODEL_DENYLIST_ERROR="$file: $err"
    return 1
  fi
  FM_MODEL_DENYLIST_JSON=$(jq -c '{never: [.never[] | {pattern, reason}], rules: (.rules // [])}' "$file" 2>/dev/null) || {
    FM_MODEL_DENYLIST_ERROR="could not read $file"
    return 1
  }
  return 0
}

fm_model_denylist_check() {
  local what=${1:-model} hit ids
  shift || true
  FM_MODEL_DENYLIST_ERROR=''
  [ $# -gt 0 ] || return 0
  ids=$(jq -nc '$ARGS.positional' --args "$@") || {
    FM_MODEL_DENYLIST_ERROR="could not check $what against the never-use model list"
    return 1
  }
  hit=$(jq -nr --argjson list "$FM_MODEL_DENYLIST_JSON" --argjson ids "$ids" "$FM_MODEL_DENYLIST_JQ"'
    model_banned_any($list; $ids) | if . == null then "" else "\(.id)\t\(.pattern)\t\(.reason)" end') || {
    FM_MODEL_DENYLIST_ERROR="could not check $what against the never-use model list"
    return 1
  }
  [ -n "$hit" ] || return 0
  local id=${hit%%$'\t'*} rest=${hit#*$'\t'}
  FM_MODEL_DENYLIST_ERROR="$what '$id' is on the never-use model list: rule '${rest%%$'\t'*}' - ${rest#*$'\t'} (${FM_MODEL_DENYLIST_FILE:-model-denylist.json})"
  return 1
}

fm_model_denylist_check_launch() {
  local what=$1 harness=${2:-} model=${3:-}
  if [ -n "$model" ] && [ "$model" != default ]; then
    fm_model_denylist_check "$what" "$model" ${harness:+"$harness/$model"}
  else
    fm_model_denylist_check "$what" "$harness"
  fi
}

# Strips quotes, backticks, and trailing punctuation a prose pin may carry.
fm_model_denylist_clean_pin() {
  local v=$1
  v=${v#[\"\'\`]}
  v=${v%%[\"\'\`,;)\]]*}
  v=${v%.}
  printf '%s' "$v"
}

fm_model_denylist_text_pins() {
  local token
  while IFS= read -r token; do
    token=${token#--model}
    token=${token#=}
    token=${token#"${token%%[![:space:]]*}"}
    token=$(fm_model_denylist_clean_pin "$token")
    [ -z "$token" ] || printf '%s\n' "$token"
  done < <(printf '%s\n' "${1:-}" | grep -oE -e '--model(=|[[:space:]]+)[^[:space:]]+' 2>/dev/null || true)
}

fm_model_denylist_yaml_pins() {
  local file=$1
  [ -f "$file" ] && [ -r "$file" ] || return 0
  awk '
    function clean(v) {
      sub(/^[ \t]*-?[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v)
      gsub(/^["\x27]|["\x27,]*[ \t]*$/, "", v)
      return v
    }
    /^[ \t]*#/ { next }
    {
      line = $0
      if (want) {
        if (line ~ /^[ \t]*-[ \t]*[^ \t]/) { v = clean(line); if (v != "") print v }
        want = 0
        next
      }
      if (line ~ /^[ \t]*-[ \t]*["\x27]?--model["\x27]?[ \t]*(#.*)?$/) { want = 1; next }
      if (match(line, /--model[= \t,"\x27]+[^] \t,"\x27]+/)) {
        v = substr(line, RSTART, RLENGTH); sub(/^--model[= \t,"\x27]+/, "", v); print v
      }
      if (line ~ /^[ \t]*model:[ \t]*[^ \t#]/) { v = line; sub(/^[ \t]*model:/, "", v); v = clean(v); if (v != "") print v }
    }
  ' "$file"
}

fm_model_denylist_check_pins() {
  local what=$1 pins=${2:-} pin
  # shellcheck disable=SC2034 # Read by sourcing callers after the check returns.
  FM_MODEL_DENYLIST_ERROR=''
  while IFS= read -r pin; do
    [ -n "$pin" ] || continue
    fm_model_denylist_check "$what" "$pin" || return 1
  done <<<"$pins"
  return 0
}

fm_model_denylist_check_nm_config() {
  local file=${1:-${NM_HOME:-$HOME/.no-mistakes}/config.yaml}
  [ -e "$file" ] || return 0
  fm_model_denylist_check_pins "no-mistakes reviewer model in $file" "$(fm_model_denylist_yaml_pins "$file")"
}

fm_model_rules_summary() {
  local summary max=$FM_MODEL_RULES_SUMMARY_MAX
  summary=$(jq -r '
    if (.never | length) == 0 and (.rules | length) == 0 then ""
    else "Captain model rules (binding; options naming a banned model were removed):"
      + (if (.never | length) > 0
         then " Never use " + ([.never[] | "\(.pattern) (\(.reason))"] | join("; ")) + "."
         else "" end)
      + (if (.rules | length) > 0 then " " + (.rules | join(" ")) else "" end)
    end' <<<"$FM_MODEL_DENYLIST_JSON" 2>/dev/null) || return 0
  if [ "$(printf '%s' "$summary" | wc -c | tr -d ' ')" -gt "$max" ]; then
    summary=$(jq -rn --arg s "$summary" --argjson max "$((max - 3))" '
      $s | explode | reduce .[] as $c ({out: [], full: false};
        if .full then .
        elif ((.out + [$c]) | implode | utf8bytelength) <= $max then .out += [$c]
        else .full = true end)
      | (.out | implode) + "..."')
  fi
  printf '%s' "$summary"
}

fm_model_option_looks_like_model() {
  local text=${1:-}
  printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | grep -qE "$FM_MODEL_FAMILY_RE" && return 0
  [ -n "$text" ] || return 1
  ! fm_model_denylist_check option "$text"
}
