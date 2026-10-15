# shellcheck shell=bash
# These constants are this library's output; its callers read them.
# shellcheck disable=SC2034
# fm-free-lane-lib.sh - the one owner of the free research lane's profiles.
#
# docs/configuration.md "Free research lane" owns the operator contract.
#   bin/fm-free-research-lane.sh installs the lane's rule with
#   FM_FREE_LANE_PROFILE, and bin/fm-free-model-canary.sh swaps that profile to
#   FM_FREE_LANE_REPLACEMENT once FM_FREE_LANE_MODEL is no longer listed by
#   `opencode models FM_FREE_LANE_PROVIDER`. No other model or replacement is
#   ever watched or written.
#
# FM_FREE_LANE_JQ defines, for a jq program:
#   lane_profiles($v)   a rule's use or the default as an array of profiles
#   lane_free($p)       true for an opencode profile on FM_FREE_LANE_MODEL
#   lane_paid($p)       true for a profile on the replacement's harness and model
#   lane_rule($r)       true for a rule whose use is exactly one lane profile,
#                       free or already swapped to the replacement
#   lane_watched        true when some rule's use or the default runs the
#                       free model (input: the rules file)

FM_FREE_LANE_MODEL='opencode/deepseek-v4.1-flash-free'
FM_FREE_LANE_PROVIDER='opencode'
FM_FREE_LANE_PAID_HARNESS='pi'
FM_FREE_LANE_PAID_MODEL='opencode-go/deepseek-v4.1-flash'
FM_FREE_LANE_PAID_PROVIDER='opencode-go'

FM_FREE_LANE_PROFILE='{"harness":"opencode","model":"'"$FM_FREE_LANE_MODEL"'","provider":"'"$FM_FREE_LANE_PROVIDER"'","private_ok":false}'
FM_FREE_LANE_REPLACEMENT='{"harness":"'"$FM_FREE_LANE_PAID_HARNESS"'","model":"'"$FM_FREE_LANE_PAID_MODEL"'","provider":"'"$FM_FREE_LANE_PAID_PROVIDER"'"}'

# shellcheck disable=SC2016 # A jq program: $p and $r are jq's, not the shell's.
FM_FREE_LANE_WHY='Free research lane (bin/fm-free-research-lane.sh): read-only, non-private work checked by a stronger model; the private-material guard enforces non-private in code and the free-model canary swaps to the paid replacement when the free tier ends.'

FM_FREE_LANE_JQ='
  def lane_profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def lane_free($p): ($p | type) == "object" and $p.harness == "opencode" and $p.model == "'"$FM_FREE_LANE_MODEL"'";
  def lane_paid($p): ($p | type) == "object" and $p.harness == "'"$FM_FREE_LANE_PAID_HARNESS"'" and $p.model == "'"$FM_FREE_LANE_PAID_MODEL"'";
  def lane_rule($r): ($r | type) == "object" and $r.why == "'"$FM_FREE_LANE_WHY"'" and (lane_profiles($r.use) | length) == 1
    and (lane_free(lane_profiles($r.use)[0]) or lane_paid(lane_profiles($r.use)[0]));
  def lane_watched: [((.rules // [])[] | lane_profiles(.use)[]), lane_profiles(.default // null)[]] | any(.[]; lane_free(.));
'
