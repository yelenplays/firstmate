#!/usr/bin/env bash
# Present a worker done: line through the real fm-wake-drain.sh in a fresh lab FM_HOME,
# with a real Jev key available, and report whether any shadow done-verify record or Jev call appears.
set -u
TREE=$1; LABHOME=$2; LABEL=$3
WT=/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M50BACA26BSQG5MZZV0FY8XY
"$WT/bin/fm-lab-home.sh" create "$LABHOME" >/dev/null || exit 1
. "$WT/bin/fm-env-lib.sh"
TYPESAFE_API_KEY=$(fmx_env_get TYPESAFE_API_KEY "$HOME/github/firstmate/.env"); export TYPESAFE_API_KEY
printf 'kind=ship\nproject=%s\n' "$WT" > "$LABHOME/state/ship-fix.meta"
printf 'done: pager off-by-one fixed\n' > "$LABHOME/state/ship-fix.status"
echo "== $LABEL: \$ FM_HOME=\$LAB bin/fm-wake-drain.sh   (state/ship-fix.status = 'done: pager off-by-one fixed')"
cd "$WT"
FM_HOME="$LABHOME" "$TREE/bin/fm-wake-drain.sh" 2>&1 | sed "s#$LABHOME#\$LAB#g"; echo "[exit ${PIPESTATUS[0]}]"
sleep 8   # the retired shadow verifier ran detached after presentation
echo "-- jev-done records:"; ls "$LABHOME/state/"*.jev-done.jsonl 2>/dev/null | sed "s#$LABHOME#\$LAB#g" || true
for f in "$LABHOME/state/"*.jev-done.jsonl; do [ -f "$f" ] && jq -c '{purpose, verdict, close, teardown}' "$f"; done
echo "-- jev-calls.jsonl rows: $(cat "$LABHOME/state/jev-calls.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
echo "-- status file after drain:"; cat "$LABHOME/state/ship-fix.status"
echo
