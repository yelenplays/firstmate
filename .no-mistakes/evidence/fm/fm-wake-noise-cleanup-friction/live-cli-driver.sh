#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/Users/yelen/.no-mistakes/evidence/01M4EXVAYQS1J60HP0BRK1QTTF
LAB=$(mktemp -d "$ROOT/.test-tmp/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_CREW_STATE_BIN TASKS_AXI_FILE TASKS_AXI_BACKEND FM_TASK_ID
export FM_HOME=$LAB TMPDIR="$ROOT/.test-tmp" FM_BACKEND=tmux FM_EXECUTION_SCAN_INTERVAL=0
bin/fm-lab-home.sh create "$LAB"
cp .tasks.toml "$LAB/.tasks.toml"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
tasks() { bin/fm-tasks-axi.sh "$@"; }
ack() {
  bin/fm-wake-drain.sh > "$LAB/drain" 2> "$LAB/drain.err"
  printf '\n--- Drain ---\n'; python3 -c 'import sys;print(open(sys.argv[1]).read())' "$LAB/drain"
  python3 - "$LAB/drain.err" "$ROOT/bin/fm-wake-drain.sh" <<'PY'
import re, subprocess, sys
text=open(sys.argv[1]).read()
m=re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', text)
if m: subprocess.run([sys.argv[2], '--ack-through',m[1], '--recovery-generation',m[2]],check=True)
PY
}
printf '\n=== Approve queued implementation; notification then acknowledged restart ===\n'
tasks add approved-change 'Implement the accepted feature' --kind ship
bin/fm-task-execution.sh approve approved-change --basis captain-approved
bin/fm-task-execution.sh notify | tee "$LAB/initial"
test -s "$LAB/initial"
ack
for i in 1 2 3; do bin/fm-task-execution.sh notify > "$LAB/repeat"; test ! -s "$LAB/repeat"; done
printf 'Three fresh notify processes after acknowledgement produced no repeated wake.\n'
bin/fm-task-execution.sh show approved-change
printf '\n=== A real hold transfers ownership; release notifies once ===\n'
tasks hold approved-change --reason 'Choose implementation scope' --kind captain
bin/fm-task-execution.sh notify > "$LAB/held"; test ! -s "$LAB/held"
bin/fm-task-execution.sh show approved-change
tasks unhold approved-change
bin/fm-task-execution.sh notify | tee "$LAB/released"; test -s "$LAB/released"
ack
bin/fm-task-execution.sh notify > "$LAB/repeat"; test ! -s "$LAB/repeat"
printf 'Release notified once; unchanged repeat stayed silent.\n'
printf '\n=== One-call cleanup of completed endpoint-free legacy scout ===\n'
tasks add empty-review 'Review the implementation' --kind scout
tasks start empty-review
mkdir -p "$LAB/data/empty-review" "$LAB/projects/demo"
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$LAB/projects/demo" init -q
printf 'kind=scout\nwindow=\nproject=%s/projects/demo\nworktree=%s/removed-scratch\nmode=local-only\n' "$LAB" "$LAB" > "$LAB/state/empty-review.meta"
printf '# Review report\nReviewed the implementation. No choices or reusable guide remain.\n' > "$LAB/data/empty-review/report.md"
printf 'Wiki guide contract: required\n' > "$LAB/data/empty-review/brief.md"
bin/fm-teardown.sh empty-review --scout-complete
 test ! -e "$LAB/state/empty-review.meta"
test -f "$LAB/data/empty-review/report.md"
test -f "$LAB/data/empty-review/guide.md"
tasks show empty-review
python3 -c 'import sys;print(open(sys.argv[1]).read())' "$LAB/data/empty-review/guide.md"
printf '\n=== Adversarial open status key refuses empty completion ===\n'
tasks add pending-review 'Review with unresolved choice' --kind scout
tasks start pending-review
mkdir -p "$LAB/data/pending-review"
printf 'kind=scout\nwindow=\nproject=%s/projects/demo\nworktree=%s/removed-scratch\nmode=local-only\n' "$LAB" "$LAB" > "$LAB/state/pending-review.meta"
printf '# Report\nA choice remains outstanding.\n' > "$LAB/data/pending-review/report.md"
printf 'Wiki guide contract: required\n' > "$LAB/data/pending-review/brief.md"
printf 'blocked [key=choose]: selection needed\n' > "$LAB/state/pending-review.status"
if bin/fm-teardown.sh pending-review --scout-complete; then echo 'FAIL: cleaned unresolved scout'; exit 1; fi
test -f "$LAB/state/pending-review.meta"; test ! -e "$LAB/data/pending-review/guide.md"
printf 'Refused; runtime record and report retained; no guide synthesized.\n'
printf '\n=== Uninventoried captain-held call refuses completion ===\n'
printf 'resolved [key=choose]: selection recorded\n' >> "$LAB/state/pending-review.status"
bin/fm-captain-hold.sh hold review-choice --title 'Choose approach' --reason 'Scope choice' --origin pending-review
if bin/fm-captain-hold.sh verify pending-review --allow-empty; then echo 'FAIL: ignored captain-held call'; exit 1; fi
test -f "$LAB/state/pending-review.meta"
printf 'Uninventoried origin call refused empty verification.\n'
printf '\n=== Generated worker handoff contract (public emitted brief) ===\n'
bin/fm-brief.sh emitted-review demo --scout > "$LAB/brief-output"
cp "$LAB/data/emitted-review/brief.md" "$EVIDENCE/emitted-scout-brief.md"
printf 'Scaffolded scout brief saved as emitted-scout-brief.md (not a model-interpretation proof).\n'
