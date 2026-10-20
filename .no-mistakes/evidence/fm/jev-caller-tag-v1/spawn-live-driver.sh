#!/usr/bin/env bash
set -u
ROOT=$PWD
E=/Users/yelen/.no-mistakes/evidence/01M5CZV2BFMDEMPV25T2MSFEWK
export FM_HERDR_LAB_STATE_DIR="$ROOT/.test-tmp/herdr-lab-state"
SESSION=$(bin/fm-herdr-lab.sh name no-skill)
LAB="$ROOT/.test-tmp/spawn-live-home"
PROJ="$ROOT/.test-tmp/live-project"
cleanup() {
  if [ -f "$FM_HERDR_LAB_STATE_DIR/$SESSION.fleet-state.json" ]; then
    bin/fm-herdr-lab.sh teardown "$SESSION"
    echo "teardown_exit=$?"
  fi
}
trap cleanup EXIT
# provision performs prepare itself for a fresh session.
bin/fm-herdr-lab.sh provision "$SESSION" || exit 20
bin/fm-lab-home.sh create "$LAB" || exit 21
touch "$LAB/config/supervision-host"
printf 'manual\n' > "$LAB/config/backlog-backend"
printf 'off\n' > "$LAB/config/herdr-presentation-spaces"
mkdir -p "$LAB/user-home" "$PROJ"
git init -q -b main "$PROJ"
git -C "$PROJ" config user.name 'Live validation'
git -C "$PROJ" config user.email 'validation@example.invalid'
printf 'max_trees = 2\nroot = "%s"\n' "$ROOT/.test-tmp/treehouse-live" > "$PROJ/treehouse.toml"
printf '# Fixture project\n' > "$PROJ/README.md"
mkdir -p "$PROJ/.agents/skills/pager"
printf '%s\n' '---' 'name: pager' 'description: Find and explain pager workflows.' '---' 'Use pager workflows.' > "$PROJ/.agents/skills/pager/SKILL.md"
git -C "$PROJ" add .
git -C "$PROJ" commit -qm 'Live validation fixture'
export FM_HOME="$LAB" FM_JEV_BRIEF_PREFLIGHT=off HERDR_SESSION="$SESSION"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH TMUX FM_TASK_ID
for MODE in shadow live; do
  ID="skill-$MODE"
  bin/fm-brief.sh "$ID" fixture --scout --herdr-lab || exit 22
  python3 - "$LAB/data/$ID/brief.md" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace('{TASK}','Confirm the worker starts without optional skill suggestions.').replace('{FIRSTMATE_SPEC}','No source modifications or external lifecycle operations.'))
PY
  printf 'Find pager skills\n' > "$LAB/data/$ID/jev-skill-query.txt"
  touch "$LAB/config/jev-skill-select-live"
  START=$SECONDS
  FM_JEV_SKILL_SELECT="$MODE" FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh "$ID" "$PROJ" --scout --backend herdr --route-override 'Isolated live validation' 'bash -c "printf raw-worker-ready; sleep 3"'
  RC=$?
  echo "mode=$MODE spawn_exit=$RC elapsed_seconds=$((SECONDS-START))"
  if [ "$RC" -ne 0 ]; then exit 23; fi
  cp "$LAB/data/$ID/launch-brief.md" "$E/spawn-$MODE-launch-brief.md"
  if [ -f "$LAB/state/jev-calls.jsonl" ]; then cp "$LAB/state/jev-calls.jsonl" "$E/spawn-jev-calls.jsonl"; fi
  if [ -f "$LAB/state/jev-calls.jsonl" ]; then echo "jev_log_bytes=$(wc -c < "$LAB/state/jev-calls.jsonl")"; else echo 'jev_log_bytes=0 (log absent)'; fi
  [ ! -s "$LAB/state/jev-calls.jsonl" ] || exit 24
  [ ! -e "$LAB/state/$ID.jev-skills.json" ] || exit 25
  [ ! -e "$LAB/state/jev-skill-shadow" ] || exit 26
  PANE=$(awk -F= '$1 == "herdr_pane_id" {print $2}' "$LAB/state/$ID.meta")
  bin/fm-herdr-lab.sh run "$SESSION" pane wait-output "$PANE" --match raw-worker-ready --timeout 5000 --raw > "$E/spawn-$MODE-pane.txt" || exit 27
  bin/fm-herdr-lab.sh run "$SESSION" pane list
  cp "$LAB/state/$ID.meta" "$E/spawn-$MODE.meta"
done
