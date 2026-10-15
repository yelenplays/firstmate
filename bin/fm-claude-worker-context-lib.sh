#!/usr/bin/env bash
# Claude launch context overlay, consumed by fm-spawn's inline --settings.
# Usage (source): fm_claude_worker_context <kind> <worktree> <code-root> <project-root>
# Prints a JSON object. Ship, scout, and secondmate launches in any repo get an
# 8000-character skill-listing budget through the documented environment knob
# (fm_claude_skill_budget_settings, also the value docs/configuration.md gives
# for no-mistakes pipeline agents); any other kind receives {}.
# Names and explicit skill invocation remain available; Claude drops less-used
# descriptions first. No global/user settings or instruction files are changed.
# A secondmate keeps every instruction file: AGENTS.md is its supervisor contract.
# For ship and scout only, this Firstmate repository's root CLAUDE.md/AGENTS.md
# are excluded, proven by physical Git common-dir equality or equal normalized
# origin URLs (pool and standalone clones). Missing identity evidence leaves project instructions on.
# claudeMdExcludes arrays merge with other settings layers. Both lexical and
# physical absolute paths are included. A root containing glob metacharacters
# or quotes skips exclusions with a warning (skill budget still applies): native
# Claude did not reliably exclude such paths. Never widen one into a pattern.
# The launch brief remains the worker contract. Other adapters are unchanged.

# shellcheck source=bin/fm-relaunch-worktree-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-relaunch-worktree-lib.sh"

FM_CLAUDE_SKILL_LISTING_BUDGET=8000

# fm_claude_skill_budget_settings: the skill-listing budget as a settings JSON object.
fm_claude_skill_budget_settings() {
  jq -nc --arg budget "$FM_CLAUDE_SKILL_LISTING_BUDGET" '{env: {SLASH_COMMAND_TOOL_CHAR_BUDGET: $budget}}'
}

fm_claude_worker_context() {
  local kind=$1 wt=$2 code=$3 project=$4 common_wt common_code url_wt url_code same=0 roots wt_real code_real project_real path budget
  case "$kind" in
    ship | scout) ;;
    secondmate)
      fm_claude_skill_budget_settings
      return
      ;;
    *) printf '{}\n'; return 0 ;;
  esac
  common_wt=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null) || common_wt=
  common_code=$(git -C "$code" rev-parse --git-common-dir 2>/dev/null) || common_code=
  if [ -n "$common_wt" ] && [ -n "$common_code" ]; then
    common_wt=$(cd "$wt" && cd "$common_wt" && pwd -P) || return 1
    common_code=$(cd "$code" && cd "$common_code" && pwd -P) || return 1
    [ "$common_wt" != "$common_code" ] || same=1
  fi
  if [ "$same" = 0 ]; then
    url_wt=$(git -C "$wt" remote get-url origin 2>/dev/null) || url_wt=
    url_code=$(git -C "$code" remote get-url origin 2>/dev/null) || url_code=
    if [ -n "$url_wt" ] && [ -n "$url_code" ]; then
      url_wt=$(fm_relaunch_origin_key "$url_wt") || url_wt=
      url_code=$(fm_relaunch_origin_key "$url_code") || url_code=
      [ -z "$url_wt" ] || [ "$url_wt" != "$url_code" ] || same=1
    fi
  fi
  roots='[]'
  if [ "$same" = 1 ]; then
    wt_real=$(cd "$wt" && pwd -P) || return 1
    code_real=$(cd "$code" && pwd -P) || return 1
    project_real=$(cd "$project" && pwd -P) || return 1
    # Claude may retain the launch spelling (for example macOS /var versus
    # /private/var), while an import can reach the physical spelling.
    roots=$(jq -nc --arg wt "$wt" --arg code "$code" --arg project "$project" \
      --arg wt_real "$wt_real" --arg code_real "$code_real" --arg project_real "$project_real" \
      '[$wt, $code, $project, $wt_real, $code_real, $project_real] | unique') || return 1
    for path in "$wt" "$code" "$project" "$wt_real" "$code_real" "$project_real"; do
      case "$path" in
        *'*'* | *'?'* | *'['* | *']'* | *'{'* | *'}'* | *'('* | *')'* | *'!'* | *'+'* | *'@'* | *"\\"* | *"'"* | *'"'*)
          echo "warning: Claude worker supervisor exclusions skipped: an instruction root contains glob metacharacters or quotes; keeping project instructions loaded" >&2
          roots='[]'
          break
          ;;
      esac
    done
  fi
  budget=$(fm_claude_skill_budget_settings) || return 1
  jq -nc --argjson budget "$budget" --argjson roots "$roots" '
    $budget +
    (if ($roots | length) == 0 then {} else
      {claudeMdExcludes: [$roots[] | . + "/CLAUDE.md", . + "/AGENTS.md"]}
    end)'
}
