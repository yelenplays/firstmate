#!/usr/bin/env bash
# fm-free-research-lane.sh - turn the free research lane on or off in this
# home's config/crew-dispatch.json.
#
# Usage:
#   fm-free-research-lane.sh status
#   fm-free-research-lane.sh enable
#   fm-free-research-lane.sh disable
#   fm-free-research-lane.sh --help
#
# The lane is one dispatch rule for read-only research and reading on
#   non-private material, whose sole profile is the free model marked
#   "private_ok": false; bin/fm-free-lane-lib.sh owns the profile and its paid
#   replacement, and docs/configuration.md "Free research lane" owns the
#   operator view.
#
# `enable` appends the lane rule as the last rule, so every existing rule
#   number and `beats` entry stays valid. It refuses in a secondmate home
#   (whose rules are inherited from the primary), when the rules file is
#   missing or not a JSON object, and when config/private-markers is missing,
#   not a readable regular file, or names no marker, because the
#   private-material guard (bin/fm-private-guard-lib.sh) can then prove nothing
#   non-private. It never reads a marker's text into its output. An existing
#   lane rule, free or already swapped to the paid replacement, is reported and
#   left alone. The previous rules file is kept as
#   config/crew-dispatch.json.bak-<YYYY-MM-DD>-research-lane. It then pushes the
#   rules to live secondmate homes with bin/fm-config-push.sh and arms the
#   free-model canary (bin/fm-free-model-canary.sh arm --if-watched).
#   Precedence over overlapping rules is a per-home `beats` edit the operator
#   makes after enabling, never this script's.
#
# `disable` removes the lane rule when it is the last rule, together with every
#   `beats` entry that names it (a `beats` left empty is dropped), so no other
#   rule number moves. A lane rule that is not last is refused, because
#   removing it would renumber later rules. It keeps the same dated backup,
#   pushes to secondmate homes, and disarms the free-model canary when no
#   other profile still runs the free model.
#
# `status` prints the lane rule's number and whether it runs the free model or
#   the paid replacement, and the marker count, never a marker.
#
# Exit codes: 0 success or nothing to do, 1 a refusal, 2 a usage error.
#
# Environment: FM_HOME, FM_CONFIG_OVERRIDE, FM_STATE_OVERRIDE,
#   FM_CONFIG_PUSH_BIN (default bin/fm-config-push.sh),
#   FM_FREE_MODEL_CANARY_BIN (default bin/fm-free-model-canary.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RULES="$CONFIG_DIR/crew-dispatch.json"
MARKERS="$CONFIG_DIR/private-markers"
CONFIG_PUSH_BIN="${FM_CONFIG_PUSH_BIN:-$SCRIPT_DIR/fm-config-push.sh}"
CANARY_BIN="${FM_FREE_MODEL_CANARY_BIN:-$SCRIPT_DIR/fm-free-model-canary.sh}"

# shellcheck source=bin/fm-free-lane-lib.sh
. "$SCRIPT_DIR/fm-free-lane-lib.sh"

# The lane rule. Rule text reaches Jev on every dispatch, so it names no
# private project, person, or client; config/private-markers holds those
# locally and the guard enforces them in code.
LANE_WHEN='read-only research and reading on non-private material whose deliverable is an evidence file, inventory, summary or first-pass research report that firstmate or a stronger model checks before anything ships or is decided: public web or GitHub research sweeps, gathering sources and documentation, codebase or public wiki inventories, transcript or document distillation, comparisons and fact checks. Only for public-code projects or public web topics. Never for code changes, tests, reviews, or a report that directly decides a captain question, and never for private projects, private people or clients, personal accounts, health or finances'
LANE_WHY='Free research lane (bin/fm-free-research-lane.sh): read-only, non-private work checked by a stronger model; the private-material guard enforces non-private in code and the free-model canary swaps to the paid replacement when the free tier ends.'

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}
die_usage() { printf 'fm-free-research-lane: %s\n' "$1" >&2; exit 2; }
refuse() { printf 'fm-free-research-lane: %s\n' "$1" >&2; exit 1; }

secondmate_home() { [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; }

rules_object() { jq -e 'type == "object"' "$RULES" >/dev/null 2>&1; }

# The 1-based number of the lane rule, empty when there is none.
lane_rule_number() {
  jq -r "$FM_FREE_LANE_JQ"' [(.rules // []) | to_entries[] | select(lane_rule(.value)) | .key + 1] | first // empty' "$RULES" 2>/dev/null
}

# The number of markers in config/private-markers; never prints a marker.
marker_count() {
  [ -f "$MARKERS" ] && [ ! -L "$MARKERS" ] && [ -r "$MARKERS" ] || return 1
  awk '{ sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") } $0 != "" && substr($0, 1, 1) != "#" { n++ } END { print n + 0 }' "$MARKERS"
}

# Replace the rules file with <new-file>, keeping a dated backup first.
install_rules() {  # <new-file>
  local tmp=$1 backup
  backup="$RULES.bak-$(date +%Y-%m-%d)-research-lane"
  [ -e "$backup" ] || cp -p -- "$RULES" "$backup" || { rm -f -- "$tmp"; refuse 'could not keep a backup of the rules file'; }
  chmod "$(stat -f '%Lp' "$RULES" 2>/dev/null || stat -c '%a' "$RULES" 2>/dev/null || printf 600)" "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$RULES" || { rm -f -- "$tmp"; refuse 'could not replace the rules file'; }
  printf 'backup: config/%s\n' "${backup#"$CONFIG_DIR"/}"
}

push_rules() {
  [ -x "$CONFIG_PUSH_BIN" ] || return 0
  FM_HOME="$FM_HOME" "$CONFIG_PUSH_BIN" >/dev/null 2>&1 \
    || printf 'warning: the config push to secondmate homes failed; run bin/fm-config-push.sh\n'
}

preflight() {
  secondmate_home && refuse 'this is a secondmate home; its dispatch rules are inherited from the primary'
  [ -f "$RULES" ] && [ -r "$RULES" ] || refuse "no readable rules file at $RULES"
  rules_object || refuse "the rules file is not a JSON object: $RULES"
}

action_status() {
  local n count
  if ! { [ -f "$RULES" ] && rules_object; }; then
    printf 'lane: disabled (no readable rules file)\n'
    return 0
  fi
  n=$(lane_rule_number)
  if [ -z "$n" ]; then
    printf 'lane: disabled\n'
  elif [ "$(jq -r --argjson n "$n" "$FM_FREE_LANE_JQ"' lane_free(lane_profiles(.rules[$n - 1].use)[0])' "$RULES")" = true ]; then
    printf 'lane: enabled as rule %s on %s\n' "$n" "$FM_FREE_LANE_MODEL"
  else
    printf 'lane: enabled as rule %s on the paid replacement %s %s\n' "$n" "$FM_FREE_LANE_PAID_HARNESS" "$FM_FREE_LANE_PAID_MODEL"
  fi
  if count=$(marker_count); then
    printf 'private markers: %s\n' "$count"
  else
    printf 'private markers: none readable at config/private-markers\n'
  fi
}

action_enable() {
  local n count tmp
  preflight
  n=$(lane_rule_number)
  [ -z "$n" ] || { printf 'lane: already enabled as rule %s\n' "$n"; return 0; }
  count=$(marker_count) || refuse 'config/private-markers is missing or not a readable regular file; the private-material guard would refuse every task, so the lane stays off'
  [ "$count" -gt 0 ] || refuse 'config/private-markers names no marker; add the private projects, people, and clients first'
  tmp=$(mktemp "$CONFIG_DIR/.crew-dispatch.json.research-lane.XXXXXX") || refuse 'mktemp failed'
  if ! jq --indent 2 --arg when "$LANE_WHEN" --arg why "$LANE_WHY" --argjson profile "$FM_FREE_LANE_PROFILE" \
    '.rules = ((.rules // []) + [{when: $when, use: [$profile], why: $why}])' "$RULES" > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    refuse 'could not add the lane rule'
  fi
  install_rules "$tmp"
  n=$(lane_rule_number)
  printf 'lane: enabled as rule %s on %s\n' "$n" "$FM_FREE_LANE_MODEL"
  push_rules
  if [ -x "$CANARY_BIN" ]; then
    FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG_DIR" FM_STATE_OVERRIDE="$STATE" "$CANARY_BIN" arm --if-watched >/dev/null 2>&1 \
      || printf 'warning: could not arm the free-model canary; run bin/fm-free-model-canary.sh arm\n'
  fi
}

action_disable() {
  local n total tmp
  preflight
  n=$(lane_rule_number)
  [ -n "$n" ] || { printf 'lane: already disabled\n'; return 0; }
  total=$(jq -r '.rules | length' "$RULES")
  [ "$n" = "$total" ] || refuse "the lane is rule $n of $total; removing it would renumber later rules, so edit config/crew-dispatch.json by hand"
  tmp=$(mktemp "$CONFIG_DIR/.crew-dispatch.json.research-lane.XXXXXX") || refuse 'mktemp failed'
  if ! jq --indent 2 --argjson n "$n" '
    .rules |= (.[:$n - 1] | map(
      if type == "object" and has("beats") then
        (.beats |= map(select(.rule != $n))) | (if (.beats | length) == 0 then del(.beats) else . end)
      else . end))' "$RULES" > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    refuse 'could not remove the lane rule'
  fi
  install_rules "$tmp"
  printf 'lane: disabled (removed rule %s)\n' "$n"
  push_rules
  if [ -x "$CANARY_BIN" ] && [ "$(jq -r "$FM_FREE_LANE_JQ"' lane_watched' "$RULES")" != true ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$CANARY_BIN" disarm >/dev/null 2>&1 \
      || printf 'warning: could not disarm the free-model canary; run bin/fm-free-model-canary.sh disarm\n'
  fi
}

command -v jq >/dev/null 2>&1 || die_usage 'jq is required'
case "${1:-}" in
  status) action_status ;;
  enable) action_enable ;;
  disable) action_disable ;;
  -h | --help) usage ;;
  *) die_usage 'usage: status|enable|disable|--help' ;;
esac
