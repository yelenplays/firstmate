#!/usr/bin/env bash
# Metadata-only advisory for a review-ready GitHub wiki PR.
# Usage: fm-jev-pr-verdict.sh <canonical-github-pr-url>
# Prints a one-line advisory to place beside the PR review ask. Empty output
# means no configured key, no eligible share-safe card, or unavailable evidence.
# Neither this script nor its caller may use the verdict as merge authority.
# Cards, PR titles/bodies, patches, page content, paths and check names never
# reach Jev. Only fixed vocabulary categories and aggregate gate counts do.
# The card is an admission gate, not an access control substitute. A PR's
# private-page/frontmatter safety still needs human review before any merge.
# One record per successful invocation is appended to state/jev-pr-verdict.jsonl.
# FM_WIKI_ROOT defaults to ~/Documents/Wikis; FM_HOME selects private state.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_WIKI_ROOT=${FM_WIKI_ROOT:-$HOME/Documents/Wikis}
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"

if [ "$#" -ne 1 ]; then
  printf 'Usage: fm-jev-pr-verdict.sh <canonical-github-pr-url>\n' >&2
  exit 2
fi
fm_pr_url_parse "$1" && [ "$FM_PR_PROVIDER" = github ] || exit 2
url=$FM_PR_URL
repo=$FM_PR_PATH
number=$FM_PR_NUMBER
fm_jev_key_configured || exit 0
command -v gh-axi >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0

# Match exactly one card. Never read a vault or send its name or path to Jev.
# Refuse duplicate repo claims, mixed/unsanitized cards, and restricted tiers.
cards="$FM_WIKI_ROOT/routing/cards"
[ -d "$cards" ] && [ ! -L "$cards" ] || exit 0
matches=0
tier=
for card in "$cards"/*.yaml; do
  [ -f "$card" ] && [ ! -L "$card" ] || continue
  card_repo=$(awk '/^repo: / {sub(/^repo: /, ""); print}' "$card")
  [ "$card_repo" = "$repo" ] || continue
  matches=$((matches + 1))
  [ "$matches" -eq 1 ] || exit 0
  tier=$(awk '/^share_tier: / {sub(/^share_tier: /, ""); print}' "$card")
  gate=$(awk '/^share_gate: / {sub(/^share_gate: /, ""); print}' "$card")
  cloud=$(awk '/^cloud: / {sub(/^cloud: /, ""); print}' "$card")
  mode=$(awk '/^modus: / {sub(/^modus: /, ""); print}' "$card")
  case "$tier:$gate:$cloud:$mode" in team:rein:ja:voll|agency:rein:ja:voll) ;; *) exit 0 ;; esac
done
[ "$matches" -eq 1 ] || exit 0

# gh-axi renders TOON rather than raw JSON. Project *only* a fixed-shape
# scalar in its jq layer; accept the body only if there is exactly one body
# line. Unprojected API results can expose private content and clone tokens.
api_scalar() { # endpoint jq-expression
  local out
  out=$(fm_gh_run gh-axi api "$1" --jq "$2" 2>/dev/null) || return 1
  printf '%s\n' "$out" | awk '
    /^api_response:$/ { response++ ; next }
    /^  body: / { n++; value=substr($0, 9); next }
    /^  truncated: false$/ { complete++; next }
    { invalid++ }
    END { if (response != 1 || n != 1 || complete != 1 || invalid || value == "") exit 1; print value }
  '
}
core=$(api_scalar "/repos/$repo/pulls/$number" '[.state, (.draft|tostring), .head.sha, .base.ref] | join("|")') || exit 0
IFS='|' read -r state draft head base <<< "$core"
[ "$state" = open ] && [ "$draft" = false ] && fm_pr_head_valid "$head" || exit 0
# Base branch is a local fact used for a deterministic concern, not sent as text.
[ -n "$base" ] || exit 0
# Only path *categories* are computed remotely. No paths, diffs, patches,
# titles or page bodies are returned to this process or to Jev. Limit this
# assessment to the first 100 changed files; larger PRs are not assessed.
files=$(api_scalar "/repos/$repo/pulls/$number/files?per_page=100" '[length, any(.[]; .filename | test("(^|/)raw/|(^|/)private/"; "i")), any(.[]; .filename | test("(^|/)(llms\\.txt|register\\.json|_meta/index[^/]*|digest\\.md)$"; "i")), any(.[]; .filename | test("\\.md$"; "i")), any(.[]; .filename | test("\\.(sh|py|ts|js)$"; "i"))] | map(tostring) | join("|")') || exit 0
IFS='|' read -r count restricted generated prose tooling <<< "$files"
case "$count" in ''|*[!0-9]*) exit 0 ;; esac
[ "$count" -gt 0 ] && [ "$count" -lt 100 ] || exit 0
for flag in "$restricted" "$generated" "$prose" "$tooling"; do
  case "$flag" in true|false) ;; *) exit 0 ;; esac
done
# GitHub's check-run summary is about this exact PR head, not an inferred
# statement that *required* checks passed. Missing/pending/failing checks are
# concerns; even all-success remains advisory, not an approval of privacy.
checks=$(api_scalar "/repos/$repo/commits/$head/check-runs?per_page=100" '[.total_count, ([.check_runs[] | select(.status != "completed")] | length), ([.check_runs[] | select(.status == "completed" and (.conclusion != "success" and .conclusion != "neutral"))] | length)] | map(tostring) | join("|")') || exit 0
IFS='|' read -r total pending failing <<< "$checks"
for value in "$total" "$pending" "$failing"; do
  case "$value" in ''|*[!0-9]*) exit 0 ;; esac
done
[ "$total" -lt 100 ] || exit 0
# Refuse a mixed observation if a force-push changed the PR while collecting
# file categories and checks from its earlier head.
after=$(api_scalar "/repos/$repo/pulls/$number" '.head.sha') || exit 0
[ "$head" = "$after" ] || exit 0

# All state fields are bounded enums or numbers, without repo identity, card
# text, check names, paths, PR prose, or vault content. Jev judges an advisory
# metadata posture; the model cannot certify privacy or grant permission.
summary=$(jq -nc --arg tier "$tier" --argjson paths "$count" \
  --argjson restricted "$restricted" --argjson generated "$generated" \
  --argjson prose "$prose" --argjson tooling "$tooling" \
  --argjson checks "$total" --argjson pending "$pending" --argjson failing "$failing" \
  '{tier:$tier, changed_file_count:$paths, restricted_path_category:$restricted,
    generated_path_category:$generated, prose_path_category:$prose,
    tooling_path_category:$tooling, reported_checks:$checks, pending_checks:$pending,
    unsuccessful_checks:$failing}') || exit 0
questions=$(jq -nc '{advisory:{type:"choice",
  instructions:"Given only the bounded metadata in state, is this PR ready to bring to the human reviewer as a metadata pass, or should the review ask flag concerns? This is not merge approval and does not verify private-page content. Restricted and generated path categories, missing, pending or unsuccessful checks are concerns.",
  criteria:{pass:"No reported metadata concern; human still inspects content, required checks and privacy before merging.", concerns:"A restricted/generated category, absent/incomplete/unsuccessful checks, or another metadata concern needs explicit human attention."}}}') || exit 0
response=$(fm_jev_decide "$summary" "$questions" 2>/dev/null) || exit 0
answer=$(printf '%s' "$response" | jq -er '.answers.advisory | select(.type == "choice") | .choice | select(. == "pass" or . == "concerns")' 2>/dev/null) || exit 0
prob=$(printf '%s' "$response" | jq -er --arg a "$answer" '.answers.advisory.probabilities[$a] | select(type == "number" and . >= 0 and . <= 1)' 2>/dev/null) || exit 0
probs=$(printf '%s' "$response" | jq -ce '.answers.advisory.probabilities' 2>/dev/null) || exit 0
printf '%s' "$probs" | jq -e 'keys == ["concerns", "pass"]' >/dev/null 2>&1 || exit 0
fm_jev_probabilities_sum_ok "$probs" || exit 0
# An inconsistent answer or a tie is not an advisory verdict.
printf '%s' "$probs" | jq -e --arg a "$answer" '.[$a] > ([to_entries[] | select(.key != $a) | .value] | max)' >/dev/null 2>&1 || exit 0
# Code owns deterministic safety warnings regardless of the model's pick.
model_choice=$answer
model_probability=$prob
reasons=
[ "$restricted" = false ] || reasons='restricted path category; '
[ "$generated" = false ] || reasons="${reasons}generated path category; "
[ "$total" -gt 0 ] || reasons="${reasons}no reported checks; "
[ "$pending" -eq 0 ] || reasons="${reasons}pending checks; "
[ "$failing" -eq 0 ] || reasons="${reasons}unsuccessful checks; "
override=false
if [ -n "$reasons" ]; then
  answer=concerns
  override=true
fi
if [ -z "$reasons" ]; then
  if [ "$answer" = concerns ]; then
    reasons='Jev flagged a metadata concern not explained by the bounded facts; '
  else
    reasons='no metadata concern identified; '
  fi
fi
reasons="${reasons}private-page content and required checks not certified"
# Never label P(Jev pass) as P(the overridden concerns verdict).
record=$(jq -nc --arg url "$url" --arg head "$head" --arg verdict "$answer" \
  --argjson override "$override" --arg model_choice "$model_choice" \
  --argjson model_probability "$model_probability" --arg reasons "$reasons" \
  --arg model "$(fm_jev_response_model "$response")" \
  '{purpose:"advisory-pr-verdict",url:$url,head:$head,verdict:$verdict,
    probability:(if $override then null else $model_probability end),
    jev_choice:$model_choice,jev_probability:$model_probability,
    deterministic_override:$override,reasons:$reasons,
    response_model:$model,merge_authority:false}') || exit 0
state_dir=${FM_STATE_OVERRIDE:-$FM_HOME/state}
if [ -d "$state_dir" ] && [ ! -L "$state_dir" ]; then
  fm_jev_log_call "$record" "$state_dir/jev-pr-verdict.jsonl" >/dev/null 2>&1 || true
fi
if [ "$override" = true ]; then
  printf 'PR advisory for %s: concerns (local rule; Jev %s p=%s); %s. Human merge decision required.\n' \
    "$url" "$model_choice" "$model_probability" "$reasons"
else
  printf 'Jev advisory for %s: %s (p=%s); %s. Human merge decision required.\n' \
    "$url" "$answer" "$model_probability" "$reasons"
fi
