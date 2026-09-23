#!/usr/bin/env bash
# Behavior tests for the bounded remote job queue and worker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
RUNTIME_BIN="$TMP_ROOT/runtime-bin"
FAKE_PERL_LOG="$TMP_ROOT/perl.log"
SUPERVISOR_LOCK_BIN=
if ! command -v flock >/dev/null 2>&1; then
  SUPERVISOR_LOCK_BIN="$TMP_ROOT/supervisor-lock-bin"
  mkdir -p "$SUPERVISOR_LOCK_BIN"
  cat > "$SUPERVISOR_LOCK_BIN/flock" <<'PY'
#!/usr/bin/env python3
import fcntl
import sys

fd = int(sys.argv[-1])
operation = fcntl.LOCK_UN if "-u" in sys.argv else fcntl.LOCK_EX
try:
    fcntl.flock(fd, operation)
except BlockingIOError:
    raise SystemExit(1)
PY
  chmod +x "$SUPERVISOR_LOCK_BIN/flock"
  PATH="$SUPERVISOR_LOCK_BIN:$PATH"
  export PATH
fi
REAL_GIT=$(command -v git)
OTHER_PID=
RECOVERY_WORKER_PID=
REPEAT_WORKER_PID=
RESTART_SUPERVISOR_PID=
RACE_SUPERVISOR_PIDS=()
CLEANUP_SUPERVISOR_PIDS=()
CLEANUP_LANE_PIDS=()
CLEANUP_TEST_STATE=
mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME" "$RUNTIME_BIN"
# worker.pid records the serving child, not its restart supervisor, so stopping
# that pid alone leaves the supervisor to respawn - the leak
# tests/fm-remote-job-orphan-reap.test.sh pins. Stop the whole worker tree.
cleanup_remote_job_fixture() {
  [ -z "$OTHER_PID" ] || kill "$OTHER_PID" 2>/dev/null || true
  [ -z "$RECOVERY_WORKER_PID" ] || kill "$RECOVERY_WORKER_PID" 2>/dev/null || true
  [ -z "$REPEAT_WORKER_PID" ] || kill "$REPEAT_WORKER_PID" 2>/dev/null || true
  [ -z "$RESTART_SUPERVISOR_PID" ] || kill -KILL "$RESTART_SUPERVISOR_PID" 2>/dev/null || true
  for pid in "${RACE_SUPERVISOR_PIDS[@]:-}" "${CLEANUP_SUPERVISOR_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  for pid in "${CLEANUP_LANE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  if [ -n "$CLEANUP_TEST_STATE" ] && [ -f "$CLEANUP_TEST_STATE/supervisor.lock/owner" ]; then
    IFS= read -r pid < "$CLEANUP_TEST_STATE/supervisor.lock/owner" || true
    case "$pid" in ''|*[!0-9]*) ;; *) kill -KILL -- "-$pid" 2>/dev/null || true; kill -KILL "$pid" 2>/dev/null || true ;; esac
  fi
  if [ -f "$STATE_ROOT/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$STATE_ROOT/worker.pid")" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup_remote_job_fixture EXIT

cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" \
  "$ROOT/bin/fm-remote-delta-read.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-probe-job.sh" <<'SH'
#!/bin/bash
set -u
printf 'home=%s\nroot=%s\nactive=%s\npath=%s\n' "$FM_HOME" "$FM_ROOT_OVERRIDE" "${FM_REMOTE_JOB_ACTIVE:-}" "$PATH"
printf 'args:'
printf ' <%s>' "$@"
printf '\n'
if [ -n "${TOP_SECRET:-}" ]; then printf 'secret=leaked\n'; else printf 'secret=absent\n'; fi
while IFS= read -r line || [ -n "$line" ]; do printf 'stdin=%s\n' "$line"; done
exit "${FM_PROBE_EXIT:-0}"
SH
cat > "$REMOTE_ROOT/bin/fm-timeout-job.sh" <<'SH'
#!/bin/bash
sleep 3
SH
cat > "$REMOTE_ROOT/bin/fm-delay-job.sh" <<'SH'
#!/bin/bash
sleep "$1"
printf 'ran\n' > "$2"
SH
cat > "$REMOTE_ROOT/bin/fm-touch-job.sh" <<'SH'
#!/bin/bash
printf 'ran\n' > "$1"
SH
cat > "$REMOTE_ROOT/bin/fm-shutdown-job.sh" <<'SH'
#!/bin/bash
trap '' HUP INT TERM
printf 'started\n' > "$1"
sleep 3
printf 'ran\n' > "$2"
SH
cat > "$REMOTE_ROOT/bin/fm-output-job.sh" <<'SH'
#!/bin/bash
set -e
head -c 1200000 < /dev/zero
head -c 1200000 < /dev/zero >&2
exit 23
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
cat > "$RUNTIME_BIN/perl" <<'SH'
#!/bin/bash
printf 'invoked\n' >> "$FM_FAKE_PERL_LOG"
exit 127
SH
chmod +x "$RUNTIME_BIN/perl"

git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'remote job fixture'

DEFAULT_STATE="$TMP_ROOT/default-timeout-jobs"
DEFAULT_BOUNDS=$(
  unset FM_REMOTE_JOB_QUEUE_TIMEOUT
  unset FM_REMOTE_JOB_TIMEOUT
  # shellcheck disable=SC2030 # This source intentionally initializes subshell-only defaults.
  FM_REMOTE_JOB_STATE_ROOT="$DEFAULT_STATE"
  export FM_REMOTE_JOB_STATE_ROOT
  # shellcheck source=bin/fm-remote-job-lib.sh
  . "$ROOT/bin/fm-remote-job-lib.sh"
  fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-probe-job.sh </dev/null >/dev/null
  printf '%s %s\n' \
    "$(cat "$DEFAULT_STATE/jobs/$FM_REMOTE_JOB_ID/queue_deadline")" \
    "$(cat "$DEFAULT_STATE/jobs/$FM_REMOTE_JOB_ID/timeout")"
)
read -r DEFAULT_QUEUE_DEADLINE DEFAULT_EXECUTION_TIMEOUT <<< "$DEFAULT_BOUNDS"
DEFAULT_QUEUE_REMAINING=$((DEFAULT_QUEUE_DEADLINE - $(date +%s)))
[ "$DEFAULT_QUEUE_REMAINING" -ge 350 ] || fail "the default queue bound is too short"
[ "$DEFAULT_EXECUTION_TIMEOUT" -ge 350 ] || fail "the default execution bound cannot contain a 300-second long poll"
pass "default queue and execution bounds independently cover long polls"

# shellcheck disable=SC2031 # The earlier assignment was confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
# shellcheck disable=SC2031 # The sourced defaults above were confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_QUEUE_TIMEOUT=5
# shellcheck disable=SC2031 # The sourced defaults above were confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_TIMEOUT=5
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

LOCAL_BIN_PARENT="$ACCOUNT_HOME/.local"
LOCAL_BIN_TARGET="$TMP_ROOT/local-bin-target"
mkdir -p "$LOCAL_BIN_PARENT" "$LOCAL_BIN_TARGET"
ln -s "$LOCAL_BIN_TARGET" "$LOCAL_BIN_PARENT/bin"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
case ":$FM_REMOTE_JOB_OPERATOR_PATH:" in
  *":$LOCAL_BIN_PARENT/bin:"*|*":$LOCAL_BIN_TARGET:"*) fail "the composed PATH followed a symlinked local bin" ;;
esac
rm -f "$LOCAL_BIN_PARENT/bin"
mkdir "$LOCAL_BIN_PARENT/bin"
pass "operator PATH excludes a symlinked local bin"

NVM_ROOT="$ACCOUNT_HOME/.nvm"
NVM_V20="$NVM_ROOT/versions/node/v20.18.0/bin"
NVM_V24="$NVM_ROOT/versions/node/v24.14.1/bin"
mkdir -p "$NVM_ROOT/alias" "$NVM_V20" "$NVM_V24"
printf '20\n' > "$NVM_ROOT/alias/default"
printf '#!/bin/bash\nprintf "20\\n"\n' > "$NVM_V20/node"
printf '#!/bin/bash\nprintf "24\\n"\n' > "$NVM_V24/node"
chmod +x "$NVM_V20/node" "$NVM_V24/node"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
NVM_SELECTED=$(PATH="$FM_REMOTE_JOB_OPERATOR_PATH" node)
[ "$NVM_SELECTED" = 20 ] || fail "the composed PATH ignored nvm's default alias"
rm -f "$NVM_ROOT/alias/default"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
NVM_SELECTED=$(PATH="$FM_REMOTE_JOB_OPERATOR_PATH" node)
[ "$NVM_SELECTED" = 24 ] || fail "the nvm fallback did not select the highest installed version"
printf 'system\n' > "$NVM_ROOT/alias/default"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
case ":$FM_REMOTE_JOB_OPERATOR_PATH:" in
  *":$NVM_V20:"*|*":$NVM_V24:"*) fail "the composed PATH ignored nvm's system default" ;;
esac
printf '20\n' > "$NVM_ROOT/alias/default"
pass "operator PATH honors nvm defaults with a deterministic fallback"

NIX_PROFILE="$ACCOUNT_HOME/.nix-profile"
NIX_BIN="$TMP_ROOT/nix-profile-bin"
mkdir -p "$NIX_PROFILE" "$NIX_BIN"
ln -s "$NIX_BIN" "$NIX_PROFILE/bin"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
case ":$FM_REMOTE_JOB_OPERATOR_PATH:" in
  *":$NIX_BIN:"*) ;;
  *) fail "the composed PATH omitted a resolved Nix profile bin link" ;;
esac
pass "operator PATH resolves the authorized Nix profile bin link"

# Which install of a multi-version tool a remote job resolves is decided by the
# order these directories land on PATH, so the composition has to be sorted
# rather than whatever order the filesystem returns. The fixture is created in
# a deliberately unsorted order, and the expectation is the shell's own
# pathname expansion - the mechanism the portable-PATH contract in
# tests/fm-on.test.sh reconstructs.
MISE_INSTALLS="$ACCOUNT_HOME/.local/share/mise/installs"
for TOOL_VERSION in node/26.7.0 node/8.1 node/26 bun/1.4 bun/1.3.14 python/3.12.7; do
  mkdir -p "$MISE_INSTALLS/$TOOL_VERSION/bin"
done
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
MISE_COMPOSED=$(printf '%s\n' "$FM_REMOTE_JOB_OPERATOR_PATH" | tr ':' '\n' | grep -F "$MISE_INSTALLS/" || true)
MISE_EXPECTED=$(printf '%s\n' "$MISE_INSTALLS"/*/*/bin)
[ "$MISE_COMPOSED" = "$MISE_EXPECTED" ] \
  || fail "the composed operator PATH did not order tool installs like the shell's own expansion"$'\n'"expected: $MISE_EXPECTED"$'\n'"actual:   $MISE_COMPOSED"
# This assertion detects the defect on bash 3.2 and 5.2, where compgen -G returns unsorted glob matches, but reads green on bash 5.3+ because glob sorting moved into the glob library so both mechanisms agree there.
rm -rf -- "$ACCOUNT_HOME/.local/share/mise"
pass "operator PATH orders discovered tool installs deterministically"

HOME="$ACCOUNT_HOME" PATH="$RUNTIME_BIN${SUPERVISOR_LOCK_BIN:+:$SUPERVISOR_LOCK_BIN}:/usr/bin:/bin:/usr/sbin:/sbin" FM_FAKE_PERL_LOG="$FAKE_PERL_LOG" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_TIMEOUT=5 \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
for _ in $(seq 1 100); do
  [ -f "$STATE_ROOT/worker.ready" ] && break
  sleep 0.05
done
assert_present "$STATE_ROOT/worker.ready" "the worker did not publish its readiness heartbeat: $(<"$TMP_ROOT/worker.err") $(<"$TMP_ROOT/worker.out")"

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

printf 'first line\nsecond line\n' > "$TMP_ROOT/stdin"
# shellcheck disable=SC2016 # Literal shell-looking argv is an injection probe.
TOP_SECRET=must-not-cross fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-probe-job.sh 'two words' '$(not executed)' < "$TMP_ROOT/stdin" > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
[ "$(file_mode "$JOB_DIR")" = 700 ] \
  || fail "staged job directory is not mode 0700"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the completed probe did not preserve exit status"
OUT=$(<"$FM_REMOTE_JOB_STDOUT")
assert_contains "$OUT" "home=$REMOTE_HOME" "the worker did not pass the staged FM_HOME"
assert_contains "$OUT" "root=$REMOTE_ROOT" "the worker did not pass the configured root"
assert_contains "$OUT" 'active=1' "the target did not execute inside the worker environment"
# shellcheck disable=SC2016 # Literal shell-looking expected output is an injection probe.
assert_contains "$OUT" 'args: <two words> <$(not executed)>' "the worker changed argv boundaries"
assert_contains "$OUT" 'stdin=first line' "the worker lost staged stdin"
assert_contains "$OUT" 'stdin=second line' "the worker lost staged stdin"
assert_contains "$OUT" 'secret=absent' "ambient environment crossed into the worker child"
case "$OUT" in *"$REMOTE_ROOT/bin:$ACCOUNT_HOME/.local/bin:"*) : ;; *) fail "worker PATH omitted its fixed root and account head" ;; esac
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the completed job could not be reaped"
assert_absent "$JOB_DIR" "reap retained a completed job record"
assert_absent "$FAKE_PERL_LOG" "the worker invoked an unavailable Perl runtime"
pass "the worker preserves bounded argv and stdin in an empty environment"

ACTIVE_SIDE_EFFECT="$TMP_ROOT/active-side-effect"
FM_REMOTE_JOB_TIMEOUT=10
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-delay-job.sh 4 "$ACTIVE_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the active-job readiness fixture did not begin running"
ACTIVE_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
touch -t 200001010000 "$STATE_ROOT/worker.ready"
for _ in $(seq 1 40); do
  fm_remote_job_probe "$ACCOUNT_HOME" && break
  sleep 0.05
done
fm_remote_job_probe "$ACCOUNT_HOME" || fail "the active worker did not refresh its readiness heartbeat"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
[ "$(cat "$STATE_ROOT/worker.pid")" = "$ACTIVE_WORKER_PID" ] \
  || fail "ensure replaced a healthy worker during an active job"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the active job did not complete after the readiness probe"
assert_present "$ACTIVE_SIDE_EFFECT" "the active job was interrupted by the concurrent readiness check"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the active readiness job could not be reaped"
pass "active jobs keep the worker ready for concurrent requests"

OLD_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
printf '\n' >> "$REMOTE_ROOT/bin/fm-remote-job-worker.sh"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "$FM_REMOTE_JOB_ERROR"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
[ "$NEW_WORKER_PID" != "$OLD_WORKER_PID" ] || fail "ensure retained a worker running stale code"
fm_remote_job_worker_identity_matches "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "the replacement worker did not publish the current code identity"
pass "ensure replaces a live worker after its code changes"

RELOCATED_ROOT="$TMP_ROOT/relocated-root"
cp -R "$REMOTE_ROOT" "$RELOCATED_ROOT"
OLD_WORKER_PID=$NEW_WORKER_PID
OLD_WORKER_PGID=$(fm_remote_job_process_pgid "$OLD_WORKER_PID") \
  || fail "the worker replacement fixture could not resolve its process group"
fm_remote_job_ensure_worker "$RELOCATED_ROOT" "$ACCOUNT_HOME" \
  || fail "$FM_REMOTE_JOB_ERROR"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
[ "$NEW_WORKER_PID" != "$OLD_WORKER_PID" ] || fail "ensure retained a worker bound to a different code root"
! kill -0 -- "-$OLD_WORKER_PGID" 2>/dev/null \
  || fail "ensure left the replaced worker supervisor group alive"
fm_remote_job_stage "$ACCOUNT_HOME" "$RELOCATED_ROOT" "$REMOTE_HOME" fm-probe-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the relocated worker rejected its configured code root"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the relocated-root probe could not be reaped"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
pass "worker identity binds the canonical configured code root"

CRASHED_WORKER_PID=$NEW_WORKER_PID
kill -KILL "$CRASHED_WORKER_PID"
wait "$CRASHED_WORKER_PID" 2>/dev/null || true
assert_present "$STATE_ROOT/worker.lock" "an unclean exit did not retain the worker ownership lock"
sleep 20 &
OTHER_PID=$!
printf '%s\n' "$OTHER_PID" > "$STATE_ROOT/worker.pid"
printf '%s\n' "$OTHER_PID" > "$STATE_ROOT/worker.lock/pid"
touch -t 200001010000 "$STATE_ROOT/worker.ready" "$STATE_ROOT/worker.lock"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "$FM_REMOTE_JOB_ERROR"
kill -0 "$OTHER_PID" 2>/dev/null || fail "stale worker state caused an unrelated process to be signaled"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
[ "$NEW_WORKER_PID" != "$OTHER_PID" ] || fail "the replacement adopted an unrelated persisted pid"
fm_remote_job_worker_identity_matches "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "stale ownership recovery did not start the current worker"
kill "$OTHER_PID" 2>/dev/null || true
wait "$OTHER_PID" 2>/dev/null || true
OTHER_PID=
pass "stale ownership is reclaimed without signaling a reused pid"

FM_REMOTE_JOB_TIMEOUT=1
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-timeout-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 124 ] || fail "the worker did not terminate an over-time job"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the timed-out job could not be reaped"
pass "the worker enforces the job timeout and publishes its result"

QUEUED_SIDE_EFFECT="$TMP_ROOT/queued-side-effect"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-timeout-job.sh < /dev/null > /dev/null
FIRST_JOB_ID=$FM_REMOTE_JOB_ID
FIRST_JOB_DIR="$STATE_ROOT/jobs/$FIRST_JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the blocking job did not begin running"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-touch-job.sh "$QUEUED_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
printf '%s\n' "$(fm_remote_job_read_deadline "$FIRST_JOB_DIR")" > "$STATE_ROOT/jobs/$JOB_ID/queue_deadline"
fm_remote_job_wait "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 124 ] || fail "an expired queued job did not publish a timeout result"
assert_absent "$QUEUED_SIDE_EFFECT" "the worker executed a queued job after its durable deadline"
fm_remote_job_reap "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "the blocking job could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the expired queued job could not be reaped"
pass "the worker expires queued jobs before they can mutate"

FIRST_DELAYED_SIDE_EFFECT="$TMP_ROOT/first-delayed-side-effect"
SECOND_DELAYED_SIDE_EFFECT="$TMP_ROOT/second-delayed-side-effect"
FM_REMOTE_JOB_QUEUE_TIMEOUT=5
FM_REMOTE_JOB_TIMEOUT=3
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-delay-job.sh 1.8 "$FIRST_DELAYED_SIDE_EFFECT" < /dev/null > /dev/null
FIRST_JOB_ID=$FM_REMOTE_JOB_ID
FIRST_JOB_DIR="$STATE_ROOT/jobs/$FIRST_JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the first delayed job did not begin running"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-delay-job.sh 1.8 "$SECOND_DELAYED_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "queue time consumed the second job's execution timeout"
assert_present "$SECOND_DELAYED_SIDE_EFFECT" "the queued job did not receive its full execution timeout"
fm_remote_job_reap "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "the first delayed job could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the second delayed job could not be reaped"
pass "queued jobs receive a fresh bounded execution window"

if command -v shasum >/dev/null 2>&1; then
  EMPTY_SHA=$(: | shasum -a 256 | awk '{print $1}')
else
  EMPTY_SHA=$(: | sha256sum | awk '{print $1}')
fi
mkdir -p "$REMOTE_HOME/state"
REPLY_LOG_REL=state/parent-replies.status
PREEMPT_SIDE_EFFECT="$TMP_ROOT/preempt-side-effect"
FM_REMOTE_JOB_QUEUE_TIMEOUT=60
FM_REMOTE_JOB_TIMEOUT=40
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-remote-delta-read.sh "$REPLY_LOG_REL" 0 "$EMPTY_SHA" 30 < /dev/null > /dev/null
POLL_JOB_ID=$FM_REMOTE_JOB_ID
POLL_JOB_DIR="$STATE_ROOT/jobs/$POLL_JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$POLL_JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$POLL_JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the long-poll job did not begin running"
PREEMPT_BEGAN=$(date +%s)
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-touch-job.sh "$PREEMPT_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
PREEMPT_ELAPSED=$(( $(date +%s) - PREEMPT_BEGAN ))
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the short command behind a long poll did not complete"
assert_present "$PREEMPT_SIDE_EFFECT" "the short command behind a long poll did not run"
[ "$PREEMPT_ELAPSED" -le 10 ] || fail "a queued short command waited a full poll window behind the long poll"
fm_remote_job_wait "$ACCOUNT_HOME" "$POLL_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq "$FM_REMOTE_JOB_PREEMPTED_EXIT" ] \
  || fail "a preempted long poll was not distinguished from an elapsed window"
[ ! -s "$FM_REMOTE_JOB_STDOUT" ] || fail "a preempted long poll published partial stdout"
[ ! -s "$FM_REMOTE_JOB_STDERR" ] || fail "a preempted long poll published partial stderr"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the short command could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$POLL_JOB_ID" || fail "the preempted poll could not be reaped"
pass "a queued short command preempts a running long poll instead of waiting its window"

printf 'hello after preemption\n' > "$REMOTE_HOME/$REPLY_LOG_REL"
FM_REMOTE_JOB_TIMEOUT=10
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-remote-delta-read.sh "$REPLY_LOG_REL" 0 "$EMPTY_SHA" 5 < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the re-armed poll after preemption did not complete"
OUT=$(<"$FM_REMOTE_JOB_STDOUT")
assert_contains "$OUT" 'status=delta' "the re-armed poll did not return a delta from the preserved cursor"
assert_contains "$OUT" 'hello after preemption' "the re-armed poll lost data appended around the preemption"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the re-armed poll could not be reaped"
rm -f -- "$REMOTE_HOME/$REPLY_LOG_REL"
pass "a poll re-armed after preemption reads the same cursor with nothing lost"

FM_REMOTE_JOB_TIMEOUT=15
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-remote-delta-read.sh "$REPLY_LOG_REL" 0 "$EMPTY_SHA" 6 < /dev/null > /dev/null
FIRST_JOB_ID=$FM_REMOTE_JOB_ID
FIRST_JOB_DIR="$STATE_ROOT/jobs/$FIRST_JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the first sibling poll did not begin running"
POLL_PAIR_BEGAN=$(date +%s)
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-remote-delta-read.sh "$REPLY_LOG_REL" 0 "$EMPTY_SHA" 1 < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
POLL_PAIR_ELAPSED=$(( $(date +%s) - POLL_PAIR_BEGAN ))
[ "$FM_REMOTE_JOB_EXIT" -eq 75 ] || fail "the first sibling poll did not close its own window"
[ "$POLL_PAIR_ELAPSED" -ge 4 ] || fail "a queued sibling poll preempted a running poll"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 75 ] || fail "the queued sibling poll did not run after the first window"
fm_remote_job_reap "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "the first sibling poll could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the queued sibling poll could not be reaped"
FM_REMOTE_JOB_QUEUE_TIMEOUT=5
pass "sibling polls never preempt each other into a re-arm churn loop"

STARTED="$TMP_ROOT/shutdown-started"
SHUTDOWN_SIDE_EFFECT="$TMP_ROOT/shutdown-side-effect"
FM_REMOTE_JOB_TIMEOUT=5
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-shutdown-job.sh "$STARTED" "$SHUTDOWN_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
for _ in $(seq 1 100); do
  [ -f "$STARTED" ] && break
  sleep 0.05
done
assert_present "$STARTED" "the shutdown fixture did not begin executing"
WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
kill -TERM "$WORKER_PID"
for _ in $(seq 1 100); do
  kill -0 "$WORKER_PID" 2>/dev/null || break
  sleep 0.05
done
kill -0 "$WORKER_PID" 2>/dev/null && fail "the worker did not finish its TERM shutdown"
HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_TIMEOUT=1 \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" >> "$TMP_ROOT/worker.out" 2>> "$TMP_ROOT/worker.err" &
for _ in $(seq 1 100); do
  [ -f "$STATE_ROOT/worker.ready" ] && break
  sleep 0.05
done
assert_present "$STATE_ROOT/worker.ready" "the replacement worker did not become ready"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 125 ] || fail "the interrupted job did not publish an unknown-completion result"
sleep 3
assert_absent "$SHUTDOWN_SIDE_EFFECT" "the active command mutated after worker shutdown"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the interrupted job could not be reaped"
pass "worker shutdown terminates the active command tree before replacement"

CRASH_STARTED="$TMP_ROOT/crash-started"
CRASH_SIDE_EFFECT="$TMP_ROOT/crash-side-effect"
FM_REMOTE_JOB_TIMEOUT=5
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-shutdown-job.sh "$CRASH_STARTED" "$CRASH_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
for _ in $(seq 1 100); do
  [ -f "$CRASH_STARTED" ] && break
  sleep 0.05
done
assert_present "$CRASH_STARTED" "the crash fixture did not begin executing"
CRASHED_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
kill -KILL "$CRASHED_WORKER_PID"
for _ in $(seq 1 200); do
  RESTARTED_WORKER_PID=$(cat "$STATE_ROOT/worker.pid" 2>/dev/null || true)
  [ -n "$RESTARTED_WORKER_PID" ] && [ "$RESTARTED_WORKER_PID" != "$CRASHED_WORKER_PID" ] && break
  sleep 0.05
done
[ -n "${RESTARTED_WORKER_PID:-}" ] && [ "$RESTARTED_WORKER_PID" != "$CRASHED_WORKER_PID" ] \
  || fail "the Linux supervisor did not restart a crashed worker"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 125 ] || fail "worker crash recovery did not publish unknown completion"
sleep 3
assert_absent "$CRASH_SIDE_EFFECT" "an orphaned command mutated after worker crash recovery"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the crash-recovered job could not be reaped"
fm_remote_job_probe "$ACCOUNT_HOME" || fail "the restarted worker did not remain ready"
pass "Linux supervision recovers crashes and stops orphaned commands"

mkdir -p "$ACCOUNT_HOME/.local/bin"
PREEXEC_STARTED="$TMP_ROOT/preexecution-started"
PREEXEC_FINISHED="$TMP_ROOT/preexecution-finished"
cat > "$ACCOUNT_HOME/.local/bin/git" <<SH
#!/bin/bash
if [ "\${3:-}" = ls-files ]; then
  printf 'started\n' > "$PREEXEC_STARTED"
  sleep 30
  printf 'finished\n' > "$PREEXEC_FINISHED"
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$ACCOUNT_HOME/.local/bin/git"
FM_REMOTE_JOB_TIMEOUT=3
PREEXEC_BEGAN=$(date +%s)
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-probe-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
PREEXEC_ELAPSED=$(( $(date +%s) - PREEXEC_BEGAN ))
[ "$FM_REMOTE_JOB_EXIT" -eq 124 ] || fail "the pre-execution deadline did not publish a timeout result"
assert_present "$PREEXEC_STARTED" "the pre-execution timeout fixture did not enter tracked-command validation"
assert_absent "$PREEXEC_FINISHED" "tracked-command validation continued after the job timeout"
[ "$PREEXEC_ELAPSED" -le 7 ] || fail "tracked-command validation exceeded the job timeout bound"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the pre-execution timeout leaked output readers or FIFOs"
rm -f -- "$ACCOUNT_HOME/.local/bin/git"
pass "pre-execution validation obeys the job timeout"

fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-output-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 23 ] || fail "bounded output changed the command exit status"
OUTPUT_BYTES=$(LC_ALL=C wc -c < "$FM_REMOTE_JOB_STDOUT" | tr -d ' ')
[ "$OUTPUT_BYTES" -le "$FM_REMOTE_JOB_MAX_BYTES" ] || fail "the worker retained output beyond its byte bound"
ERROR_BYTES=$(LC_ALL=C wc -c < "$FM_REMOTE_JOB_STDERR" | tr -d ' ')
[ "$ERROR_BYTES" -le "$FM_REMOTE_JOB_MAX_BYTES" ] || fail "the worker retained stderr beyond its byte bound"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the bounded-output job could not be reaped"
pass "the worker drains bounded output without changing command results"

SIDE_EFFECT="$TMP_ROOT/side-effect"
WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
fm_remote_job_stop_worker_tree "$WORKER_PID" \
  || fail "the worker tree did not stop before the staged-record tamper"
assert_absent "$STATE_ROOT/worker.pid" "the worker did not clear its pid before the staged-record tamper"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-touch-job.sh "$SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
rm -f -- "$JOB_DIR/argv"
ln -s "$TMP_ROOT/not-an-argv" "$JOB_DIR/argv"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 126 ] || fail "the worker accepted a symlinked argv record"
assert_absent "$SIDE_EFFECT" "the worker executed a job after its argv changed to a symlink"
pass "the worker refuses symlinked job fields before command execution"

QUARANTINE_STARTED="$TMP_ROOT/quarantine-started"
QUARANTINE_SIDE_EFFECT="$TMP_ROOT/quarantine-side-effect"
FM_REMOTE_JOB_TIMEOUT=5
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-shutdown-job.sh "$QUARANTINE_STARTED" "$QUARANTINE_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
for _ in $(seq 1 100); do
  [ -f "$QUARANTINE_STARTED" ] && break
  sleep 0.05
done
assert_present "$QUARANTINE_STARTED" "the quarantine fixture did not begin executing"
GROUP_PID=$(cat "$JOB_DIR/.claim/group")
printf 'invalid\n' > "$JOB_DIR/.claim/group"
WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
kill -TERM "$WORKER_PID"
wait "$WORKER_PID" 2>/dev/null || true
for _ in $(seq 1 100); do
  [ -f "$STATE_ROOT/worker.lock/quarantine" ] && break
  sleep 0.05
done
assert_present "$STATE_ROOT/worker.lock/quarantine" "failed shutdown released worker ownership"
fm_remote_job_probe "$ACCOUNT_HOME" && fail "quarantined worker ownership still reported ready"
set +e
HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  >> "$TMP_ROOT/worker.out" 2>> "$TMP_ROOT/worker.err"
REPLACEMENT_RC=$?
set -e
[ "$REPLACEMENT_RC" -ne 0 ] || fail "a replacement worker ignored quarantined ownership"
assert_present "$STATE_ROOT/worker.lock/quarantine" "a replacement removed quarantined ownership"
kill -KILL -- "-$GROUP_PID" 2>/dev/null || true
sleep 3
assert_absent "$QUARANTINE_SIDE_EFFECT" "the quarantined command mutated after explicit termination"
pass "failed shutdown quarantines ownership against replacement workers"

RECOVERY_HOME="$TMP_ROOT/recovery-account"
RECOVERY_STATE="$TMP_ROOT/recovery-jobs"
RECOVERY_JOB="$RECOVERY_STATE/jobs/job-quarantine"
mkdir -p "$RECOVERY_HOME" "$RECOVERY_STATE/jobs" "$RECOVERY_STATE/logs" \
  "$RECOVERY_STATE/worker.lock" "$RECOVERY_JOB/.claim"
chmod 700 "$RECOVERY_HOME" "$RECOVERY_STATE" "$RECOVERY_STATE/jobs" "$RECOVERY_STATE/logs" \
  "$RECOVERY_STATE/worker.lock" "$RECOVERY_JOB" "$RECOVERY_JOB/.claim"
sleep 20 &
QUARANTINED_PROCESS_PID=$!
sleep 0.01 &
QUARANTINE_OWNER_PID=$!
wait "$QUARANTINE_OWNER_PID" 2>/dev/null || true
printf '%s\n' "$QUARANTINE_OWNER_PID" > "$RECOVERY_STATE/worker.lock/pid"
printf 'stale\n' > "$RECOVERY_STATE/worker.lock/start"
printf 'stale\n' > "$RECOVERY_STATE/worker.lock/command"
printf 'active execution could not be confirmed stopped\n' > "$RECOVERY_STATE/worker.lock/quarantine"
printf 'running\n' > "$RECOVERY_JOB/state"
printf '%s\n' "$QUARANTINE_OWNER_PID" > "$RECOVERY_JOB/.claim/owner"
printf '%s\n' "$QUARANTINED_PROCESS_PID" > "$RECOVERY_JOB/.claim/supervisor"
: > "$RECOVERY_JOB/stdout"
: > "$RECOVERY_JOB/stderr"
chmod 600 "$RECOVERY_STATE/worker.lock"/* "$RECOVERY_JOB/state" "$RECOVERY_JOB/.claim"/* \
  "$RECOVERY_JOB/stdout" "$RECOVERY_JOB/stderr"
touch -t 200001010000 "$RECOVERY_STATE/worker.lock"
set +e
HOME="$RECOVERY_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RECOVERY_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/recovery-refused.out" 2> "$TMP_ROOT/recovery-refused.err"
RECOVERY_REFUSED_RC=$?
set -e
[ "$RECOVERY_REFUSED_RC" -ne 0 ] || fail "quarantine recovery ignored a recorded live process"
assert_present "$RECOVERY_STATE/worker.lock/quarantine" "a live recorded process lost quarantine protection"
printf '%s\n' "$QUARANTINED_PROCESS_PID" > "$RECOVERY_JOB/.claim/owner"
printf 'stale owner identity\n' > "$RECOVERY_JOB/.claim/owner_start"
printf 'stale supervisor identity\n' > "$RECOVERY_JOB/.claim/supervisor_start"
chmod 600 "$RECOVERY_JOB/.claim/owner" "$RECOVERY_JOB/.claim/owner_start" \
  "$RECOVERY_JOB/.claim/supervisor_start"
HOME="$RECOVERY_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RECOVERY_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" \
  > "$TMP_ROOT/recovery-worker.out" 2> "$TMP_ROOT/recovery-worker.err" &
RECOVERY_WORKER_PID=$!
for _ in $(seq 1 300); do
  [ -f "$RECOVERY_STATE/worker.ready" ] && break
  sleep 0.05
done
assert_present "$RECOVERY_STATE/worker.ready" "a reused supervisor pid did not permit worker recovery"
assert_absent "$RECOVERY_STATE/worker.lock/quarantine" "recovered worker retained stale quarantine"
kill -0 "$QUARANTINED_PROCESS_PID" 2>/dev/null \
  || fail "worker recovery signalled a process whose supervisor identity did not match"
kill -TERM "$RECOVERY_WORKER_PID"
wait "$RECOVERY_WORKER_PID" 2>/dev/null || true
RECOVERY_WORKER_PID=
kill "$QUARANTINED_PROCESS_PID" 2>/dev/null || true
wait "$QUARANTINED_PROCESS_PID" 2>/dev/null || true
pass "quarantine recovery refuses unverifiable supervisors and ignores reused pids"

# A replacement stops a Linux worker by signalling its whole isolated group, and
# the supervisor in that group forwards a second stop signal to the same serving
# child, so the serving child is always signalled more than once. Signal a small
# bounded burst and then keep signalling until it is gone: the first signal
# starts the shutdown and every later one lands inside it, the same way the group
# signal and the forwarded signal do. A shutdown that dies part way through
# leaves its ownership lock behind holding a half-written temp file no later
# worker can clear, and every replacement then fails to report ready.
#
# The burst is bounded and the follow-up signals are paced deliberately. An
# unpaced signal loop delivers hundreds of thousands of signals per second,
# which corrupts the signalled bash's own pending-trap bookkeeping ("warning:
# run_pending_traps: bad value in trap_list[15]") and then kills it part way
# through the shutdown with SIGTERM or SIGSEGV. That reports a shutdown defect
# this worker does not have. Ten back-to-back signals still all land inside the
# shutdown's first file operation, so the repeat this pins is unchanged: with
# the default disposition restored instead of ignored, the ownership lock is
# left behind every run.
REPEAT_HOME="$TMP_ROOT/repeat-signal-account"
REPEAT_STATE="$TMP_ROOT/repeat-signal-jobs"
mkdir -p "$REPEAT_HOME"
chmod 700 "$REPEAT_HOME"
HOME="$REPEAT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$REPEAT_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/repeat-signal.out" 2> "$TMP_ROOT/repeat-signal.err" &
REPEAT_WORKER_PID=$!
for _ in $(seq 1 300); do
  [ -f "$REPEAT_STATE/worker.ready" ] && break
  sleep 0.05
done
assert_present "$REPEAT_STATE/worker.ready" "the repeated-signal worker did not become ready"
REPEAT_DEADLINE=$((SECONDS + 30))
REPEAT_BURST=0
while [ "$REPEAT_BURST" -lt 10 ]; do
  kill -TERM "$REPEAT_WORKER_PID" 2>/dev/null || true
  REPEAT_BURST=$((REPEAT_BURST + 1))
done
while kill -0 "$REPEAT_WORKER_PID" 2>/dev/null && [ "$SECONDS" -lt "$REPEAT_DEADLINE" ]; do
  kill -TERM "$REPEAT_WORKER_PID" 2>/dev/null || true
  sleep 0.05
done
if kill -0 "$REPEAT_WORKER_PID" 2>/dev/null; then
  kill -KILL "$REPEAT_WORKER_PID" 2>/dev/null || true
  wait "$REPEAT_WORKER_PID" 2>/dev/null || true
  REPEAT_WORKER_PID=
  fail "the repeatedly signalled worker never finished its shutdown"
fi
wait "$REPEAT_WORKER_PID" 2>/dev/null || true
REPEAT_WORKER_PID=
assert_absent "$REPEAT_STATE/worker.lock" \
  "a repeatedly signalled shutdown left its ownership lock behind"
assert_absent "$REPEAT_STATE/worker.ready" \
  "a repeatedly signalled shutdown left its readiness heartbeat behind"
HOME="$REPEAT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$REPEAT_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  >> "$TMP_ROOT/repeat-signal.out" 2>> "$TMP_ROOT/repeat-signal.err" &
REPEAT_WORKER_PID=$!
for _ in $(seq 1 600); do
  [ -f "$REPEAT_STATE/worker.ready" ] && break
  sleep 0.05
done
assert_present "$REPEAT_STATE/worker.ready" \
  "the worker after a repeatedly signalled shutdown never reported ready"
kill -TERM "$REPEAT_WORKER_PID"
wait "$REPEAT_WORKER_PID" 2>/dev/null || true
REPEAT_WORKER_PID=
pass "a repeatedly signalled shutdown still releases ownership for the next worker"

# A child that stays up for FM_REMOTE_JOB_SUPERVISOR_HEALTHY_SECONDS clears the
# consecutive-failure backoff, so a child that dies just past that threshold
# used to reset the only guard the supervisor had and restart forever. The
# fixture below is that worker: it exits non-zero after living just longer than
# the healthy window, so every restart is accounted as healthy-then-failed.
RESTART_ROOT="$TMP_ROOT/restart-root"
RESTART_HOME="$TMP_ROOT/restart-account"
RESTART_STATE="$TMP_ROOT/restart-state"
RESTART_CHILD_LOG="$TMP_ROOT/restart-children"
mkdir -p "$RESTART_ROOT/bin" "$RESTART_HOME"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$RESTART_ROOT/bin/"
cp "$ROOT/bin/fm-remote-job-worker.sh" "$RESTART_ROOT/bin/fm-remote-job-supervisor-under-test.sh"
printf 'fixture\n' > "$RESTART_ROOT/AGENTS.md"
cat > "$RESTART_ROOT/bin/fm-remote-job-worker.sh" <<'SH'
#!/bin/bash
set -u
[ "${1:-}" = --serve ] || exit 2
printf '%s\n' "${BASHPID:-$$}" >> "$FM_TEST_SUPERVISOR_CHILD_LOG"
sleep "$FM_TEST_SUPERVISOR_CHILD_SECONDS"
exit "$FM_TEST_SUPERVISOR_CHILD_STATUS"
SH
chmod +x "$RESTART_ROOT/bin"/*.sh
HOME="$RESTART_HOME" FM_ROOT_OVERRIDE="$RESTART_ROOT" \
  FM_REMOTE_JOB_STATE_ROOT="$RESTART_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_SUPERVISOR_HEALTHY_SECONDS=1 FM_REMOTE_JOB_SUPERVISOR_MAX_RESTARTS=3 \
  FM_REMOTE_JOB_SUPERVISOR_MAX_BACKOFF_SECONDS=0 FM_TEST_SUPERVISOR_CHILD_LOG="$RESTART_CHILD_LOG" \
  FM_TEST_SUPERVISOR_CHILD_SECONDS=1.1 FM_TEST_SUPERVISOR_CHILD_STATUS=1 \
  "$RESTART_ROOT/bin/fm-remote-job-supervisor-under-test.sh" \
  > "$TMP_ROOT/restart-supervisor.out" 2> "$TMP_ROOT/restart-supervisor.err" &
RESTART_SUPERVISOR_PID=$!
for _ in $(seq 1 300); do
  kill -0 "$RESTART_SUPERVISOR_PID" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$RESTART_SUPERVISOR_PID" 2>/dev/null; then
  fail "workers dying just past the healthy threshold drove an unbounded restart loop"
fi
set +e
wait "$RESTART_SUPERVISOR_PID"
RESTART_SUPERVISOR_RC=$?
set -e
RESTART_SUPERVISOR_PID=
[ "$RESTART_SUPERVISOR_RC" -ne 0 ] || fail "the exhausted restart guard reported success"
[ "$(wc -l < "$RESTART_CHILD_LOG" | tr -d ' ')" -eq 3 ] \
  || fail "the restart guard did not stop at the configured maximum"
assert_grep "remote job worker exited 3 times; stopping the supervisor" "$TMP_ROOT/restart-supervisor.err" \
  "the restart guard did not explain why it stopped"
pass "barely healthy worker failures remain bounded by the restart guard"

# All remote entrypoints can race while creating first-use state and before a
# serving child publishes worker.pid. The lifetime lock admits one restart loop
# and separately recovers a stale owner.
RACE_ROOT="$TMP_ROOT/supervisor-race-root"
RACE_HOME="$TMP_ROOT/supervisor-race-home"
RACE_STATE="$TMP_ROOT/supervisor-race-state"
RACE_PID_LOG="$TMP_ROOT/supervisor-race-pids"
RACE_SUPERVISOR="$RACE_ROOT/bin/fm-remote-job-supervisor-under-test.sh"
mkdir -p "$RACE_ROOT/bin" "$RACE_HOME"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$RACE_ROOT/bin/"
cp "$RACE_ROOT/bin/fm-remote-job-worker.sh" "$RACE_SUPERVISOR"
printf 'fixture\n' > "$RACE_ROOT/AGENTS.md"
git -C "$RACE_ROOT" init -q -b main
git -C "$RACE_ROOT" config user.email test@example.com
git -C "$RACE_ROOT" config user.name Test
git -C "$RACE_ROOT" add AGENTS.md bin
git -C "$RACE_ROOT" commit -qm 'remote supervisor fixture'
cat > "$RACE_ROOT/bin/fm-remote-job-worker.sh" <<'SH'
#!/bin/bash
case "${1:-}" in
  --serve) sleep 4; exit 1 ;;
  '') printf '%s\n' "$$" >> "$FM_TEST_SUPERVISOR_PID_LOG"; sleep 1; exec "$(dirname "$0")/fm-remote-job-supervisor-under-test.sh" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$RACE_ROOT/bin/fm-remote-job-worker.sh" "$RACE_SUPERVISOR"
RACE_RELEASE_BIN="$TMP_ROOT/supervisor-release-bin"
RACE_RELEASE_READY="$TMP_ROOT/supervisor-release-ready"
RACE_RELEASE_CONTINUE="$TMP_ROOT/supervisor-release-continue"
mkdir -p "$RACE_RELEASE_BIN"
cat > "$RACE_RELEASE_BIN/rm" <<'SH'
#!/bin/bash
for path do
  if [ "$path" = "$FM_TEST_SUPERVISOR_OWNER_PATH" ]; then
    printf 'ready\n' > "$FM_TEST_SUPERVISOR_RELEASE_READY"
    while [ ! -e "$FM_TEST_SUPERVISOR_RELEASE_CONTINUE" ]; do sleep 0.05; done
    break
  fi
done
exec /bin/rm "$@"
SH
chmod +x "$RACE_RELEASE_BIN/rm"
export FM_TEST_SUPERVISOR_PID_LOG="$RACE_PID_LOG"
set -m
for index in $(seq 1 12); do
  PATH="$RACE_RELEASE_BIN:$PATH" \
    FM_TEST_SUPERVISOR_OWNER_PATH="$RACE_STATE/supervisor.lock/owner" \
    FM_TEST_SUPERVISOR_RELEASE_READY="$RACE_RELEASE_READY" \
    FM_TEST_SUPERVISOR_RELEASE_CONTINUE="$RACE_RELEASE_CONTINUE" \
    HOME="$RACE_HOME" FM_ROOT_OVERRIDE="$RACE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RACE_STATE" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$RACE_ROOT/bin/fm-remote-job-worker.sh" \
    > "$TMP_ROOT/race-supervisor-$index.out" 2>&1 &
  RACE_SUPERVISOR_PIDS+=("$!")
done
set +m
for _ in $(seq 1 100); do
  if [ -f "$RACE_PID_LOG" ] && [ "$(wc -l < "$RACE_PID_LOG" | tr -d ' ')" -eq 12 ]; then break; fi
  sleep 0.05
done
assert_present "$RACE_PID_LOG" "the concurrent-start reproduction did not start any supervisor"
[ "$(wc -l < "$RACE_PID_LOG" | tr -d ' ')" -eq 12 ] \
  || fail "the concurrent-start reproduction did not launch all requested supervisor attempts"
[ "${#RACE_SUPERVISOR_PIDS[@]}" -eq 12 ] \
  || fail "the concurrent-start reproduction did not launch all requested supervisor attempts"
RACE_ACTIVE_SUPERVISORS=0
RACE_ACTIVE_SUPERVISOR_PID=
for _ in $(seq 1 100); do
  RACE_ACTIVE_SUPERVISORS=0
  RACE_ACTIVE_SUPERVISOR_PID=
  for pid in "${RACE_SUPERVISOR_PIDS[@]}"; do
    command=$(fm_remote_job_process_command "$pid" 2>/dev/null || true)
    case "$command" in
      *"$RACE_SUPERVISOR")
        RACE_ACTIVE_SUPERVISORS=$((RACE_ACTIVE_SUPERVISORS + 1))
        RACE_ACTIVE_SUPERVISOR_PID=$pid
        ;;
    esac
  done
  [ "$RACE_ACTIVE_SUPERVISORS" -eq 1 ] && break
  sleep 0.1
done
[ "$RACE_ACTIVE_SUPERVISORS" -eq 1 ] \
  || fail "concurrent Linux starts left $RACE_ACTIVE_SUPERVISORS active restart supervisors"
pass "concurrent Linux starts admit one restart supervisor per account queue"
for _ in $(seq 1 10); do
  kill -TERM "$RACE_ACTIVE_SUPERVISOR_PID" 2>/dev/null || true
done
for _ in $(seq 1 100); do
  [ -f "$RACE_RELEASE_READY" ] && break
  sleep 0.05
done
assert_present "$RACE_RELEASE_READY" "the exiting supervisor did not reach owner release"
RACE_PID_LOG_LINES=$(wc -l < "$RACE_PID_LOG" | tr -d ' ')
set -m
HOME="$RACE_HOME" FM_ROOT_OVERRIDE="$RACE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RACE_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$RACE_ROOT/bin/fm-remote-job-worker.sh" \
  > "$TMP_ROOT/release-contender.out" 2>&1 &
RACE_RELEASE_CONTENDER_PID=$!
RACE_SUPERVISOR_PIDS+=("$RACE_RELEASE_CONTENDER_PID")
set +m
for _ in $(seq 1 100); do
  [ "$(wc -l < "$RACE_PID_LOG" | tr -d ' ')" -ge "$((RACE_PID_LOG_LINES + 1))" ] && break
  sleep 0.05
done
[ "$(wc -l < "$RACE_PID_LOG" | tr -d ' ')" -ge "$((RACE_PID_LOG_LINES + 1))" ] \
  || fail "the replacement did not reach the releasing supervisor"
RACE_RELEASE_CONTENDER_COMMAND=
for _ in $(seq 1 100); do
  RACE_RELEASE_CONTENDER_COMMAND=$(fm_remote_job_process_command "$RACE_RELEASE_CONTENDER_PID" 2>/dev/null || true)
  case "$RACE_RELEASE_CONTENDER_COMMAND" in
    *"$RACE_SUPERVISOR") break ;;
    *"$RACE_ROOT/bin/fm-remote-job-worker.sh") ;;
    *) break ;;
  esac
  sleep 0.05
done
case "$RACE_RELEASE_CONTENDER_COMMAND" in
  *"$RACE_SUPERVISOR") ;;
  *) fail "the replacement exited instead of waiting for supervisor release" ;;
esac
[ "$(head -n 1 "$RACE_STATE/supervisor.lock/owner" 2>/dev/null || true)" = "$RACE_ACTIVE_SUPERVISOR_PID" ] \
  || fail "the exiting supervisor lost ownership before release completed"
: > "$RACE_RELEASE_CONTINUE"
for pid in "${RACE_SUPERVISOR_PIDS[@]}"; do
  [ "$pid" = "$RACE_RELEASE_CONTENDER_PID" ] && continue
  wait "$pid" 2>/dev/null || true
done
RACE_RELEASE_OWNER_PID=
for _ in $(seq 1 100); do
  RACE_RELEASE_OWNER_PID=$(head -n 1 "$RACE_STATE/supervisor.lock/owner" 2>/dev/null || true)
  [ "$RACE_RELEASE_OWNER_PID" = "$RACE_RELEASE_CONTENDER_PID" ] && break
  sleep 0.05
done
[ "$RACE_RELEASE_OWNER_PID" = "$RACE_RELEASE_CONTENDER_PID" ] \
  || fail "the replacement did not claim ownership after the prior supervisor exited"
command=$(fm_remote_job_process_command "$RACE_RELEASE_CONTENDER_PID" 2>/dev/null || true)
case "$command" in *"$RACE_SUPERVISOR") ;; *) fail "the replacement exited after claiming ownership" ;; esac
pass "guard contention starts a replacement after owner release"
kill -TERM "$RACE_RELEASE_CONTENDER_PID" 2>/dev/null || true
wait "$RACE_RELEASE_CONTENDER_PID" 2>/dev/null || true
assert_absent "$RACE_STATE/supervisor.lock" "the replacement left stale supervisor ownership"
RACE_SUPERVISOR_PIDS=()
mkdir -m 700 "$RACE_STATE/supervisor.lock"
printf '2147483646\nstale start\nstale command\n' > "$RACE_STATE/supervisor.lock/owner"
chmod 600 "$RACE_STATE/supervisor.lock/owner"
touch -t 200001010000 "$RACE_STATE/supervisor.lock"
HOME="$RACE_HOME" FM_ROOT_OVERRIDE="$RACE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RACE_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$RACE_ROOT/bin/fm-remote-job-worker.sh" \
  > "$TMP_ROOT/stale-supervisor.out" 2>&1 &
RACE_STALE_SUPERVISOR_PID=$!
RACE_SUPERVISOR_PIDS+=("$RACE_STALE_SUPERVISOR_PID")
for _ in $(seq 1 100); do
  owner_pid=$(head -n 1 "$RACE_STATE/supervisor.lock/owner" 2>/dev/null || true)
  [ "$owner_pid" = "$RACE_STALE_SUPERVISOR_PID" ] && break
  sleep 0.05
done
[ "$owner_pid" = "$RACE_STALE_SUPERVISOR_PID" ] \
  || fail "the supervisor did not recover a stale lock: $(<"$TMP_ROOT/stale-supervisor.out")"
command=$(fm_remote_job_process_command "$RACE_STALE_SUPERVISOR_PID" 2>/dev/null || true)
case "$command" in *"$RACE_SUPERVISOR") ;; *) fail "stale owner record does not match a live supervisor" ;; esac
pass "a supervisor reclaims stale ownership after an abnormal exit"
kill -TERM "$RACE_STALE_SUPERVISOR_PID" 2>/dev/null || true
wait "$RACE_STALE_SUPERVISOR_PID" 2>/dev/null || true
assert_absent "$RACE_STATE/supervisor.lock" "stale-lock fixture left supervisor ownership behind: $(<"$TMP_ROOT/stale-supervisor.out") owner=$(head -n 1 "$RACE_STATE/supervisor.lock/owner" 2>/dev/null || true)"
RACE_SUPERVISOR_PIDS=()
mkdir -m 700 "$RACE_STATE/supervisor.lock"
touch -t 200001010000 "$RACE_STATE/supervisor.lock"
HOME="$RACE_HOME" FM_ROOT_OVERRIDE="$RACE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RACE_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$RACE_ROOT/bin/fm-remote-job-worker.sh" \
  > "$TMP_ROOT/ownerless-supervisor.out" 2>&1 &
RACE_OWNERLESS_SUPERVISOR_PID=$!
RACE_SUPERVISOR_PIDS+=("$RACE_OWNERLESS_SUPERVISOR_PID")
for _ in $(seq 1 100); do
  owner_pid=$(head -n 1 "$RACE_STATE/supervisor.lock/owner" 2>/dev/null || true)
  [ "$owner_pid" = "$RACE_OWNERLESS_SUPERVISOR_PID" ] && break
  sleep 0.05
done
[ "$owner_pid" = "$RACE_OWNERLESS_SUPERVISOR_PID" ] \
  || fail "the supervisor did not recover an aged ownerless lock: $(<"$TMP_ROOT/ownerless-supervisor.out")"
command=$(fm_remote_job_process_command "$RACE_OWNERLESS_SUPERVISOR_PID" 2>/dev/null || true)
case "$command" in *"$RACE_SUPERVISOR") ;; *) fail "recovered ownerless lock does not match a live supervisor" ;; esac
pass "a supervisor reclaims an aged ownerless lock after publication grace"
kill -TERM "$RACE_OWNERLESS_SUPERVISOR_PID" 2>/dev/null || true
wait "$RACE_OWNERLESS_SUPERVISOR_PID" 2>/dev/null || true
assert_absent "$RACE_STATE/supervisor.lock" "ownerless-lock fixture left supervisor ownership behind"
RACE_SUPERVISOR_PIDS=()

RACE_SLOW_BIN="$TMP_ROOT/supervisor-slow-bin"
RACE_PUBLISH_READY="$TMP_ROOT/supervisor-publish-ready"
RACE_PUBLISH_RELEASE="$TMP_ROOT/supervisor-publish-release"
mkdir -p "$RACE_SLOW_BIN"
cat > "$RACE_SLOW_BIN/ln" <<'SH'
#!/bin/bash
printf 'ready\n' > "$FM_TEST_LOCK_PUBLISHER_READY"
while [ ! -e "$FM_TEST_LOCK_PUBLISHER_RELEASE" ]; do sleep 0.05; done
exec /bin/ln "$@"
SH
chmod +x "$RACE_SLOW_BIN/ln"
RACE_PID_LOG_LINES=$(wc -l < "$RACE_PID_LOG" | tr -d ' ')
set -m
PATH="$RACE_SLOW_BIN:$PATH" \
  FM_TEST_LOCK_PUBLISHER_READY="$RACE_PUBLISH_READY" \
  FM_TEST_LOCK_PUBLISHER_RELEASE="$RACE_PUBLISH_RELEASE" \
  HOME="$RACE_HOME" FM_ROOT_OVERRIDE="$RACE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RACE_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$RACE_ROOT/bin/fm-remote-job-worker.sh" \
  > "$TMP_ROOT/paused-publisher.out" 2>&1 &
RACE_PAUSED_SUPERVISOR_PID=$!
RACE_SUPERVISOR_PIDS+=("$RACE_PAUSED_SUPERVISOR_PID")
set +m
for _ in $(seq 1 100); do
  [ -f "$RACE_PUBLISH_READY" ] && break
  sleep 0.05
done
assert_present "$RACE_PUBLISH_READY" "the supervisor did not reach owner publication"
touch -t 200001010000 "$RACE_STATE/supervisor.lock"
HOME="$RACE_HOME" FM_ROOT_OVERRIDE="$RACE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RACE_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$RACE_ROOT/bin/fm-remote-job-worker.sh" \
  > "$TMP_ROOT/reclaimer-publisher.out" 2>&1 &
RACE_RECLAIMER_PID=$!
RACE_SUPERVISOR_PIDS+=("$RACE_RECLAIMER_PID")
for _ in $(seq 1 100); do
  [ "$(wc -l < "$RACE_PID_LOG" | tr -d ' ')" -ge "$((RACE_PID_LOG_LINES + 2))" ] && break
  sleep 0.05
done
[ "$(wc -l < "$RACE_PID_LOG" | tr -d ' ')" -ge "$((RACE_PID_LOG_LINES + 2))" ] \
  || fail "the second supervisor did not reach the lock race"
RACE_RECLAIMER_COMMAND=
for _ in $(seq 1 100); do
  RACE_RECLAIMER_COMMAND=$(fm_remote_job_process_command "$RACE_RECLAIMER_PID" 2>/dev/null || true)
  case "$RACE_RECLAIMER_COMMAND" in
    *"$RACE_SUPERVISOR") break ;;
    *"$RACE_ROOT/bin/fm-remote-job-worker.sh") ;;
    *) break ;;
  esac
  sleep 0.05
done
case "$RACE_RECLAIMER_COMMAND" in
  *"$RACE_SUPERVISOR") ;;
  *) fail "the competing startup exited instead of waiting for publication" ;;
esac
assert_absent "$RACE_STATE/supervisor.lock/owner" "the publisher lost its claim before publication"
: > "$RACE_PUBLISH_RELEASE"
for _ in $(seq 1 100); do
  owner_pid=$(head -n 1 "$RACE_STATE/supervisor.lock/owner" 2>/dev/null || true)
  [ "$owner_pid" = "$RACE_PAUSED_SUPERVISOR_PID" ] && break
  sleep 0.05
done
[ "$owner_pid" = "$RACE_PAUSED_SUPERVISOR_PID" ] || fail "the paused publisher did not retain the lock"
wait "$RACE_RECLAIMER_PID" 2>/dev/null || fail "the competing startup did not verify its owner"
[ "$(head -n 1 "$RACE_STATE/supervisor.lock/owner")" = "$RACE_PAUSED_SUPERVISOR_PID" ] \
  || fail "the competing startup removed the published owner"
command=$(fm_remote_job_process_command "$RACE_PAUSED_SUPERVISOR_PID" 2>/dev/null || true)
case "$command" in *"$RACE_SUPERVISOR") ;; *) fail "the paused publisher did not remain the active supervisor" ;; esac
pass "stale reclamation cannot remove a live supervisor claim"
kill -TERM "$RACE_PAUSED_SUPERVISOR_PID" 2>/dev/null || true
wait "$RACE_PAUSED_SUPERVISOR_PID" 2>/dev/null || true
assert_absent "$RACE_STATE/supervisor.lock" "publisher-race fixture left supervisor ownership behind"
RACE_SUPERVISOR_PIDS=()
unset FM_TEST_SUPERVISOR_PID_LOG

# Cleanup must refuse before touching any queue with a live lane. The active-job
# guard is portable even though process consolidation itself needs Linux /proc.
CLEANUP_TEST_STATE="$RACE_STATE"
CLEANUP_JOB="$RACE_STATE/jobs/job-cleanup-active"
cp "$ROOT/bin/fm-remote-job-worker.sh" "$RACE_ROOT/bin/fm-remote-job-worker.sh"
sleep 30 &
CLEANUP_TEST_LANE=$!
CLEANUP_LANE_PIDS+=("$CLEANUP_TEST_LANE")
mkdir -p "$CLEANUP_JOB/.claim"
printf 'running\n' > "$CLEANUP_JOB/state"
printf '%s\n' "$CLEANUP_TEST_LANE" > "$CLEANUP_JOB/.claim/owner"
fm_remote_job_process_start "$CLEANUP_TEST_LANE" > "$CLEANUP_JOB/.claim/owner_start" \
  || fail "could not record the active lane identity"
chmod 700 "$CLEANUP_JOB" "$CLEANUP_JOB/.claim"
chmod 600 "$CLEANUP_JOB/state" "$CLEANUP_JOB/.claim/owner" "$CLEANUP_JOB/.claim/owner_start"
set +e
cleanup_out=$(HOME="$RACE_HOME" FM_ROOT_OVERRIDE="$RACE_ROOT" \
  FM_REMOTE_JOB_STATE_ROOT="$RACE_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$RACE_ROOT/bin/fm-remote-job-worker.sh" --cleanup 2>&1)
cleanup_rc=$?
set -e
[ "$cleanup_rc" -eq 75 ] \
  || fail "cleanup did not refuse a live lane (exit=$cleanup_rc): $cleanup_out"
assert_contains "$cleanup_out" 'refusing cleanup while job job-cleanup-active has a live lane' \
  "cleanup did not explain its active-lane refusal"
set +e
cleanup_override_out=$(HOME="$RACE_HOME" FM_ROOT_OVERRIDE="$RACE_ROOT" \
  FM_REMOTE_JOB_STATE_ROOT="$RACE_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$RACE_ROOT/bin/fm-remote-job-worker.sh" --cleanup --allow-active 2>&1)
cleanup_override_rc=$?
set -e
[ "$cleanup_override_rc" -eq 2 ] \
  || fail "cleanup accepted the removed interruption option: $cleanup_override_out"
kill -0 "$CLEANUP_TEST_LANE" 2>/dev/null || fail "cleanup killed a lane after refusing its active job"
assert_contains "$(<"$CLEANUP_JOB/state")" 'running' "cleanup changed the interrupted job record"
rm -rf -- "$CLEANUP_JOB"
kill "$CLEANUP_TEST_LANE" 2>/dev/null || true
wait "$CLEANUP_TEST_LANE" 2>/dev/null || true
CLEANUP_LANE_PIDS=()
pass "cleanup refuses to signal a lane while its job is active"

# On Linux, consolidation proves one healthy current worker and stops only old
# supervisors whose process environments bind them to this account queue.
if [ "$(uname -s)" = Linux ]; then
  CLEANUP_PID_LOG="$TMP_ROOT/cleanup-supervisor-pids"
  CLEANUP_LANE_LOG="$TMP_ROOT/cleanup-lane-pids"
  cat > "$RACE_ROOT/bin/fm-remote-job-worker.sh" <<'SH'
#!/bin/bash
case "${1:-}" in
  --lane)
    printf '%s\n' "$$" >> "$FM_TEST_CLEANUP_LANE_LOG"
    exec sleep 30
    ;;
  '')
    printf '%s\n' "$$" >> "$FM_TEST_CLEANUP_SUPERVISOR_LOG"
    "$0" --lane cleanup-active &
    wait "$!" 2>/dev/null || true
    while :; do "$0" --lane extra & wait "$!" 2>/dev/null || true; done
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$RACE_ROOT/bin/fm-remote-job-worker.sh"
  export FM_TEST_CLEANUP_LANE_LOG="$CLEANUP_LANE_LOG"
  export FM_TEST_CLEANUP_SUPERVISOR_LOG="$CLEANUP_PID_LOG"
  set -m
  HOME="$RACE_HOME" FM_ROOT_OVERRIDE="$RACE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RACE_STATE" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$RACE_ROOT/bin/fm-remote-job-worker.sh" \
    > "$TMP_ROOT/cleanup-old-1.out" 2>&1 &
  CLEANUP_OLD_1=$!
  HOME="$RACE_HOME" FM_ROOT_OVERRIDE="$RACE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RACE_STATE" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$RACE_ROOT/bin/fm-remote-job-worker.sh" \
    > "$TMP_ROOT/cleanup-old-2.out" 2>&1 &
  CLEANUP_OLD_2=$!
  set +m
  CLEANUP_SUPERVISOR_PIDS+=("$CLEANUP_OLD_1" "$CLEANUP_OLD_2")
  for _ in $(seq 1 100); do
    if [ -f "$CLEANUP_LANE_LOG" ] && [ "$(wc -l < "$CLEANUP_LANE_LOG" | tr -d ' ')" -ge 2 ]; then break; fi
    sleep 0.05
  done
  assert_present "$CLEANUP_LANE_LOG" "the legacy cleanup fixtures did not start their lane processes"
  while IFS= read -r pid; do
    [ -n "$pid" ] && CLEANUP_LANE_PIDS+=("$pid")
  done < "$CLEANUP_LANE_LOG"
  [ "${#CLEANUP_LANE_PIDS[@]}" -ge 2 ] || fail "both legacy supervisor lanes did not start"
  cp "$ROOT/bin/fm-remote-job-worker.sh" "$RACE_ROOT/bin/fm-remote-job-worker.sh"
  cleanup_out=$(HOME="$RACE_HOME" FM_ROOT_OVERRIDE="$RACE_ROOT" \
    FM_REMOTE_JOB_STATE_ROOT="$RACE_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    "$RACE_ROOT/bin/fm-remote-job-worker.sh" --cleanup 2>&1) \
    || fail "cleanup could not retain one healthy worker: $cleanup_out"
  cleanup_stopped=$(printf '%s\n' "$cleanup_out" | grep -c '^stopped surplus remote job supervisor ' || true)
  [ "$cleanup_stopped" -eq 2 ] \
    || fail "cleanup stopped $cleanup_stopped legacy supervisors instead of both: $cleanup_out"
  for pid in "$CLEANUP_OLD_1" "$CLEANUP_OLD_2" "${CLEANUP_LANE_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
    kill -0 "$pid" 2>/dev/null && fail "cleanup left legacy worker process $pid alive"
  done
  worker_supervisor=$(head -n 1 "$RACE_STATE/supervisor.lock/owner")
  CLEANUP_SUPERVISOR_PIDS+=("$worker_supervisor")
  [ "$(cat "$RACE_STATE/worker.identity")" != '' ] \
    || fail "cleanup left no current worker identity"
  worker_pid=$(cat "$RACE_STATE/worker.pid")
  fm_remote_job_stop_worker_tree "$worker_pid" || fail "the cleanup fixture's retained worker did not stop"
  CLEANUP_SUPERVISOR_PIDS=()
  CLEANUP_LANE_PIDS=()
  unset FM_TEST_CLEANUP_LANE_LOG FM_TEST_CLEANUP_SUPERVISOR_LOG
  pass "Linux cleanup stops surplus supervisors and keeps one healthy worker"
fi

echo "ALL TESTS PASSED"
