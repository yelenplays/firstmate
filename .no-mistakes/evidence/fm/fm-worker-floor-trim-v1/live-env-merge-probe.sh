#!/usr/bin/env bash
# Live probe: does the worker --settings env overlay keep the user-level
# CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000 from ~/.claude/settings.json?
# Usage: live-env-merge-probe.sh <firstmate-worktree>
set -eu
ROOT=$1
. "$ROOT/bin/fm-claude-worker-context-lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-envprobe.XXXXXX")
trap 'rm -rf "$T"' EXIT
git -C "$T" init -q
S=$(fm_claude_worker_context ship "$T" "$ROOT" "$ROOT")
echo "worker settings fragment: $S"
SETTINGS="{\"feedbackDrafts\":\"off\",${S#\{}"
echo "launch --settings: $SETTINGS"
cd "$T"
env -u CLAUDECODE -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u SLASH_COMMAND_TOOL_CHAR_BUDGET \
  claude -p --settings "$SETTINGS" --allowedTools 'Bash(printenv:*)' --max-turns 3 --effort low --output-format stream-json --verbose \
  'Run exactly this one shell command with the Bash tool: printenv CLAUDE_CODE_AUTO_COMPACT_WINDOW SLASH_COMMAND_TOOL_CHAR_BUDGET . Then reply with its raw output only.'
