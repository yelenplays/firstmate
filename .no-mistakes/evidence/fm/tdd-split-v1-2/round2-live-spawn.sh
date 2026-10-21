#!/usr/bin/env bash
# Attempt a real Opus seat on a throwaway fixture via the mandatory lab helper.
set -eu
ROOT=$PWD
E=/Users/yelen/.no-mistakes/evidence/01M5DR0CF1E1R45T9NEBBZT18D
LAB=$(mktemp -d "$ROOT/.test-tdd-live.XXXXXX")
HELPER="$ROOT/bin/fm-herdr-lab.sh"
ORIGINAL_PATH=$PATH
export FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab"
SESSION=$("$HELPER" name tdd-seat-round2)
PREPARED=0
cleanup() {
  rc=$?; trap - EXIT
  if [ "$PREPARED" = 1 ]; then PATH="$ORIGINAL_PATH" "$HELPER" teardown "$SESSION" || rc=1; fi
  chmod -R u+w "$LAB"; rm -rf "$LAB"
  exit "$rc"
}
trap cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONTROL_BIN FM_GATE_REFUSE_BYPASS FM_TEST_SEAM HERDR_ENV HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID TMUX TMUX_PANE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
export FM_HOME="$LAB/home" HERDR_SESSION="$SESSION" FM_BACKEND=herdr
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
mkdir -p "$LAB/tmp" "$LAB/route"
export TMPDIR="$LAB/tmp"
# A transport router, not a Herdr double: every request invokes the real helper.
cat > "$LAB/route/herdr" <<EOF
#!/usr/bin/env python3
import os, sys
args=sys.argv[1:]; out=[]; i=0
while i<len(args):
    if args[i]=='--session':
        if i+1>=len(args) or args[i+1]!='$SESSION': raise SystemExit('foreign session refused')
        i+=2
    else:
        out.append(args[i]); i+=1
env=dict(os.environ, PATH='$ORIGINAL_PATH')
os.execve('$HELPER', ['$HELPER','run','$SESSION']+out, env)
EOF
chmod +x "$LAB/route/herdr"
git init -q --bare "$LAB/origin.git"
git init -q -b main "$LAB/project"
printf 'Fixture for tests-first validation.\n' > "$LAB/project/README"
printf 'root = "%s"\nmax_trees = 1\n' "$LAB/pool" > "$LAB/project/treehouse.toml"
git -C "$LAB/project" add .; git -C "$LAB/project" commit -q -m base
git -C "$LAB/project" remote add origin "$LAB/origin.git"
git -C "$LAB/project" push -q -u origin main
git --git-dir="$LAB/origin.git" symbolic-ref HEAD refs/heads/main
"$ROOT/bin/fm-brief.sh" trial "$LAB/project" --mode local-only --herdr-lab
python3 - "$FM_HOME/data/trial/brief.md" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
s=s.replace('{TASK}', 'In this disposable fixture add feature.sh. Running bash feature.sh must print exactly hello. Tests must pin that observable behavior.')
s=s.replace('{FIRSTMATE_SPEC}', 'This is an isolated validation fixture. Write shell behavior tests under tests/ in the test seat. Do not invoke no-mistakes or publish or merge anything. During implementation change feature.sh only, run the handed-over tests, commit, report ready in branch, and stop. Do not modify anything outside this fixture and the exact task status file instructed below.')
s+='\nFail-to-pass command: `for t; do bash "$t" || exit 1; done`\n'
p.write_text(s)
PY
# Provision owns prepare for the fresh named session and its tripwire.
PATH="$ORIGINAL_PATH" "$HELPER" provision "$SESSION"
PREPARED=1
export PATH="$LAB/route:$ORIGINAL_PATH"
set +e
"$ROOT/bin/fm-spawn.sh" trial "$LAB/project" --mode local-only --yolo off --backend herdr --tdd-split --harness claude --model claude-sonnet-5-5 --effort medium
RC=$?
set -e
printf 'spawn_exit=%s\n' "$RC"
[ "$RC" -eq 0 ] || exit "$RC"
META="$FM_HOME/state/trial.meta"
cp "$META" "$E/round2-live-seat.meta"
PANE=$(awk -F= '$1=="herdr_pane_id"{print $2}' "$META")
for ((i=0; i<45; i++)); do
  PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" pane read "$PANE" --source visible > "$E/round2-live-seat-screen.txt" 2>&1 || true
  if [ -f "$FM_HOME/state/trial.status" ] && grep -q 'done: tests-ready' "$FM_HOME/state/trial.status"; then break; fi
  sleep 1
done
if [ -f "$FM_HOME/state/trial.status" ]; then cp "$FM_HOME/state/trial.status" "$E/round2-live-seat.status"; fi
printf '\nFinal visible worker screen:\n'
while IFS= read -r line; do printf '%s\n' "$line"; done < "$E/round2-live-seat-screen.txt"
if [ ! -f "$FM_HOME/state/trial.status" ] || ! grep -q 'done: tests-ready' "$FM_HOME/state/trial.status"; then
  printf '\nNo tests-ready report within 45 seconds; full live handoff not exercised.\n'; exit 4
fi
"$ROOT/bin/fm-tdd-split.sh" handoff trial --timeout 10
cp "$FM_HOME/state/trial.meta" "$E/round2-live-implement.meta"
cp "$FM_HOME/data/trial/tdd-split-red.log" "$E/round2-live-red.log"
for ((i=0; i<45; i++)); do
  PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" pane read "$PANE" --source visible > "$E/round2-live-implement-screen.txt" 2>&1 || true
  WT=$(awk -F= '$1=="worktree"{print $2}' "$META")
  if [ -f "$WT/feature.sh" ] && [ "$(bash "$WT/feature.sh" 2>/dev/null)" = hello ]; then
    printf '\nReal implementer produced feature.sh with hello output.\n'; break
  fi
  sleep 1
done
[ -f "$WT/feature.sh" ] && [ "$(bash "$WT/feature.sh")" = hello ]
git -C "$WT" log -3 --oneline
printf 'fixture_feature_output=%s\n' "$(bash "$WT/feature.sh")"
printf 'All real worker lifecycle activity stayed in named session %s; teardown follows.\n' "$SESSION"
