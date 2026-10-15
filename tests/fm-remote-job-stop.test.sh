#!/usr/bin/env bash
# Stop waits must follow the selected target: the verified group or one pid.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-job-stop)
GROUP_PID=
SINGLE_PID=
cleanup_stop_fixture() {
  [ -z "$GROUP_PID" ] || kill -KILL -- "-$GROUP_PID" 2>/dev/null || true
  [ -z "$SINGLE_PID" ] || kill -KILL "$SINGLE_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_stop_fixture EXIT

# The serving child exits on TERM before its supervisor finishes shutdown.
# The supervisor's marker proves it received its graceful shutdown window,
# rather than being killed as soon as the serving pid disappeared.
cat > "$TMP_ROOT/fm-remote-job-worker.sh" <<'SH'
#!/bin/bash
trap 'sleep 1; printf "stopped\n" > "$2"; exit 0' TERM
sleep 30 &
printf '%s\n' "$!" > "$1"
wait "$!"
SH
set -m
bash "$TMP_ROOT/fm-remote-job-worker.sh" "$TMP_ROOT/child.pid" "$TMP_ROOT/stopped" &
GROUP_PID=$!
set +m
for ((i = 0; i < 100; i++)); do
  [ -s "$TMP_ROOT/child.pid" ] && break
  sleep 0.05
done
assert_present "$TMP_ROOT/child.pid" "the serving child did not start"
IFS= read -r CHILD_PID < "$TMP_ROOT/child.pid"
[ "$(fm_remote_job_worker_process_group "$CHILD_PID")" = "$GROUP_PID" ] \
  || fail "the fixture does not reproduce an isolated worker group"
fm_remote_job_stop_worker_tree "$CHILD_PID" \
  || fail "stop refused after the serving child exited before its supervisor"
wait "$GROUP_PID" || fail "the supervisor did not finish gracefully"
assert_present "$TMP_ROOT/stopped" "stop killed the supervisor before its graceful shutdown finished"
! kill -0 -- "-$GROUP_PID" 2>/dev/null || fail "stop left a worker group alive"
GROUP_PID=
pass "stop waits for the whole worker group after its serving child exits"

sleep 30 &
SINGLE_PID=$!
! fm_remote_job_worker_process_group "$SINGLE_PID" >/dev/null \
  || fail "the single-process fixture unexpectedly has a worker group"
fm_remote_job_stop_worker_tree "$SINGLE_PID" || fail "stop refused the single-process fallback"
wait "$SINGLE_PID" 2>/dev/null || true
! kill -0 "$SINGLE_PID" 2>/dev/null || fail "stop left the single process alive"
SINGLE_PID=
pass "stop still handles a worker without a verified isolated group"
