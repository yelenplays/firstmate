#!/usr/bin/env bash
set -eu
ROOT="$PWD"
EVIDENCE=/Users/yelen/.no-mistakes/evidence/01M54RFHN24MTHTBZ0N0DVCS3X
export TMPDIR="$ROOT/.test-tmp"
export FM_HERDR_LAB_STATE_DIR="$ROOT/.test-tmp/herdr-state"
LAB=$(mktemp -d "$TMPDIR/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
ORIGINAL_PATH=$PATH
SESSION=$(bin/fm-herdr-lab.sh name jev-approval)
HELPER="$ROOT/bin/fm-herdr-lab.sh"
cleanup() {
  rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$HELPER" teardown "$SESSION" > "$EVIDENCE/lab-cleanup.log" 2>&1 || rc=1
  rm -rf "$LAB"
  exit "$rc"
}
trap cleanup EXIT
unset HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID TMUX
"$HELPER" provision "$SESSION" > "$EVIDENCE/lab-setup.log" 2>&1
mkdir -p "$LAB/bin"
printf '#!/usr/bin/env bash\nset -eu\nargs=("$@")\nn=${#args[@]}\nif [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ] && [ "${args[$((n-1))]}" = "%s" ]; then\n  args=("${args[@]:0:$((n-2))}")\nelse\n  echo "lab wrapper refuses unscoped or foreign Herdr calls" >&2; exit 98\nfi\nexec env PATH=%q %q run %q "${args[@]}"\n' "$SESSION" "$ORIGINAL_PATH" "$HELPER" "$SESSION" > "$LAB/bin/herdr"
chmod +x "$LAB/bin/herdr"
WS_JSON=$("$HELPER" run "$SESSION" workspace create --cwd "$ROOT" --label jev-inbox-lab --no-focus)
printf '%s\n' "$WS_JSON" >> "$EVIDENCE/lab-setup.log"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id')
# The real sender's public contract defines enqueue as delivery. Use a passive
# terminal, not an agent authorized to execute the generated gate commands.
PATH="$LAB/bin:$ORIGINAL_PATH" python3 "$EVIDENCE/drive-jev-live.py" "$LAB" "$SESSION" "$PANE"
