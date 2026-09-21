#!/usr/bin/env bash
# Live driver: exercises the orphaned browser bridge sweep through the real
# bin/fm-bootstrap.sh entry point. Everything lives under $SCRATCH. The sweep's
# process-table hook is a regular file that a background refresher rewrites
# ATOMICALLY every 50ms with a fresh snapshot of this account's processes, with
# the machine's one real bridge tree (pids 42934/43428) filtered out - so the
# post-reap rescan sees reality and no real bridge is ever signalled here.
set -u
REPO=/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M32WJ9ZT44XD4S9Q2701135C
SCRATCH=${SCRATCH:?}
UID_=$(id -u)
TABLE=$SCRATCH/table.tsv
AXI=$SCRATCH/axi-state

GEN_PID=
start_generator() {
  (
    while :; do
      ps -u "$UID_" -o pid=,ppid=,pgid=,stat=,etime=,command= \
        | awk '{pid=$1;ppid=$2;pgid=$3;st=$4;et=$5;$1="";$2="";$3="";$4="";$5="";sub(/^ +/,"");
                printf "%s\t%s\t%s\t%s\t%s\t%s\n",pid,ppid,pgid,st,et,$0}' \
        | awk -F'\t' -v g="${GUARD_FAKE_PID:-0}" '$1!=42934 && $1!=43428 && $3!=42934 && $2!=42934 && $1!=g' > "$SCRATCH/table.new" 2>/dev/null
      # scenario 8 hostile hook: REPLACE an unrelated live pid's row so the
      # table claims it is a bridge-tree member running a command it does not
      # actually run (exactly what a recycled pid looks like to a stale scan)
      if [ -n "${GUARD_FAKE_PID:-}" ] && [ -n "${GUARD_BRIDGE_PID:-}" ]; then
        printf '%s\t%s\t%s\tS\t00:00\tpython3 chrome-devtools-axi-bridge-ghost.js\n' \
          "$GUARD_FAKE_PID" "$GUARD_BRIDGE_PID" "$GUARD_BRIDGE_PID" >> "$SCRATCH/table.new"
      fi
      mv -f "$SCRATCH/table.new" "$TABLE" 2>/dev/null
      sleep 0.05
    done
  ) &
  GEN_PID=$!
  sleep 0.3
}
stop_generator() {
  [ -n "$GEN_PID" ] && kill "$GEN_PID" 2>/dev/null
  GEN_PID=
  rm -f "$SCRATCH/table.new"
}

run_bootstrap() { # <detect-only:0|1> [extra env...]
  local detect=$1; shift
  env "$@" \
    FM_BACKEND=tmux FM_HOME="$SCRATCH/home" FM_ROOT_OVERRIDE="$SCRATCH/root" \
    FM_BOOTSTRAP_NETWORK=skip \
    FM_BOOTSTRAP_DETECT_ONLY="$detect" \
    FM_BROWSER_BRIDGE_PROC_TABLE="$TABLE" \
    FM_CHROME_AXI_STATE_DIR="$AXI" \
    bash "$REPO/bin/fm-bootstrap.sh" 2>&1
}

FIXTURE=$SCRATCH/chrome-devtools-axi-bridge.py
cat > "$FIXTURE" <<'PY'
import os, subprocess, sys, time
outdir = sys.argv[1]
profiles = sys.argv[2:]
try:
    os.setsid()
except OSError:
    pass
kids = []
kids.append(subprocess.Popen(["python3", "-c", "import time;time.sleep(600)"]))
kids.append(subprocess.Popen(["python3", "-c", "import time;time.sleep(600)", "gap  gap"]))
kids.append(subprocess.Popen(["python3", "-c", "import time;time.sleep(600)", "trail "],
                             start_new_session=True))
ignorer = "import signal,time;signal.signal(signal.SIGTERM, signal.SIG_IGN);time.sleep(600)"
kids.append(subprocess.Popen(["python3", "-c", ignorer], start_new_session=True))
for d in profiles:
    kids.append(subprocess.Popen(
        ["python3", "-c", "import time;time.sleep(600)", "--user-data-dir=" + d],
        start_new_session=True))
with open(os.path.join(outdir, "children"), "w") as f:
    for k in kids:
        f.write("%d\n" % k.pid)
time.sleep(600)
PY

start_bridge() { # <case> <task-id-or-empty> <session> [profile ...] ; echoes pid
  local case=$1 id=$2 session=$3; shift 3
  local dir=$SCRATCH/cases/$case
  rm -rf "$dir"; mkdir -p "$dir"
  if [ -n "$id" ]; then
    env FM_TASK_ID="$id" CHROME_DEVTOOLS_AXI_SESSION="$session" \
      python3 "$FIXTURE" "$dir" "$@" >/dev/null 2>&1 &
  else
    env CHROME_DEVTOOLS_AXI_SESSION="$session" \
      python3 "$FIXTURE" "$dir" "$@" >/dev/null 2>&1 &
  fi
  local pid=$!
  local i=0
  while [ ! -f "$dir/children" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  [ -f "$dir/children" ] || { echo "START-FAIL"; return 1; }
  echo "$pid"
}

alive() {
  kill -0 "$1" 2>/dev/null || return 1
  ! ps -p "$1" -o stat= 2>/dev/null | grep -q Z
}
wait_gone() { local i=0; while alive "$1" && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i+1)); done; ! alive "$1"; }
