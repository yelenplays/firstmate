#!/usr/bin/env bash
# tests/fm-send-inbox-doorbell-live-e2e.test.sh - the live doorbell guard
# (live-harness-optin family).
#
# The steering inbox's one behavioral assumption is that a real worker agent
# follows the constant self-describing doorbell line: list the inbox, read and
# act on its records in numeric order, then mv each into handled/. The
# doorbell names the inbox as "$FM_TASK_INBOX", so each worker is launched the
# way bin/fm-spawn.sh launches it, with FM_TASK_INBOX exported to its home's
# state/<task>.inbox, and receives no brief at all: it must resolve the inbox
# from the doorbell plus its own environment. A stub can only confirm the
# assumption already written into the stub, so per
# .agents/skills/firstmate-coding-guidelines this is proven against every
# INSTALLED verified harness: each is launched idle in an isolated tmux server,
# steered through the REAL fm-send (durable record + doorbell), and must both
# ACT on the instruction (create a named file) and ACKNOWLEDGE it (the mv into
# handled/), failing loudly with the harness name and version.
#
# Run explicitly with FM_SEND_INBOX_LIVE_E2E=1. This test spends a small
# number of real model tokens per installed harness (one short turn each) -
# authorized by the harness-dependent-checks rule. An absent harness is
# reported explicitly and skipped; a run that verified nothing fails rather
# than passing vacuously. Restrict with
# FM_SEND_INBOX_LIVE_HARNESSES="claude codex ..." when needed, and tune the
# per-harness wait with FM_SEND_INBOX_LIVE_TIMEOUT (seconds, default 240).
# Record the dated per-harness result in
# docs/verification/runtime-backends.md ("Steering-inbox doorbell").
#
# Folder trust: harnesses launch with the repo root as cwd, which the
# operator's machine has normally already trusted; a trust dialog is a real
# unready state and correctly fails that harness's check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Set FM_SEND_INBOX_LIVE_BACKEND=herdr for the Claude/Pi reproduction below.
# A transport shim swallows two Enters, not text: real composers must accept
# the third Enter without retyping. An operator must pre-register Claude's
# workspace trust and pass that exact directory as FM_SEND_INBOX_LIVE_CWD.
if [ "${FM_SEND_INBOX_LIVE_BACKEND:-tmux}" = herdr ]; then
  fm_live_gate opt-in FM_SEND_INBOX_LIVE_E2E herdr jq
  unset NO_MISTAKES_GATE
  LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
  ORIGINAL_PATH=$PATH
  HERDR_LAB_SESSION=$("$LAB_HELPER" name inbox-doorbell)
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-inbox-herdr.XXXXXX")
  LAB=$(cd "$LAB" && pwd -P)
  cleanup_herdr() {
    local rc=$?
    trap - EXIT
    PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
    cp "$LAB"/*.out "$LAB"/*.err "$LAB"/*.log "$EVIDENCE/" 2>/dev/null || true
    [ ! -d "$LAB/home/state" ] || cp -R "$LAB/home/state" "$EVIDENCE/final-state-${h:-unknown}"
    if [ -d "$LAB/project" ]; then
      python3 - "$LAB/project" <<'CLEANTRUST'
import json,sys
from pathlib import Path
p=Path('/Users/yelen/.claude-lay/.claude.json')
d=json.loads(p.read_text())
if sys.argv[1] in d.get('projects', {}):
    del d['projects'][sys.argv[1]]
    p.write_text(json.dumps(d, indent=2)+'\n')
    print('Removed exact lab trust entry only: '+sys.argv[1])
CLEANTRUST
    fi
    [ ! -e "$LAB/transport.log" ] || cp "$LAB/transport.log" "$EVIDENCE/${h:-startup}-transport.log"
    for marker in "$LAB"/acted-*; do
      [ ! -e "$marker" ] || printf 'acted marker exists: %s\n' "${marker##*/}" >> "$EVIDENCE/${h:-startup}-markers.log"
    done
    rm -rf "$LAB"
    exit "$rc"
  }
  capture_evidence() {
    [ -n "${pane:-}" ] || return 0
    PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" > "$EVIDENCE/${h:-startup}-${1}.json" 2>&1 || true
    PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$HERDR_LAB_SESSION" agent get "$pane" > "$EVIDENCE/${h:-startup}-${1}-agent.json" 2>&1 || true
  }
  original_fail=$(declare -f fail)
  fail() { capture_evidence failed; printf 'not ok - %s\n' "$1" >&2; exit 1; }
  trap cleanup_herdr EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
  mkdir -p "$LAB/shim" "$LAB/home/state"
  "$ROOT/bin/fm-lab-home.sh" create "$LAB/project" >/dev/null
  mkdir -p "$LAB/project/bin"
  touch "$LAB/project/AGENTS.md"
  git -C "$LAB/project" init -q
  if [[ " ${FM_SEND_INBOX_LIVE_HARNESSES:-} " == *' claude '* ]]; then
    CLAUDE_CONFIG_DIR=/Users/yelen/.claude-lay "$ROOT/bin/fm-claude-trust.sh" --lab-home "$LAB/project" || exit 1
  fi
  cat > "$LAB/shim/herdr" <<EOF
#!/usr/bin/env bash
set -eu
printf '%s\\n' "\$*" >> "$LAB/transport.log"
args=("\$@")
n=\${#args[@]}
[ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$HERDR_LAB_SESSION" ] || exit 97
args=("\${args[@]:0:\$((n-2))}")
if [ "\${args[0]} \${args[1]}" = 'pane send-keys' ] && [ "\${args[3]:-}" = enter ] && [ -f "$LAB/drop-enters" ]; then
  drops=\$(< "$LAB/drop-enters")
  if [ "\$drops" -gt 0 ]; then echo \$((drops-1)) > "$LAB/drop-enters"; exit 0; fi
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$HERDR_LAB_SESSION" "\${args[@]}"
EOF
  chmod +x "$LAB/shim/herdr"
  "$LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not provision isolated Herdr session'
  export PATH="$LAB/shim:$ORIGINAL_PATH"
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  # The readiness probes below run in substitutions; their lazy adapter load
  # cannot populate this shell's functions for the literal preloads.
  fm_backend_source herdr || fail 'could not load the Herdr adapter'
  # shellcheck source=bin/fm-task-inbox-lib.sh
  . "$ROOT/bin/fm-task-inbox-lib.sh"
  lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
  wait_herdr_idle() {  # <target>
    local i
    for ((i=0; i<60; i++)); do
      if [ "$(fm_backend_composer_state herdr "$1")" = empty ] \
         && [ "$(fm_backend_busy_state herdr "$1")" != busy ]; then return 0; fi
      sleep 1
    done
    return 1
  }
  lab help > "$EVIDENCE/herdr-help.log" 2>&1
  lab terminal --help > "$EVIDENCE/herdr-terminal-help.log" 2>&1
  lab pane --help > "$EVIDENCE/herdr-pane-help.log" 2>&1
  checked=0
  for h in ${FM_SEND_INBOX_LIVE_HARNESSES:-claude pi}; do
    if ! command -v "$h" >/dev/null 2>&1; then
      printf '# harness absent, not verified here: %s\n' "$h"
      continue
    fi
    case "$h" in
      claude)
        jq -nc --arg root "$ROOT" '{claudeMdExcludes: [($root+"/CLAUDE.md"),($root+"/AGENTS.md")]}' > "$LAB/claude-settings.json"
        cmd="CLAUDE_CONFIG_DIR=/Users/yelen/.claude-lay CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --safe-mode --dangerously-skip-permissions --settings $(printf '%q' "$LAB/claude-settings.json")"
        ;;
      pi) cmd='pi --thinking low --no-approve --no-context-files' ;;
      *) fail "Herdr doorbell reproduction supports claude and pi, got $h" ;;
    esac
    version=$("$h" --version 2>/dev/null | head -1)
    task="live-$h"; home="$LAB/home"
    created=$(lab workspace create --cwd "${FM_SEND_INBOX_LIVE_CWD:-$LAB/project}" --label "fm-$task" --no-focus) || fail "$h ($version): could not create workspace"
    pane=$(printf '%s' "$created" | jq -er '.result.root_pane.pane_id') || fail "$h ($version): missing pane"
    target="$HERDR_LAB_SESSION:$pane"
    printf 'backend=herdr\nherdr_session=%s\nherdr_pane_id=%s\nwindow=%s\nkind=ship\nharness=%s\n' "$HERDR_LAB_SESSION" "$pane" "$target" "$h" > "$home/state/$task.meta"
    lab pane run "$pane" "export FM_TASK_INBOX=$(printf '%q' "$home/state/$task.inbox"); $cmd" >/dev/null || fail "$h ($version): could not launch"
    for scenario in fresh stale; do
      wait_herdr_idle "$target" || fail "$h ($version): no empty composer before $scenario; resolve trust/login dialogs first"
      capture_evidence "$scenario-before"
      rec="$home/state/$task.inbox/001.msg"
      if [ "$scenario" = stale ]; then
        line=$(fm_task_inbox_doorbell_line "$rec")
        fm_backend_herdr_send_literal "$target" "$line" || fail "$h ($version): could not preload stale doorbell"
        sleep 1
        [ "$(fm_backend_composer_state herdr "$target")" = pending ] || fail "$h ($version): preload is not pending"
        capture_evidence stale-preloaded
        rec="$home/state/$task.inbox/002.msg"
      fi
      echo 2 > "$LAB/drop-enters"
      acted="$LAB/acted-$h-$scenario"
      FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" \
        "Run exactly: touch $acted . Then move this message into handled/. Reply with one short line." \
        > "$LAB/send.out" 2> "$LAB/send.err" || fail "$h ($version): $scenario fm-send failed"
      [ "$(< "$LAB/drop-enters")" = 0 ] || fail "$h ($version): $scenario never attempted both swallowed Enters"
      landed=0
      for ((i=0; i<${FM_SEND_INBOX_LIVE_TIMEOUT:-240}; i++)); do
        if [ -f "${rec%/*}/handled/${rec##*/}" ] && [ -e "$acted" ]; then landed=1; break; fi
        sleep 1
      done
      capture_evidence "$scenario-after"
      cp "$LAB/send.out" "$EVIDENCE/$h-$scenario-send.out"; cp "$LAB/send.err" "$EVIDENCE/$h-$scenario-send.err"
      [ "$landed" = 1 ] || fail "$h ($version): $scenario doorbell never acted and acknowledged after two swallowed Enters"
      printf 'ok - Herdr %s (%s): %s doorbell acted and acknowledged after two swallowed Enters\n' "$h" "$version" "$scenario"
    done
    rm -f "$LAB/drop-enters"
    wait_herdr_idle "$target" || fail "$h did not settle before exhaustion test"
    echo 3 > "$LAB/drop-enters"
    acted="$LAB/acted-$h-exhausted"
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task"       "Run exactly: touch $acted . Then move this message into handled/. Reply with one short line."       > "$EVIDENCE/$h-exhausted-send.out" 2> "$EVIDENCE/$h-exhausted-send.err" || fail "$h exhausted send failed before durable record"
    rec="$home/state/$task.inbox/003.msg"
    line=$(fm_task_inbox_doorbell_line "$rec")
    grep -qF 'doorbell did not reach' "$EVIDENCE/$h-exhausted-send.err" || fail "$h swallowed Enter exhaustion falsely confirmed"
    [ -f "$rec" ] && [ ! -e "$acted" ] || fail "$h exhaustion lost record or unexpectedly acted"
    fm_task_inbox_composer_holds herdr "$target" "$line" || fail "$h exhaustion lost exact doorbell"
    capture_evidence retry-exhausted
    echo 2 > "$LAB/drop-enters"
    fm_task_inbox_ring herdr "$target" "$rec" || fail "$h exhausted retry failed"
    landed=0
    for ((i=0;i<120;i++)); do
      if [ -f "${rec%/*}/handled/${rec##*/}" ] && [ -e "$acted" ]; then landed=1; break; fi
      sleep 1
    done
    [ "$landed" = 1 ] || fail "$h exhausted message did not act and acknowledge after re-ring"
    capture_evidence retry-recovered
    printf 'ok - Herdr %s: exhausted retries report unconfirmed and preserve a recoverable single doorbell\n' "$h"
    # The acknowledgement happens inside the turn, before the worker settles.
    # Do not inject the unrelated draft into a still-running turn.
    wait_herdr_idle "$target" || fail "$h ($version): did not settle before draft protection check"
    fm_backend_herdr_send_literal "$target" 'unsubmitted human draft' || fail "$h ($version): could not preload draft"
    sleep 1
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" 'Do not submit the pending draft.' > "$LAB/draft.out" 2> "$LAB/draft.err" || fail "$h ($version): draft steer failed"
    grep -qF 'doorbell skipped' "$LAB/draft.err" || fail "$h ($version): unrelated draft was not protected"
    fm_task_inbox_composer_holds herdr "$target" 'unsubmitted human draft' || fail "$h ($version): unrelated draft was modified"
    capture_evidence protected-draft
    printf 'ok - Herdr %s (%s): unrelated draft stays unsubmitted\n' "$h" "$version"
    if [ "$h" = pi ]; then
      lab pane send-keys "$pane" ctrl+u >/dev/null
      wait_herdr_idle "$target" || fail 'Pi did not clear draft for busy baseline test'
      echo 0 > "$LAB/drop-enters"
      FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task"         'Run sleep 35 now, then move this message into handled/ and reply with one short line.'         > "$EVIDENCE/pi-start-busy-send.out" 2> "$EVIDENCE/pi-start-busy-send.err"
      busy=0
      for ((i=0;i<20;i++)); do
        if [ "$(fm_backend_busy_state herdr "$target")" = busy ]; then busy=1; break; fi
        sleep 0.2
      done
      [ "$busy" = 1 ] || fail 'Pi never became busy for adversarial test'
      rec=$(fm_task_inbox_write "$home/state" "$task" 'Reply with busy-baseline-check and then move this message into handled/.')
      line=$(fm_task_inbox_doorbell_line "$rec")
      fm_backend_herdr_send_literal "$target" "$line" || fail 'could not preload busy Pi doorbell'
      sleep 0.3
      capture_evidence busy-preloaded
      echo 99 > "$LAB/drop-enters"
      busy_rc=0
      fm_task_inbox_ring herdr "$target" "$rec" || busy_rc=$?
      printf 'busy-baseline ring rc=%s remaining-dropped-enters=%s record=%s\n' "$busy_rc" "$(< "$LAB/drop-enters")" "$rec" > "$EVIDENCE/pi-busy-result.log"
      [ "$busy_rc" = 2 ] || fail "pre-existing busy activity falsely confirmed submit: $busy_rc"
      fm_task_inbox_composer_holds herdr "$target" "$line" || fail 'busy test changed exact pending doorbell'
      [ -f "$rec" ] && [ ! -f "${rec%/*}/handled/${rec##*/}" ] || fail 'busy test falsely acknowledged message'
      capture_evidence busy-after-refusal
      printf 'ok - Herdr Pi: pre-existing working status does not confirm three dropped Enter attempts\n'
    fi
    checked=$((checked + 1))
  done
  [ "$checked" -gt 0 ] || fail 'Herdr doorbell guard verified no installed harness'
  exit 0
fi

fm_live_gate opt-in FM_SEND_INBOX_LIVE_E2E tmux

unset NO_MISTAKES_GATE

SOCKET="fm-inbox-live-$$"
SESSION="inboxlive"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-inbox-live.XXXXXX")
LAB=$(cd "$LAB" && pwd)
TIMEOUT=${FM_SEND_INBOX_LIVE_TIMEOUT:-240}
CHECKED=0
FAILED=0

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

# fm-send and the composer readiness read both reach tmux through bare `tmux`
# calls, so a PATH shim pins them to the private socket.
SHIM_DIR="$LAB/shim"
mkdir -p "$SHIM_DIR"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$ROOT"

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

# Launch <name> idle with its unattended-autonomy flags (the same posture
# bin/fm-spawn.sh uses), so the doorbell-triggered shell actions need no
# interactive approval.
launch_cmd() {  # <name>
  case "$1" in
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '\''{"feedbackDrafts":"off"}'\''' ;;
    codex) printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox' ;;
    opencode) printf '%s' "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode" ;;
    pi|pi-signed) printf '%s' "$1" ;;
    grok) printf '%s' 'grok --always-approve' ;;
    kimi) printf '%s' 'kimi --auto' ;;
    muse) printf '%s' 'MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on muse --yolo' ;;
    *) return 1 ;;
  esac
}

# Wait for the harness to look steerable. 0 = the composer classified a
# proven empty; 2 = the readiness budget expired without an empty verdict but
# also without a pending one. The caller proceeds on 2 with a note, because
# that mirrors production exactly: the send path's composer check is ADVISORY
# and skips only on visibly pending text, so a harness whose idle screen the
# classifier cannot positively identify still gets its doorbell (the composer
# matrix guard, not this one, owns re-proving the classifier per release).
wait_ready() {  # <window>
  local win=$1 i=0 budget=60 verdict dismissed=0 screen
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$SESSION:$win")
    [ "$verdict" = empty ] && return 0
    i=$((i + 1))
    # Dismiss one non-trust startup modal (update prompts), as the composer
    # matrix guard does; never Enter, which could accept an upgrade.
    if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
      screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null || true)
      if ! printf '%s\n' "$screen" | grep -qi 'trust'; then
        tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Escape 2>/dev/null || true
      fi
      dismissed=1
    fi
    sleep 1
  done
  case "$verdict" in
    pending) return 1 ;;
  esac
  return 2
}

check_harness_doorbell() {  # <name>
  local name=$1 version cmd win="hx-$1" home task acted rec handled i ready_rc
  version=$(harness_version "$name")
  cmd=$(launch_cmd "$name") || { note "no launch recipe for $name"; return 0; }
  home="$LAB/$name-home"
  mkdir -p "$home/state"
  task="live-$name"
  acted="$LAB/acted-$name"
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" \
    -- bash -lc "export FM_TASK_INBOX=$(printf '%q' "$home/state/$task.inbox"); $cmd" \
    || { FAILED=1; printf 'not ok - %s (%s): could not launch in the isolated tmux server\n' "$name" "$version" >&2; return 0; }
  wait_ready "$win"; ready_rc=$?
  if [ "$ready_rc" -eq 1 ]; then
    FAILED=1
    printf 'not ok - %s (%s): composer stayed visibly pending; the pane is not steerable\n' "$name" "$version" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -6 | sed 's/^/#   /' >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  [ "$ready_rc" -eq 0 ] || note "$name ($version): idle composer never classified empty; proceeding as production does (advisory check skips only on pending)"
  printf 'window=%s:%s\nkind=ship\nharness=%s\n' "$SESSION" "$win" "$name" > "$home/state/$task.meta"
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" \
    "Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line." \
    >/dev/null 2>&1; then
    FAILED=1
    printf 'not ok - %s (%s): fm-send refused the live steer\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  rec="$home/state/$task.inbox/001.msg"
  handled="$home/state/$task.inbox/handled/001.msg"
  [ -f "$rec" ] || {
    FAILED=1
    printf 'not ok - %s (%s): fm-send left no durable inbox record\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  }
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -f "$handled" ] && [ -e "$acted" ] && break
    # Halfway through, play the watcher's role once: re-ring an unacknowledged
    # message so a doorbell swallowed by a startup or update modal recovers
    # exactly as the production re-ring ladder recovers it.
    if [ "$i" -eq $((TIMEOUT / 2)) ] && [ -f "$rec" ]; then
      fm_task_inbox_ring tmux "$SESSION:$win" "$rec" || true
      note "$name ($version): re-rang the doorbell once (watcher's role) at ${i}s"
    fi
    sleep 1
    i=$((i + 1))
  done
  if [ -f "$handled" ] && [ -e "$acted" ]; then
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): the doorbell reached a real worker, which acted and acked with the mv"
  else
    FAILED=1
    printf 'not ok - %s (%s): doorbell not honored within %ss (acted=%s acked=%s)\n' \
      "$name" "$version" "$TIMEOUT" "$([ -e "$acted" ] && echo yes || echo no)" \
      "$([ -f "$handled" ] && echo yes || echo no)" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  fi
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

HARNESSES=${FM_SEND_INBOX_LIVE_HARNESSES:-'claude codex opencode pi grok kimi muse'}
for h in $HARNESSES; do
  if command -v "$h" >/dev/null 2>&1; then
    check_harness_doorbell "$h"
  else
    note "harness absent, not verified here: $h"
  fi
done

if [ "$FAILED" -ne 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard found failures above\n' >&2
  exit 1
fi
if [ "$CHECKED" -eq 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard verified nothing (no harness installed?)\n' >&2
  exit 1
fi
pass "live steering-inbox doorbell guard: $CHECKED harness(es) honored the doorbell contract"
