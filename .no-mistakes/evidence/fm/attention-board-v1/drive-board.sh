#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=/Users/yelen/.no-mistakes/evidence/01M5F6QX9TE6QXV066J3EK4DEC
LAB=$(mktemp -d "$PWD/.attention-lab.XXXXXX")
trap 'rm -rf -- "$LAB"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND
unset TYPESAFE_API_KEY OPENROUTER_API_KEY
export FM_HOME="$LAB/main"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
export FM_BROWSER_BRIDGE_PROC_TABLE=/dev/null FM_CHROME_AXI_STATE_DIR=/dev/null FM_CLAUDE_AGENTS_BIN=/dev/null
printf '\n$ fm-tasks-axi.sh add queue-demo "Review the deployment plan" --kind docs --repo lab\n'
"$ROOT/bin/fm-tasks-axi.sh" add queue-demo 'Review the deployment plan' --kind docs --repo lab
printf '\n$ fm-captain-hold.sh hold approval-demo --title "Choose a rollout window" --reason "Approve the rollout window" --repo lab\n'
"$ROOT/bin/fm-captain-hold.sh" hold approval-demo --title 'Choose a rollout window' --reason 'Approve the rollout window' --repo lab
printf '\n$ fm-board.sh (first read)\n'
"$ROOT/bin/fm-board.sh" | tee "$E/board-before.txt"
printf '\n$ fm-board.sh (second read; no new event)\n'
"$ROOT/bin/fm-board.sh" | tee "$E/board-reread.txt"
"$ROOT/bin/fm-board.sh" --json > "$E/board-before.json"
jq -e '.counts.needs_you == 1 and .counts.queued == 1 and .groups.needs_you[0].id == "approval-demo"' "$E/board-before.json"
printf 'Use the Tuesday window.\n' > "$LAB/decision.txt"
printf '\n$ fm-captain-hold.sh answer approval-demo --decision-file <decision>\n'
"$ROOT/bin/fm-captain-hold.sh" answer approval-demo --decision-file "$LAB/decision.txt"
printf '\n$ fm-board.sh --skip-done (answered decision omitted; count retained)\n'
"$ROOT/bin/fm-board.sh" --skip-done | tee "$E/board-after-answer.txt"
"$ROOT/bin/fm-board.sh" --json > "$E/board-after-answer.json"
jq -e '.counts.needs_you == 0 and .counts.done == 1 and .counts.queued == 1' "$E/board-after-answer.json"
MATE="$LAB/routed"
"$ROOT/bin/fm-lab-home.sh" create "$MATE"
printf '# Disposable validation home\n' > "$MATE/AGENTS.md"
printf 'routed\n' > "$MATE/.fm-secondmate-home"
printf -- '- routed - Validation domain (home: %s; scope: validation tasks; projects: lab; added 2026-10-20)\n' "$MATE" > "$FM_HOME/data/secondmates.md"
for n in $(seq 1 12); do
  FM_HOME="$MATE" "$ROOT/bin/fm-tasks-axi.sh" add "routed-$n" "Routed follow-up $n" --kind docs --repo lab >/dev/null
done
FM_HOME="$MATE" "$ROOT/bin/fm-captain-hold.sh" hold routed-call --title 'Approve the routed plan' --reason 'Select the routed plan' --repo lab
printf '\n$ FM_HOME=<routed> FM_SNAPSHOT_SECONDMATE_QUEUED=3 fm-home-summary-refresh.sh\n'
FM_HOME="$MATE" FM_SNAPSHOT_SECONDMATE_QUEUED=3 "$ROOT/bin/fm-home-summary-refresh.sh"
cp "$MATE/state/home-summary.json" "$E/routed-home-summary.json"
printf '\n$ fm-board.sh --all (parent consumes published child board)\n'
"$ROOT/bin/fm-board.sh" --all | tee "$E/board-parent.txt"
"$ROOT/bin/fm-board.sh" --json > "$E/board-parent.json"
jq -e 'any(.unavailable[]; .home == "routed" and (.reason | contains("cannot be inside the firstmate repo")))' "$E/board-parent.json"
printf '\nChild aggregation live proof blocked: real secondmate homes must be outside the repository, forbidden by this run worktree boundary. Published bounded ledger captured; parent correctly reports it unavailable.\n'
jq -e '.board.omitted.queued > 0 and ([.board.items[] | select(.group == "queued")] | length) == 3' "$E/routed-home-summary.json"
printf '\n$ fm-session-start.sh (real CLI, isolated home)\n'
"$ROOT/bin/fm-session-start.sh" > "$E/session-start-live.txt" 2>&1
python3 - "$E/session-start-live.txt" <<'PY'
import sys
s=open(sys.argv[1]).read()
a=s.find('Board (bin/fm-board.sh')
print(s[max(0,a-100):a+2200])
assert a >= 0 and 'queue-demo' in s[a:] and '1 done' in s[a:] and 'approval-demo' not in s[a:s.find('Work under way',a) if 'Work under way' in s[a:] else a+2200]
PY
printf '\nLive queue, decision, bounded publication, and digest assertions passed; parent aggregation remains blocked by the worktree boundary.\n'
