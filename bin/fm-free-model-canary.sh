#!/usr/bin/env bash
# fm-free-model-canary.sh - once a day, prove that the free research lane's
# model is still listed, and swap its dispatch profile to the paid replacement
# once it is gone.
#
# Usage:
#   fm-free-model-canary.sh run [--record]
#   fm-free-model-canary.sh check
#   fm-free-model-canary.sh arm [--if-watched]
#   fm-free-model-canary.sh disarm
#   fm-free-model-canary.sh --help
#
# The watched profile is any opencode profile in config/crew-dispatch.json (a
#   rule's `use` or the `default`) on the lane's free model, and the
#   replacement is the lane's paid profile; bin/fm-free-lane-lib.sh owns both,
#   and docs/configuration.md "Free research lane" owns the operator view. No
#   other model is watched and no other replacement is ever written.
#
# `run` lists the free model's provider once with
#   `opencode models <provider> --refresh --pure` (autoupdate and sharing off,
#   bounded by FM_FREE_MODEL_CANARY_TIMEOUT seconds, default 120). A listed
#   model is ok. A model missing from a listing that exited 0 and named at least
#   one model of that provider is gone: every watched profile is rewritten in
#   place to the replacement (harness, model, and provider come from the
#   replacement, any effort keys are dropped, and every other key, such as
#   private_ok, is kept), the previous file is kept as
#   config/crew-dispatch.json.bak-<YYYY-MM-DD>-canary, and
#   bin/fm-config-push.sh converges live secondmate homes. A listing that fails
#   or names nothing proves nothing, so nothing is swapped. The rewrite refuses
#   when the rules file changed while the listing ran. It never touches any
#   OpenCode account or plan setting (in particular, never the Go plan's
#   "use balance"). Prints one line and exits 0 when the model is listed, was
#   swapped, or is not watched, 1 when the listing proved nothing or the swap
#   failed, 2 for a usage error, a secondmate home (whose rules are inherited
#   from the primary), or an unreadable rules file.
#   --record writes the outcome to state/free-model-canary/.
#
# `check` is the watcher check. It prints one captain-notice line for a
#   recorded swap, and one line when the canary first becomes unable to verify,
#   then stays silent until that changes. When no recorded run started within
#   FM_FREE_MODEL_CANARY_INTERVAL seconds (default 86400) and some profile is
#   watched, it launches `run --record` detached (nohup, its own process group,
#   stdio closed) and returns at once, so it always fits the watcher's bound.
# `arm` writes state/free-model-canary.check.sh (embedding this home), sets its
#   state/free-model-canary.check-every cadence to 3600 seconds, and binds it
#   with bin/fm-check-register.sh. It refuses in a secondmate home and when no
#   profile is watched; with --if-watched (the session-start auto-arm) those two
#   cases instead exit 0 and change nothing. `disarm` retires the shim through
#   bin/fm-check-unregister.sh; results under state/free-model-canary/ stay.
#
# State: state/free-model-canary/result.json (started, finished, state
#   running|done, outcome ok|swapped|unverifiable|failed|none, summary,
#   reported, last_reported_outcome), state/free-model-canary/running (the
#   ownership guard), state/free-model-canary/last.out (the last run output).
#
# Environment: FM_OPENCODE_BIN (default opencode), FM_FREE_MODEL_CANARY_TIMEOUT,
#   FM_FREE_MODEL_CANARY_INTERVAL, FM_CONFIG_PUSH_BIN (default
#   bin/fm-config-push.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RULES="$CONFIG_DIR/crew-dispatch.json"
OPENCODE_BIN="${FM_OPENCODE_BIN:-opencode}"
CONFIG_PUSH_BIN="${FM_CONFIG_PUSH_BIN:-$SCRIPT_DIR/fm-config-push.sh}"
CHECK_ID=free-model-canary
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_EVERY="$STATE/$CHECK_ID.check-every"
RESULT_DIR="$STATE/free-model-canary"
RESULT="$RESULT_DIR/result.json"
LAST_OUT="$RESULT_DIR/last.out"
LOCK="$RESULT_DIR/running"
NO_RECORD='{}'

# shellcheck source=bin/fm-free-lane-lib.sh
. "$SCRIPT_DIR/fm-free-lane-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}
die_usage() { printf 'fm-free-model-canary: %s\n' "$1" >&2; exit 2; }

positive_int() {  # <value> <default>
  case "$1" in
    '' | *[!0-9]* | 0) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

secondmate_home() { [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; }

# True when some rule's use or the default runs the lane's free model.
watched() { [ "$(jq -r "$FM_FREE_LANE_JQ"' lane_watched' "$RULES" 2>/dev/null)" = true ]; }

bounded() {  # <seconds> <command...>
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
  fi
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}

# Rewrite every watched profile to the replacement, keeping the previous bytes
# as a dated backup. Refuses when the file changed since <digest> was taken.
swap_profile() {  # <digest>
  local digest=$1 tmp backup
  [ "$(sha256_file "$RULES")" = "$digest" ] || { printf 'the rules file changed while the canary ran'; return 1; }
  tmp=$(mktemp "$CONFIG_DIR/.crew-dispatch.json.canary.XXXXXX") || { printf 'mktemp failed'; return 1; }
  if ! jq --indent 2 --argjson replacement "$FM_FREE_LANE_REPLACEMENT" "$FM_FREE_LANE_JQ"'
    def swap: if lane_free(.)
              then $replacement + del(.harness, .model, .provider, .effort, .effort_min, .effort_max, .effort_floor)
              else . end;
    def swap_all: if type == "array" then map(swap) else swap end;
    (if has("rules") then .rules |= map(if has("use") then .use |= swap_all else . end) else . end)
    | (if has("default") then .default |= swap_all else . end)' "$RULES" > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    printf 'could not rewrite the rules file'
    return 1
  fi
  backup="$RULES.bak-$(date +%Y-%m-%d)-canary"
  [ -e "$backup" ] || cp -p -- "$RULES" "$backup" || { rm -f -- "$tmp"; printf 'could not keep a backup'; return 1; }
  [ "$(sha256_file "$RULES")" = "$digest" ] || { rm -f -- "$tmp"; printf 'the rules file changed while the canary ran'; return 1; }
  chmod "$(stat -f '%Lp' "$RULES" 2>/dev/null || stat -c '%a' "$RULES" 2>/dev/null || printf 600)" "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$RULES" || { rm -f -- "$tmp"; printf 'could not replace the rules file'; return 1; }
  printf '%s' "${backup#"$CONFIG_DIR"/}"
}

# ---- run ----------------------------------------------------------------------
# Prints one OK, SWAPPED, FAILED, or UNVERIFIABLE line (the recorded outcome is
# derived from it) and returns the run's exit code.
canary_run() {
  local timeout_s listing rc digest how model=$FM_FREE_LANE_MODEL provider=$FM_FREE_LANE_PROVIDER
  [ -f "$RULES" ] && [ -r "$RULES" ] || { printf 'error: rules file is not readable: %s\n' "$RULES"; return 2; }
  jq -e . "$RULES" >/dev/null 2>&1 || { printf 'error: rules file is not valid JSON: %s\n' "$RULES"; return 2; }
  digest=$(sha256_file "$RULES")
  watched || { printf 'canary: no watched profile\n'; return 0; }
  timeout_s=$(positive_int "${FM_FREE_MODEL_CANARY_TIMEOUT:-}" 120)
  rc=0
  listing=$(OPENCODE_CONFIG_CONTENT='{"autoupdate":false,"share":"disabled"}' OPENCODE_DISABLE_AUTOUPDATE=1 \
    bounded "$timeout_s" "$OPENCODE_BIN" models "$provider" --refresh --pure </dev/null 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || ! grep -qF -- "$provider/" <<<"$listing"; then
    printf 'UNVERIFIABLE %s: opencode models %s listed nothing (exit %s)\n' "$model" "$provider" "$rc"
    return 1
  fi
  if grep -qxF -- "$model" <<<"$listing"; then
    printf 'OK %s: listed\n' "$model"
    return 0
  fi
  if ! how=$(swap_profile "$digest"); then
    printf 'FAILED %s: no longer listed by opencode, but the swap failed: %s\n' "$model" "$how"
    return 1
  fi
  printf 'SWAPPED %s: no longer listed by opencode; its dispatch profile now runs %s %s (backup config/%s)\n' \
    "$model" "$FM_FREE_LANE_PAID_HARNESS" "$FM_FREE_LANE_PAID_MODEL" "$how"
  if [ -x "$CONFIG_PUSH_BIN" ]; then
    FM_HOME="$FM_HOME" "$CONFIG_PUSH_BIN" >/dev/null 2>&1 \
      || printf 'WARN the config push to secondmate homes failed; run bin/fm-config-push.sh\n'
  fi
  return 0
}

record_read() { jq -ce 'select(type == "object")' "$RESULT" 2>/dev/null; }
record_write() {
  [ -d "$RESULT_DIR" ] && [ ! -L "$RESULT_DIR" ] || return 1
  printf '%s\n' "$1" > "$RESULT.tmp.$$" && mv -f "$RESULT.tmp.$$" "$RESULT"
}

action_run() {
  local record=0 out rc previous started
  while [ $# -gt 0 ]; do
    case "$1" in
      --record) record=1; shift ;;
      *) die_usage "unknown run flag: $1" ;;
    esac
  done
  secondmate_home && die_usage 'this is a secondmate home; its dispatch rules are inherited from the primary, which runs the canary'
  if [ "$record" -eq 0 ]; then
    canary_run
    return
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  mkdir -p "$RESULT_DIR" || return 2
  fm_lock_try_acquire "$LOCK" || { printf 'fm-free-model-canary: a recorded run is already active\n' >&2; return 2; }
  # shellcheck disable=SC2064  # Expand the path now.
  trap "fm_lock_release '$LOCK'" EXIT
  previous=$(record_read) || previous=$NO_RECORD
  started=$(date +%s)
  record_write "$(jq -c --argjson at "$started" '.started = $at | .state = "running"' <<<"$previous")" || true
  rc=0
  out=$(canary_run) || rc=$?
  printf '%s\n' "$out"
  printf '%s\n' "$out" > "$LAST_OUT.tmp.$$" && mv -f "$LAST_OUT.tmp.$$" "$LAST_OUT"
  record_write "$(jq -cn --argjson prev "$previous" --argjson started "$started" \
    --argjson at "$(date +%s)" --argjson rc "$rc" --arg out "$out" '
    ($out | split("\n")) as $lines |
    (if any($lines[]; startswith("FAILED ") or startswith("error: ")) then "failed"
     elif any($lines[]; startswith("SWAPPED ")) then "swapped"
     elif any($lines[]; startswith("UNVERIFIABLE ")) then "unverifiable"
     elif any($lines[]; startswith("OK ")) then "ok"
     else "none" end) as $outcome |
    {started: $started, finished: $at, state: "done", exit: $rc, outcome: $outcome,
     summary: ([$lines[] | select(test("^(SWAPPED|FAILED|UNVERIFIABLE|WARN) |^error: "))] | join("; ")),
     reported: false, last_reported_outcome: ($prev.last_reported_outcome // null)}')" || true
  return "$rc"
}

# ---- check ------------------------------------------------------------------------
action_check() (
  local record interval started now state outcome last
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  secondmate_home && return 0
  mkdir -p "$RESULT_DIR" 2>/dev/null || return 0
  fm_lock_try_acquire "$LOCK" || return 0
  trap 'fm_lock_release "$LOCK"' EXIT
  record=$(record_read) || record=''
  state=$(jq -r '.state // ""' <<<"${record:-$NO_RECORD}")
  if [ "$state" = running ]; then
    record_write "$(jq -c --argjson at "$(date +%s)" '.state = "done" | .finished = $at | .exit = 3 | .outcome = "failed" | .summary = "the canary run stopped before it finished" | .reported = false' <<<"$record")"
    record=$(record_read) || record=''
  fi
  if [ -n "$record" ] && [ "$(jq -r '.reported == false' <<<"$record")" = true ]; then
    outcome=$(jq -r '.outcome // ""' <<<"$record")
    last=$(jq -r '.last_reported_outcome // ""' <<<"$record")
    record_write "$(jq -c '.reported = true | .last_reported_outcome = .outcome' <<<"$record")" || return 0
    case "$outcome" in
      swapped)
        printf 'captain notice - free-model canary swapped a dispatch profile: %s\n' "$(jq -r '.summary' <<<"$record")"
        ;;
      unverifiable | failed)
        [ "$outcome" = "$last" ] \
          || printf 'free-model canary could not verify the free opencode models: %s; details in state/free-model-canary/last.out\n' "$(jq -r '.summary' <<<"$record")"
        ;;
    esac
    return 0
  fi
  interval=$(positive_int "${FM_FREE_MODEL_CANARY_INTERVAL:-}" 86400)
  now=$(date +%s)
  started=$(jq -r '.started // 0' <<<"${record:-$NO_RECORD}")
  [ $((now - started)) -ge "$interval" ] || return 0
  watched || return 0
  fm_lock_release "$LOCK"
  trap - EXIT
  local monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  nohup "$0" run --record >/dev/null 2>&1 </dev/null &
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  return 0
)

# ---- arm / disarm ----------------------------------------------------------------
shim_content() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-free-model-canary.sh - daily free-model canary poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-free-model-canary.sh") check"
}

# shellcheck disable=SC2031  # Use the parent's home and state.
action_arm() {
  local home device tmp
  if [ "${1:-}" = --if-watched ]; then
    ! secondmate_home && watched || return 0
  elif [ -n "${1:-}" ]; then
    die_usage "unknown arm flag: $1"
  fi
  secondmate_home && { printf 'fm-free-model-canary: a secondmate home inherits its rules; arm the canary in the primary home\n' >&2; return 1; }
  watched || { printf 'fm-free-model-canary: no opencode profile in %s runs %s\n' "$RULES" "$FM_FREE_LANE_MODEL" >&2; return 1; }
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || { printf 'fm-free-model-canary: cannot resolve FM_HOME\n' >&2; return 1; }
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || { printf 'fm-free-model-canary: unsafe shim path\n' >&2; return 1; }
  fm_pr_regular_destination_on_device_or_absent "$CHECK_EVERY" "$device" || { printf 'fm-free-model-canary: unsafe cadence path\n' >&2; return 1; }
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ] \
    && shim_content "$home" | cmp -s - "$CHECK_SHIM" \
    && [ "$(cat "$CHECK_EVERY" 2>/dev/null)" = 3600 ] \
    && fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-free-model-canary-check.XXXXXX") || return 1
  if ! shim_content "$home" > "$tmp" || ! chmod 0700 "$tmp" || ! fm_pr_private_file_valid "$tmp" 700 "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    printf 'fm-free-model-canary: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM"
    printf 'fm-free-model-canary: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  printf '3600\n' > "$CHECK_EVERY" || return 1
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

# shellcheck disable=SC2031  # Use the parent's state.
action_disarm() {
  FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null || return 1
  rm -f -- "$CHECK_EVERY"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

command -v jq >/dev/null 2>&1 || die_usage 'jq is required'
case "${1:-}" in
  run) shift; action_run "$@" ;;
  check) action_check ;;
  arm) shift; action_arm "$@" ;;
  disarm) action_disarm ;;
  -h | --help) usage ;;
  *) die_usage 'usage: run [--record]|check|arm [--if-watched]|disarm|--help' ;;
esac
