#!/usr/bin/env bash
# Live drive of bin/fm-task-execution.sh against a disposable lab home and a real git worktree.
set -u
R=$1 LAB=$2
export FM_HOME="$LAB" FM_BACKEND=tmux FM_EXECUTION_SCAN_INTERVAL=0
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE
EXEC="$R/bin/fm-task-execution.sh"
step() { printf '\n$ %s\n' "$*"; }
cp "$R/.tasks.toml" "$LAB/.tasks.toml"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
tasks-axi add busy-worker 'Approved implementation' --kind ship --start --file "$LAB/data/backlog.md" >/dev/null
P="$LAB/projects/demo"; mkdir -p "$P"; git -C "$P" init -q; git -C "$P" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$P" worktree add -q "$LAB/wt" -b fm/busy-worker
printf 'kind=ship\nwindow=fake\nworktree=%s\nproject=%s\nspawn_gen=g1\nharness=codex\n' "$LAB/wt" "$P" > "$LAB/state/busy-worker.meta"
step "$EXEC approve busy-worker --basis captain-approved"; "$EXEC" approve busy-worker --basis captain-approved; echo rc=$?
step "TOKEN=\$($EXEC attempt busy-worker --spawn-gen g1)"; TOKEN=$("$EXEC" attempt busy-worker --spawn-gen g1); echo "token issued (rc=$?)"
echo; echo '### Baseline (the reported false alarm): busy worker posts plain working:/paused: lines, never runs started'
step "echo 'working [at=1]: implementing' >> state/busy-worker.status  (old plain recipe)"; echo 'working [at=1]: implementing' >> "$LAB/state/busy-worker.status"
step "$EXEC confirmed busy-worker"; "$EXEC" confirmed busy-worker; echo rc=$?
step "$EXEC show busy-worker"; "$EXEC" show busy-worker
echo; echo '### Adversarial: receipt-bearing status from the PRIMARY checkout (safety report path)'
step "(cd $P && $EXEC status busy-worker \$TOKEN 'blocked [at=2]: launched in primary checkout')"; (cd "$P" && "$EXEC" status busy-worker "$TOKEN" 'blocked [at=2]: launched in primary checkout'); echo rc=$?
step "tail -n1 state/busy-worker.status"; /usr/bin/tail -n 1 "$LAB/state/busy-worker.status"
step "$EXEC confirmed busy-worker"; "$EXEC" confirmed busy-worker; echo rc=$?
echo; echo '### Adversarial: from a subdirectory of the worktree'
mkdir -p "$LAB/wt/pkg/foo"
step "(cd wt/pkg/foo && $EXEC status busy-worker \$TOKEN 'paused [at=3]: waiting on build')"; (cd "$LAB/wt/pkg/foo" && "$EXEC" status busy-worker "$TOKEN" 'paused [at=3]: waiting on build'); echo rc=$?
step "tail -n1 state/busy-worker.status"; /usr/bin/tail -n 1 "$LAB/state/busy-worker.status"
step "$EXEC confirmed busy-worker"; "$EXEC" confirmed busy-worker; echo rc=$?
echo; echo '### Adversarial: stale token and multi-line from the worktree are refused and append nothing'
before=$(wc -l < "$LAB/state/busy-worker.status")
step "(cd wt && $EXEC status busy-worker stale 'working: stale')"; (cd "$LAB/wt" && "$EXEC" status busy-worker stale 'working: stale'); echo rc=$?
step "(cd wt && $EXEC status busy-worker \$TOKEN \$'working: a\\nworking: b')"; (cd "$LAB/wt" && "$EXEC" status busy-worker "$TOKEN" $'working: a\nworking: b'); echo rc=$?
echo "status lines before=$before after=$(wc -l < "$LAB/state/busy-worker.status")"
step "$EXEC confirmed busy-worker"; "$EXEC" confirmed busy-worker; echo rc=$?
echo; echo '### Adversarial: worker relaunched (spawn_gen g2) - old-generation token must not confirm'
sed -i '' 's/spawn_gen=g1/spawn_gen=g2/' "$LAB/state/busy-worker.meta"
step "(cd wt && $EXEC status busy-worker \$TOKEN 'working: old incarnation')"; (cd "$LAB/wt" && "$EXEC" status busy-worker "$TOKEN" 'working: old incarnation'); echo rc=$?
step "$EXEC confirmed busy-worker"; "$EXEC" confirmed busy-worker; echo rc=$?
sed -i '' 's/spawn_gen=g2/spawn_gen=g1/' "$LAB/state/busy-worker.meta"
echo; echo '### Fix: normal status reporting from the isolated worktree root confirms processing'
step "(cd wt && $EXEC status busy-worker \$TOKEN 'working [at=4]: implementing feature')"; (cd "$LAB/wt" && "$EXEC" status busy-worker "$TOKEN" 'working [at=4]: implementing feature'); echo rc=$?
step "tail -n1 state/busy-worker.status"; /usr/bin/tail -n 1 "$LAB/state/busy-worker.status"
step "$EXEC confirmed busy-worker"; "$EXEC" confirmed busy-worker; echo rc=$?
step "jq -c . state/busy-worker.execution (token redacted)"; jq -c '.attempt="<redacted>"' "$LAB/state/busy-worker.execution"
step "$EXEC show busy-worker"; "$EXEC" show busy-worker
