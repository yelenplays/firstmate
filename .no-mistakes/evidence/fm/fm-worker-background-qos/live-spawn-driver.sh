#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/Users/yelen/.no-mistakes/evidence/01M4FX8WGTCAVF0NABDEZP63VV
LAB=$(mktemp -d "$ROOT/.test-validation/fm-lab.XXXXXX")
SOCKET_DIR=
rm -f "$E/live-worker-qos.json" "$E/live-worker-allowlist.json"
cleanup() {
  if [ -n "$SOCKET_DIR" ]; then
    TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab kill-server 2>/dev/null || true
    "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" || true
  fi
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
SOCKET_DIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
mkdir -p "$LAB/user-home" "$LAB/tmp" "$LAB/data/qos-live" "$LAB/projects/probe"
ZSH=$(command -v zsh)
PYTHON=$(command -v python3)
P="$LAB/projects/probe"
git -C "$P" init -q
printf '# disposable QoS launch project\n' >"$P/README.md"
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$P" add README.md
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$P" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git clone --bare -q "$P" "$LAB/origin.git"
git -C "$P" remote add origin "file://$LAB/origin.git"
printf manual >"$LAB/config/backlog-backend"
cat >"$LAB/data/qos-live/brief.md" <<'BRIEF'
# Task
## Captain's intent
Verify CPU scheduling and zsh raw-command compatibility in a disposable local project.

## Firstmate spec
Run the provided command and report its scheduling class without changing the project.
BRIEF
cat >"$LAB/probe.py" <<'PY'
import ctypes,os,sys,subprocess,json,pathlib
parent=ctypes.CDLL(None).qos_class_self()
child=subprocess.check_output([sys.executable,'-I','-c','import ctypes; print(hex(ctypes.CDLL(None).qos_class_self()))'],text=True).strip()
record=dict(parent_qos=hex(parent),child_qos=child,applied=os.getenv('FM_QOS_APPLIED'),zsh_input=pathlib.Path(sys.argv[1]).read_text().strip(),cwd=os.getcwd())
print(json.dumps(record),flush=True)
pathlib.Path(sys.argv[2]).write_text(json.dumps(record,indent=2)+'\n')
assert parent==0x11 and child=='0x11' and record['applied']=='utility'
assert record['zsh_input']=='zsh-process-substitution'
PY
cat >"$LAB/spawn.sh" <<SH
#!/usr/bin/env bash
set -eu
export FM_HOME='$LAB'
export HOME='$LAB/user-home' TMPDIR='$LAB/tmp' SHELL='$ZSH'
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_QOS_UNAME FM_QOS_TASKPOLICY FM_QOS_APPLIED
FM_SPAWN_NO_GUARD=1 '$ROOT/bin/fm-spawn.sh' qos-live '$P' --mode local-only --yolo off --backend tmux \
  "'$PYTHON' -I '$LAB/probe.py' =(printf '%s\\n' zsh-process-substitution) '$E/live-worker-qos.json'" >'$E/live-spawn.log' 2>&1
printf '%s\\n' done >'$LAB/spawn-done'
SH
chmod +x "$LAB/spawn.sh"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  HOME="$LAB/user-home" TMPDIR="$LAB/tmp" SHELL="$ZSH" TMUX_TMPDIR="$SOCKET_DIR" \
  tmux -f /dev/null -L fm-lab new-session -d -x 120 -y 40 -s qos-driver -c "$ROOT" -e FM_HOME="$LAB" "$ZSH -f"
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab set-option -g default-shell "$ZSH"
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab set-option -g default-command "$ZSH -f"
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab send-keys -t qos-driver "bash '$LAB/spawn.sh'" Enter
for ((i=0;i<100;i++)); do
  [ ! -f "$LAB/spawn-done" ] || break
  sleep 1
done
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab capture-pane -p -t qos-driver >"$E/live-spawn-controller.txt"
if [ ! -f "$LAB/spawn-done" ]; then
  TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab capture-pane -p -t qos-driver:fm-qos-live >"$E/live-spawn-pane.txt" 2>&1 || true
  printf 'spawn did not complete\n' >&2
  exit 1
fi
for ((i=0;i<10;i++)); do [ ! -f "$E/live-worker-qos.json" ] || break; sleep 1; done
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab capture-pane -p -t qos-driver:fm-qos-live >"$E/live-spawn-pane.txt"
[ -f "$E/live-worker-qos.json" ]
"$PYTHON" -I - "$E/live-worker-qos.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); assert x['parent_qos']=='0x11' and x['child_qos']=='0x11'
assert x['zsh_input']=='zsh-process-substitution' and x['applied']=='utility'
print(json.dumps(x,indent=2))
PY
# Run a second real spawn through the clean-environment allowlist boundary.
mkdir -p "$LAB/data/qos-allow"
cp "$LAB/data/qos-live/brief.md" "$LAB/data/qos-allow/brief.md"
touch "$LAB/config/launch-env-allowlist"
printf '%s\n' zsh-process-substitution >"$LAB/probe-input"
cat >"$LAB/allowlist-spawn.sh" <<SH
#!/usr/bin/env bash
set -eu
export FM_HOME='$LAB' HOME='$LAB/user-home' TMPDIR='$LAB/tmp' SHELL='$ZSH'
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_QOS_UNAME FM_QOS_TASKPOLICY FM_QOS_APPLIED
FM_SPAWN_NO_GUARD=1 '$ROOT/bin/fm-spawn.sh' qos-allow '$P' --mode local-only --yolo off --backend tmux \
  "'$PYTHON' -I '$LAB/probe.py' '$LAB/probe-input' '$E/live-worker-allowlist.json'" >'$E/live-allowlist-spawn.log' 2>&1
printf '%s\\n' done >'$LAB/allowlist-done'
SH
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab send-keys -t qos-driver "bash '$LAB/allowlist-spawn.sh'" Enter
for ((i=0;i<90;i++)); do [ ! -f "$LAB/allowlist-done" ] || break; sleep 1; done
[ -f "$LAB/allowlist-done" ]
for ((i=0;i<10;i++)); do [ ! -f "$E/live-worker-allowlist.json" ] || break; sleep 1; done
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab capture-pane -p -t qos-driver:fm-qos-allow >"$E/live-allowlist-pane.txt"
"$PYTHON" -I - "$E/live-worker-allowlist.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); assert x['parent_qos']=='0x11' and x['child_qos']=='0x11'
assert x['applied']=='utility'
print(json.dumps(x,indent=2))
PY
