#!/usr/bin/env bash
# Eval adapter for bin/fm-jev-pr-verdict.sh: answers the GitHub metadata calls
# from the case's bounded facts through a fake gh-axi and one share-safe card,
# and prints Jev's own pick (before the deterministic override) as pass or
# concerns; no advisory prints none.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
mkdir -p "$WORK/home/state" "$WORK/bin" "$WORK/wikis/routing/cards"
printf 'repo: eval-org/eval-wiki\nshare_tier: %s\nshare_gate: rein\ncloud: ja\nmodus: voll\n' \
  "$(jq -r '.input.tier' "$CASE")" >"$WORK/wikis/routing/cards/eval.yaml"
files=$(jq -r '.input | [.files, .restricted, .generated, .prose, .tooling] | map(tostring) | join("|")' "$CASE")
checks=$(jq -r '.input | [.checks, .pending, .failing] | map(tostring) | join("|")' "$CASE")
cat >"$WORK/bin/gh-axi" <<SH
#!/usr/bin/env bash
case "\$2" in
  */pulls/7) if [ "\${4:-}" = '.head.sha' ]; then body=0123456789abcdef0123456789abcdef01234567; else body='open|false|0123456789abcdef0123456789abcdef01234567|main'; fi ;;
  */files\\?*) body='$files' ;;
  */check-runs\\?*) body='$checks' ;;
  *) exit 1 ;;
esac
printf 'api_response:\n  body: %s\n  truncated: false\n' "\$body"
SH
chmod +x "$WORK/bin/gh-axi"
PATH="$WORK/bin:$PATH" FM_HOME=$WORK/home FM_WIKI_ROOT=$WORK/wikis \
  "$ROOT/bin/fm-jev-pr-verdict.sh" https://github.com/eval-org/eval-wiki/pull/7 >"$WORK/out" 2>"$WORK/err" || true
log=$WORK/home/state/jev-pr-verdict.jsonl
[ -s "$log" ] || { printf 'none\tno-advisory\n'; exit 0; }
jq -r '"\(.jev_choice)\tp=\(.jev_probability) final=\(.verdict)"' "$log" | tail -n 1
