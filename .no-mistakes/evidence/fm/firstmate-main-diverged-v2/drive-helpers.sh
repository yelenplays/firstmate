#!/usr/bin/env bash
# Live drive of bin/fm-jev-status-triage.sh and bin/fm-jev-wedge-check.sh with
# real curl against a local fake TypeSafe endpoint (fake_jev.py).
set -u; export LC_ALL=C LC_NUMERIC=C
ROOT=${ROOT:?}; EV=${EV:?}
T=$(mktemp -d /tmp/fmjev-live.XXXXXX); REC=$T/rec; mkdir -p $REC
PORT=$((20000 + RANDOM % 20000))
python3 $EV/fake_jev.py $PORT $REC & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
sleep 0.7
export TYPESAFE_API_KEY=tsk-live-drive-secret-KEY123 JEV_URL=http://127.0.0.1:$PORT/v1/systemone
unset OPENROUTER_API_KEY JEV_TIMEOUT JEV_ROUTE FM_STATE_OVERRIDE
PRIMARY=$T/primary; SECOND=$T/second; mkdir -p $PRIMARY/state $SECOND/state; touch $SECOND/.fm-secondmate-home
OTHER=$T/wiki-project; mkdir -p $OTHER; git -C $OTHER init -q; git -C $OTHER remote add origin https://github.com/example/wiki.git
SMPROJ=$T/sm-project; mkdir -p $SMPROJ; touch $SMPROJ/.fm-secondmate-home
for h in $PRIMARY $SECOND; do
  printf 'kind=ship\nproject=%s\n' "$ROOT" > $h/state/fmtask.meta
  printf 'kind=ship\nproject=%s\n' "$OTHER" > $h/state/wikitask.meta
  printf 'kind=ship\nproject=%s\n' "$SMPROJ" > $h/state/smtask.meta
done
mode() { printf '%s' "$1" > $REC/mode; }
last_body() { tail -1 $REC/requests.jsonl | jq -c '.body.state'; }
run() {  # <label> <helper> <home> <task|-> <input>
  local label=$1 helper=$2 home=$3 task=$4 input=$5 args=() t0 t1 out rc
  [ "$task" = - ] || args=(--task "$task" --state-dir "$home/state")
  t0=$(python3 -c 'import time;print(time.time())')
  out=$(printf '%s' "$input" | FM_HOME=$home "$ROOT/bin/$helper" "${args[@]}" 2>$T/err); rc=$?
  t1=$(python3 -c 'import time;print(time.time())')
  printf '\n### %s\n$ printf ... | FM_HOME=%s bin/%s %s\n' "$label" "${home##*/}" "$helper" "${args[*]}"
  printf 'stdout=%q exit=%s elapsed=%.2fs stderr=%s\n' "$out" "$rc" "$(python3 -c "print($t1-$t0)")" "$(tr '\n' ' ' < $T/err)"
}
LINE='note: pushed fix; gho_AbCdEf0123456789 in log, DB_PASSWORD="alpha\"omega" leftover, need captain sign-off?'
echo "== S1 eligible firstmate-repo task in primary home: compacted free text, secrets stripped =="
mode noul=0.82; run "status escalate" fm-jev-status-triage.sh $PRIMARY fmtask "$LINE"
echo "request state sent: $(last_body)"
echo "auth header: $(tail -1 $REC/requests.jsonl | jq -r .auth | sed 's/tsk-live-drive-secret-KEY123/<key matches configured key>/')"
echo "audit record: $(tail -1 $PRIMARY/state/jev-status-triage.jsonl)"
mode noul=0.12; run "status suppress" fm-jev-status-triage.sh $PRIMARY fmtask 'working: running tests, 40% through'
echo "audit record: $(tail -1 $PRIMARY/state/jev-status-triage.jsonl | jq -c '{status,noul,payload}')"
echo; echo "== S2 data boundary: non-eligible callers send structured facts only =="
SECRET='acme-confidential-merger: draft ready for contoso'
mode noul=0.7
for c in "secondmate home|$SECOND|fmtask" "secondmate task|$PRIMARY|smtask" "other-project task|$PRIMARY|wikitask" "no --task|$PRIMARY|-"; do
  IFS='|' read -r lbl h tk <<<"$c"
  run "status $lbl" fm-jev-status-triage.sh $h $tk "$SECRET"
  echo "request state sent: $(last_body)"
  echo "audit record: $(tail -1 $h/state/jev-status-triage.jsonl | jq -c '{status,payload,line_excerpt,line_chars}')"
done
run "status known verb, other-project task" fm-jev-status-triage.sh $PRIMARY wikitask 'note: contoso deal memo drafted'
echo "request state sent: $(last_body)"
echo "leak check (acme|contoso|merger in any request body or audit record outside eligible fmtask):"
grep -c -iE 'acme|contoso|merger' $REC/requests.jsonl $SECOND/state/*.jsonl || true
echo; echo "== S3 wedge check =="
PANE=$'$ claude\n> Allow edit to src/app.ts? (y/n)\n  waiting for approval - ghs_ZZZ999abc secret'
mode noul=0.69; run "wedge eligible escalate" fm-jev-wedge-check.sh $PRIMARY fmtask "$PANE"
echo "request state sent: $(last_body)"
echo "audit record: $(tail -1 $PRIMARY/state/jev-wedge-check.jsonl | jq -c '{status,noul,payload,tail_excerpt}')"
mode noul=0.2; run "wedge other-project suppress" fm-jev-wedge-check.sh $PRIMARY wikitask "$PANE"
echo "request state sent: $(last_body)"
echo "audit record: $(tail -1 $PRIMARY/state/jev-wedge-check.jsonl | jq -c '{status,noul,payload,tail_excerpt}')"
echo; echo "== S4 fail closed =="
mode hang; run "black-holed endpoint, default supervision bound" fm-jev-status-triage.sh $PRIMARY fmtask 'blocked: x'
printf 'JEV_TIMEOUT=1\n' > $PRIMARY/.env
run "black-holed endpoint, JEV_TIMEOUT=1 in \$FM_HOME/.env (status)" fm-jev-status-triage.sh $PRIMARY fmtask 'blocked: x'
run "black-holed endpoint, JEV_TIMEOUT=1 in \$FM_HOME/.env (wedge)" fm-jev-wedge-check.sh $PRIMARY fmtask "$PANE"
rm $PRIMARY/.env
mode http=503; run "http 503" fm-jev-status-triage.sh $PRIMARY fmtask 'blocked: x'
mode garbage; run "out-of-range noul" fm-jev-status-triage.sh $PRIMARY fmtask 'blocked: x'
run "out-of-range noul (wedge)" fm-jev-wedge-check.sh $PRIMARY fmtask "$PANE"
echo "error audit records: $(jq -c '{status,http,decide_code}' $PRIMARY/state/jev-status-triage.jsonl | tail -4 | tr '\n' ' ')"
( unset TYPESAFE_API_KEY; mode noul=0.9; run "no key configured" fm-jev-status-triage.sh $PRIMARY fmtask 'blocked: x' )
echo; echo "key leak check across all audit logs: $(cat $PRIMARY/state/*.jsonl $SECOND/state/*.jsonl | grep -c 'tsk-live-drive-secret-KEY123\|gho_AbCd\|ghs_ZZZ\|alpha' || true) hits"
echo "total requests reaching endpoint: $(wc -l < $REC/requests.jsonl)"
