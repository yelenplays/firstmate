#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=/Users/yelen/.no-mistakes/evidence/01M5G097QX1HT5QR2KEXWQZZBK
export TMPDIR="$ROOT/.test-validation/tmp"
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND FM_GATE_REFUSE_BYPASS
LAB=$(mktemp -d "$TMPDIR/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME="$LAB"
# Serialized status/meta protocol inputs, not a live worker or real GitHub PR.
bin/fm-tasks-axi.sh add approval 'Reported-only PR awaiting approval' --kind ship --repo demo >/dev/null
bin/fm-tasks-axi.sh start approval >/dev/null
printf 'kind=ship\nmode=no-mistakes\nspawn_gen=protocol.approval\n' > "$LAB/state/approval.meta"
{
  echo 'PROTOCOL-INPUT CHECK ONLY: no worker or real PR was launched.'
  for event in 'note: review evidence collected' 'resolved [key=unrelated]: unrelated question answered' 'captain-held [key=unrelated]: unrelated question transferred'; do
    printf 'done: PR https://github.com/acme/demo/pull/181 checks green\n%s\n' "$event" > "$LAB/state/approval.status"
    echo "After $event"
    bin/fm-board.sh --json --home-only > "$LAB/board.json"
    jq -e '.counts.ready == 1 and .groups.ready[0].url == "https://github.com/acme/demo/pull/181"' "$LAB/board.json" >/dev/null
    bin/fm-board.sh --home-only
  done
  printf 'done: PR https://github.com/acme/demo/pull/181 checks green\nneeds-decision [key=release]: Choose release window\nresolved [key=unrelated]: Other question answered\nnote: review evidence collected\n' > "$LAB/state/approval.status"
  echo 'An unrelated resolution and later note do not hide an open decision:'
  bin/fm-board.sh --json --home-only > "$LAB/board.json"
  jq -e '.counts.ready == 0 and .counts.needs_you == 1 and .groups.needs_you[0].reason == "needs-decision"' "$LAB/board.json" >/dev/null
  bin/fm-board.sh --home-only
  printf 'resolved [key=release]: Next window\ndone: PR https://github.com/acme/demo/pull/181 checks green\n' >> "$LAB/state/approval.status"
  echo 'Resolving the actual decision and reporting done restores ready:'
  bin/fm-board.sh --json --home-only > "$LAB/board.json"
  jq -e '.counts.ready == 1 and .counts.needs_you == 0' "$LAB/board.json" >/dev/null
  bin/fm-board.sh --home-only
  printf 'working: addressing review\nnote: halfway\n' >> "$LAB/state/approval.status"
  echo 'Resumed work invalidates readiness even beneath a later note:'
  bin/fm-board.sh --json --home-only > "$LAB/board.json"
  jq -e '.counts.ready == 0 and .counts.working == 1' "$LAB/board.json" >/dev/null
  bin/fm-board.sh --home-only
} > "$E/lifecycle-protocol-transcript.txt" 2>&1
