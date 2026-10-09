#!/usr/bin/env bash
# Drives the real bin/fm-jev-ask-user.sh (head and base) inside a disposable lab
# home. One task per case: a real ask-user needs-decision line, brief, findings
# snapshot and an inbox steer carrying the case text. JEV_URL points at a local
# capture endpoint, so "reached Jev" means the CLI really POSTed the state.
# Usage: drive-live.sh <worktree> <base-bin-root> <cases.json> <out-dir>
set -u
WT=$1 BASE=$2 CASES=$3 OUT=$4
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
PORT=$((20000 + RANDOM % 20000))
REQ="$LAB/requests"; mkdir -p "$REQ"
python3 -I "$(dirname "$0")/capture-endpoint.py" "$PORT" "$REQ" & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$LAB"' EXIT
sleep 1
cat > "$LAB/send-recorder" <<'R'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_HOME/last-send-args"
R
chmod +x "$LAB/send-recorder"
PROJECT="$LAB/projects/sample"; mkdir -p "$PROJECT"
GATE=nm-01M4LIVE000000000000000000-review
n=0
: > "$OUT/results.tsv"
while IFS= read -r row; do
  n=$((n + 1))
  id=$(jq -r .id <<<"$row"); text=$(jq -r .text <<<"$row")
  findings_file=$(jq -r '.findings_file // ""' <<<"$row")
  ids=$(jq -r '.finding_ids // "F1"' <<<"$row")
  for side in head base; do
    task="t$n$side"
    mkdir -p "$LAB/state/$task.inbox/handled" "$LAB/data/$task"
    printf 'kind=ship\nmode=no-mistakes\nproject=%s\n' "$PROJECT" > "$LAB/state/$task.meta"
    F="$LAB/data/$task/$GATE-findings.txt"
    if [ -n "$findings_file" ]; then cp "$findings_file" "$F"; else
      printf 'id: F1\nseverity: warning\nfile: tests/parse.test.sh\nline: 3\ndescription: No test covers a final line without a trailing newline.\nauthority: ask-user\n' > "$F"
    fi
    printf '# Task\n## Captain'"'"'s intent\nMake the parser keep every field.\n\n## Firstmate spec\n- Fix bin/parse.sh and add a regression test.\n' > "$LAB/data/$task/brief.md"
    printf 'schema=fm-task-inbox.v1\nat=2026-10-09T18:00:00Z\n--\n%s\n' "$text" > "$LAB/state/$task.inbox/handled/001.msg"
    printf 'needs-decision [at=1791571614] [key=%s]: ask-user findings=%s file=%s\n' "$GATE" "$ids" "$F" > "$LAB/state/$task.status"
    root=$WT; [ "$side" = base ] && root=$BASE
    before=$(ls "$REQ" | wc -l | tr -d ' ')
    out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_HOME="$LAB" TYPESAFE_API_KEY=ts-live-lab-dummy-key-0123456789 \
      JEV_URL="http://127.0.0.1:$PORT/v1/systemone" FM_WIKIS_ROOT="$LAB/no-wikis" \
      FM_JEV_ASK_USER_SEND="$LAB/send-recorder" "$root/bin/fm-jev-ask-user.sh" "$task" "$GATE" --round 1 2>&1)
    code=$?
    after=$(ls "$REQ" | wc -l | tr -d ' ')
    sent_req=$((after - before)); exact=-
    if [ "$sent_req" -gt 0 ]; then
      last=$(ls "$REQ" | sort | tail -n 1)
      if jq -r .state "$REQ/$last" | grep -qF -- "$(printf '%s' "$text" | head -n 1)"; then exact=yes; else exact=no; fi
      [ "$side" = head ] && cp "$REQ/$last" "$OUT/request-$id.json"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$side" "$code" "$sent_req" "$exact" "$(head -n 1 <<<"$out")" >> "$OUT/results.tsv"
  done
done < <(jq -c '.[]' "$CASES")
cp "$LAB/state/jev-ask-user.jsonl" "$OUT/jev-ask-user.jsonl" 2>/dev/null
