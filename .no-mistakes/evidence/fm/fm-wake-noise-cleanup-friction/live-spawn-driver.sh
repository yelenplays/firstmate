#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$ROOT/l
EVIDENCE=/Users/yelen/.no-mistakes/evidence/01M4EXVAYQS1J60HP0BRK1QTTF
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_CREW_STATE_BIN TASKS_AXI_FILE TASKS_AXI_BACKEND FM_TASK_ID
export FM_HOME=$LAB TMPDIR="$ROOT/.test-tmp" TMUX_TMPDIR="$LAB/tmux" FM_BACKEND=tmux
cleanup() {
 TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server >/dev/null 2>&1 || true
 chmod -R u+w "$LAB"
 rm -rf "$LAB"
}
trap cleanup EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME='Live test' GIT_AUTHOR_EMAIL='test@example.invalid' GIT_COMMITTER_NAME='Live test' GIT_COMMITTER_EMAIL='test@example.invalid'
git -C "$LAB/projects/demo" init -q -b main
printf 'Live disposable validation project.\n' > "$LAB/projects/demo/README.md"
printf 'Follow the supplied task launch brief. This is a disposable live validation project; never run a delivery pipeline.\n' > "$LAB/projects/demo/CLAUDE.md"
printf 'Follow the supplied task launch brief.\n' > "$LAB/projects/demo/AGENTS.md"
printf 'max_trees = 1\nroot = "."\n' > "$LAB/projects/demo/treehouse.toml"
git -C "$LAB/projects/demo" add README.md treehouse.toml CLAUDE.md AGENTS.md
git -C "$LAB/projects/demo" -c commit.gpgsign=false commit -qm 'Disposable scenario project'
git init --bare -q "$LAB/origin.git"
git -C "$LAB/projects/demo" remote add origin "$LAB/origin.git"
git -C "$LAB/projects/demo" push -q origin main
git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
cp .tasks.toml "$LAB/.tasks.toml"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
printf 'demo 1\n' > "$LAB/config/project-capacity"
printf 'codex\n' > "$LAB/config/crew-harness"
printf 'kind=captain\nwindow=\nproject=%s/projects/demo\n' "$LAB" > "$LAB/state/captain-call.meta"
printf 'kind=task\nwindow=\nproject=%s/projects/demo\n' "$LAB" > "$LAB/state/queued-record.meta"
touch "$LAB/config/supervision-host"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -c "$PWD" -x 120 -y 40 -e FM_HOME="$LAB" codex
export TMUX=$(tmux -L fm-lab display-message -p -t primary '#{socket_path}'),1,0
printf 'Private socket and nonzero grid: '
tmux -L fm-lab display-message -p -t primary '#{socket_path} #{pane_width}x#{pane_height}'
# Capture actual CLI availability without making an authentication change.
sleep 3
tmux -L fm-lab capture-pane -p -t primary > "$EVIDENCE/primary-codex.txt"
bin/fm-tasks-axi.sh add live-review 'Review the disposable demo' --kind scout
bin/fm-brief.sh live-review demo --scout > "$LAB/scaffold"
python3 - "$LAB/data/live-review/brief.md" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);s=p.read_text();s=s.replace('{TASK}', 'Review README.md in this disposable test repository. Write a concise report.md in the exact report path given below stating that the README contains the project purpose and no outstanding captain choices or reusable guide are owed. Do not change tracked project files. This is knowledge-only; never start a delivery pipeline.');s=s.replace('{FIRSTMATE_SPEC}', 'This is a focused live validation. Perform only the requested read-only review, write the report, append the required done status, then idle. Do not call cleanup or lifecycle commands.');p.write_text(s)
PY
bin/fm-spawn.sh live-review "$LAB/projects/demo" --scout --harness codex > "$EVIDENCE/live-spawn-output.txt" 2>&1
python3 -c 'import sys;print(open(sys.argv[1]).read())' "$EVIDENCE/live-spawn-output.txt"
cp "$LAB/state/live-review.meta" "$EVIDENCE/live-spawn-meta.txt"
test -f "$LAB/state/captain-call.meta"
# An actual dispatched worker occupies the only place; an extra spawn must defer.
bin/fm-tasks-axi.sh add excess-review 'Second disposable review' --kind scout
bin/fm-brief.sh excess-review demo --scout > "$LAB/second-scaffold"
python3 - "$LAB/data/excess-review/brief.md" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text().replace('{TASK}', 'Review README.md.').replace('{FIRSTMATE_SPEC}', 'Read-only review.'))
PY
rc=0
bin/fm-spawn.sh excess-review "$LAB/projects/demo" --scout --harness codex > "$EVIDENCE/live-capacity-defer.txt" 2>&1 || rc=$?
python3 -c 'import sys;print(open(sys.argv[1]).read())' "$EVIDENCE/live-capacity-defer.txt"
test "$rc" -eq 75
test ! -e "$LAB/state/excess-review.meta"
bin/fm-tasks-axi.sh show excess-review
# Inspect actual worker and report readiness; bounded observation, not a fake CLI.
for i in $(seq 1 90); do
 tmux -L fm-lab capture-pane -p -t primary:fm-live-review > "$EVIDENCE/live-worker.txt"
 if [ -f "$LAB/data/live-review/report.md" ]; then break; fi
 sleep 1
done
if [ ! -f "$LAB/data/live-review/report.md" ]; then
 printf 'LIVE_REPORT_UNAVAILABLE: actual Codex worker did not produce the report within 90 seconds; inspect live-worker.txt.\n'
 exit 3
fi
cp "$LAB/data/live-review/report.md" "$EVIDENCE/live-scout-report.md"
cp "$LAB/data/live-review/launch-brief.md" "$EVIDENCE/live-launch-brief.md"
# The firstmate/test driver, not the scout, owns empty completion.
bin/fm-teardown.sh live-review --scout-complete
 test ! -e "$LAB/state/live-review.meta"
test -f "$LAB/data/live-review/report.md"
cp "$LAB/data/live-review/guide.md" "$EVIDENCE/live-scout-guide.md" 2>/dev/null || true
bin/fm-tasks-axi.sh show live-review
printf 'Live worker admitted despite captain call; second spawn deferred; report preserved and scout completed by firstmate in one call.\n'
