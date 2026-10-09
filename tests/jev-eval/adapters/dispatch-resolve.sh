#!/usr/bin/env bash
# Eval adapter for bin/fm-dispatch-resolve.sh: writes the case's brief sections
# into a scratch home with the public rules fixture, a fixed quota snapshot, and
# no spend ledger, then prints the matched rule when the resolver clears or
# picks a profile, or decline when it leaves the choice to firstmate.
# --typed-only scores Jev alone: no backup judge or default stage answers.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
FIX=$(dirname "$0")/../fixtures
mkdir -p "$WORK/home/config" "$WORK/bin"
cp "$FIX/dispatch-rules.json" "$WORK/home/config/crew-dispatch.json"
cat >"$WORK/bin/quota-axi" <<SH
#!/usr/bin/env bash
cat '$FIX/quota.json'
SH
printf '#!/usr/bin/env bash\nprintf %s\\n\n' "'{\"status\":\"unavailable\"}'" >"$WORK/ledger"
chmod +x "$WORK/bin/quota-axi" "$WORK/ledger"
BRIEF=$WORK/brief.md
{
  printf '# Task\n\n'
  if [ "$(jq -r '.input.kind' "$CASE")" = scout ]; then
    printf 'This is a SCOUT task: the deliverable is a written report, not a PR.\n\n'
  fi
  printf "## Captain's intent\n\n%s\n\n" "$(jq -r '.input.intent' "$CASE")"
  spec=$(jq -r '.input.spec // ""' "$CASE")
  [ -z "$spec" ] || printf '## Firstmate spec\n\n%s\n\n' "$spec"
} >"$BRIEF"
PATH="$WORK/bin:$PATH" FM_HOME=$WORK/home FM_SPEND_LEDGER=$WORK/ledger \
  FM_JEV_DISPATCH_COMPACT=${FM_JEV_DISPATCH_COMPACT:-1} \
  "$ROOT/bin/fm-dispatch-resolve.sh" "$BRIEF" --typed-only --project "$(jq -r '.input.project' "$CASE")" >"$WORK/out" 2>"$WORK/err"
status=$(awk '$1 == "status:" { print $2; exit }' "$WORK/out")
rule=$(awk '$1 == "rule:" { print $2; exit }' "$WORK/out")
case "$status" in
  clear|picked) printf '%s\t%s\n' "${rule:-default}" "$status" ;;
  '') printf 'decline\tno-status\n' ;;
  *) printf 'decline\t%s:%s\n' "$status" "${rule:-none}" ;;
esac
