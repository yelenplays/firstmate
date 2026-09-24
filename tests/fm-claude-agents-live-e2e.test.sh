#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/environment.sh"
fm_test_sanitize_environment
# Opt-in credentialed Claude live regression for the claude-agents busy source
# (bin/fm-busy-lib.sh fm_busy_claude_agents_status). Proves, against the real
# installed Claude Code and its real `claude agents --json`, that a pane-style
# interactive session in an isolated lab worktree classifies:
#   idle claude-agents        before any prompt,
#   busy claude-agents        while its turn runs,
#   busy claude-needs-input   while a permission prompt holds the turn, which
#                             fm_busy_verdict_working refuses as progress,
#   idle claude-agents        after the prompt is answered and the turn ends,
# and that a killed session drops out of the list so classification falls
# back to the hook-record path instead of inventing a verdict.
# The session runs in a Python pty so the guard does not depend on tmux or a
# Herdr lab; it submits two short prompts on the cheapest model, which is why
# it is opt-in. No live fleet home, worktree, or session is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_AGENTS_LIVE_E2E claude jq python3

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)

fail() {
  printf 'not ok - claude %s: %s\n' "$CLAUDE_VERSION" "$1" >&2
  [ -f "${SCREEN:-}" ] && python3 - "$SCREEN" >&2 <<'PY'
import re, sys
d = open(sys.argv[1], 'rb').read().decode('utf8', 'replace')
d = re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]', '', d)
print('screen tail:', re.sub(r'\s+', ' ', d)[-600:])
PY
  exit 1
}

LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-agents-live.XXXXXX")" && pwd -P)
WT="$LAB/wt"
STATE="$LAB/state"
FIFO="$LAB/keys"
SCREEN="$LAB/screen.log"
DRIVER_PID=''

cleanup() {
  [ -z "$DRIVER_PID" ] || kill "$DRIVER_PID" 2>/dev/null || true
  [ -z "${SESSION_PID:-}" ] || kill -9 "$SESSION_PID" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$WT" "$STATE"
git -C "$WT" init -q
printf 'window=live\nworktree=%s\nharness=claude\n' "$WT" > "$STATE/t1.meta"
mkfifo "$FIFO"

# The pty driver: runs the session with a 160x50 terminal, copies its output
# to SCREEN, and forwards whatever arrives on FIFO as keystrokes.
cat > "$LAB/keydriver.py" <<'PY'
import os, pty, select, sys, fcntl, termios, struct
fifo, log, cwd = sys.argv[1:4]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    os.execvp(sys.argv[4], sys.argv[4:])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 160, 0, 0))
keys = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
out = open(log, 'ab')
while True:
    r, _, _ = select.select([fd, keys], [], [], 1)
    if fd in r:
        try:
            d = os.read(fd, 65536)
        except OSError:
            break
        if not d:
            break
        out.write(d)
        out.flush()
    if keys in r:
        d = os.read(keys, 4096)
        if d:
            os.write(fd, d)
        else:
            os.close(keys)
            keys = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
    if os.waitpid(pid, os.WNOHANG)[0]:
        break
PY

# A session started from inside another Claude session inherits a child
# marker and never registers in `claude agents`, so the launch drops every
# CLAUDE* variable, exactly like a fresh worker pane.
(
  for v in $(env | sed -n 's/^\(CLAUDE[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
  exec python3 "$LAB/keydriver.py" "$FIFO" "$SCREEN" "$WT" claude --model haiku --permission-mode default
) &
DRIVER_PID=$!

keys() { printf '%b' "$1" > "$FIFO"; }
classify() { FM_CLAUDE_AGENTS_BIN=claude fm_busy_classify tmux live claude t1 "$STATE"; }
screen_has() {
  [ -f "$SCREEN" ] || return 1
  python3 - "$SCREEN" "$1" <<'PY'
import re, sys
d = open(sys.argv[1], 'rb').read().decode('utf8', 'replace')
d = re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]', '', d)
sys.exit(0 if sys.argv[2] in re.sub(r'\s+', '', d) else 1)
PY
}

# wait_verdict <want> <seconds>: poll the real classifier until it prints
# <want>; records every distinct verdict seen in SEEN.
SEEN=''
wait_verdict() {
  local want=$1 limit=$2 i=0 v
  while [ "$i" -lt $((limit * 2)) ]; do
    v=$(classify)
    case " $SEEN " in *" ${v// /_} "*) ;; *) SEEN="$SEEN ${v// /_}" ;; esac
    [ "$v" = "$want" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

# The lab directory is new, so Claude asks for workspace trust first.
for _ in $(seq 1 30); do
  screen_has 'trustthisfolder' && break
  classify | grep -q claude-agents && break
  sleep 0.5
done
if screen_has 'trustthisfolder'; then
  keys '\033[B'
  sleep 0.5
  keys '\r'
fi

wait_verdict 'idle claude-agents' 30 || fail "a fresh session never classified 'idle claude-agents' (seen:$SEEN)"
SESSION_PID=$(claude agents --json | jq -r --arg wt "$WT" '.[] | select(.cwd == $wt) | .pid')
[ -n "$SESSION_PID" ] || fail "the session list named no pid for the lab worktree"

keys 'Run this exact shell command and nothing else: touch agents-probe.txt'
sleep 0.5
keys '\r'
wait_verdict 'busy claude-needs-input' 90 || fail "the permission prompt never classified 'busy claude-needs-input' (seen:$SEEN)"
case " $SEEN " in
  *' busy_claude-agents '*) ;;
  *) fail "the running turn never classified 'busy claude-agents' before the prompt (seen:$SEEN)" ;;
esac
if fm_busy_verdict_working "$(classify)"; then
  fail "a turn waiting on a permission answer counted as working"
fi

keys '\r'
wait_verdict 'idle claude-agents' 90 || fail "the approved turn never settled to 'idle claude-agents' (seen:$SEEN)"
[ -f "$WT/agents-probe.txt" ] || fail "the approved command did not run, so the prompt read was not the permission prompt"

kill -9 "$SESSION_PID" 2>/dev/null || true
SESSION_PID=''
sleep 2
v=$(classify)
case "$v" in
  *claude-agents*|*claude-needs-input*) fail "a killed session still classified from the session list: '$v'" ;;
esac

printf 'ok - claude %s: session list classified idle, busy, needs-input, idle, then fell back after the session died (%s)\n' \
  "$CLAUDE_VERSION" "${SEEN# }"
