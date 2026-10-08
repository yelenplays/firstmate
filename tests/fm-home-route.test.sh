#!/usr/bin/env bash
# Public CLI tests for the typed intake home router and its fm-spawn gate.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TOOL="$ROOT/bin/fm-home-route.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-route)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
BASE_PATH=$PATH
mkdir -p "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/state"
REG="$HOME_DIR/data/secondmates.md"
APPROVAL="$HOME_DIR/config/jev-mate-public-scopes.json"
LOG="$HOME_DIR/state/home-route.jsonl"
PAYLOAD="$TMP_ROOT/payload"
RESPONSE="$TMP_ROOT/response"
export FM_ROUTE_PAYLOAD="$PAYLOAD" FM_ROUTE_RESPONSE="$RESPONSE"
unset TYPESAFE_API_KEY OPENROUTER_API_KEY JEV_ROUTE JEV_URL JEV_MODEL
# The fake endpoint records the request body and answers from $FM_ROUTE_RESPONSE;
# an absent response file stands for an endpoint that does not answer.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s' "$(</dev/stdin)" >> "$FM_ROUTE_PAYLOAD"
[ -f "$FM_ROUTE_RESPONSE" ] || exit 7
printf '200'
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    shift
    cp "$FM_ROUTE_RESPONSE" "$1"
    break
  fi
  shift
done
SH
chmod +x "$FAKEBIN/curl"
# The fake backup judge records its prompt and answers FM_BACKUP_ANSWER as
# structured output, or exits 1 when FM_BACKUP_ANSWER is unset.
BACKUP_PROMPT="$TMP_ROOT/backup-prompt"
export BACKUP_PROMPT
cat > "$FAKEBIN/fake-claude" <<'SH'
#!/usr/bin/env bash
cat >> "$BACKUP_PROMPT"
[ -n "${FM_BACKUP_ANSWER:-}" ] || exit 1
jq -nc --argjson a "$FM_BACKUP_ANSWER" '{type:"result",is_error:false,structured_output:$a,modelUsage:{"claude-haiku-5-5":{}}}'
SH
chmod +x "$FAKEBIN/fake-claude"
printf '%s\n' \
  '- lay - Company domain (home: /safe/lay; scope: Company facts for Lay Distribution except the marketing site.; projects: lay-distribution-vault; added 2026-09-01)' \
  '- frontend - Website domain (home: /safe/frontend; scope: Website and web-app work including lay-distribution-site.; projects: lay-distribution-site; added 2026-09-01)' \
  '- zimmer - Private room (home: /safe/zimmer; scope: The captain'"'"'s private room planning.; projects: ; added 2026-09-01)' > "$REG"
jq -n '{lay:"Company facts for Lay Distribution except the marketing site.", frontend:"Website and web-app work including lay-distribution-site."}' > "$APPROVAL"
printf '%s\n' '# Fleet projects' '' \
  '- lay-distribution-site [no-mistakes +yolo] - Lay marketing site (added 2026-09-01)' \
  '- firstmate [no-mistakes +yolo] - This fleet home (added 2026-09-01)' \
  '- private-notes [local-only +yolo] - Local notes (added 2026-09-01)' > "$HOME_DIR/data/projects.md"

write_answer() { # <lead> <lead probability> <lay consult> <frontend consult>
  local rest
  rest=$(awk -v p="$2" 'BEGIN { printf "%.2f", (1 - p) / 2 }')
  jq -n --arg lead "$1" --argjson p "$2" --argjson rest "$rest" --argjson lay "$3" --argjson fe "$4" '
    {model: "typesafe/jev-1.13-20260917", answers: {
      lead: {type: "choice", choice: $lead, probabilities: ({lay: $rest, frontend: $rest, main: $rest} + {($lead): $p})},
      consult_lay: {type: "noul", noul: $lay},
      consult_frontend: {type: "noul", noul: $fe}}}' > "$RESPONSE"
}
run_tool() {
  FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$BASE_PATH" TYPESAFE_API_KEY=fixture-key JEV_URL=https://example.invalid/decision \
    FM_BACKUP_JUDGE_CMD=fake-claude /bin/bash "$TOOL" "$@"
}
last_event() { tail -n 1 "$LOG"; }

# A Lay site task: frontend leads and lay supplies the company facts.
: > "$PAYLOAD"
write_answer frontend 0.98 0.79 0.62
out=$(run_tool decide lay-faq --project lay-distribution-site --public-summary 'Rewrite the FAQ page of the Lay Distribution marketing website') || fail 'decide failed'
assert_contains "$out" 'route: frontend+lay' 'lead plus consult route'
assert_contains "$out" 'bin/fm-backlog-handoff.sh frontend lay-faq' 'decide names the handoff'
jq -e '.state.task_summary == "Rewrite the FAQ page of the Lay Distribution marketing website" and .state.project == "lay-distribution-site"
  and (.state.mate_scopes | keys) == ["frontend", "lay"]
  and (.questions.lead.criteria | keys) == ["frontend", "lay", "main"]
  and (.questions | has("consult_lay") and has("consult_frontend") and (has("consult_zimmer") | not))
  and (tostring | contains("lay-faq") | not)' "$PAYLOAD" >/dev/null || fail 'outbound state or option set violated'
last_event | jq -e '.event == "decide" and .task_id == "lay-faq" and .route == "frontend+lay" and .lead == "frontend" and .consult == ["lay"]
  and .source == "jev" and .probability == 0.98 and .response_model == "typesafe/jev-1.13-20260917" and .consult_probabilities.lay == 0.79' >/dev/null ||
  fail 'decision not logged'
pass 'Lay site task routes to frontend with lay consulted, from approved scopes only'

rc=0
out=$(run_tool check lay-faq "$TMP_ROOT/projects/lay-distribution-site" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'a main-home check allowed a task routed to a second mate'
assert_contains "$out" 'bin/fm-backlog-handoff.sh frontend lay-faq' 'refusal names the handoff command'
assert_contains "$out" 'lay supplies the facts' 'refusal names the consulted mate'
assert_contains "$out" '--route-override' 'refusal names the override flag'
last_event | jq -e '.event == "check" and .outcome == "refuse" and .route == "frontend+lay"' >/dev/null || fail 'refusal not logged'
pass 'check refuses a secondmate route with the one-step handoff'

# Override: only a captain redirect or a concrete blocker, and it is logged.
rc=0
out=$(run_tool check lay-faq "$TMP_ROOT/projects/lay-distribution-site" --override 'because' 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail 'an unlabeled override was accepted'
out=$(run_tool check lay-faq "$TMP_ROOT/projects/lay-distribution-site" --override 'captain: build it from main this once' 2>&1) || fail 'labeled override refused'
assert_contains "$out" 'home route overridden' 'override is announced'
last_event | jq -e '.event == "override" and .outcome == "allow" and .route == "frontend+lay" and .reason == "captain: build it from main this once"' >/dev/null ||
  fail 'override not logged'
pass 'override needs a captain or blocker reason and is logged'

# A record for another project does not authorize this spawn.
rc=0
out=$(run_tool check lay-faq "$TMP_ROOT/projects/firstmate" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'a record for another project allowed the spawn'
assert_contains "$out" 'was routed for project lay-distribution-site' 'project mismatch named'
pass 'a route binds to its project'

# local-only always stays main, with no endpoint call.
: > "$PAYLOAD"
out=$(run_tool decide notes-task --project private-notes --public-summary 'Tidy the notes index') || fail 'local-only decide failed'
assert_contains "$out" 'route: main' 'local-only routes main'
[ ! -s "$PAYLOAD" ] || fail 'local-only reached the endpoint'
last_event | jq -e '.source == "local_only" and .route == "main"' >/dev/null || fail 'local-only not logged'
run_tool check unrouted-local "$TMP_ROOT/projects/private-notes" || fail 'local-only spawn needed a record'
pass 'local-only projects stay main without a Jev call'

# Firstmate itself routes main and passes the gate.
write_answer main 0.99 0.05 0.1
out=$(run_tool decide fm-task --project firstmate --public-summary 'Add a typed intake home router to the dispatch scripts') || fail 'main decide failed'
assert_contains "$out" 'route: main' 'main route'
run_tool check fm-task "$TMP_ROOT/projects/firstmate" || fail 'main route refused'
last_event | jq -e '.event == "check" and .outcome == "allow" and .route == "main"' >/dev/null || fail 'allow not logged'
pass 'a main route allows the spawn'

# Abstain: below the lead floor the backup judge decides on the same state.
: > "$BACKUP_PROMPT"
write_answer frontend 0.6 0.3 0.4
out=$(FM_BACKUP_ANSWER='{"lead":"main","consult_lay":false,"consult_frontend":false}' run_tool decide vague-task --project firstmate --public-summary 'Improve the onboarding') || fail 'abstain decide failed'
assert_contains "$out" 'route: main' 'abstain is decided by the backup'
assert_contains "$out" 'decided: backup' 'the backup is named'
assert_contains "$out" 'typed: abstained' 'the typed reason is named'
assert_contains "$out" 'judge vague-task' 'a backup route names the judge override'
assert_contains "$(cat "$BACKUP_PROMPT")" '"task_summary":"Improve the onboarding"' 'the backup sees the typed state'
assert_not_contains "$(cat "$BACKUP_PROMPT")" 'vague-task' 'the backup never sees the task id'
assert_not_contains "$(cat "$BACKUP_PROMPT")" 'zimmer' 'the backup never sees an unapproved scope'
last_event | jq -e '.route == "main" and .source == "backup" and .reason == "abstained" and (.backup | startswith("ok"))' >/dev/null || fail 'backup decision not logged'
run_tool check vague-task "$TMP_ROOT/projects/firstmate" || fail 'a backup main route refused'
out=$(run_tool judge vague-task --route frontend --reason 'onboarding pages live on the website') || fail 'judge over a backup route failed'
assert_contains "$out" 'route: frontend' 'judge overrides a backup route'
jq -e '.source == "judgment" and .judged_over == "backup" and .jev_reason == "abstained"' "$HOME_DIR/state/home-route/vague-task.json" >/dev/null || fail 'judgment record lost its provenance'
rc=0
run_tool judge lay-faq --route main --reason 'disagree' 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail 'judge overwrote a confident Jev route'
rc=0
run_tool judge vague-task --route ghost --reason 'unknown' 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail 'judge accepted an unregistered mate'
pass 'abstain is decided by the backup judge, and judge stays an override'

# Backup consult answers form the route like Jev's nouls.
out=$(FM_BACKUP_ANSWER='{"lead":"frontend","consult_lay":true,"consult_frontend":true}' run_tool decide backup-site --project lay-distribution-site --public-summary 'Add the pricing table to the Lay site') || fail 'backup consult decide failed'
assert_contains "$out" 'route: frontend+lay' 'a backup lead with consults forms the full route'
pass 'the backup forms lead plus consult routes'

# Jev unreachable: the backup decides; when the backup fails too, main.
rm -f "$RESPONSE"
out=$(FM_BACKUP_ANSWER='{"lead":"frontend","consult_lay":false,"consult_frontend":false}' run_tool decide outage-task --project lay-distribution-site --public-summary 'Fix the mobile navigation overlap') || fail 'outage decide failed'
assert_contains "$out" 'route: frontend' 'outage is decided by the backup'
last_event | jq -e '.reason == "decision_unavailable" and .source == "backup"' >/dev/null || fail 'outage not logged'
rc=0
out=$(run_tool check outage-task "$TMP_ROOT/projects/lay-distribution-site" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'a backup secondmate route let the spawn through'
assert_contains "$out" 'bin/fm-backlog-handoff.sh frontend outage-task' 'backup route names the handoff'
out=$(run_tool decide outage-two --project lay-distribution-site --public-summary 'Fix the footer spacing') || fail 'double outage decide failed'
assert_contains "$out" 'route: main' 'a failed backup keeps the task in main'
assert_contains "$out" 'decided: default' 'the default is named'
assert_contains "$out" 'backup: failed' 'the backup failure is named'
last_event | jq -e '.route == "main" and .source == "default" and .reason == "decision_unavailable" and (.backup | startswith("failed"))' >/dev/null || fail 'default not logged'
run_tool check outage-two "$TMP_ROOT/projects/lay-distribution-site" || fail 'a default main route refused'
out=$(run_tool decide outage-three --project lay-distribution-site --public-summary 'Fix the header spacing') || fail 'failed backup decide failed'
assert_contains "$out" 'backup: failed (fake-claude exited 1)' 'a failing backup is named'
assert_contains "$out" 'route: main' 'a failed backup keeps the task in main'
pass 'an unreachable endpoint goes to the backup, then to main; a route is always recorded'

# No key goes to the backup; private input reaches neither judge and stays main.
: > "$PAYLOAD"
: > "$BACKUP_PROMPT"
write_answer main 0.99 0 0
out=$(FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$BASE_PATH" TYPESAFE_API_KEY='' OPENROUTER_API_KEY='' FM_BACKUP_JUDGE_CMD=fake-claude \
  FM_BACKUP_ANSWER='{"lead":"main","consult_lay":false,"consult_frontend":false}' /bin/bash "$TOOL" decide nokey-task --project firstmate --public-summary 'Update a guide') || fail 'no-key decide failed'
assert_contains "$out" 'route: main' 'no key is decided'
assert_contains "$out" 'decided: backup' 'no key goes to the backup'
: > "$BACKUP_PROMPT"
out=$(FM_BACKUP_ANSWER='{"lead":"frontend","consult_lay":false,"consult_frontend":false}' run_tool decide private-task --project firstmate --public-summary 'Plan the IchWiki overlay') || fail 'private decide failed'
assert_contains "$out" 'route: main' 'private input stays main'
last_event | jq -e '.reason == "unsafe_summary" and .route == "main" and .source == "default" and .backup == "skipped (unsafe_summary)"' >/dev/null || fail 'private skip not logged'
[ ! -s "$PAYLOAD" ] || fail 'no-key or private input reached the endpoint'
[ ! -s "$BACKUP_PROMPT" ] || fail 'private input reached the backup judge'
pass 'missing key goes to the backup; private summaries reach neither judge'

# A legacy judgment-needed record still refuses the spawn until judged.
jq -n '{task_id: "legacy-task", project: "firstmate", route: "judgment-needed", lead: "", consult: [], source: "jev", probability: 0.6, reason: "abstained"}' > "$HOME_DIR/state/home-route/legacy-task.json"
rc=0
out=$(run_tool check legacy-task "$TMP_ROOT/projects/firstmate" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'a legacy judgment-needed record let the spawn through'
assert_contains "$out" 'bin/fm-home-route.sh judge legacy-task' 'legacy refusal names the judge command'
run_tool judge legacy-task --route main --reason 'main owns it' >/dev/null || fail 'judge over a legacy record failed'
run_tool check legacy-task "$TMP_ROOT/projects/firstmate" || fail 'judged legacy record refused'
pass 'legacy judgment-needed records still need a judgment'

# A missing record refuses; a secondmate home and an unconfigured home are not gated.
rc=0
out=$(run_tool check never-routed "$TMP_ROOT/projects/firstmate" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'an unrouted task passed'
assert_contains "$out" 'bin/fm-home-route.sh decide never-routed --project firstmate' 'missing record names decide'
touch "$HOME_DIR/.fm-secondmate-home"
run_tool check never-routed "$TMP_ROOT/projects/firstmate" || fail 'a secondmate home was gated'
rc=0
run_tool decide sm-task --project firstmate --public-summary 'Anything' 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail 'decide ran in a secondmate home'
rm -f "$HOME_DIR/.fm-secondmate-home"
mv "$APPROVAL" "$APPROVAL.off"
run_tool check never-routed "$TMP_ROOT/projects/firstmate" || fail 'an unconfigured home was gated'
mv "$APPROVAL.off" "$APPROVAL"
pass 'missing records refuse; secondmate and unconfigured homes pass'

out=$(run_tool review) || fail 'review failed'
assert_contains "$out" 'overrides=1' 'review counts overrides'
assert_contains "$out" 'typed_undecided_reasons: abstained=2 decision_unavailable=3 no_key=1 unsafe_summary=1' 'review groups the typed reasons'
assert_contains "$out" 'backup_routed=4' 'review counts backup routes'
assert_contains "$out" 'backup_failures: failed (fake-claude exited 1)=2' 'review groups backup failures'
assert_contains "$out" 'override lay-faq: router said frontend+lay' 'review lists overrides'
pass 'review summarises the log'

# fm-spawn wiring: the gate runs before anything is created, and the override
# reaches it. The spawn stops at the next gate (no backlog item) after it.
SP="$TMP_ROOT/spawn"
SP_HOME="$SP/home"
SP_BIN=$(fm_fakebin "$SP")
mkdir -p "$SP_HOME/state" "$SP_HOME/config" "$SP_HOME/data/lay-faq" "$SP/user-home"
touch "$SP_HOME/state/.last-watcher-beat"
printf '%s\n' claude > "$SP_HOME/config/crew-harness"
cp "$REG" "$APPROVAL" "$SP_HOME/data/" && mv "$SP_HOME/data/jev-mate-public-scopes.json" "$SP_HOME/config/"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$SP_HOME/data/backlog.md"
printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$SP_HOME/.tasks.toml"
printf '%s\n' '# Task' "## Captain's intent" 'Rewrite the FAQ.' '' '## Firstmate spec' 'Rewrite it.' '' '# Definition of done' 'Delivery contract: mode=no-mistakes' > "$SP_HOME/data/lay-faq/brief.md"
cat > "$SP_BIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
chmod +x "$SP_BIN/tmux"
fm_fake_exit0 "$SP_BIN" treehouse gh gh-axi no-mistakes
fm_git_init_commit "$SP/lay-distribution-site"
run_spawn() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SP_HOME" HOME="$SP/user-home" FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" CLAUDE_CONFIG_DIR='' \
    PATH="$SP_BIN:$BASE_PATH" "$SPAWN" lay-faq "$SP/lay-distribution-site" --mode no-mistakes --yolo off "$@" 2>&1
}
rc=0
out=$(run_spawn) || rc=$?
[ "$rc" -ne 0 ] || fail 'spawn passed without a route decision'
assert_contains "$out" 'has no home-route decision' 'spawn names the missing decision'
[ ! -e "$SP_HOME/state/lay-faq.meta" ] || fail 'refused spawn left a record'
mkdir -p "$SP_HOME/state/home-route"
jq -n '{task_id: "lay-faq", project: "lay-distribution-site", route: "frontend+lay", lead: "frontend", consult: ["lay"], source: "jev", probability: 0.98, reason: ""}' > "$SP_HOME/state/home-route/lay-faq.json"
rc=0
out=$(run_spawn) || rc=$?
[ "$rc" -ne 0 ] || fail 'spawn passed a secondmate route'
assert_contains "$out" 'bin/fm-backlog-handoff.sh frontend lay-faq' 'spawn refusal names the handoff'
[ ! -e "$SP_HOME/state/lay-faq.meta" ] || fail 'refused spawn left a record'
rc=0
out=$(run_spawn --route-override 'blocker: frontend mate is down for repair') || rc=$?
assert_contains "$out" 'home route overridden' 'spawn passed the override to the gate'
assert_not_contains "$out" 'bin/fm-backlog-handoff.sh' 'override still refused at the route gate'
tail -n 1 "$SP_HOME/state/home-route.jsonl" | jq -e '.event == "override" and .reason == "blocker: frontend mate is down for repair"' >/dev/null || fail 'spawn override not logged'
rc=0
out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SP_HOME" PATH="$SP_BIN:$BASE_PATH" "$SPAWN" lay-faq --relaunch --route-override 'captain: x' 2>&1) || rc=$?
[ "$rc" -ne 0 ] && [[ "$out" == *'--route-override needs a reason and applies only to a fresh ship or scout spawn'* ]] || fail 'relaunch accepted a route override'
pass 'fm-spawn enforces the home route before creating anything'
