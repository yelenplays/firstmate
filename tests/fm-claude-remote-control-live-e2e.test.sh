#!/usr/bin/env bash
# Opt-in live guard for a Claude Code PRIMARY launched with Remote Control on.
#
# bin/fm-claude-primary.sh adds `--remote-control <name>` when the home opts in
# through config/claude-remote-control. That flag bridges the local interactive
# session to claude.ai so the captain can steer it from a phone; the firstmate
# supervision contract still depends on the tracked .claude/settings.json hooks
# firing in that same process. Only the real claude binary can answer whether
# they do, so this drives the installed binary end to end and proves, in one
# Remote Control session:
#   1. the launcher really started claude with --remote-control and the bridge
#      came up;
#   2. the SessionStart run tier took the fleet lock, completed session start,
#      and delivered the digest into model context;
#   3. the Stop-hook auto-arm armed a real watcher and rewoke the session with a
#      real wake;
#   4. the turn-end guard ran on every stop and allowed the healthy session.
#
# tests/fm-claude-primary.test.sh is the portable regression for the launcher's
# resolution. This guard submits prompts and connects to claude.ai, so it is
# opt-in: FM_CLAUDE_REMOTE_CONTROL_LIVE_E2E=1 (or FM_LIVE=1) and a claude.ai
# login on this machine. Run it after every Claude Code upgrade.
#
# Isolation: a throwaway firstmate home under a temp dir and a private tmux
# socket. It never touches the fleet's tmux server or a live home. Claude still
# records the throwaway path's workspace trust and transcript under ~/.claude,
# and claude.ai keeps the ended Remote Control session in its session list.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_REMOTE_CONTROL_LIVE_E2E claude tmux jq

REAL_TMUX=$(command -v tmux)
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
[ -n "$CLAUDE_VERSION" ] || fail "claude did not report a version; refusing to claim a verified result"
printf 'harness: claude %s\n' "$CLAUDE_VERSION"

harness_fail() {  # <message>
  fail "$1 [harness: claude $CLAUDE_VERSION]"
}

SOCKET="fm-claude-rc-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-rc.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
HOME_DIR="$LAB/home"
RC_NAME="fm-live-rc-$$"
# The hooks under test do not depend on the model, so keep the spend small.
LIVE_MODEL=${FM_CLAUDE_LIVE_MODEL:-haiku}

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  # Reap only processes started from this throwaway home's own bin/.
  [ -n "${HOME_DIR:-}" ] && pkill -f "$HOME_DIR/bin/" >/dev/null 2>&1
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

# A plain (non-worktree) checkout of the CURRENT working tree, so the guard
# tests the code under review rather than whatever is committed.
mkdir -p "$HOME_DIR"
(cd "$ROOT" && tar --exclude=.git --exclude=state --exclude=data --exclude=config \
  --exclude=projects --exclude=node_modules --exclude=.claude/settings.local.json -cf - .) \
  | (cd "$HOME_DIR" && tar -xf -) \
  || harness_fail "could not stage the working tree into the throwaway home"
git init -q "$HOME_DIR"
git -C "$HOME_DIR" add -A >/dev/null 2>&1 || true
git -C "$HOME_DIR" -c user.email=fmtest@example.invalid -c user.name=fmtest \
  commit -q -m "live-e2e fixture" >/dev/null 2>&1 || true

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
printf 'on %s\n' "$RC_NAME" > "$HOME_DIR/config/claude-remote-control"
printf '# Backlog\n\n- live probe\n' > "$HOME_DIR/data/backlog.md"
# One in-flight task so supervision is genuinely needed, plus a status line the
# watcher must surface as a real wake.
cat > "$HOME_DIR/state/probe.meta" <<EOF
id=probe
project=probe
harness=claude
backend=tmux
window=fm-probe
EOF
printf 'blocked: fixture needs a decision\n' > "$HOME_DIR/state/probe.status"

# Record every turn-end guard run and its exit status, then behave exactly as
# the real guard does.
GUARD_LOG="$LAB/guard.log"
mv "$HOME_DIR/bin/fm-turnend-guard.sh" "$HOME_DIR/bin/fm-turnend-guard.real.sh"
cat > "$HOME_DIR/bin/fm-turnend-guard.sh" <<SH
#!/usr/bin/env bash
"\$(dirname "\$0")/fm-turnend-guard.real.sh" "\$@"
rc=\$?
printf 'rc=%s\n' "\$rc" >> '$GUARD_LOG'
exit "\$rc"
SH
chmod +x "$HOME_DIR/bin/fm-turnend-guard.sh"

"$HOME_DIR/bin/fm-claude-primary.sh" --print --dangerously-skip-permissions > "$LAB/argv" \
  || harness_fail "the launcher refused the fixture config"
[ "$(sed -n '2,3p' "$LAB/argv" | tr '\n' ' ')" = "--remote-control $RC_NAME " ] \
  || harness_fail "the launcher did not resolve Remote Control: $(tr '\n' ' ' < "$LAB/argv")"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s primary -x 220 -y 60 -c "$HOME_DIR" \
  "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PROJECT_DIR -u FM_TASK_ID \
     FM_HOME='$HOME_DIR' FM_HEARTBEAT=30 FM_HEARTBEAT_MAX=30 \
     '$HOME_DIR/bin/fm-claude-primary.sh' --dangerously-skip-permissions --model '$LIVE_MODEL' --effort low" \
  || harness_fail "could not start the private tmux server"

pane_text() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t primary -S -300 2>/dev/null
}

wait_for_file() {  # <path> <seconds> <what>
  local path=$1 limit=$2 what=$3 i=0
  while [ "$i" -lt "$((limit * 2))" ]; do
    [ -e "$path" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  printf 'pane at failure:\n%s\n' "$(pane_text)" >&2
  harness_fail "$what did not appear within ${limit}s"
}

wait_for_pane() {  # <regex> <seconds> <what>
  local needle=$1 limit=$2 what=$3 i=0
  while [ "$i" -lt "$((limit * 2))" ]; do
    pane_text | grep -qE "$needle" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  printf 'pane at failure:\n%s\n' "$(pane_text)" >&2
  harness_fail "$what did not appear within ${limit}s"
}

submit() {  # <text>
  "$REAL_TMUX" -L "$SOCKET" send-keys -t primary -l "$1"
  sleep 1
  "$REAL_TMUX" -L "$SOCKET" send-keys -t primary Enter
}

# Claude asks once whether it trusts a folder it has never seen, and the
# session-open hook fires only after that is answered. harness-adapters owns
# trust handling outside tests; here the trusting option is chosen explicitly
# because it is not always the default selection.
n=0
while [ "$n" -lt 60 ] && [ ! -e "$HOME_DIR/state/.lock" ]; do
  if pane_text | grep -qiE 'trust this folder'; then
    if pane_text | grep -qE '❯ *No'; then
      "$REAL_TMUX" -L "$SOCKET" send-keys -t primary Down
      sleep 1
    fi
    "$REAL_TMUX" -L "$SOCKET" send-keys -t primary Enter
    sleep 3
  fi
  sleep 1
  n=$((n + 1))
done

# --- 1. Remote Control is on ------------------------------------------------

PANE_PID=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t primary '#{pane_pid}' 2>/dev/null)
CLAUDE_ARGS=$(ps -o args= -p "$PANE_PID" 2>/dev/null)
case "$CLAUDE_ARGS" in
  *"--remote-control $RC_NAME"*) ;;
  *) harness_fail "the pane process was not launched with --remote-control $RC_NAME: $CLAUDE_ARGS" ;;
esac
wait_for_pane 'remote-control is active|claude\.ai/code/session_' 120 "the Remote Control bridge"
pass "claude primary: the launcher started claude with --remote-control and the bridge came up"

# --- 2. session start ---------------------------------------------------------

wait_for_file "$HOME_DIR/state/.lock" 180 "the fleet session lock"
wait_for_file "$HOME_DIR/state/.session-start-complete" 240 "the completed session-start record"
LOCK_PID=$(cat "$HOME_DIR/state/.lock" 2>/dev/null)
[ -n "$LOCK_PID" ] && [ "$LOCK_PID" = "$PANE_PID" ] \
  || harness_fail "the session lock must be owned by the Remote Control claude process (lock=$LOCK_PID pane=$PANE_PID)"
pass "claude primary: the SessionStart run tier takes the fleet lock and completes session start"

submit "This is a throwaway test home. Answer only from the context you were given at session start. Do not run any command. Reply with only the number of the harness pid shown on the lock line of the session-start digest, and nothing else. After that, whenever a hook wakes you, reply with exactly WAKE_SEEN and nothing else, and do not run any command."
# --- 3. the Stop-hook auto-arm ----------------------------------------------

EPOCH="$HOME_DIR/state/.claude-autoarm-epoch"
i=0
while [ "$i" -lt 600 ]; do
  grep -q 'outcome=rewake' "$EPOCH" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -q 'outcome=rewake' "$EPOCH" 2>/dev/null \
  || { pane_text >&2; harness_fail "the Stop-hook auto-arm recorded no rewake: $(cat "$EPOCH" 2>/dev/null)"; }
[ -e "$HOME_DIR/state/.last-watcher-beat" ] \
  || harness_fail "the Stop-hook auto-arm armed no watcher: there is no liveness beacon"
wait_for_pane 'WAKE_SEEN' 180 "the session handling the watcher's rewake"
pass "claude primary: the Stop-hook auto-arm arms a watcher and rewakes the session with a real wake"

# The digest's lock line names the session's own pid, which only the digest
# can have told the model. Claude redraws its transcript, so the reply can
# scroll out of the pane; read it from the session's own transcript, where only
# an assistant message counts. The digest can exceed Claude's inline hook-output
# limit and arrive as a preview plus a saved file; the lock line is in the
# preview either way.
PROJECT_SLUG=$(printf '%s' "$HOME_DIR" | sed 's/[^A-Za-z0-9]/-/g')
# The throwaway path is fresh, so its project directory holds only this session.
TRANSCRIPT=$(find "$HOME/.claude/projects/$PROJECT_SLUG" -name '*.jsonl' 2>/dev/null | head -n 1)
[ -n "$TRANSCRIPT" ] || harness_fail "found no Claude transcript under ~/.claude/projects/$PROJECT_SLUG"
jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' "$TRANSCRIPT" 2>/dev/null \
  | grep -qw "$LOCK_PID" \
  || harness_fail "the model never quoted the digest's lock pid $LOCK_PID; the digest did not reach model context"
pass "claude primary: the session-start digest reaches model context under Remote Control"

# --- 4. the turn-end guard ----------------------------------------------------

[ -s "$GUARD_LOG" ] || harness_fail "the turn-end guard never ran on a stop"
grep -qv '^rc=0$' "$GUARD_LOG" \
  && harness_fail "the turn-end guard blocked a healthy session: $(tr '\n' ' ' < "$GUARD_LOG")"
pass "claude primary: the turn-end guard ran on $(wc -l < "$GUARD_LOG" | tr -d ' ') stop(s) and allowed the healthy session"

printf 'ok - Claude %s with --remote-control kept session start, the Stop-hook auto-arm, and the turn-end guard working\n' "$CLAUDE_VERSION"
