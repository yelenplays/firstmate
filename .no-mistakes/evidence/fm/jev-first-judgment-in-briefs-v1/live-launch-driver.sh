#!/usr/bin/env bash
# Live drive: run the real bin/fm-spawn.sh for a Claude task worker against a
# REAL tmux server (isolated socket) and capture the argv the pane actually
# hands to the real installed `claude` entry point. The only doubles are the
# external tools firstmate delegates to: a `treehouse get` shim that cd's the
# pane into a pre-created isolated git worktree, and a `claude` recorder that
# logs its argv instead of starting an interactive model session. fm-spawn.sh,
# tmux, the pane shell, and the emitted launch command are all real.
set -u

ROOT=${ROOT:?}
LAB=${LAB:?}
MODE=${1:-ship}          # ship | scout | secondmate
ID=${2:-live-jev-worker}

export TMPDIR="$LAB/tmp"
mkdir -p "$LAB/project" "$LAB/wt" "$LAB/home/data" "$LAB/home/state" "$LAB/home/projects" "$LAB/home/config" "$LAB/home/user-home" "$LAB/fakebin" "$TMPDIR"
touch "$LAB/home/state/.last-watcher-beat"

# --- throwaway project + isolated worktree -------------------------------
if [ ! -d "$LAB/project/.git" ]; then
  git -C "$LAB/project" init -q -b main
  git -C "$LAB/project" config user.email t@example.invalid
  git -C "$LAB/project" config user.name t
  printf 'seed\n' > "$LAB/project/README.md"
  git -C "$LAB/project" add README.md
  git -C "$LAB/project" commit -qm seed
fi
if [ ! -e "$LAB/wt/.git" ]; then
  git -C "$LAB/project" worktree add -q -b "wt-$ID" "$LAB/wt"
fi

# --- real private tmux server on an isolated socket ----------------------
SOCK="$LAB/tmux.sock"
cat > "$LAB/fakebin/tmux" <<SH
#!/usr/bin/env bash
exec /opt/homebrew/bin/tmux -S "$SOCK" "\$@"
SH
chmod +x "$LAB/fakebin/tmux"
rm -f "$SOCK"
export PATH="$LAB/fakebin:$PATH"
tmux new-session -d -s firstmate -x 220 -y 50 -c "$LAB/project" >/dev/null
# The pane's login shell rebuilds PATH from /etc/paths, which would put the real
# treehouse/claude ahead of the lab shims. Run a non-login interactive shell and
# pin the server PATH so every new window resolves the lab shims first.
tmux set-option -g default-command '/bin/bash -i'
tmux set-environment -g PATH "$PATH"

# --- treehouse shim: cd the pane into the pre-created worktree -----------
cat > "$LAB/fakebin/treehouse" <<SH
#!/usr/bin/env bash
# Only \`get\` matters here: replace the pane's shell with one sitting in the
# isolated worktree, which is what a real \`treehouse get\` subshell does.
if [ "\${1:-}" = get ]; then
  cd "$LAB/wt" || exit 1
  exec /bin/bash -i
fi
exit 0
SH
chmod +x "$LAB/fakebin/treehouse"

# --- claude recorder: log argv, start no model session -------------------
ARGV_LOG="$LAB/claude-argv.log"
: > "$ARGV_LOG"
cat > "$LAB/fakebin/claude" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then printf '2.1.280 (Claude Code)\\n'; exit 0; fi
{
  printf '=== claude invocation ===\\n'
  i=0
  for a in "\$@"; do printf 'ARG[%d]=<<%s>>\\n' "\$i" "\$a"; i=\$((i+1)); done
} >> "$ARGV_LOG"
exit 0
SH
chmod +x "$LAB/fakebin/claude"

# --- real brief, placeholders filled -------------------------------------
BRIEF="$LAB/home/data/$ID/brief.md"
case "$MODE" in
  scout)      FM_HOME="$LAB/home" "$ROOT/bin/fm-brief.sh" "$ID" firstmate --scout >/dev/null ;;
  secondmate) FM_HOME="$LAB/home" FM_SECONDMATE_CHARTER='Supervise assigned work.' "$ROOT/bin/fm-brief.sh" "$ID" --secondmate --no-projects >/dev/null ;;
  *)          FM_HOME="$LAB/home" "$ROOT/bin/fm-brief.sh" "$ID" firstmate --mode no-mistakes >/dev/null ;;
esac
if [ "$MODE" != secondmate ]; then
  python3 - "$BRIEF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('{TASK}', 'Exercise the live Jev-first launch rule.')
s = s.replace('{FIRSTMATE_SPEC}', 'Prove the emitted launch command reaches a worker session.')
open(p, 'w').write(s)
PY
fi

# --- seeded secondmate home for the negative (supervisor) case -----------
SM_HOME="$LAB/sm"
if [ "$MODE" = secondmate ]; then
  mkdir -p "$SM_HOME/bin" "$SM_HOME/data"
  printf '# Firstmate\n' > "$SM_HOME/AGENTS.md"
  printf '%s\n' "$ID" > "$SM_HOME/.fm-secondmate-home"
  printf 'charter for %s\n' "$ID" > "$SM_HOME/data/charter.md"
fi

# --- run the real spawn --------------------------------------------------
args=("$ID" "$LAB/project" --harness claude)
case "$MODE" in
  scout)      args+=(--scout) ;;
  secondmate) args=("$ID" "$SM_HOME" --harness claude --secondmate) ;;
  *)          args+=(--mode no-mistakes --yolo off) ;;
esac

export TMUX="fake,1,0"
set +e
out=$(
  FM_ROOT_OVERRIDE='' FM_HOME="$LAB/home" HOME="$LAB/home/user-home" \
  CLAUDE_CONFIG_DIR='' GROK_HOME="$LAB/grok-home" \
  FM_STATE_OVERRIDE="$LAB/home/state" FM_DATA_OVERRIDE="$LAB/home/data" \
  FM_PROJECTS_OVERRIDE="$LAB/home/projects" FM_CONFIG_OVERRIDE="$LAB/home/config" \
  FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 \
  "$ROOT/bin/fm-spawn.sh" "${args[@]}" 2>&1
)
status=$?
set -e
printf '%s\n' "$out" > "$LAB/spawn-output.txt"
printf 'spawn exit=%s\n' "$status"

# Confirm the lab shims actually won inside the pane (they must, or this is not a
# drive of firstmate's own emitted command).
tmux new-window -d -t firstmate: -n shim-probe -c "$LAB/project" >/dev/null 2>&1 || true
sleep 0.5
tmux send-keys -t firstmate:shim-probe 'which treehouse claude > '"$LAB"'/which.log 2>&1' Enter
sleep 0.5

sleep 1
echo "=== shim resolution in pane ==="
cat "$LAB/which.log" 2>/dev/null || echo "(probe failed)"
echo "=== claude argv log ==="
cat "$ARGV_LOG"
echo "=== spawn output ==="
cat "$LAB/spawn-output.txt"

tmux kill-server >/dev/null 2>&1 || true
