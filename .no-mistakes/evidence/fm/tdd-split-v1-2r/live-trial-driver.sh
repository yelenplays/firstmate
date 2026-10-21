#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/Users/yelen/.no-mistakes/evidence/01M5FXMCSN5XSMQ4HBDZX37G3E
export TMPDIR="$ROOT/.test-tmp"
LAB=$(mktemp -d "$TMPDIR/fm-lab.XXXXXX")
export FM_HERDR_LAB_STATE_DIR="$LAB/herdr-labs"
# Mark before populating the disposable home.
bin/fm-lab-home.sh create "$LAB" >/dev/null
SESSION=$(bin/fm-herdr-lab.sh name tdd-trial)
cleanup() {
  rc=$?
  trap - EXIT
  bin/fm-herdr-lab.sh teardown "$SESSION" >>"$EVIDENCE/live-trial.log" 2>&1 || rc=1
  chmod -R u+w "$LAB"
  rm -rf "$LAB"
  exit "$rc"
}
trap cleanup EXIT
exec >"$EVIDENCE/live-trial.log" 2>&1
printf 'Isolated tdd-split real-task trial; session=%s\n' "$SESSION"
export FM_HOME="$LAB"
# These must precede server startup: new pane shells inherit its environment.
export TREEHOUSE_ROOT="$LAB/treehouse" DISABLE_AUTOUPDATER=1
export FM_BACKEND=herdr HERDR_SESSION="$SESSION"
# provision owns prepare when the named session does not yet exist.
bin/fm-herdr-lab.sh provision "$SESSION"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_SOCKET_PATH HERDR_ENV TMUX
mkdir -p "$LAB/projects/counter"
git -C "$LAB/projects/counter" init -q -b main
printf 'counter() { printf "0\\n"; }\n' >"$LAB/projects/counter/counter.sh"
printf 'root = "%s"\nmax_trees = 1\n' "$LAB/treehouse" >"$LAB/projects/counter/treehouse.toml"
git -C "$LAB/projects/counter" add counter.sh treehouse.toml
git -C "$LAB/projects/counter" -c user.name=Lab -c user.email=lab@example.invalid commit -qm initial
# A local origin supplies the same base-ref contract as a user's project.
git clone -q "$LAB/projects/counter" "$LAB/projects/trial"
bin/fm-brief.sh tdd-trial trial --mode local-only --herdr-lab
python3 - "$LAB/data/tdd-trial/brief.md" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])
s=p.read_text().replace('{TASK}', 'Change counter.sh so sourcing it and running counter prints exactly 1 instead of 0. This is a disposable local-only acceptance trial; never push, open a PR, run no-mistakes, run linters, formatters, or static analysis. Only execute the behavioral shell tests and Git commands. Do not use any command or file outside this isolated project or the brief-defined lab home.').replace('{FIRSTMATE_SPEC}', 'Add shell behavior tests under tests/ for the requested output. Keep this task confined to this disposable project. Use git -c user.name=Lab -c user.email=lab@example.invalid commit if Git identity is unavailable.')
s+='\nFail-to-pass command: `for t; do bash "$t" || exit 1; done`\n'
p.write_text(s)
PY
printf '\nCOMMAND: fm-spawn.sh tdd-trial trial --mode local-only --yolo off --backend herdr --tdd-split --harness claude --model sonnet --effort medium\n'
bin/fm-spawn.sh tdd-trial "$LAB/projects/trial" --mode local-only --yolo off --backend herdr --tdd-split --harness claude --model sonnet --effort medium
printf '\nTask record after launch:\n'
python3 - "$LAB/state/tdd-trial.meta" <<'PY'
import pathlib,sys
print(pathlib.Path(sys.argv[1]).read_text())
PY
PANE=$(awk -F= '$1=="herdr_pane_id" {print $2}' "$LAB/state/tdd-trial.meta")
deadline=$((SECONDS+100))
while [ "$SECONDS" -lt "$deadline" ]; do
  if [ -f "$LAB/state/tdd-trial.status" ] && grep -q 'done.*tests-ready' "$LAB/state/tdd-trial.status"; then break; fi
  sleep 2
done
printf '\nActual terminal output:\n'
bin/fm-herdr-lab.sh run "$SESSION" pane read "$PANE" --lines 200 --format text
printf '\nWorker status:\n'
if [ -f "$LAB/state/tdd-trial.status" ]; then python3 - "$LAB/state/tdd-trial.status" <<'PY'
import pathlib,sys
print(pathlib.Path(sys.argv[1]).read_text())
PY
fi
WT=$(awk -F= '$1=="worktree" {print substr($0,index($0,"=")+1)}' "$LAB/state/tdd-trial.meta")
case "$WT" in "$LAB"/*) ;; *) echo 'BLOCKED: pane did not inherit isolated TREEHOUSE_ROOT'; exit 1 ;; esac
if ! grep -q 'done.*tests-ready' "$LAB/state/tdd-trial.status"; then echo 'BLOCKED: native test seat did not finish'; exit 1; fi
SEAT=$(git -C "$WT" rev-parse HEAD)
TEST=$(git -C "$WT" diff --name-only origin/main HEAD | head -n 1)
printf '\nCOMMAND: fm-tdd-split.sh handoff tdd-trial\n'
bin/fm-tdd-split.sh handoff tdd-trial
printf '\nRed evidence and implementer record:\n'
python3 - "$LAB/data/tdd-trial/tdd-split-red.log" "$LAB/state/tdd-trial.meta" <<'PY'
import pathlib,sys
for p in sys.argv[1:]: print(pathlib.Path(p).read_text())
PY
deadline=$((SECONDS+100))
while [ "$SECONDS" -lt "$deadline" ]; do
  if grep -q 'ready in branch' "$LAB/state/tdd-trial.status"; then break; fi
  sleep 2
done
printf '\nActual implementer terminal:\n'
bin/fm-herdr-lab.sh run "$SESSION" pane read "$PANE" --lines 200 --format text
printf '\nCOMMAND: fm-control.sh tdd-trial exit\n'
bin/fm-control.sh tdd-trial exit
printf '\nFinal committed files:\n'
git -C "$WT" log --oneline -3
git -C "$WT" diff "$SEAT" HEAD -- counter.sh
printf '\nCOMMAND: run every handed-over shell test without modifying it\n'
(cd "$WT"; for t in tests/*; do bash "$t"; done)
git -C "$WT" diff --exit-code "$SEAT" HEAD -- tests
printf '\nAdversarial lock: change a handed-over test and claim done\n'
printf '\n# unauthorized implementer edit\n' >>"$WT/$TEST"
git -C "$WT" add tests
git -C "$WT" -c user.name=Lab -c user.email=lab@example.invalid commit -qm 'adversarial test edit'
printf 'done: ready in branch fm/tdd-trial\n' >>"$LAB/state/tdd-trial.status"
bin/fm-crew-state.sh tdd-trial
