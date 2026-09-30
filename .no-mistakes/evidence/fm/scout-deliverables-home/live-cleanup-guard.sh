#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$(mktemp -d "$ROOT/.l.XXXXXX")
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
"$ROOT/bin/fm-lab-home.sh" create "$LAB"
trap 'rm -rf "$LAB"' EXIT
export FM_HOME="$LAB" HOME="$LAB/user"
export XDG_CACHE_HOME="$LAB/user/.cache" XDG_CONFIG_HOME="$LAB/user/.config" XDG_DATA_HOME="$LAB/user/.local/share"
export TMUX="$LAB/tmux/tmux-$(id -u)/fm-lab,0,0"
mkdir -p "$HOME" "$LAB/projects/sample" "$LAB/data/sibling-task"
printf 'manual\n' > "$LAB/config/backlog-backend"
printf 'sibling deliverable\n' > "$LAB/data/sibling-task/keep.txt"
PROJ="$LAB/projects/sample"
git -C "$PROJ" init -q -b main
printf 'max_trees = 1\nroot = "%s"\n' "$PROJ" > "$PROJ/treehouse.toml"
printf 'item,value\na,1\n' > "$PROJ/measurements.csv"
git -C "$PROJ" add .
git -C "$PROJ" -c user.name=Lab -c user.email=lab@example.invalid commit -qm 'Seed guard test'
WT=$(cd "$PROJ" && treehouse get --lease --lease-holder scout-guard)
"$ROOT/bin/fm-brief.sh" guard-results sample --scout
printf 'window=primary:fm-guard-results\nendpoint_task_id=guard-results\nworktree=%s\nproject=%s\nkind=scout\nmode=local-only\nspawn_gen=live-guard\n' "$WT" "$PROJ" > "$LAB/state/guard-results.meta"
printf '# Guard report\nNo open decisions.\n' > "$WT/report.md"
printf 'item,value\na,1\n' > "$WT/results.csv"
printf 'disposable note\n' > "$WT/scratch.txt"
# Attempt cleanup with a report only in the disposable directory.
rc=0
"$ROOT/bin/fm-teardown.sh" guard-results > "$LAB/refusal.txt" 2>&1 || rc=$?
printf 'Cleanup with worktree-only report returned exit %s\n' "$rc"
cat "$LAB/refusal.txt"
[ "$rc" -ne 0 ]
grep -q 'has no report at' "$LAB/refusal.txt"
[ -f "$WT/report.md" ] && [ -f "$WT/results.csv" ] && [ -f "$WT/scratch.txt" ] && [ -f "$LAB/state/guard-results.meta" ]
printf 'Refusal preserved the leased worktree, scratch files, result CSV and task metadata.\n'
cp "$WT/report.md" "$WT/results.csv" "$LAB/data/guard-results/"
# A report alone must not skip unresolved-decision completion.
rc=0
"$ROOT/bin/fm-teardown.sh" guard-results > "$LAB/completion-refusal.txt" 2>&1 || rc=$?
printf 'Cleanup without completion attestation returned exit %s\n' "$rc"
cat "$LAB/completion-refusal.txt"
[ "$rc" -ne 0 ]
grep -q 'has not passed the captain-call completion gate' "$LAB/completion-refusal.txt"
[ -f "$WT/scratch.txt" ] && [ -f "$LAB/state/guard-results.meta" ]
"$ROOT/bin/fm-captain-hold.sh" complete guard-results --none
(cd "$LAB/data" && sha256sum guard-results/report.md guard-results/results.csv sibling-task/keep.txt) > "$LAB/before"
"$ROOT/bin/fm-teardown.sh" guard-results
(cd "$LAB/data" && sha256sum guard-results/report.md guard-results/results.csv sibling-task/keep.txt) > "$LAB/after"
cmp "$LAB/before" "$LAB/after"
[ ! -e "$WT/report.md" ] && [ ! -e "$WT/results.csv" ] && [ ! -e "$WT/scratch.txt" ]
[ ! -e "$LAB/state/guard-results.meta" ]
printf 'After satisfying both guards: all scratch files removed; durable report, CSV and unrelated sibling file byte-identical.\n'
cat "$LAB/after"
(cd "$PROJ" && treehouse status)
