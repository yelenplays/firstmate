#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
. "$SCRIPT_DIR/fm-pr-lib.sh"
. "$SCRIPT_DIR/fm-wake-lib.sh"

rearm_one() (
  id=$1
  fm_pr_task_id_valid "$id" || exit 1
  control="$STATE/.control-$id.lock"
  publish="$STATE/.pr-poll-publish-$id.lock"
  control_held=0
  publish_held=0
  cleanup() {
    fm_pr_poll_cleanup
    [ "$publish_held" = 0 ] || fm_lock_release "$publish" || true
    [ "$control_held" = 0 ] || fm_lock_release "$control" || true
  }
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM
  fm_lock_acquire_wait "$control"
  control_held=1
  fm_lock_acquire_wait "$publish"
  publish_held=1
  template="$SCRIPT_DIR/fm-pr-poll.sh"
  fm_pr_poll_retirement_recover_one "$STATE" "$id" "$template" || exit 1
  [ -e "$STATE/$id.pr-poll-registration" ] || exit 0
  fm_pr_poll_artifacts_valid "$STATE" "$id" "$template" && exit 0
  fm_pr_poll_artifacts_valid "$STATE" "$id" "$STATE/$id.check.sh" || exit 1
  fm_pr_poll_prepare "$STATE" "$id" "$FM_PR_DATA_PROVIDER" "$FM_PR_DATA_URL" \
    "$FM_PR_DATA_HOST" "$FM_PR_DATA_PATH" "$FM_PR_DATA_NUMBER" "$template" || exit 1
  fm_pr_poll_publish_prepared || exit 1
)

[ ! -L "$STATE" ] || exit 1
[ -d "$STATE" ] || exit 0
failed=0
for registration in "$STATE"/*.pr-poll-registration; do
  [ -e "$registration" ] || [ -L "$registration" ] || continue
  id=${registration##*/}
  id=${id%.pr-poll-registration}
  if ! rearm_one "$id"; then
    printf 'error: could not refresh merge watch %s\n' "$id" >&2
    failed=1
  fi
done
exit "$failed"
