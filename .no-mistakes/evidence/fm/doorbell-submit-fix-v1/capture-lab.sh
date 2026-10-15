#!/usr/bin/env bash
set -u
ROOT=/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M501Y41X1MGX5GCEX9PDZXD5
E=/Users/yelen/.no-mistakes/evidence/01M501Y41X1MGX5GCEX9PDZXD5
H="$ROOT/bin/fm-herdr-lab.sh"
printf '%s ' "$(date -u +%FT%TZ)" "$@" >> "$E/live-transport.log"; printf '\n' >> "$E/live-transport.log"
if [ "$1" = teardown ]; then
  "$H" run "$2" workspace list > "$E/final-workspaces.json" 2>&1 || true
  "$H" run "$2" agent list > "$E/final-agents.json" 2>&1 || true
  for dir in "$ROOT"/.test-tmp/fm-inbox-herdr.*; do
    [ -d "$dir/home/state" ] || continue
    for f in send.out send.err draft.out draft.err drop-enters; do
      [ ! -f "$dir/$f" ] || cp "$dir/$f" "$E/live-$f"
    done
    for meta in "$dir"/home/state/*.meta; do
      [ -f "$meta" ] || continue
      pane=$(sed -n 's/^herdr_pane_id=//p' "$meta")
      task=$(basename "$meta" .meta)
      "$H" run "$2" pane read "$pane" --source visible --format ansi > "$E/$task-final.ansi" 2>&1 || true
      "$H" run "$2" pane read "$pane" --source recent-unwrapped --lines 200 > "$E/$task-transcript.txt" 2>&1 || true
      cp "$meta" "$E/$task.meta"
      [ ! -d "$dir/home/state/$task.inbox" ] || cp -R "$dir/home/state/$task.inbox" "$E/$task.inbox"
      for acted in "$dir"/acted-*; do
        [ ! -f "$acted" ] || printf 'worker-created %s\n' "$acted" >> "$E/worker-actions.log"
      done
    done
  done
fi
"$H" "$@"
rc=$?
if [ "$rc" = 0 ] && [ "$1" = provision ]; then
  "$H" run "$2" status --json > "$E/lab-status.json" 2>&1 || true
  "$H" run "$2" pane > "$E/pane-capabilities.txt" 2>&1 || true
fi
if [ "$rc" = 0 ] && [ "$1" = run ] && [ "${3:-} ${4:-}" = 'pane run' ]; then
  for ((i=0; i<15; i++)); do
    screen=$("$H" run "$2" pane read "$5" --source visible 2>/dev/null) || screen=
    if [[ "$screen" == *'Trust project folder?'* ]] && [[ "$screen" == *'Trust (this session only)'* ]]; then
      printf '%s\n' "$screen" > "$E/pi-session-only-trust.txt"
      "$H" run "$2" pane send-keys "$5" down down enter >> "$E/pi-session-only-trust.txt" 2>&1 || exit 1
      printf 'Selected session-only project trust; no persistent trust granted.\n' >> "$E/pi-session-only-trust.txt"
      break
    fi
    sleep 1
  done
fi
if [ "$rc" = 0 ] && [ "$1" = run ] && [ "${3:-} ${4:-}" = 'pane send-keys' ]; then
  printf '\n--- %s pane=%s key=%s ---\n' "$(date -u +%FT%TZ)" "$5" "${6:-}" >> "$E/live-enter-snapshots.txt"
  "$H" run "$2" pane read "$5" --source visible >> "$E/live-enter-snapshots.txt" 2>&1 || true
  "$H" run "$2" agent get "$5" >> "$E/live-enter-snapshots.txt" 2>&1 || true
fi
if [ "$1" = teardown ]; then printf 'teardown_exit=%s\n' "$rc" >> "$E/live-transport.log"; fi
exit "$rc"
