#!/usr/bin/env bash
# fm-quota-guard.sh - the runtime quota floor guard for one firstmate home.
# Usage: fm-quota-guard.sh heartbeat  [--config <dir>] [--state <dir>]
#        fm-quota-guard.sh preflight  --harness <name> [--model <name>]
#                                     [--provider <name>|none]
#                                     [--config <dir>] [--state <dir>]
#        fm-quota-guard.sh report     [--config <dir>] [--state <dir>]
#        fm-quota-guard.sh refresh    [--catalog] [--config <dir>] [--state <dir>]
#
# WHAT THIS GUARD IS FOR
# ----------------------
# `quota-axi` is consulted by the first mate at dispatch intake and never again,
# so between a dispatch and the captain's morning nothing watched a provider's
# allowance drain. This guard closes exactly that window, and only that window.
# It has two entry points and one hard boundary.
#
#   heartbeat  The watcher calls this on its heartbeat cadence. It prints ONE
#              line when firstmate should wake and nothing otherwise - the same
#              contract every state check in state/<id>.check.sh follows - so a
#              crossed floor reaches the captain through the ordinary wake path.
#              `check:` wakes always escalate, including under away mode, which
#              is what makes this survive the night (bin/fm-supervise-daemon.sh's
#              classify_check).
#   preflight  bin/fm-spawn.sh calls this before it creates an endpoint,
#              provisions a worktree, or publishes a task record, so a launch
#              aimed at an exhausted provider is refused with no task left behind.
#
# THE HARD BOUNDARY: THIS GUARD NEVER STOPS RUNNING WORK
# ------------------------------------------------------
# It stops NEW dispatch and it escalates. It never interrupts, exits, relaunches,
# kills, or tears down a worker, and it must never learn how. Terminating a live
# validation pipeline can destroy hours of unlanded work, and a quiet pipeline in
# this fleet is not a dead one - a single review step has run over an hour of
# continuous model time. Saving quota is never worth that trade. Do not add a
# lifecycle action here, and do not add one to a caller "just for the exhausted
# case": if running work must be stopped to protect an allowance, that is the
# captain's explicit decision through bin/fm-control.sh, never this guard's.
#
# WHAT COUNTS AS MEASURED
# -----------------------
# `quota-axi` stays data-only: it reports windows and computes the vendor's own
# effective availability, and it never recommends. This guard supplies the only
# judgment in the loop - comparing a measured remaining percentage against a
# configured floor - and it never selects a provider or proposes one. Choosing
# among candidates at intake remains firstmate's open reasoning, owned by
# .agents/skills/quota-array-dispatch/SKILL.md.
#
# Three verdicts, and the third is a synonym for neither of the others:
#   ok       measured, and remaining is at or above the floor.
#   below    measured, and remaining is under the floor.
#   unknown  NOT measured. A stale window, a missing availability entry, a
#            missing or incompatible quota-axi, a missing jq, a failed or
#            timed-out read, and a harness with no verified provider binding all
#            land here. Unknown never refuses a launch and is never reported as
#            headroom; it is disclosed as uncertainty.
#
# Granularity comes from the vendor, never from a name:
#   - The provider-wide bound is `quotaSemantics.effectiveAvailability` scoped
#     `all_models` or `all_products`. That window bounds every model in the
#     family, and it is the bound that actually protects an unattended night.
#   - A named model adds a bound only when `quota-axi models --json` - the
#     vendor's own deterministic model-to-scope join - carries that exact model
#     id. Its `effective` is already the minimum across every window bounding it,
#     so it can only lower the effective remaining, never raise it. A model
#     absent from that catalog adds no bound and is disclosed as such. This guard
#     never parses a model name to guess a provider or a family.
#   - `state.stale` forces unknown even when a percentage is present, because a
#     stale window is diagnostic data and not headroom.
#   - `providers[].credits` is never read. Grok's `credits.remaining` is a
#     prepaid balance rather than a consumption window, and a zero balance there
#     is not exhaustion of anything this guard governs.
#
# PROVIDER BINDING (which allowance a launch actually burns)
# ----------------------------------------------------------
# docs/verification/dispatch-auth.md records that no script maps a model to a
# provider, a provider to a credential store, or a name prefix to a family, and
# that invariant holds here: nothing below is derived from a name. The bindings
# this guard ships are VERIFIED declarations in the same sense as the fixed-argv
# registry in bin/fm-vendor-auth-probe.sh - each is corroborated by `quota-axi
# auth --json` naming the same credential source the harness itself
# authenticates from, with the dated evidence in
# docs/verification/dispatch-auth.md. Precedence, strongest first:
#
#   1. --provider <name>   what firstmate resolved in the open for this launch.
#                          `--provider none` states that no measurable provider
#                          governs it: a disclosed unknown, not a way to walk
#                          past a floor that was measured.
#   2. config/quota-floor  a `launch <harness> <provider|none>` line, so the
#                          captain's real local setup outranks anything shipped.
#   3. the shipped table   claude, codex, grok, and kimi only.
#
# Every other harness is deliberately unbound and resolves to unknown: pi,
# pi-signed, and opencode route to providers that cannot be observed from the
# harness alone, muse authenticates outside every provider quota-axi reports, and
# a raw launch command names no adapter at all. Guessing for any of them would be
# exactly the inference the dispatch contract forbids.
#
# READ PATHS, AND WHY THEY DIFFER
# -------------------------------
# The heartbeat runs inside the watcher's supervision cycle, so it must never
# block on the network. It reads ONLY the cached snapshot under state/ and, when
# that snapshot is missing or older than the refresh interval, starts a detached
# hard-bounded refresh for the NEXT heartbeat while evaluating what it has now. A
# hung or slow `quota-axi` therefore costs the watcher nothing measurable: the
# worst case is an unknown verdict, which is disclosed rather than resolved.
#
# The preflight runs once per spawn, off the supervision cycle, so it takes the
# fresh hard-bounded read the heartbeat deliberately will not (whole process
# group, bin/fm-timeout-lib.sh). If that read cannot complete it falls back to
# the cached snapshot while it is younger than the maximum age, and says in the
# diagnostic how old that reading was. Past that age there is no reading at all,
# so the verdict is unknown and the launch proceeds.
#
# A STALE CACHE IS NOT THE SAME AS A BROKEN READ
# ------------------------------------------------
# The watcher's own heartbeat cadence backs off from HEARTBEAT to
# HEARTBEAT_MAX on an idle fleet (bin/fm-watch.sh), and HEARTBEAT_MAX can run
# well past SNAPSHOT_MAX_AGE - so on a quiet fleet the cache reliably ages past
# SNAPSHOT_MAX_AGE between two heartbeats even when every refresh attempt is
# succeeding. That is not a measurement failure, and the heartbeat must not
# report it as one. stale_snapshot_blocker tells the two apart by the snapshot
# meta's own status rather than by SNAPSHOT's raw age: status=ok means the
# cache is merely older than its TTL and stays in use for the per-provider
# verdicts below it, exactly like a fresh reading; status=failed or
# status=unmeasurable means the last attempt genuinely could not produce a
# reading, and that stays a loud, disclosed blocker.
#
# ESCALATION IS BY TRANSITION, NOT BY POLL
# ----------------------------------------
# state/.quota-floor-state records the last verdict reported for each provider
# and for the guard itself, so only a CHANGE prints. A floor that stays crossed
# escalates once instead of on every heartbeat, a recovery is reported because it
# is what tells the captain dispatch is unblocked, and a provider that stops
# being measurable is reported as exactly that rather than quietly dropping out.
#
# STATE AND CONFIG
# ----------------
#   state/.quota-snapshot.json   last successful `quota-axi --json`
#   state/.quota-models.json     last successful `quota-axi models --json`
#   state/.quota-snapshot.meta   epoch=, status=, reason= for that snapshot
#   state/.quota-refresh.lock    single-flight directory lock for the refresh
#   state/.quota-floor-state     last reported verdict per key, for dedupe
# These are home-level records rather than per-task ones, so task teardown does
# not touch them; deleting any of them costs one re-read, never correctness.
#
# docs/configuration.md "Quota floor guard" owns config/quota-floor's accepted
# directives, the documented default floor, and the operator-facing contract.
# This header owns the mechanics. Environment overrides are validated by value
# and fall back to the default rather than refusing, because this guard's own
# bounds must never become the reason a spawn cannot start:
#   FM_QUOTA_GUARD=off             render no verdict; disclose that and proceed.
#   FM_QUOTA_REFRESH_TIMEOUT       seconds bounding one quota-axi read.
#   FM_QUOTA_SNAPSHOT_MAX_AGE      seconds before the preflight stops trusting a
#                                  cached reading outright, and before the
#                                  heartbeat starts checking the last refresh
#                                  attempt's own recorded outcome (see above).
#   FM_QUOTA_REFRESH_MIN_INTERVAL  seconds between detached refreshes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SCRIPT_DIR/fm-quota-guard.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"   # fm_run_timed: the shared hard bound
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh" # fm_quota_axi_compatible: the version floor

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

# The documented default floor: refuse new dispatch once a provider has less than
# this percentage of its effective allowance left. docs/configuration.md states
# the same number; change both together.
FLOOR_DEFAULT=10

REFRESH_TIMEOUT_DEFAULT=15
REFRESH_TIMEOUT_MAX=300
SNAPSHOT_MAX_AGE_DEFAULT=1800
SNAPSHOT_MAX_AGE_MAX=86400
REFRESH_MIN_INTERVAL_DEFAULT=300
REFRESH_MIN_INTERVAL_MAX=86400
# The version probe only has to answer `quota-axi --version`, so it gets its own
# much shorter bound.
VERSION_PROBE_TIMEOUT=5
# A wake reason is one line. A pathological provider list is truncated rather
# than allowed to flood a durable queue record.
MAX_WAKE_LINE=600
# Crash recovery for the refresh lock: an abandoned lock older than this many
# multiples of the read bound is taken over. Losing that race only means two
# reads run, and both publish atomically.
LOCK_STALE_MULTIPLE=3
# Below this age a cached reading is not worth calling out in a diagnostic.
CACHED_NOTICE_SECONDS=60

log_note() { printf 'quota guard: %s\n' "$1" >&2; }

# bounded_int <value> <default> <min> <max>
# Validated by VALUE, not by shape. Empty, non-numeric, over-long, and
# out-of-range all fall back to the default.
bounded_int() {
  local value=$1 fallback=$2 min=$3 max=$4
  case "$value" in
    ''|*[!0-9]*) printf '%s\n' "$fallback"; return 0 ;;
  esac
  [ "${#value}" -le 6 ] || { printf '%s\n' "$fallback"; return 0; }
  value=$((10#$value))
  if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  printf '%s\n' "$value"
}

REFRESH_TIMEOUT=$(bounded_int "${FM_QUOTA_REFRESH_TIMEOUT:-}" "$REFRESH_TIMEOUT_DEFAULT" 1 "$REFRESH_TIMEOUT_MAX")
SNAPSHOT_MAX_AGE=$(bounded_int "${FM_QUOTA_SNAPSHOT_MAX_AGE:-}" "$SNAPSHOT_MAX_AGE_DEFAULT" 1 "$SNAPSHOT_MAX_AGE_MAX")
REFRESH_MIN_INTERVAL=$(bounded_int "${FM_QUOTA_REFRESH_MIN_INTERVAL:-}" "$REFRESH_MIN_INTERVAL_DEFAULT" 1 "$REFRESH_MIN_INTERVAL_MAX")

# --- argument parsing --------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

COMMAND=${1:-}
case "$COMMAND" in
  heartbeat|preflight|report|refresh) shift ;;
  '') usage >&2; exit 2 ;;
  *) printf 'fm-quota-guard.sh: unknown command: %s\n' "$COMMAND" >&2; exit 2 ;;
esac

ARG_CONFIG=
ARG_STATE=
ARG_HARNESS=
ARG_MODEL=
ARG_PROVIDER=
PROVIDER_EXPLICIT=0
WANT_CATALOG=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)   [ "$#" -ge 2 ] || { usage >&2; exit 2; }; ARG_CONFIG=$2; shift 2 ;;
    --state)    [ "$#" -ge 2 ] || { usage >&2; exit 2; }; ARG_STATE=$2; shift 2 ;;
    --harness)  [ "$#" -ge 2 ] || { usage >&2; exit 2; }; ARG_HARNESS=$2; shift 2 ;;
    --model)    [ "$#" -ge 2 ] || { usage >&2; exit 2; }; ARG_MODEL=$2; shift 2 ;;
    --provider) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; ARG_PROVIDER=$2; PROVIDER_EXPLICIT=1; shift 2 ;;
    --catalog)  WANT_CATALOG=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) printf 'fm-quota-guard.sh: unexpected argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE=${ARG_STATE:-${FM_STATE_OVERRIDE:-$FM_HOME/state}}
CONFIG=${ARG_CONFIG:-${FM_CONFIG_OVERRIDE:-$FM_HOME/config}}

SNAPSHOT="$STATE/.quota-snapshot.json"
MODELS="$STATE/.quota-models.json"
SNAPSHOT_META="$STATE/.quota-snapshot.meta"
REFRESH_LOCK="$STATE/.quota-refresh.lock"
FLOOR_STATE="$STATE/.quota-floor-state"
FLOOR_CONFIG="$CONFIG/quota-floor"

# --- shipped provider bindings ----------------------------------------------
#
# Verified declarations, not inferences; see the header and
# docs/verification/dispatch-auth.md. A harness absent here is UNBOUND on
# purpose and resolves to unknown.
shipped_launch_binding() {  # <harness> -> quota-axi provider, or empty
  case "$1" in
    claude) printf 'claude\n' ;;
    codex)  printf 'codex\n' ;;
    grok)   printf 'grok\n' ;;
    kimi)   printf 'kimi\n' ;;
    *)      : ;;
  esac
}

# --- configuration -----------------------------------------------------------
#
# config/quota-floor holds one directive per non-empty, non-comment line:
#   floor  <provider|default>  <0-100|off>
#   launch <harness>           <provider|none>
# A malformed line is a disclosed, actionable error: it is reported and the guard
# keeps evaluating with the documented default, so a typo neither passes silently
# nor turns into a blanket refusal of every spawn. Records are kept as
# newline-delimited TAB-separated text rather than arrays, so this runs the same
# under the bash 3.2 that ships with macOS.
CONFIG_ERRORS=
FLOOR_RECORDS=
LAUNCH_RECORDS=
FLOOR_FOR_DEFAULT=$FLOOR_DEFAULT

config_error() {
  if [ -z "$CONFIG_ERRORS" ]; then
    CONFIG_ERRORS=$1
  else
    CONFIG_ERRORS="$CONFIG_ERRORS; $1"
  fi
}

# A provider or harness token is a conservative identifier, so nothing that could
# reshape a command line or a state record ever reaches one.
valid_token() {
  case "$1" in
    ''|*[!a-zA-Z0-9._-]*) return 1 ;;
  esac
  return 0
}

load_config() {
  local line directive key value lineno=0
  [ -e "$FLOOR_CONFIG" ] || return 0
  if [ ! -f "$FLOOR_CONFIG" ] || [ ! -r "$FLOOR_CONFIG" ]; then
    config_error "config/quota-floor is not a readable regular file"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    # shellcheck disable=SC2086  # deliberate word split of one sanitized line
    set -- $line
    if [ "$#" -ne 3 ]; then
      config_error "line $lineno is not '<directive> <key> <value>'"
      continue
    fi
    directive=$1
    key=$2
    value=$3
    case "$directive" in
      floor)
        if ! valid_token "$key"; then
          config_error "line $lineno names an invalid provider"
          continue
        fi
        case "$value" in
          off) ;;
          ''|*[!0-9]*)
            config_error "line $lineno floor '$value' is not 0-100 or off"
            continue ;;
          *)
            if [ "${#value}" -gt 3 ] || [ "$((10#$value))" -gt 100 ]; then
              config_error "line $lineno floor '$value' is not 0-100 or off"
              continue
            fi
            value=$((10#$value))
            ;;
        esac
        if [ "$key" = default ]; then
          # A default of "off" would remove the guard entirely, which is not an
          # available setting: it degrades to the lowest real floor instead, and
          # a single provider can still be excused with "floor <provider> off".
          [ "$value" = off ] && value=0
          FLOOR_FOR_DEFAULT=$value
        else
          FLOOR_RECORDS="$FLOOR_RECORDS$key	$value
"
        fi
        ;;
      launch)
        if ! valid_token "$key" || ! valid_token "$value"; then
          config_error "line $lineno names an invalid harness or provider"
          continue
        fi
        LAUNCH_RECORDS="$LAUNCH_RECORDS$key	$value
"
        ;;
      *)
        config_error "line $lineno has unknown directive '$directive'"
        ;;
    esac
  done < "$FLOOR_CONFIG"
}

# lookup_record <records> <key> -> the LAST value recorded for that key, or empty
lookup_record() {
  [ -n "$1" ] || return 0
  printf '%s' "$1" | awk -F'\t' -v k="$2" '$1 == k { v = $2 } END { if (v != "") print v }'
}

floor_for() {  # <provider> -> integer percent, or "off"
  local found
  found=$(lookup_record "$FLOOR_RECORDS" "$1")
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
  else
    printf '%s\n' "$FLOOR_FOR_DEFAULT"
  fi
}

configured_launch_binding() {  # <harness> -> provider, "none", or empty
  lookup_record "$LAUNCH_RECORDS" "$1"
}

# --- snapshot mechanics ------------------------------------------------------

path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# age_of <path> -> whole seconds. An unreadable or missing path reads as
# effectively infinite, so "cannot tell how old" never passes for "fresh".
age_of() {
  local m now
  m=$(path_mtime "$1") || { printf '%s\n' 999999999; return 0; }
  case "$m" in ''|*[!0-9]*) printf '%s\n' 999999999; return 0 ;; esac
  now=$(date +%s)
  case "$now" in ''|*[!0-9]*) printf '%s\n' 999999999; return 0 ;; esac
  printf '%s\n' "$(( now - m ))"
}

write_snapshot_meta() {  # <status> <reason>
  local tmp="$SNAPSHOT_META.$$"
  {
    printf 'epoch=%s\n' "$(date +%s)"
    printf 'status=%s\n' "$1"
    printf 'reason=%s\n' "$2"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$SNAPSHOT_META" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

snapshot_meta_field() {  # <field>
  [ -f "$SNAPSHOT_META" ] || return 1
  sed -n "s/^$1=//p" "$SNAPSHOT_META" 2>/dev/null | head -n 1
}

# quota_read <output-path> <quota-axi args...>
# One hard-bounded read published atomically, and only after it parses. The bound
# covers the whole process group, so a quota-axi hung on a keychain prompt or a
# vendor endpoint cannot outlive it. Exit 124 means the bound was reached.
quota_read() {
  local out=$1 tmp status
  shift
  tmp="$out.$$"
  fm_run_timed "$REFRESH_TIMEOUT" quota-axi "$@" > "$tmp" 2>/dev/null </dev/null
  status=$?
  if [ "$status" -ne 0 ]; then
    rm -f "$tmp"
    [ "$status" -eq 124 ] && return 124
    return 1
  fi
  if [ ! -s "$tmp" ] || ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$out" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# do_refresh <with-catalog:0|1>
# Single-flight, hard-bounded, best effort. It never fails its caller; an
# unsuccessful pass is recorded in the snapshot meta so every reader can tell
# "not measured" apart from "measured and fine".
do_refresh() {
  local with_catalog=$1 lock_age status reason
  mkdir -p "$STATE" 2>/dev/null || return 0
  if ! mkdir "$REFRESH_LOCK" 2>/dev/null; then
    lock_age=$(age_of "$REFRESH_LOCK")
    if [ "$lock_age" -lt $((REFRESH_TIMEOUT * LOCK_STALE_MULTIPLE)) ]; then
      return 0
    fi
    rm -rf "$REFRESH_LOCK" 2>/dev/null || return 0
    mkdir "$REFRESH_LOCK" 2>/dev/null || return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    write_snapshot_meta unmeasurable "jq is not installed, so quota-axi output cannot be read"
    rmdir "$REFRESH_LOCK" 2>/dev/null || true
    return 0
  fi
  if ! command -v quota-axi >/dev/null 2>&1; then
    write_snapshot_meta unmeasurable "quota-axi is not installed"
    rmdir "$REFRESH_LOCK" 2>/dev/null || true
    return 0
  fi
  if ! fm_quota_axi_compatible "$VERSION_PROBE_TIMEOUT"; then
    write_snapshot_meta unmeasurable "installed quota-axi is older than $FM_QUOTA_AXI_MIN or its version is unreadable"
    rmdir "$REFRESH_LOCK" 2>/dev/null || true
    return 0
  fi

  quota_read "$SNAPSHOT" --json
  status=$?
  if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 124 ]; then
      reason="quota-axi --json did not finish within ${REFRESH_TIMEOUT}s"
    else
      reason="quota-axi --json failed or returned unreadable output"
    fi
    write_snapshot_meta failed "$reason"
    rmdir "$REFRESH_LOCK" 2>/dev/null || true
    return 0
  fi

  # The model catalog is a refinement, never a precondition: a provider-wide
  # bound is a real bound without it.
  if [ "$with_catalog" -eq 1 ] && ! quota_read "$MODELS" models --json; then
    rm -f "$MODELS"
  fi

  write_snapshot_meta ok ''
  rmdir "$REFRESH_LOCK" 2>/dev/null || true
  return 0
}

# start_detached_refresh: hand the read to a child and return immediately.
#
# The redirections are attached to the subshell itself rather than run inside it,
# so the child never holds the caller's stdout for even an instant. That matters
# more than it looks: the watcher captures this command with $(...), and a
# command substitution blocks until EVERY process holding the pipe's write end
# releases it. A child that inherited stdout would make the "never blocks on the
# network" guarantee false by exactly the length of the read it just started.
start_detached_refresh() {
  mkdir -p "$STATE" 2>/dev/null || return 0
  if [ -e "$SNAPSHOT_META" ] && [ "$(age_of "$SNAPSHOT_META")" -lt "$REFRESH_MIN_INTERVAL" ]; then
    return 0
  fi
  [ -d "$REFRESH_LOCK" ] && return 0
  ( "$SELF" refresh --catalog --state "$STATE" --config "$CONFIG" ) \
    >/dev/null 2>&1 </dev/null &
  return 0
}

# --- reading the snapshot ----------------------------------------------------
#
# Every row is TSV:
#   provider  availStatus  remainingCenti  scope  limitingWindows  resetsAt  stale
# remainingCenti is hundredths of a percent, so an integer comparison keeps the
# vendor's fractional precision; "-" means the vendor supplied no number.

# shellcheck disable=SC2016  # a jq program, not a shell expansion
PROVIDER_ROWS_JQ='
  .providers[]? as $p
  | ($p.windows // []) as $w
  | (($p.quotaSemantics.effectiveAvailability // [])
      | map(select(.scope == "all_models" or .scope == "all_products"))
      | first) as $a
  | (($a.limitingWindowIds // [])) as $lim
  | (($lim | first) // "") as $lw
  | ((($w | map(select(.id == $lw)) | first).resetsAt) // "-") as $reset
  | [ ($p.provider // "-"),
      ($a.status // "unknown"),
      (if ($a.effectivePercentRemaining | type) == "number"
         then (($a.effectivePercentRemaining * 100) | floor | tostring)
         else "-" end),
      ($a.scope // "-"),
      (($lim | join(",")) | if . == "" then "-" else . end),
      $reset,
      (($p.state.stale // false) | tostring)
    ] | @tsv
'

# shellcheck disable=SC2016  # a jq program, not a shell expansion
MODEL_ROW_JQ='
  .models[]? | select(.id == $m)
  | (.effective // null) as $e
  | [ (.provider // "-"),
      ($e.status // "unknown"),
      (if ($e.effectivePercentRemaining | type) == "number"
         then (($e.effectivePercentRemaining * 100) | floor | tostring)
         else "-" end),
      ($e.scope // "-"),
      ((($e.limitingWindowIds // []) | join(",")) | if . == "" then "-" else . end),
      "-",
      ((.state.stale // false) | tostring)
    ] | @tsv
'

provider_rows_from() {  # <snapshot>
  jq -r "$PROVIDER_ROWS_JQ" "$1" 2>/dev/null || true
}

model_row_from() {  # <catalog> <model-id>
  [ -s "$1" ] || return 1
  jq -r --arg m "$2" "$MODEL_ROW_JQ" "$1" 2>/dev/null | head -n 1
}

# guard_blocker: why nothing at all can be measured right now, or empty. Checked
# before any per-provider verdict so one systemic cause is reported once rather
# than once per provider.
#
# GUARD_BLOCKER_BOOTSTRAP is set to 1 when the cause is simply that no read has
# been ATTEMPTED yet - a brand new home, or a home whose state was cleared. That
# is a transient the detached refresh resolves on its own, so it is recorded but
# never escalated; a home does not deserve a wake for having just started. Every
# other cause reflects a read that was attempted and could not produce a
# measurement, which is a real condition the captain should hear once.
# Sets GUARD_BLOCKER (empty when measurement is possible) and, alongside it,
# GUARD_BLOCKER_BOOTSTRAP. Both are globals rather than stdout so one call
# answers both questions; a command substitution would lose the second.
GUARD_BLOCKER=''
GUARD_BLOCKER_BOOTSTRAP=0
guard_blocker() {
  local reason
  GUARD_BLOCKER=''
  GUARD_BLOCKER_BOOTSTRAP=0
  if [ "${FM_QUOTA_GUARD:-}" = off ]; then
    GUARD_BLOCKER='disabled by FM_QUOTA_GUARD=off'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    GUARD_BLOCKER='jq is not installed, so quota readings cannot be parsed'
    return 0
  fi
  if [ ! -s "$SNAPSHOT" ]; then
    reason=$(snapshot_meta_field reason 2>/dev/null || true)
    if [ -n "$reason" ]; then
      GUARD_BLOCKER="no quota reading yet: $reason"
    else
      [ -f "$SNAPSHOT_META" ] || GUARD_BLOCKER_BOOTSTRAP=1
      GUARD_BLOCKER='no quota reading has been taken yet'
    fi
    return 0
  fi
  return 0
}

# stale_snapshot_blocker: called only once guard_blocker has already found
# SNAPSHOT non-empty (a real reading exists) and its age has reached
# SNAPSHOT_MAX_AGE. A cache can age past that bound for two entirely different
# reasons, and only one of them is a blocker:
#
#   - every attempted refresh has succeeded, but the caller (the watcher's own
#     backed-off heartbeat cadence, which ranges from HEARTBEAT to
#     HEARTBEAT_MAX in bin/fm-watch.sh) simply polls less often than
#     SNAPSHOT_MAX_AGE on an idle fleet. The reading is old but real, so
#     evaluating it is strictly better than declaring it unmeasurable.
#   - the last attempted refresh could not produce a reading at all, and the
#     snapshot on disk is a stale leftover from before that failure started.
#
# The snapshot meta already tells the two apart: do_refresh writes status=ok
# only alongside a freshly published SNAPSHOT, and status=failed or
# status=unmeasurable when an attempt could not publish one, carrying the same
# reason a first-ever failure would. Trusting that status (rather than
# SNAPSHOT's raw age) is what keeps a merely-slow-to-poll idle fleet quiet
# while a genuinely broken read stays loud.
stale_snapshot_blocker() {
  local status reason
  status=$(snapshot_meta_field status 2>/dev/null || true)
  case "$status" in
    ok) return 0 ;;
    failed|unmeasurable)
      reason=$(snapshot_meta_field reason 2>/dev/null || true)
      if [ -n "$reason" ]; then
        printf 'the last refresh attempt failed: %s\n' "$reason"
      else
        printf 'the last refresh attempt failed\n'
      fi
      ;;
    *)
      # No readable status for the last attempt at all - cannot confirm the
      # cache is merely old rather than broken, so this stays loud rather than
      # assuming health it cannot see.
      printf 'the last reading is over %s minutes old and its refresh status is unreadable\n' \
        "$((SNAPSHOT_MAX_AGE / 60))"
      ;;
  esac
}

# verdict_of <provider> <availStatus> <remainingCenti> <stale>
#   -> "<ok|below|unknown|skipped> <remainingCenti|-> <floor|->"
verdict_of() {
  local provider=$1 avail=$2 remaining=$3 stale=$4 floor
  floor=$(floor_for "$provider")
  if [ "$floor" = off ]; then
    printf 'skipped - -\n'
    return 0
  fi
  if [ "$stale" = true ] || [ "$avail" != known ] || [ "$remaining" = "-" ]; then
    printf 'unknown - %s\n' "$floor"
    return 0
  fi
  case "$remaining" in
    ''|*[!0-9]*) printf 'unknown - %s\n' "$floor"; return 0 ;;
  esac
  if [ "$remaining" -lt "$((floor * 100))" ]; then
    printf 'below %s %s\n' "$remaining" "$floor"
  else
    printf 'ok %s %s\n' "$remaining" "$floor"
  fi
}

verdict_from_row() {  # <row>
  local provider avail remaining stale
  IFS=$'\t' read -r provider avail remaining _ _ _ stale <<< "$1"
  verdict_of "$provider" "$avail" "$remaining" "$stale"
}

show_percent() {  # <remainingCenti> -> a short human percentage
  local centi=$1 whole frac
  case "$centi" in
    ''|-|*[!0-9]*) printf -- '-\n'; return 0 ;;
  esac
  whole=$((centi / 100))
  frac=$((centi % 100))
  if [ "$frac" -eq 0 ]; then
    printf '%s%%\n' "$whole"
  else
    printf '%s.%02d%%\n' "$whole" "$frac"
  fi
}

# --- transition bookkeeping --------------------------------------------------

last_reported() {  # <key>
  [ -f "$FLOOR_STATE" ] || return 0
  awk -F'\t' -v k="$1" '$1 == k { v = $2 } END { if (v != "") print v }' "$FLOOR_STATE" 2>/dev/null
}

record_reported() {  # <key> <value>
  local tmp
  mkdir -p "$STATE" 2>/dev/null || return 0
  tmp="$FLOOR_STATE.$$"
  {
    if [ -f "$FLOOR_STATE" ]; then
      awk -F'\t' -v k="$1" '$1 != k' "$FLOOR_STATE" 2>/dev/null || true
    fi
    printf '%s\t%s\n' "$1" "$2"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$FLOOR_STATE" 2>/dev/null || rm -f "$tmp"
  return 0
}

join_message() {  # <accumulated> <new>
  if [ -z "$1" ]; then
    printf '%s' "$2"
  elif [ -z "$2" ]; then
    printf '%s' "$1"
  else
    printf '%s; %s' "$1" "$2"
  fi
}

emit_wake_line() {
  local line=$1
  [ -n "$line" ] || return 0
  line=${line//$'\n'/ }
  if [ "${#line}" -gt "$MAX_WAKE_LINE" ]; then
    line="${line:0:$MAX_WAKE_LINE}..."
  fi
  printf '%s\n' "$line"
}

# --- commands ----------------------------------------------------------------

cmd_refresh() {
  load_config
  [ -z "$CONFIG_ERRORS" ] || log_note "config/quota-floor: $CONFIG_ERRORS"
  do_refresh "$WANT_CATALOG"
  return 0
}

cmd_report() {
  local row provider avail remaining scope lim reset stale state floor
  load_config
  [ -z "$CONFIG_ERRORS" ] || log_note "config/quota-floor: $CONFIG_ERRORS"
  guard_blocker
  if [ -n "$GUARD_BLOCKER" ]; then
    printf 'guard\tunmeasurable\t%s\n' "$GUARD_BLOCKER"
    return 0
  fi
  printf 'guard\tmeasured\tage=%ss\n' "$(age_of "$SNAPSHOT")"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r provider avail remaining scope lim reset stale <<< "$row"
    read -r state _ floor <<< "$(verdict_of "$provider" "$avail" "$remaining" "$stale")"
    printf '%s\t%s\tremaining=%s\tfloor=%s\tscope=%s\twindows=%s\tresets=%s\tstale=%s\tsource=%s\n' \
      "$provider" "$state" "$(show_percent "$remaining")" "$floor" \
      "$scope" "$lim" "$reset" "$stale" "$avail"
  done < <(provider_rows_from "$SNAPSHOT")
  return 0
}

# heartbeat: print ONE line only when firstmate should wake. It never blocks on
# the network; the refresh it may start is detached and hard-bounded.
cmd_heartbeat() {
  local blocker bootstrap row provider lim reset state remaining floor prev detail
  local messages=''

  # An explicit kill switch is a stated choice, not a surprise, so it is silent
  # here. `report` still shows it, and the preflight still says so per launch.
  [ "${FM_QUOTA_GUARD:-}" = off ] && return 0

  load_config
  if [ -n "$CONFIG_ERRORS" ]; then
    prev=$(last_reported guard-config)
    if [ "$prev" != "$CONFIG_ERRORS" ]; then
      messages="quota floor settings need correcting: $CONFIG_ERRORS"
      record_reported guard-config "$CONFIG_ERRORS"
    fi
  else
    record_reported guard-config ok
  fi

  # Classify BEFORE kicking a refresh, so the bootstrap flag reflects the state
  # this heartbeat actually found rather than one a concurrent child just changed.
  guard_blocker
  blocker=$GUARD_BLOCKER
  bootstrap=$GUARD_BLOCKER_BOOTSTRAP
  start_detached_refresh
  if [ -z "$blocker" ] && [ "$(age_of "$SNAPSHOT")" -ge "$SNAPSHOT_MAX_AGE" ]; then
    blocker=$(stale_snapshot_blocker)
    bootstrap=0
  fi
  if [ -n "$blocker" ]; then
    # Systemic uncertainty is reported once per transition, AS uncertainty. It is
    # never allowed to read as "every provider is fine". The one exception is the
    # bootstrap case, which the refresh just started resolves by itself.
    prev=$(last_reported guard)
    if [ "$prev" != "unmeasurable:$blocker" ]; then
      record_reported guard "unmeasurable:$blocker"
      [ "$bootstrap" -eq 1 ] || messages=$(join_message "$messages" \
        "quota allowances cannot be measured right now ($blocker), so no floor is being enforced")
    fi
    emit_wake_line "$messages"
    return 0
  fi
  record_reported guard measured

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r provider _ _ _ lim reset _ <<< "$row"
    read -r state remaining floor <<< "$(verdict_from_row "$row")"
    [ "$state" = skipped ] && continue
    prev=$(last_reported "provider:$provider")
    [ "$prev" = "$state" ] && continue
    record_reported "provider:$provider" "$state"
    case "$state" in
      below)
        detail=""
        [ "$reset" = "-" ] || detail=", resets $reset"
        messages=$(join_message "$messages" \
          "$provider has $(show_percent "$remaining") of its allowance left, under the ${floor}% floor ($lim window$detail); new work will not be dispatched onto it, and nothing already running is affected")
        ;;
      ok)
        # A recovery is worth a wake because it says dispatch is unblocked. A
        # first observation, or a return from merely-unmeasurable, is not.
        [ "$prev" = below ] || continue
        messages=$(join_message "$messages" \
          "$provider is back to $(show_percent "$remaining") of its allowance, above the ${floor}% floor, and can take new work again")
        ;;
      unknown)
        [ -n "$prev" ] || continue
        messages=$(join_message "$messages" \
          "$provider's allowance can no longer be measured, so it is unknown rather than known good")
        ;;
    esac
  done < <(provider_rows_from "$SNAPSHOT")

  emit_wake_line "$messages"
  return 0
}

# preflight: the pre-endpoint gate. Exit 0 launches, exit 1 refuses.
cmd_preflight() {
  local provider binding source row state remaining floor
  local avail scope lim reset snap_age model_row
  local used=''
  local m_provider m_avail m_remaining m_scope m_lim m_stale m_state m_floor

  if [ -z "$ARG_HARNESS" ]; then
    printf 'fm-quota-guard.sh preflight: --harness is required\n' >&2
    exit 2
  fi
  load_config
  [ -z "$CONFIG_ERRORS" ] || \
    log_note "config/quota-floor: $CONFIG_ERRORS (evaluating with the default ${FLOOR_FOR_DEFAULT}% floor)"

  if [ "${FM_QUOTA_GUARD:-}" = off ]; then
    log_note "disabled by FM_QUOTA_GUARD=off; launching without a measured floor"
    return 0
  fi

  # Provider binding, strongest source first. Nothing here is derived from a name.
  if [ "$PROVIDER_EXPLICIT" -eq 1 ]; then
    provider=$ARG_PROVIDER
    source="the provider stated for this launch"
  else
    binding=$(configured_launch_binding "$ARG_HARNESS")
    if [ -n "$binding" ]; then
      provider=$binding
      source="config/quota-floor's launch binding"
    else
      provider=$(shipped_launch_binding "$ARG_HARNESS")
      source="the verified binding for the $ARG_HARNESS harness"
    fi
  fi
  if [ -z "$provider" ] || [ "$provider" = none ]; then
    log_note "no measurable provider is bound to the $ARG_HARNESS harness, so this launch has no floor to check; launching"
    return 0
  fi
  if ! valid_token "$provider"; then
    log_note "the provider named for this launch is not a usable identifier, so no floor was checked; launching"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log_note "jq is not installed, so $provider's allowance cannot be read; launching without a measured floor"
    return 0
  fi

  # Fresh and hard-bounded: a spawn is one shot off the supervision cycle, so it
  # can afford the read the heartbeat deliberately will not take. The catalog is
  # fetched only when a model actually needs narrowing.
  if [ -n "$ARG_MODEL" ]; then
    do_refresh 1
  else
    do_refresh 0
  fi

  if [ ! -s "$SNAPSHOT" ]; then
    log_note "$provider's allowance could not be read ($(snapshot_meta_field reason 2>/dev/null || printf 'no reading')), so it is unknown rather than exhausted; launching"
    return 0
  fi
  snap_age=$(age_of "$SNAPSHOT")
  if [ "$snap_age" -ge "$SNAPSHOT_MAX_AGE" ]; then
    log_note "$provider's allowance could not be read now and the last reading is over $((SNAPSHOT_MAX_AGE / 60)) minutes old, so it is unknown rather than exhausted; launching"
    return 0
  fi
  [ "$snap_age" -lt "$CACHED_NOTICE_SECONDS" ] || \
    used=" (from a reading taken ${snap_age}s ago, because a fresh read did not complete)"

  row=$(provider_rows_from "$SNAPSHOT" | awk -F'\t' -v p="$provider" '$1 == p' | head -n 1)
  if [ -z "$row" ]; then
    log_note "quota-axi reports no windows for $provider, so its allowance is unknown rather than exhausted; launching"
    return 0
  fi
  IFS=$'\t' read -r _ avail _ scope lim reset _ <<< "$row"
  read -r state remaining floor <<< "$(verdict_from_row "$row")"

  # A named model narrows the bound only when the vendor's own catalog carries
  # that exact id, and only ever downward.
  if [ -n "$ARG_MODEL" ]; then
    if model_row=$(model_row_from "$MODELS" "$ARG_MODEL") && [ -n "$model_row" ]; then
      IFS=$'\t' read -r m_provider m_avail m_remaining m_scope m_lim _ m_stale <<< "$model_row"
      if [ "$m_provider" != "$provider" ]; then
        log_note "quota-axi's catalog places model $ARG_MODEL under $m_provider, not the $provider this launch is bound to; checking $provider's own allowance only"
      else
        read -r m_state m_remaining m_floor <<< "$(verdict_of "$provider" "$m_avail" "$m_remaining" "$m_stale")"
        if [ "$m_state" != unknown ] && [ "$m_state" != skipped ]; then
          if [ "$remaining" = "-" ] || [ "$m_remaining" -lt "$remaining" ]; then
            state=$m_state
            remaining=$m_remaining
            floor=$m_floor
            scope=$m_scope
            lim=$m_lim
            reset="-"
          fi
        fi
      fi
    else
      log_note "model $ARG_MODEL is not in quota-axi's catalog, so only $provider's provider-wide allowance bounds this launch"
    fi
  fi

  case "$state" in
    skipped)
      log_note "config/quota-floor turns the floor off for $provider; launching"
      return 0
      ;;
    unknown)
      log_note "$provider's allowance is not measurable right now (quota-axi reports it as $avail), so it is unknown rather than exhausted; launching"
      return 0
      ;;
    below)
      {
        printf 'error: refusing to launch onto %s: %s of its allowance is left, under the %s%% floor.\n' \
          "$provider" "$(show_percent "$remaining")" "$floor"
        printf '  measured at scope %s, bounded by the %s window' "$scope" "$lim"
        [ "$reset" = "-" ] || printf ', which resets %s' "$reset"
        printf '%s.\n' "$used"
        printf '  Bound to %s via %s. Nothing already running is affected by this refusal.\n' \
          "$provider" "$source"
        printf "  Proceed only on the captain's explicit word: re-run with --quota-provider none, or set \"floor %s off\" in config/quota-floor.\n" \
          "$provider"
      } >&2
      return 1
      ;;
  esac
  return 0
}

case "$COMMAND" in
  heartbeat) cmd_heartbeat ;;
  preflight) cmd_preflight ;;
  report)    cmd_report ;;
  refresh)   cmd_refresh ;;
esac
