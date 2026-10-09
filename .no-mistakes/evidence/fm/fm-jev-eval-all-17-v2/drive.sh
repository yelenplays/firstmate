#!/usr/bin/env bash
set -euo pipefail
export TMPDIR="$PWD/.test-scratch"
export FM_HOME="$PWD/.test-scratch/operator-home"
unset TYPESAFE_API_KEY OPENROUTER_API_KEY FM_JEV_REPLAY_DIR FM_JEV_EVAL_SCORES FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
E=/Users/yelen/.no-mistakes/evidence/01M4G1F9GGK05QXXQEFP8FBMR3
mkdir -p "$FM_HOME/state" "$FM_HOME/config"
{
  printf '$ bin/fm-jev-eval.sh status (empty isolated home)\n'
  bin/fm-jev-eval.sh status
  printf '\n$ bin/fm-jev-eval.sh mode <each configured site>\n'
  while IFS= read -r site; do
    mode=$(bin/fm-jev-eval.sh mode "$site")
    printf '%s: %s\n' "$site" "$mode"
    test "$mode" = advise
  done < <(jq -r '.sites | keys[]' tests/jev-eval/sites.json)
  printf '\n$ bin/fm-jev-eval.sh run --live --site ask-user\n'
  rc=0
  bin/fm-jev-eval.sh run --live --site ask-user >"$TMPDIR/keyless.out" 2>&1 || rc=$?
  printf 'exit=%s\n' "$rc"
  while IFS= read -r line; do printf '%s\n' "$line"; done <"$TMPDIR/keyless.out"
  test "$rc" = 1
  test ! -e "$FM_HOME/state/jev-eval/latest.json"
  printf 'No live scorecard published.\n'
  printf '\n$ bin/fm-jev-eval.sh arm\n'
  bin/fm-jev-eval.sh arm
  test -x "$FM_HOME/state/jev-eval.check.sh"
  test -f "$FM_HOME/state/jev-eval.check-trust"
  printf 'cadence(seconds): %s\n' "$(<"$FM_HOME/state/jev-eval.check-every")"
  printf '\n$ <registered hourly check shim> (no key)\n'
  "$FM_HOME/state/jev-eval.check.sh"
  test ! -e "$FM_HOME/state/jev-eval/nightly.pid"
  printf 'No credentialless nightly started.\n'
  printf '\n$ bin/fm-jev-eval.sh disarm\n'
  bin/fm-jev-eval.sh disarm
  test ! -e "$FM_HOME/state/jev-eval.check.sh"
  test ! -e "$FM_HOME/state/jev-eval.check-trust"
  test ! -e "$FM_HOME/state/jev-eval.check-every"
  printf 'Check shim, cadence, and registration removed.\n'
} >"$E/runtime-guard.txt" 2>&1
{
  for state in 'SSHPASS=hunter2 sshpass -e ssh host' 'DBPASS=hunter2 ./run' 'Call 030/1234/5678' '2026-10-08 Call +1 415 555 2671'; do
    printf '$ bin/fm-jev.sh yes <privacy probe> "May I proceed?"\n'
    rc=0
    bin/fm-jev.sh yes "$state" 'May I proceed?' >"$TMPDIR/privacy.out" 2>&1 || rc=$?
    printf 'input=%s\nexit=%s\n' "$state" "$rc"
    while IFS= read -r line; do printf '%s\n' "$line"; done <"$TMPDIR/privacy.out"
    test "$rc" = 1
    grep -q 'refused, nothing sent' "$TMPDIR/privacy.out"
  done
  . bin/fm-jev-lib.sh
  printf '\nDate followed by phone compacted: %s\n' "$(fm_jev_compact_state '2026-10-08 Call +1 415 555 2671')"
  test ! -e "$FM_HOME/state/jev-calls.jsonl"
  printf 'All probes refused before any attempted model call.\n'
} >"$E/privacy-refusals.txt" 2>&1
printf 'Runtime guard and privacy refusals verified.\n'
FM_JEV_EVAL_OVERLAY="$TMPDIR/no-overlay" bin/fm-jev-eval.sh run --jobs 4 --out "$E/replay-scorecard.json" >"$E/replay-table.txt" 2>&1
jq -e '(.sites | length) == 20 and all(.sites[]; .errors == 0)' "$E/replay-scorecard.json" >/dev/null
printf 'All 20 configured sites replayed without adapter errors.\n'
FM_JEV_EVAL_OVERLAY="$TMPDIR/no-overlay" bin/fm-jev-eval.sh check-baseline >"$E/check-baseline.txt" 2>&1
printf 'Committed baseline verified.\n'
test ! -e "$FM_HOME/state/jev-eval/latest.json"
printf 'Replay did not authorize live autonomy.\n'
