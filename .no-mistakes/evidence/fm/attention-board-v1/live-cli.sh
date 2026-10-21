#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=/Users/yelen/.no-mistakes/evidence/01M5G097QX1HT5QR2KEXWQZZBK
export TMPDIR="$ROOT/.test-validation/tmp"
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND FM_GATE_REFUSE_BYPASS
LAB=$(mktemp -d "$TMPDIR/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB"
export FM_HOME="$LAB"
{
  echo '$ fm-tasks-axi.sh add investigate "Investigate the release delay" --kind scout --repo demo'
  bin/fm-tasks-axi.sh add investigate 'Investigate the release delay' --kind scout --repo demo
  bin/fm-tasks-axi.sh add implement 'Implement the approved change' --kind ship --repo demo
  bin/fm-tasks-axi.sh add document 'Document the release' --kind docs --repo demo
  echo '$ fm-captain-hold.sh hold investigate --reason "Choose the deployment window"'
  bin/fm-captain-hold.sh hold investigate --reason 'Choose the deployment window'
  python3 - "$LAB" "$E/live-home-before-board.json" <<'PY'
import hashlib,json,sys
from pathlib import Path
home=Path(sys.argv[1])
snapshot={str(p.relative_to(home)):hashlib.sha256(p.read_bytes()).hexdigest() for d in ('state','data') for p in (home/d).rglob('*') if p.is_file()}
Path(sys.argv[2]).write_text(json.dumps(snapshot,sort_keys=True,indent=2))
PY
  echo '$ fm-board.sh --home-only'
  bin/fm-board.sh --home-only | tee "$E/live-board-held.txt"
  bin/fm-board.sh --json --home-only > "$E/live-board-held.json"
  bin/fm-board.sh --json --home-only > "$LAB/repeated.json"
  jq -e '.counts.needs_you == 1 and .counts.queued == 2 and .groups.needs_you[0].id == "investigate" and .groups.needs_you[0].detail == "Choose the deployment window"' "$E/live-board-held.json" >/dev/null
  diff <(jq '.groups' "$E/live-board-held.json") <(jq '.groups' "$LAB/repeated.json")
  python3 - "$LAB" "$E/live-home-before-board.json" <<'PY'
import hashlib,json,sys
from pathlib import Path
home=Path(sys.argv[1])
now={str(p.relative_to(home)):hashlib.sha256(p.read_bytes()).hexdigest() for d in ('state','data') for p in (home/d).rglob('*') if p.is_file()}
assert now == json.loads(Path(sys.argv[2]).read_text())
print('Repeated board reads preserved every data/ and state/ file byte-for-byte.')
PY
  echo '$ FM_BOARD_SHOW=1 fm-board.sh --home-only'
  FM_BOARD_SHOW=1 bin/fm-board.sh --home-only | tee "$E/live-board-bounded.txt"
  grep -q 'QUEUED (2, showing 1' "$E/live-board-bounded.txt"
  echo '$ FM_BOARD_SHOW=1 fm-board.sh --all --home-only'
  FM_BOARD_SHOW=1 bin/fm-board.sh --all --home-only | tee "$E/live-board-all.txt"
  grep -q 'QUEUED (2)' "$E/live-board-all.txt"
  echo '$ fm-home-summary-refresh.sh'
  bin/fm-home-summary-refresh.sh
  cp "$LAB/state/home-summary.json" "$E/live-home-summary.json"
  jq -e '.board.schema == "fm-board-home.v1" and (.board.items | length) == 3' "$E/live-home-summary.json" >/dev/null
  echo '$ two simultaneous fm-main-sync.sh processes (no PR tasks)'
  bin/fm-main-sync.sh > "$LAB/sync1.log" & p1=$!
  bin/fm-main-sync.sh > "$LAB/sync2.log" & p2=$!
  wait "$p1"; wait "$p2"
  python3 - "$LAB/sync1.log" "$LAB/sync2.log" "$E/live-sync-contention.txt" <<'PY'
import sys
from pathlib import Path
out=''.join(Path(p).read_text() for p in sys.argv[1:3])
print(out, end='')
Path(sys.argv[3]).write_text(out)
assert 'fm-main-sync skipped: another run holds' in out
PY
  test ! -e "$LAB/state/.main-sync.lock"
  echo '$ fm-captain-hold.sh answer investigate --decision-file <answer>'
  printf 'Use the next scheduled deployment window.\n' > "$LAB/answer.txt"
  bin/fm-captain-hold.sh answer investigate --decision-file "$LAB/answer.txt"
  echo '$ fm-board.sh --home-only'
  bin/fm-board.sh --home-only | tee "$E/live-board-answered.txt"
  bin/fm-board.sh --json --home-only > "$E/live-board-answered.json"
  jq -e '.counts.needs_you == 0 and .counts.done == 1 and .counts.queued == 2' "$E/live-board-answered.json" >/dev/null
} > "$E/live-cli-transcript.txt" 2>&1
