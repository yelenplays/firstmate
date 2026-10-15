#!/usr/bin/env bash
# Drive the real fm-jev.sh against the production TypeSafe endpoint inside a lab FM_HOME.
# The key is read from the fleet .env into this process's env only; it is never written.
set -u
LAB=$1
cd /Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M50BACA26BSQG5MZZV0FY8XY
. bin/fm-env-lib.sh
TYPESAFE_API_KEY=$(fmx_env_get TYPESAFE_API_KEY "$HOME/github/firstmate/.env")
export TYPESAFE_API_KEY
export FM_HOME=$LAB
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
run() { echo "\$ $*"; "$@"; echo "[exit $?]"; echo; }
echo "== S1: yes question from a dispatched task (FM_TASK_ID=lab-demo-v1)"
FM_TASK_ID=lab-demo-v1 run bin/fm-jev.sh yes "A shell script test suite passed with zero failures and the diff only touches docs." "Is the change safe to merge?"
echo "== S2: no task id -> caller is the logging home"
FM_TASK_ID= run bin/fm-jev.sh pick "The task edits a CSS stylesheet for a button colour." "Which area does this task touch?" "frontend=web UI styling" "backend=server API" "infra=CI and deploy"
echo "== S3: batch of pick, score, yes"
FM_TASK_ID=lab-demo-v1 run bin/fm-jev.sh batch <<'JSON'
{"state":"A one-line typo fix in README.md, reviewed and CI green.","questions":[{"id":"area","type":"pick","q":"Which area?","opts":["docs","code","infra"]},{"id":"size","type":"score","q":"How large is the change?","opts":["tiny","small","medium","large"]},{"id":"ok","type":"yes","q":"Can it merge without captain review?"}]}
JSON
echo "== S4: pick with nine options is refused before sending"
FM_TASK_ID=lab-demo-v1 run bin/fm-jev.sh pick "s" "Choose one?" o1 o2 o3 o4 o5 o6 o7 o8 o9
echo "== S4b: batch pick with nine options is refused"
FM_TASK_ID=lab-demo-v1 run bin/fm-jev.sh batch <<'JSON'
{"state":"s","questions":[{"id":"wide","type":"pick","q":"Choose one?","opts":["o1","o2","o3","o4","o5","o6","o7","o8","o9"]}]}
JSON
echo "== S5: pick with exactly eight options is sent and answered"
FM_TASK_ID=lab-demo-v1 run bin/fm-jev.sh pick "The bug is a null pointer in the Rust parser module." "Which language is the bug in?" rust go python java ruby swift kotlin php
echo "== jev-calls.jsonl in the lab home (one record per attempted call)"
jq -c . "$LAB/state/jev-calls.jsonl"
