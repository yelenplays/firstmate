#!/usr/bin/env bash
# fm-dispatch-selftest.sh - prove that crew dispatch routing still answers and
# still picks the expected rule, on a fixed set of sample tasks.
#
# Usage:
#   fm-dispatch-selftest.sh run [--rules <file>] [--samples <file>] [--record]
#   fm-dispatch-selftest.sh check
#   fm-dispatch-selftest.sh arm
#   fm-dispatch-selftest.sh disarm
#   fm-dispatch-selftest.sh --help
#
# `run` routes every sample through bin/fm-dispatch-resolve.sh against the
#   rules file (default $FM_HOME/config/crew-dispatch.json) and prints one
#   PASS or FAIL line per sample plus a summary. A sample passes when the
#   resolver names the expected rule on its `decided:` line, which carries the
#   lane actually used rather than a rule that fell through to another lane,
#   and answers it: a `profile:` line, or the escalation a captain-approval
#   rule requires.
#   Coverage is part of the proof: every rule needs at least three samples, so
#   a new rule without samples fails the run. Exit 0 when every sample passes
#   and coverage holds, 1 otherwise, 2 for a usage or input error (missing or
#   malformed rules or samples file). Each sample runs with an isolated
#   FM_HOME (sharing $FM_HOME/.env for the typed-call keys and read-only
#   prediction evidence from the home) and an isolated config directory
#   holding the rules file and, when the home has
#   one, its dispatch-never-send list, so an unrecorded run writes nothing into
#   the home and turns on no shadow logging. A present list that is not a
#   readable regular file (including a dangling symlink) refuses the entire
#   run before any sample is sent. With both judges unavailable, the default
#   stage answers every sample and the run fails, which is the point: it
#   measures routing as dispatch will see it.
#   --record also writes the result to state/dispatch-selftest/ (used by the
#   detached nightly run).
#
# Samples file (default $FM_HOME/config/dispatch-samples.json, home-local and
#   gitignored like the rules it tests): {"samples": [{"id", "brief",
#   "project"?, "spec"?, "expect"}]}. `brief` becomes the sample's
#   `## Captain's intent`, `spec` its `## Firstmate spec`, `expect` is
#   "rule_<n>" (1-based, as the resolver names rules) or "default". Ids match
#   ^[A-Za-z0-9._-]+$ and are unique. tests/fixtures/dispatch-selftest/ holds
#   the tracked synthetic example that CI runs offline.
#
# `check` is the watcher check the nightly run rides on. It stays silent
#   except for one failure line per attempted input digest. When the
#   rules+samples+resolver+backup digest differs from the last attempted
#   digest, it launches
#   `run --record` immediately; unchanged inputs wait until no run has started
#   since the most recent FM_DISPATCH_SELFTEST_HOUR:00 local time (default 3,
#   0..23), when the nightly run retries them.
#   It launches the run detached (nohup, its own process
#   group, stdio closed) and returns at once, so it always fits the watcher's
#   per-check bound. A run that died before recording is reported as failed.
#   Missing rules or samples files produce one failure report per changed
#   missing-input digest or nightly slot, and replace last.out with that error.
# `arm` writes state/dispatch-selftest.check.sh (embedding this home), sets its
#   state/dispatch-selftest.check-every cadence to 3600 seconds, and binds it
#   with bin/fm-check-register.sh, so the watcher dispatches it and turns its
#   one line into an ordinary `check:` wake. It refuses when the samples file
#   is absent. `disarm` retires the shim through bin/fm-check-unregister.sh and
#   removes the cadence file; results under state/dispatch-selftest/ stay.
#
# State: state/dispatch-selftest/result.json (started, finished, state
#   running|done, exit, failing, summary, reported),
#   state/dispatch-selftest/running (ownership guard for recorded runs and
#   watcher checks),
#   state/dispatch-selftest/attempted.sha256 (the last attempted rules+samples
#   and routing-implementation digest, including missing-file markers), and
#   state/dispatch-selftest/last.out
#   (the last recorded output).
#   docs/configuration.md "Typed dispatch resolution" owns the operator view.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RESOLVER="${FM_DISPATCH_RESOLVE_BIN:-$SCRIPT_DIR/fm-dispatch-resolve.sh}"
CHECK_ID=dispatch-selftest
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_EVERY="$STATE/$CHECK_ID.check-every"
RESULT_DIR="$STATE/dispatch-selftest"
RESULT="$RESULT_DIR/result.json"
LAST_OUT="$RESULT_DIR/last.out"
ATTEMPT_HASH="$RESULT_DIR/attempted.sha256"
LOCK="$RESULT_DIR/running"
MIN_PER_RULE=3
NO_RECORD='{}'

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}
die_usage() { printf 'fm-dispatch-selftest: %s\n' "$1" >&2; exit 2; }

# ---- run ----------------------------------------------------------------------
validate_samples() { # <samples> <rule-count> -> error text, or nothing
  jq -r --argjson n "$2" '
    def ids: [.samples[].id];
    if type != "object" or (.samples | type) != "array" or (.samples | length) == 0 then "samples must be a non-empty array under \"samples\""
    elif any(.samples[]; type != "object") then "each sample must be an object"
    elif any(.samples[]; (.id | type) != "string" or (.id | test("^[A-Za-z0-9._-]+$") | not)) then "each sample needs an id matching ^[A-Za-z0-9._-]+$"
    elif (ids | length) != (ids | unique | length) then "sample ids must be unique"
    elif any(.samples[]; (.brief | type) != "string" or (.brief | length) == 0) then "each sample needs a non-empty brief"
    elif any(.samples[]; has("spec") and ((.spec | type) != "string")) then "spec must be a string when present"
    elif any(.samples[]; has("project") and ((.project | type) != "string" or (.project | length) == 0 or (.project | test("[/\n]")))) then "project must be a plain name when present"
    elif any(.samples[]; (.expect | type) != "string"
        or ((.expect == "default") or ((.expect | test("^rule_[1-9][0-9]*$")) and ((.expect | ltrimstr("rule_") | tonumber) <= $n))) | not) then
      "each sample expect must be \"default\" or rule_1..rule_\($n)"
    else empty end' "$1" 2>/dev/null || printf 'samples file is not JSON\n'
}

action_run() (
  local rules="$CONFIG_DIR/crew-dispatch.json" samples="$CONFIG_DIR/dispatch-samples.json" record=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --rules) [ "$#" -ge 2 ] || die_usage '--rules needs a file'; rules=$2; shift 2 ;;
      --samples) [ "$#" -ge 2 ] || die_usage '--samples needs a file'; samples=$2; shift 2 ;;
      --record) record=1; shift ;;
      *) die_usage "unknown run argument: $1" ;;
    esac
  done
  local out rc=0 started_hash
  if [ "$record" -eq 1 ]; then
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    mkdir -p "$RESULT_DIR" || return 2
    fm_lock_try_acquire "$LOCK" || { printf 'fm-dispatch-selftest: a recorded run is already active\n' >&2; return 1; }
    trap 'fm_lock_release "$LOCK"' EXIT
    started_hash=''
    if [ "$rules" = "$CONFIG_DIR/crew-dispatch.json" ] \
      && [ "$samples" = "$CONFIG_DIR/dispatch-samples.json" ]; then
      started_hash=$(inputs_hash "$rules" "$samples") || started_hash=''
      if [ -n "$started_hash" ] && ! record_attempted_hash "$started_hash"; then
        return 2
      fi
    fi
    record_write "$(jq -cn --argjson at "$(date +%s)" '{started: $at, state: "running"}')" || return 2
    out=$(run_samples "$rules" "$samples") || rc=$?
    printf '%s\n' "$out" > "$LAST_OUT.tmp.$$" && mv -f "$LAST_OUT.tmp.$$" "$LAST_OUT"
    record_finish "$rc" "$out"
    printf '%s\n' "$out"
    return "$rc"
  fi
  run_samples "$rules" "$samples"
)

run_samples() { # <rules> <samples>
  local rules=$1 samples=$2 rule_count err work n i id brief spec project expect line decided by status
  local pass=0 fail=0 failing='' coverage rc
  [ -f "$rules" ] && [ -r "$rules" ] || { printf 'error: rules file not readable: %s\n' "$rules"; return 2; }
  [ -f "$samples" ] && [ -r "$samples" ] || { printf 'error: samples file not readable: %s\n' "$samples"; return 2; }
  rule_count=$(jq -r 'if type == "object" and ((.rules // []) | type) == "array" then ((.rules // []) | length) else error("bad") end' "$rules" 2>/dev/null) \
    || { printf 'error: rules file is not a rules object: %s\n' "$rules"; return 2; }
  err=$(validate_samples "$samples" "$rule_count")
  [ -z "$err" ] || { printf 'error: %s: %s\n' "$samples" "$err"; return 2; }
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-dispatch-selftest.XXXXXX") || { printf 'error: mktemp failed\n'; return 2; }
  # shellcheck disable=SC2064  # Expand the path now.
  trap "rm -rf '$work'" RETURN
  mkdir -p "$work/home/state" "$work/config" || return 2
  cp "$rules" "$work/config/crew-dispatch.json" || return 2
  # A present list, including a dangling symlink, is a privacy boundary: copy
  # it only as a readable regular file and refuse the run otherwise, as the
  # resolver itself withholds every request in that case.
  if [ -e "$CONFIG_DIR/dispatch-never-send" ] || [ -L "$CONFIG_DIR/dispatch-never-send" ]; then
    { [ -f "$CONFIG_DIR/dispatch-never-send" ] && [ -r "$CONFIG_DIR/dispatch-never-send" ]; } \
      || { printf 'error: dispatch-never-send list is not a readable regular file; nothing sent\n'; return 2; }
    cp "$CONFIG_DIR/dispatch-never-send" "$work/config/dispatch-never-send" 2>/dev/null \
      || { printf 'error: dispatch-never-send list is not readable; nothing sent\n'; return 2; }
  fi
  [ ! -f "$FM_HOME/.env" ] || ln -s "$FM_HOME/.env" "$work/home/.env"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'exec %q --state %q "$@" --read-only\n' "${FM_SPEND_LEDGER:-$SCRIPT_DIR/fm-spend-ledger.py}" "$STATE"
  } > "$work/predict.sh"
  chmod 0700 "$work/predict.sh" || return 2
  n=$(jq '.samples | length' "$samples")
  for ((i = 0; i < n; i++)); do
    id=$(jq -r --argjson i "$i" '.samples[$i].id' "$samples")
    brief=$(jq -r --argjson i "$i" '.samples[$i].brief' "$samples")
    spec=$(jq -r --argjson i "$i" '.samples[$i].spec // ""' "$samples")
    project=$(jq -r --argjson i "$i" '.samples[$i].project // "selftest"' "$samples")
    expect=$(jq -r --argjson i "$i" '.samples[$i].expect' "$samples")
    {
      printf '# Task\n\n## Captain'"'"'s intent\n%s\n\n' "$brief"
      [ -z "$spec" ] || printf '## Firstmate spec\n%s\n\n' "$spec"
    } > "$work/brief.md"
    rc=0
    line=$(FM_HOME="$work/home" FM_CONFIG_OVERRIDE="$work/config" FM_SPEND_LEDGER="$work/predict.sh" "$RESOLVER" "$work/brief.md" --project "$project" 2> "$work/stderr") || rc=$?
    if [ "$rc" -eq 2 ]; then
      printf 'error: the resolver refused the rules: %s\n' "$(grep -m 1 . "$work/stderr" | tr -d '\r')"
      return 2
    fi
    decided=$(printf '%s\n' "$line" | sed -n 's/^  decided: \([^ ]*\) by \([^ ]*\)$/\1/p' | head -n 1)
    by=$(printf '%s\n' "$line" | sed -n 's/^  decided: \([^ ]*\) by \([^ ]*\)$/\2/p' | head -n 1)
    status=$(printf '%s\n' "$line" | sed -n 's/^  status: //p' | head -n 1)
    if [ "$decided" = "$expect" ] && { printf '%s\n' "$line" | grep -q '^  profile: ' || [ "$status" = escalate ]; }; then
      pass=$((pass + 1))
      printf 'PASS %s expect=%s decided=%s by=%s status=%s\n' "$id" "$expect" "$decided" "$by" "$status"
    else
      fail=$((fail + 1))
      failing="$failing $id"
      printf 'FAIL %s expect=%s decided=%s by=%s status=%s\n' "$id" "$expect" "${decided:--}" "${by:--}" "${status:-none}"
    fi
  done
  coverage=$(jq -r --argjson n "$rule_count" --argjson min "$MIN_PER_RULE" --slurpfile s "$samples" '
    [range(1; $n + 1) as $r | "rule_\($r)" as $k
      | ([$s[0].samples[] | select(.expect == $k)] | length) as $c
      | select($c < $min) | "COVERAGE \($k) has \($c) sample(s), needs \($min)"] | .[]' -n)
  if [ -n "$coverage" ]; then
    printf '%s\n' "$coverage"
    fail=$((fail + 1))
    failing="$failing coverage"
  fi
  printf 'selftest: %s samples, %s pass, %s fail%s\n' "$n" "$pass" "$((fail))" "${failing:+:$failing}"
  [ "$fail" -eq 0 ]
}

# ---- result record --------------------------------------------------------------
record_write() {
  [ -d "$RESULT_DIR" ] && [ ! -L "$RESULT_DIR" ] || return 1
  printf '%s\n' "$1" > "$RESULT.tmp.$$" && mv -f "$RESULT.tmp.$$" "$RESULT"
}

record_read() { jq -ce 'select(type == "object")' "$RESULT" 2>/dev/null; }

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

input_file_token() {
  local digest
  if [ ! -f "$1" ]; then
    printf 'missing'
    return 0
  fi
  if [ ! -r "$1" ]; then
    printf 'unreadable'
    return 0
  fi
  digest=$(sha256_file "$1") || digest=''
  if [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]]; then
    printf '%s' "$digest"
  else
    printf 'unreadable'
  fi
}

inputs_hash() { # <rules> <samples>
  local rules_hash samples_hash resolver_hash backup_hash
  rules_hash=$(input_file_token "$1") || return 1
  samples_hash=$(input_file_token "$2") || return 1
  resolver_hash=$(input_file_token "$SCRIPT_DIR/fm-dispatch-resolve.sh") || return 1
  backup_hash=$(input_file_token "$SCRIPT_DIR/fm-backup-judge-lib.sh") || return 1
  printf '%s\n%s\n%s\n%s\n' "$rules_hash" "$samples_hash" "$resolver_hash" "$backup_hash" | sha256_stdin
}

record_attempted_hash() { # <hash>
  local tmp
  tmp=$(umask 077; mktemp "$RESULT_DIR/.attempted.sha256.XXXXXX") || return 1
  if ! printf '%s\n' "$1" > "$tmp" || ! mv -f -- "$tmp" "$ATTEMPT_HASH"; then
    rm -f -- "$tmp"
    return 1
  fi
}

record_finish() { # <exit> <output>
  local started summary failing
  started=$(record_read | jq -r '.started // empty') || started=''
  summary=$(printf '%s\n' "$2" | grep '^selftest: \|^error: ' | tail -n 1)
  failing=$(printf '%s\n' "$2" | awk '$1 == "FAIL" { printf "%s%s(%s->%s)", sep, $2, substr($3, 8), substr($4, 9); sep = " " } $1 == "COVERAGE" { printf "%s%s-coverage", sep, $2; sep = " " }')
  record_write "$(jq -cn --argjson started "${started:-$(date +%s)}" --argjson at "$(date +%s)" --argjson rc "$1" --arg summary "$summary" --arg failing "$failing" \
    '{started: $started, finished: $at, state: "done", exit: $rc, summary: $summary, failing: $failing, reported: false}')"
}

# ---- check ------------------------------------------------------------------------
# The most recent HOUR:00 local time at or before now, as epoch seconds.
last_slot() {
  perl -MPOSIX -e 'my $h = shift; my @t = localtime; my $s = mktime(0, 0, $h, $t[3], $t[4], $t[5]); $s -= 86400 if $s > time; print "$s\n"' "$1"
}

emit_failure() {
  local record
  record=$(record_read) || return 0
  [ "$(jq -r '.exit != 0 and .reported == false' <<<"$record")" = true ] || return 0
  record_write "$(jq -c '.reported = true' <<<"$record")" || return 0
  printf 'dispatch selftest failed: %s%s; details in state/dispatch-selftest/last.out\n' \
    "$(jq -r '.summary // "no summary"' <<<"$record")" \
    "$(jq -r 'if (.failing // "") == "" then "" else " - misrouted: " + .failing end' <<<"$record")"
}

action_check() (
  local hour=${FM_DISPATCH_SELFTEST_HOUR:-3} record started slot state current_hash attempted_hash changed=0 nightly=0 missing=''
  case "$hour" in ''|*[!0-9]*) hour=3 ;; esac
  [ "$hour" -le 23 ] || hour=3
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  mkdir -p "$RESULT_DIR" 2>/dev/null || return 0
  # Own the same guard as run --record before reading, recovering, or
  # acknowledging a result, so a check cannot overwrite a live run's state.
  fm_lock_try_acquire "$LOCK" || return 0
  trap 'fm_lock_release "$LOCK"' EXIT
  current_hash=$(inputs_hash "$CONFIG_DIR/crew-dispatch.json" "$CONFIG_DIR/dispatch-samples.json") || current_hash=''
  slot=$(last_slot "$hour") || return 0
  attempted_hash=$(cat "$ATTEMPT_HASH" 2>/dev/null) || attempted_hash=''
  [ -n "$current_hash" ] && [ "$current_hash" = "$attempted_hash" ] || changed=1
  record=$(record_read) || record=''
  state=$(jq -r '.state // ""' <<<"${record:-$NO_RECORD}")
  if [ "$state" = running ]; then
    record_write "$(jq -c --argjson at "$(date +%s)" '.state = "done" | .finished = $at | .exit = 3 | .summary = "the run stopped before it finished" | .failing = "" | .reported = false' <<<"$record")"
    record=$(record_read) || record=''
  fi
  if [ -n "$record" ] && [ "$(jq -r '.exit != 0 and .reported == false' <<<"$record")" = true ]; then
    emit_failure
    return 0
  fi
  started=$(jq -r '.started // 0' <<<"${record:-$NO_RECORD}")
  [ "$started" -lt "$slot" ] && nightly=1
  if [ ! -f "$CONFIG_DIR/dispatch-samples.json" ]; then
    missing="samples file is missing: $CONFIG_DIR/dispatch-samples.json"
  elif [ ! -f "$CONFIG_DIR/crew-dispatch.json" ]; then
    missing="rules file is missing: $CONFIG_DIR/crew-dispatch.json"
  fi
  if [ -n "$missing" ]; then
    [ "$changed" -eq 1 ] || [ "$nightly" -eq 1 ] || return 0
    if ! record_attempted_hash "$current_hash" \
      || ! printf 'error: %s\n' "$missing" > "$LAST_OUT.tmp.$$" \
      || ! mv -f "$LAST_OUT.tmp.$$" "$LAST_OUT" \
      || ! record_write "$(jq -cn --argjson at "$(date +%s)" --arg message "error: $missing" \
        '{started: $at, finished: $at, state: "done", exit: 2, summary: $message, failing: "", reported: false}')"; then
      rm -f "$LAST_OUT.tmp.$$"
      return 0
    fi
    emit_failure
    return 0
  fi
  [ "$changed" -eq 1 ] || [ "$nightly" -eq 1 ] || return 0
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
    '# Auto-generated by fm-dispatch-selftest.sh - nightly dispatch selftest poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-dispatch-selftest.sh") check"
}

action_arm() {
  local home device tmp
  [ -f "$CONFIG_DIR/dispatch-samples.json" ] || { printf 'fm-dispatch-selftest: no samples file at %s\n' "$CONFIG_DIR/dispatch-samples.json" >&2; return 1; }
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || { printf 'fm-dispatch-selftest: cannot resolve FM_HOME\n' >&2; return 1; }
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || { printf 'fm-dispatch-selftest: unsafe shim path\n' >&2; return 1; }
  fm_pr_regular_destination_on_device_or_absent "$CHECK_EVERY" "$device" || { printf 'fm-dispatch-selftest: unsafe cadence path\n' >&2; return 1; }
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ] \
    && shim_content "$home" | cmp -s - "$CHECK_SHIM" \
    && [ "$(cat "$CHECK_EVERY" 2>/dev/null)" = 3600 ] \
    && fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-dispatch-selftest-check.XXXXXX") || return 1
  # The shim is renamed into place whole and bound right after; any failure in
  # between removes it, so the home never holds an unbound shim.
  if ! shim_content "$home" > "$tmp" || ! chmod 0700 "$tmp" || ! fm_pr_private_file_valid "$tmp" 700 "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    printf 'fm-dispatch-selftest: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM"
    printf 'fm-dispatch-selftest: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  printf '3600\n' > "$CHECK_EVERY" || return 1
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null || return 1
  rm -f -- "$CHECK_EVERY"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

command -v jq >/dev/null 2>&1 || die_usage 'jq is required'
case "${1:-}" in
  run) shift; action_run "$@" ;;
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage 'usage: run|check|arm|disarm|--help' ;;
esac
