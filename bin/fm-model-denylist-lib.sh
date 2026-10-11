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
#   fm_model_denylist_command_pins <command>
#     Prints one model id per line for every `--model <id>` or `--model=<id>`
#     in one command line, as `<provider>/<id>` when the command also passes
#     `--provider <provider>`. A word starting with # ends the command. When
#     the command's binary is codex, opencode, or kimi, `-m <id>`, `-m=<id>`,
#     and `-m<id>` count as `--model`. Quotes around a flag or value are ignored.
#   fm_model_denylist_brief_pins <text>
#     The command pins of every launch command line in prose: a line (joined
#     across trailing-backslash continuations), code span, or shell-separated
#     segment whose first words (after list markers, prompts, and VAR=value
#     words) form a shape in FM_MODEL_LAUNCH_SHAPES followed by a flag or
#     nothing, such as `no-mistakes axi run --model x`, `codex exec --model x`,
#     or `pi --model x`. Prose that only mentions or forbids `--model <id>` is
#     no pin.
#   fm_model_denylist_is_launch <segment>
#     Succeeds when the segment is such a launch command line.
#   fm_model_denylist_yaml_pins <file>
#     Prints one model id per line for every model a no-mistakes config pins:
#     `--provider`/`--model` argument lists (block or inline) and `provider:`
#     with `model:` keys, each combined within its own block and read as a
#     command line of the block's agent key, so `codex: [-m, <id>]` is a pin. Comments,
#     whole-line or trailing, are ignored.
#   fm_model_denylist_check_pins <what> <pins>
#     Checks each newline-separated pin from the helpers above.
#   fm_model_denylist_check_nm_config [<file>]
#     Checks every model the no-mistakes global config pins for its pipeline
#     agents (default ${NM_HOME:-$HOME/.no-mistakes}/config.yaml); an absent
#     file passes.
#   fm_model_rules_summary
#     Prints the captain model-rules summary for a Jev state, at most
#     FM_MODEL_RULES_SUMMARY_MAX bytes, or nothing when the list is empty.
#   fm_model_option_looks_like_model <text>
#     Succeeds when the text names a model: it matches a never-use rule or
#     carries a known model-family, harness, or provider token.
#   FM_MODEL_ID_RE
#     Lowercase ERE for a concrete model id: a token carrying a model family
#     token, never a bare harness, provider, or route name; a slash alone is
#     not a model id.
#   FM_MODEL_DENYLIST_JQ
#     jq definitions for callers that filter inside jq: model_token strips
#     surrounding backticks, quotes, markdown emphasis (* and _), brackets,
#     and trailing punctuation from an id; model_ban($list; $id) matches that
#     cleaned id and returns the first matching rule object or null, and
#     model_banned_any($list; $ids) does the same over an array of ids.

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
  def model_token:
    gsub("^[`\"\u0027*_\\[<(]+|[`\"\u0027*_\\]>).,:;!?]+$"; "");
  def model_ban($list; $raw):
    (if ($raw | type) == "string" then $raw | model_token else "" end) as $id
    | if $id == "" or $id == "default" then null
    else ($id | model_subjects) as $s
      | first((($list.never // [])[] | . as $r
          | ($r.pattern | model_glob_re) as $re
          | select(any($s[]; test($re))) | $r), null)
    end;
  def model_banned_any($list; $ids):
    first(($ids[] | . as $id | model_ban($list; $id) | select(. != null) | . + {id: $id}), null);
'
# Family tokens that mark a Jev option as a model even when no rule names it.
FM_MODEL_ID_TOKENS='claude|opus|sonnet|haiku|fable|gpt-?[0-9o]|o[0-9]-|gemini-[0-9]|grok-[0-9]|glm|qwen|deepseek|kimi|moonshot|mimo|minimax|mistral|llama|swe-[0-9]|space-bunny'
FM_MODEL_ROUTE_TOKENS='codex|gemini|grok|devin|openai|anthropic|openrouter|opencode'
# shellcheck disable=SC2034 # Read by the sourcing caller (bin/fm-jev.sh).
FM_MODEL_ID_RE="(^|[^a-z0-9])(($FM_MODEL_ID_TOKENS)|(sol|luna)([^a-z]|\$))"
FM_MODEL_FAMILY_RE="(^|[^a-z0-9])(($FM_MODEL_ID_TOKENS|$FM_MODEL_ROUTE_TOKENS)|(sol|luna)([^a-z]|\$))"

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

FM_MODEL_LAUNCH_PREFIX_RE='^([-*+>$]|[0-9]+[.)]|[A-Za-z_][A-Za-z0-9_]*=.*)$'

fm_model_denylist_command_pins() {
  local -a words models=()
  local i=0 word provider='' model short=''
  read -r -a words <<<"${1//$'\n'/ }"
  while [ "$i" -lt "${#words[@]}" ] && [[ ${words[i]} =~ $FM_MODEL_LAUNCH_PREFIX_RE ]]; do
    i=$((i + 1))
  done
  case "${words[i]:-}" in
    codex | */codex | opencode | */opencode | kimi | */kimi) short=1 ;;
  esac
  for ((; i < ${#words[@]}; i++)); do
    word=${words[i]#[\"\'\`]}
    word=${word%[\"\'\`]}
    if [ -n "$short" ]; then
      case "$word" in
        -m=*) word="--model=${word#-m=}" ;;
        -m) word=--model ;;
        -m?*) word="--model=${word#-m}" ;;
      esac
    fi
    case "$word" in
      '#'*) break ;;
      --model=*) models+=("${word#--model=}") ;;
      --model) models+=("${words[i + 1]:-}"); i=$((i + 1)) ;;
      --provider=*) provider=${word#--provider=} ;;
      --provider) provider=${words[i + 1]:-}; i=$((i + 1)) ;;
    esac
  done
  provider=$(fm_model_denylist_clean_pin "$provider")
  for model in "${models[@]+"${models[@]}"}"; do
    model=$(fm_model_denylist_clean_pin "$model")
    [ -n "$model" ] || continue
    if [ -n "$provider" ] && [ "${model#"$provider"/}" = "$model" ]; then
      model="$provider/$model"
    fi
    printf '%s\n' "$model"
  done
}

FM_MODEL_LAUNCH_SHAPES='no-mistakes axi run
no-mistakes axi rerun
no-mistakes run
no-mistakes rerun
claude
codex
codex exec
opencode
opencode run
pi
pi-signed
grok
kimi
cursor-agent
gemini
muse
rovo
omp
agy
devin'

fm_model_denylist_is_launch() {
  local -a words shape_words
  local i=0 j shape next
  read -r -a words <<<"${1:-}"
  while [ "$i" -lt "${#words[@]}" ] && [[ ${words[i]} =~ $FM_MODEL_LAUNCH_PREFIX_RE ]]; do
    i=$((i + 1))
  done
  [ "$i" -lt "${#words[@]}" ] || return 1
  words[i]=${words[i]##*/}
  while IFS= read -r shape; do
    read -r -a shape_words <<<"$shape"
    for ((j = 0; j < ${#shape_words[@]}; j++)); do
      [ "${words[i + j]:-}" = "${shape_words[j]}" ] || continue 2
    done
    next=${words[i + j]:-}
    case "$next" in '' | -*) return 0 ;; esac
  done <<<"$FM_MODEL_LAUNCH_SHAPES"
  return 1
}

fm_model_denylist_brief_pins() {
  local segment text=${1:-}
  text=${text//$'\\\n'/ }
  while IFS= read -r segment; do
    fm_model_denylist_is_launch "$segment" || continue
    fm_model_denylist_command_pins "$segment"
  done <<<"${text//[\`;|&]/$'\n'}"
}

fm_model_denylist_yaml_pins() {
  local file=$1 command
  [ -f "$file" ] && [ -r "$file" ] || return 0
  while IFS= read -r command; do
    fm_model_denylist_command_pins "$command"
  done < <(awk '
    function owner(ind, item) {
      while (depth > 0 && (at[depth] > ind || (!item && at[depth] == ind))) depth--
      return depth > 0 ? id[depth] : 0
    }
    function unquote(v) { gsub(/^["\x27]|["\x27]$/, "", v); return v }
    function words(v) { gsub(/[][,"\x27]/, " ", v); return v }
    function add(o, v) { if (!(o in cmd)) { order[++n] = o; cmd[o] = name[o] } cmd[o] = cmd[o] " " v }
    /^[ \t]*(#|$)/ { next }
    {
      line = $0
      sub(/[ \t]+#.*$/, "", line); sub(/[ \t]+$/, "", line)
      match(line, /^[ \t]*/); ind = RLENGTH
      body = substr(line, ind + 1)
      if (body ~ /^-([ \t]|$)/) { sub(/^-[ \t]*/, "", body); add(owner(ind, 1), words(body)); next }
      if (!match(body, /^["\x27]?[A-Za-z0-9_.-]+["\x27]?[ \t]*:([ \t]|$)/)) next
      key = substr(body, 1, RLENGTH); sub(/[ \t]*:[ \t]*$/, "", key); key = unquote(key); name[NR] = key
      val = substr(body, RLENGTH + 1); sub(/^[ \t]+/, "", val)
      parent = owner(ind, 0)
      if (val == "") { depth++; at[depth] = ind; id[depth] = NR; next }
      if (key == "provider") add(parent, "--provider " unquote(val))
      else if (key == "model") add(parent, "--model " unquote(val))
      else add(NR, words(val))
    }
    END { for (i = 1; i <= n; i++) print cmd[order[i]] }
  ' "$file")
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
