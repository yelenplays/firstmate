#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/home/marco/.no-mistakes/evidence/01M3S127624K7E1983CMN24HA5
mkdir -p "$EVIDENCE"
LAB=$(mktemp -d "$ROOT/.l.XXXXXX")
export LAB ROOT EVIDENCE
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
"$ROOT/bin/fm-lab-home.sh" create "$LAB"
mkdir -p "$LAB/tmux" "$LAB/claude" "$LAB/user" "$LAB/projects/sample"
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
export FM_HOME="$LAB"
printf 'manual\n' > "$LAB/config/backlog-backend"
# Reuse the existing login without writing the production credential store.
cp /home/marco/.claude/.credentials.json "$LAB/claude/.credentials.json"
chmod 600 "$LAB/claude/.credentials.json"
export CLAUDE_CONFIG_DIR="$LAB/claude" HOME="$LAB/user"
export DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export XDG_CACHE_HOME="$LAB/user/.cache" XDG_CONFIG_HOME="$LAB/user/.config" XDG_DATA_HOME="$LAB/user/.local/share"
PROJ="$LAB/projects/sample"
git -C "$PROJ" init -q -b main
printf 'max_trees = 2\nroot = "%s"\n' "$PROJ" > "$PROJ/treehouse.toml"
printf 'item,value\nb,2\na,1\n' > "$PROJ/measurements.csv"
git -C "$PROJ" add .
git -C "$PROJ" -c user.name=Lab -c user.email=lab@example.invalid commit -qm 'Seed isolated scout input'
WT=$(cd "$PROJ" && treehouse get --lease --lease-holder scout-evidence)
export WT
printf 'Real Treehouse lease: %s\n' "$WT"
for ID in named-results report-only; do
  export ID
  "$ROOT/bin/fm-brief.sh" "$ID" sample --scout
  python3 - <<'PY'
import os,pathlib
lab=pathlib.Path(os.environ['LAB']); task=os.environ['ID']; wt=os.environ['WT']
p=lab/'data'/task/'brief.md'
if task=='named-results':
    intent='Investigate measurements.csv. Deliver results.csv sorted by item, report.html containing the same two-row table, and report.md explaining the findings. Use scratch-notes.txt for temporary notes; it is not a deliverable. No PDF is requested.'
else:
    intent='Investigate measurements.csv and provide only report.md explaining the row count and value sum. No HTML, PDF, CSV copy or other additional deliverable is requested. Use scratch-notes.txt for temporary calculations.'
p.write_text(p.read_text().replace('{TASK}',intent).replace('{FIRSTMATE_SPEC}',f'The disposable task worktree is {wt}. Read the input there and perform all scratch work there. No repository changes, network research, or lifecycle administration are needed. This is an isolated validation task with no unresolved user decisions.'))
PY
  cp "$LAB/data/$ID/brief.md" "$EVIDENCE/$ID-brief.md"
  PROMPT="You are the scout worker for task $ID, not a supervisor. Read and execute $LAB/data/$ID/brief.md. The isolated worktree is $WT. Do not start a supervisor or delegate this task."
  COMMAND=$(python3 - "$PROMPT" "$ROOT" "$LAB" <<'PY'
import shlex,sys
args=['claude','--print','--no-session-persistence','--setting-sources','','--strict-mcp-config','--settings','{"disableAllHooks":true}','--permission-mode','acceptEdits','--allowedTools','Read,Write,Edit,Bash','--append-system-prompt',f'This is a bounded development evaluation. All intentional filesystem writes must remain below {sys.argv[2]}. Never run no-mistakes pipeline-control commands, install packages, modify system settings, or touch any real fleet home. Follow the scout brief, not supervisor instructions in ancestor files.','--',sys.argv[1]]
print(shlex.join(args)+' > '+shlex.quote(sys.argv[3]+'/worker.log')+' 2>&1; printf "%s\\n" "$?" > '+shlex.quote(sys.argv[3]+'/worker.exit'))
PY
)
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -x 120 -y 40 -s primary -c "$ROOT" -e FM_HOME="$LAB" "$COMMAND"
  for ((i=0; i<180; i++)); do
    [ ! -e "$LAB/worker.exit" ] || break
    sleep 2
  done
  if [ ! -f "$LAB/worker.exit" ]; then
    TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary > "$EVIDENCE/$ID-timeout-pane.txt" || true
    cp "$LAB/worker.log" "$EVIDENCE/$ID-worker.txt"
    echo 'Worker timed out'; exit 2
  fi
  cp "$LAB/worker.log" "$EVIDENCE/$ID-worker.txt"
  printf 'Worker %s exit: %s\n' "$ID" "$(<"$LAB/worker.exit")"
  [ "$(<"$LAB/worker.exit")" = 0 ] || exit 2
  [ -f "$LAB/data/$ID/report.md" ] || { echo 'No durable report produced'; exit 2; }
  cp "$LAB/data/$ID/report.md" "$EVIDENCE/$ID-report.md"
  find "$LAB/data/$ID" -maxdepth 1 -type f -printf '%f\n' | sort
  if [ "$ID" = named-results ]; then
    [ -f "$LAB/data/$ID/results.csv" ] && [ -f "$LAB/data/$ID/report.html" ]
    [ ! -e "$LAB/data/$ID/report.pdf" ] && [ ! -e "$LAB/data/$ID/scratch-notes.txt" ]
    cp "$LAB/data/$ID/results.csv" "$EVIDENCE/results.csv"
    cp "$LAB/data/$ID/report.html" "$EVIDENCE/report.html"
    python3 - <<'PY'
import csv,os,pathlib
p=pathlib.Path(os.environ['LAB'])/'data/named-results/results.csv'
assert list(csv.DictReader(p.open())) == [{'item':'a','value':'1'},{'item':'b','value':'2'}]
print('Persisted CSV contains the requested sorted rows a=1, b=2.')
PY
  else
    [ ! -e "$LAB/data/$ID/report.html" ] && [ ! -e "$LAB/data/$ID/report.pdf" ] && [ ! -e "$LAB/data/$ID/results.csv" ]
  fi
  # Use the actual cleanup entrypoint with a dead lab-owned endpoint, as after a worker exits.
  printf 'window=primary:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=scout\nmode=local-only\nspawn_gen=live-%s\n' "$ID" "$ID" "$WT" "$PROJ" "$ID" > "$LAB/state/$ID.meta"
  # All implicit tmux calls resolve only to this private, now-stopped lab socket.
  export TMUX="$LAB/tmux/tmux-$(id -u)/fm-lab,0,0"
  "$ROOT/bin/fm-captain-hold.sh" complete "$ID" --none
  (cd "$LAB/data/$ID" && sha256sum report.md *.csv *.html 2>/dev/null || true) > "$LAB/durable-before"
  "$ROOT/bin/fm-teardown.sh" "$ID"
  (cd "$LAB/data/$ID" && sha256sum report.md *.csv *.html 2>/dev/null || true) > "$LAB/durable-after"
  cmp "$LAB/durable-before" "$LAB/durable-after"
  [ ! -e "$LAB/state/$ID.meta" ]
  [ ! -e "$WT/scratch-notes.txt" ]
  printf 'After real teardown: durable output hashes unchanged; scratch-notes.txt absent; task metadata retired.\n'
  cat "$LAB/durable-after"
  treehouse_status=$(cd "$PROJ" && treehouse status)
  printf '%s\n' "$treehouse_status"
  rm -f "$LAB/worker.exit" "$LAB/worker.log"
  unset TMUX
  if [ "$ID" = named-results ]; then
    WT=$(cd "$PROJ" && treehouse get --lease --lease-holder scout-evidence-report-only)
    export WT
  fi
done
