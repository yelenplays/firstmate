#!/usr/bin/env bash
# Run the real fm-dispatch-resolve.sh (typed Jev + runoff) in a lab FM_HOME and show the receipt.
set -u
LAB=$1; TASK=$2
cd /Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M50BACA26BSQG5MZZV0FY8XY
. bin/fm-env-lib.sh
TYPESAFE_API_KEY=$(fmx_env_get TYPESAFE_API_KEY "$HOME/github/firstmate/.env"); export TYPESAFE_API_KEY
export FM_HOME=$LAB
echo "\$ FM_HOME=\$LAB bin/fm-dispatch-resolve.sh $TASK"
out=$(bin/fm-dispatch-resolve.sh "$TASK" 2>"$LAB/dispatch-stderr"); code=$?
printf '%s\n' "$out" | sed "s#$LAB#\$LAB#g"; echo "[exit $code]"
echo "--- stderr:"; sed "s#$LAB#\$LAB#g" "$LAB/dispatch-stderr"
receipt=$(printf '%s\n' "$out" | awk '/^  receipt: / {sub(/^  receipt: /, ""); print}')
echo "--- receipt top level (selected_rule vs first-pass consultation answer):"
[ -n "$receipt" ] && jq '{kind, selected_rule, selected, first_pass_answer: .consultation.answer, outcome, exception, reason}' "$receipt"
echo "--- decisions.jsonl last row selected_rule:"
tail -n 1 "$LAB/state/model-route/decisions.jsonl" 2>/dev/null | jq -c '{selected_rule, selected}'
