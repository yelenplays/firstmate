#!/usr/bin/env bash
# Behavior tests for bin/fm-rules.sh.
#
# Drives the real script against scratch homes: the rule store and its repeat
# and check bookkeeping, the rendered always-loaded block, the Claude capture
# hook (candidate, confirm, dismiss, "nein" revoke) and its scope guards, the
# registered settings.json entries, the brief section through the real
# bin/fm-brief.sh, and the weekly report and reminder check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-rules)
RULES="$ROOT/bin/fm-rules.sh"
HOME_DIR="$TMP_ROOT/home"
FAKE_ROOT="$TMP_ROOT/primary"

run_env() {
  env -u FM_TASK_ID -u FM_SUPERVISION_ACTOR -u FM_MEMORY_CAPTURE_CHILD -u NO_MISTAKES_GATE \
    -u FM_CONFIG_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_RULES_TODAY=2026-10-20 "$@"
}

fresh_home() {
  rm -rf "$HOME_DIR" "$FAKE_ROOT"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data" "$FAKE_ROOT/bin"
  : > "$FAKE_ROOT/AGENTS.md"
  git -C "$FAKE_ROOT" init -q
}

prompt() {  # <text> -> hook stdout
  jq -nc --arg p "$1" '{prompt:$p}' | run_env "$RULES" prompt-hook
}

candidates() {
  find "$HOME_DIR/state/captain-rules/candidates" -type f 2>/dev/null | sort
}

test_store_records_repeats_and_checks() {
  local out rc file="$HOME_DIR/config/captain-rules.md"
  fresh_home
  out=$(run_env "$RULES" render) || fail 'render failed on an empty store'
  [ -z "$out" ] || fail 'an empty store rendered a block'

  out=$(run_env "$RULES" add merge-self 'Merge green PRs yourself.') || fail "add failed: $out"
  assert_equals 'added: merge-self' "$out" 'add did not report the new rule'
  out=$(run_env env FM_RULES_TODAY=2026-10-22 "$RULES" add merge-self 'Merge green PRs yourself once checks pass.') \
    || fail "repeat add failed: $out"
  assert_equals 'repeated: merge-self (seen 2)' "$out" 'a second add of the same id was not a repeat'
  assert_grep '- [merge-self] Merge green PRs yourself once checks pass. <!-- since=2026-10-20 seen=2 last=2026-10-22 -->' "$file" \
    'the repeat did not replace the text and keep since, seen, and last'
  assert_equals 1 "$(grep -c 'merge-self' "$file")" 'a repeat duplicated the rule line'

  out=$(run_env "$RULES" unchecked)
  assert_contains "$out" 'merge-self' 'a rule seen twice without a check was not listed as unchecked'
  out=$(run_env "$RULES" render)
  assert_contains "$out" 'outrank generic harness, tool, and skill hints' 'the block lost its precedence line'
  assert_contains "$out" '- Merge green PRs yourself once checks pass.' 'the block lost the rule text'
  assert_contains "$out" 'REPEATED WITHOUT A CHECK' 'the block did not surface the unchecked repeat'
  assert_contains "$out" '- merge-self (seen 2 times)' 'the unchecked list did not name the rule'

  out=$(run_env "$RULES" check merge-self no-such-check 2>&1); rc=$?
  expect_code 3 "$rc" 'an unknown check id must be refused'
  assert_contains "$out" 'unknown check id' 'the refusal did not explain itself'
  run_env "$RULES" check merge-self bang-interactive >/dev/null || fail 'linking a listed check failed'
  [ -z "$(run_env "$RULES" unchecked)" ] || fail 'a checked rule stayed unchecked'
  assert_contains "$(run_env "$RULES" render)" '[check: bang-interactive]' 'the block did not show the linked check'
  run_env "$RULES" nocheck merge-self 'needs judgment about CI state' >/dev/null || fail 'nocheck failed'
  [ -z "$(run_env "$RULES" unchecked)" ] || fail 'a rule with a recorded reason stayed unchecked'
  assert_not_contains "$(run_env "$RULES" render)" '[check: ' 'nocheck did not replace the linked check'

  out=$(run_env "$RULES" add 'Bad Id' 'text' 2>&1); rc=$?
  expect_code 3 "$rc" 'an invalid rule id must be refused'
  out=$(run_env "$RULES" add good-id 'smuggled <!-- seen=99 --> meta' 2>&1); rc=$?
  expect_code 3 "$rc" 'rule text carrying a comment marker must be refused'
  out=$(run_env "$RULES" add --check nope good-id 'text' 2>&1); rc=$?
  expect_code 3 "$rc" 'add with an unknown check id must be refused'
  assert_no_grep 'good-id' "$file" 'a refused add still wrote a rule'

  run_env "$RULES" revoke merge-self >/dev/null || fail 'revoke failed'
  assert_no_grep 'merge-self' "$file" 'revoke left the rule behind'
  out=$(run_env "$RULES" revoke merge-self 2>&1); rc=$?
  expect_code 1 "$rc" 'revoking an unknown rule must exit 1'
  [ -z "$(run_env "$RULES" render)" ] || fail 'a store without rules still rendered a block'
  assert_contains "$(cat "$HOME_DIR/state/captain-rules/log.jsonl")" '"event":"revoke"' 'revoke was not logged'
  pass 'the store records rules, repeats, checks, and reasons, and refuses invalid input'
}

test_render_is_bounded() {
  local out i
  fresh_home
  for i in $(seq 1 40); do
    run_env "$RULES" add "rule-$i" "Rule number $i keeps a long enough line to fill the bounded block quickly." >/dev/null \
      || fail "seeding rule $i failed"
  done
  out=$(run_env "$RULES" render --max-chars 800)
  [ "${#out}" -le 800 ] || fail "render exceeded --max-chars (${#out})"
  assert_contains "$out" 'print all with bin/fm-rules.sh list' 'a cut block did not say how to see every rule'
  assert_equals 40 "$(run_env "$RULES" list | grep -c .)" 'list did not print every rule'
  pass 'the rendered block honors its character bound and points at the full list'
}

test_writes_refuse_in_a_secondmate_home() {
  local out rc
  fresh_home
  printf 'mate-a\n' > "$HOME_DIR/.fm-secondmate-home"
  out=$(run_env "$RULES" add some-rule 'Some rule.' 2>&1); rc=$?
  expect_code 2 "$rc" 'a secondmate home must refuse to record a rule'
  assert_contains "$out" 'primary home only' 'the secondmate refusal did not explain itself'
  assert_absent "$HOME_DIR/config/captain-rules.md" 'a secondmate home wrote a rule file'
  pass 'rule writes refuse in a secondmate home, whose config is a primary copy'
}

test_prompt_hook_captures_and_confirms() {
  local out cid file="$HOME_DIR/config/captain-rules.md" context
  fresh_home
  for text in 'merge it' 'looks good, ship the wiki page' 'FIRSTMATE SUPERVISION WAKE ab jetzt nie wieder' \
    '<task-notification>ab jetzt</task-notification>' \
    'see this <pasted_content id="x">ab jetzt nie wieder falsch</pasted_content> and summarize it'; do
    out=$(prompt "$text") || fail "hook failed on: $text"
    [ -z "$out" ] || fail "hook raised a candidate for: $text"
  done
  [ -z "$(candidates)" ] || fail 'non-corrections left candidates behind'

  out=$(prompt 'hab ich dir schon gesagt: kein ! fuer sudo, nimm pbcopy') || fail 'hook failed on a correction'
  context=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext') || fail "hook output is not JSON: $out"
  assert_equals UserPromptSubmit "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" 'hook named the wrong event'
  cid=$(basename "$(candidates)")
  assert_contains "$context" "CAPTAIN RULE CANDIDATE $cid" 'the injected instruction did not name its candidate'
  assert_contains "$context" "fm-rules.sh confirm $cid" 'the instruction did not give the confirm command'
  assert_contains "$context" '"nein" nimmt sie zurueck' 'the instruction did not carry the one-line confirmation'
  assert_absent "$file" 'the hook wrote a rule by itself'

  run_env "$RULES" confirm --check bang-interactive "$cid" no-bang-sudo 'Never hand the captain a "! <cmd>" line for sudo.' >/dev/null \
    || fail 'confirm failed'
  assert_grep '- [no-bang-sudo] Never hand the captain a "! <cmd>" line for sudo. <!-- since=2026-10-20 seen=1 check=bang-interactive -->' "$file" \
    'confirm did not record the rule with its check'
  [ -z "$(candidates)" ] || fail 'confirm left its candidate open'

  out=$(prompt 'Nein.')
  assert_contains "$out" 'fm-rules.sh revoke no-bang-sudo' 'a bare nein right after a confirm did not inject the revoke'
  printf '%s no-bang-sudo\n' "$(( $(date +%s) - 4000 ))" > "$HOME_DIR/state/captain-rules/last-confirmed"
  [ -z "$(prompt 'nein')" ] || fail 'a nein long after the confirm still injected a revoke'

  prompt 'that is wrong, never do that again' >/dev/null
  cid=$(basename "$(candidates)")
  run_env "$RULES" dismiss "$cid" >/dev/null || fail 'dismiss failed'
  [ -z "$(candidates)" ] || fail 'dismiss left its candidate open'
  assert_equals 1 "$(run_env "$RULES" list | grep -c .)" 'dismiss changed the rule set'
  pass 'the capture hook raises candidates only for corrections, never writes rules, and supports confirm, dismiss, and nein'
}

test_hooks_stand_down_outside_their_scope() {
  local guard out
  fresh_home
  run_env "$RULES" add some-rule 'Some rule.' >/dev/null || fail 'seeding a rule failed'
  for guard in FM_TASK_ID=t1 FM_SUPERVISION_ACTOR=branch FM_MEMORY_CAPTURE_CHILD=1 NO_MISTAKES_GATE=1; do
    out=$(jq -nc '{prompt:"ab jetzt nie wieder"}' | run_env env -u FM_GATE_REFUSE_BYPASS "$guard" "$RULES" prompt-hook) \
      || fail "prompt hook failed under $guard"
    [ -z "$out" ] || fail "prompt hook raised a candidate under $guard"
    out=$(run_env env -u FM_GATE_REFUSE_BYPASS "$guard" "$RULES" session </dev/null) || fail "session hook failed under $guard"
    [ -z "$out" ] || fail "session hook loaded rules under $guard"
  done
  out=$(jq -nc '{prompt:"ab jetzt nie wieder"}' | run_env env FM_ROOT_OVERRIDE="$TMP_ROOT/not-primary" "$RULES" prompt-hook)
  [ -z "$out" ] || fail 'prompt hook ran outside a primary root'
  [ -z "$(candidates)" ] || fail 'an out-of-scope hook left a candidate'

  printf 'mate-a\n' > "$HOME_DIR/.fm-secondmate-home"
  out=$(jq -nc '{prompt:"ab jetzt nie wieder"}' | run_env "$RULES" prompt-hook)
  [ -z "$out" ] || fail 'a secondmate home raised a candidate'
  out=$(run_env "$RULES" session </dev/null)
  assert_contains "$out" '- Some rule.' 'a secondmate seat did not load the inherited rules'
  pass 'capture runs only in the primary main session and the session block reaches main and secondmate seats only'
}

test_registered_claude_entries_reach_the_script() {
  local command out
  fresh_home
  run_env "$RULES" add some-rule 'Some rule.' >/dev/null || fail 'seeding a rule failed'
  command=$(jq -r '.hooks.SessionStart[].hooks[].command | select(test("fm-rules.sh session"))' "$ROOT/.claude/settings.json")
  [ -n "$command" ] || fail 'settings.json registers no fm-rules.sh session hook'
  for source in startup resume compact clear; do
    out=$(printf '{"source":"%s"}' "$source" | run_env env CLAUDE_PROJECT_DIR="$ROOT" bash -c "$command") \
      || fail "registered session hook failed on $source"
    assert_contains "$out" '- Some rule.' "registered session hook dropped the rules on $source"
  done
  command=$(jq -r '.hooks.UserPromptSubmit[].hooks[].command | select(test("fm-rules.sh prompt-hook"))' "$ROOT/.claude/settings.json")
  [ -n "$command" ] || fail 'settings.json registers no fm-rules.sh prompt-hook'
  out=$(jq -nc '{prompt:"from now on, never use that tool"}' | run_env env CLAUDE_PROJECT_DIR="$ROOT" bash -c "$command")
  assert_contains "$out" 'CAPTAIN RULE CANDIDATE' 'the registered prompt hook did not raise a candidate'
  pass 'the registered Claude SessionStart and UserPromptSubmit entries reach fm-rules.sh'
}

test_briefs_carry_the_rules() {
  local home="$TMP_ROOT/brief-home" brief kind
  rm -rf "$home"
  mkdir -p "$home/config"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" rules-absent some-proj --scout >/dev/null || fail 'scout scaffold failed without rules'
  assert_no_grep '# Captain rules' "$home/data/rules-absent/brief.md" 'a home without rules still added a section'

  FM_HOME="$home" FM_ROOT_OVERRIDE="$FAKE_ROOT" "$RULES" add pbcopy-for-sudo 'Hand sudo steps over through pbcopy.' >/dev/null \
    || fail 'seeding a rule failed'
  for kind in ship scout; do
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "rules-$kind" some-proj --scout >/dev/null || fail 'scout scaffold failed'
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "rules-$kind" some-proj --mode no-mistakes >/dev/null || fail 'ship scaffold failed'
    fi
    brief="$home/data/rules-$kind/brief.md"
    assert_grep '# Captain rules' "$brief" "$kind brief lost the captain rules section"
    assert_grep '- Hand sudo steps over through pbcopy.' "$brief" "$kind brief lost the rule"
    assert_grep "this brief's task scope and safety rules still win" "$brief" "$kind brief lost the precedence wording"
  done
  FM_HOME="$home" FM_SECONDMATE_CHARTER='Supervise assigned work.' \
    "$ROOT/bin/fm-brief.sh" rules-mate --secondmate --no-projects >/dev/null || fail 'secondmate scaffold failed'
  assert_no_grep '# Captain rules' "$home/data/rules-mate/brief.md" 'a secondmate charter took the rules section'
  pass 'ship and scout briefs carry the captain rules; charters and rule-free homes carry none'
}

test_report_and_weekly_check() {
  local tdir="$TMP_ROOT/transcripts" now out shim
  fresh_home
  now=$(date +%s)
  mkdir -p "$tdir"
  {
    jq -nc --arg t "$(date -u -r $((now - 3600)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((now - 3600))" +%Y-%m-%dT%H:%M:%SZ)" \
      '{type:"user",timestamp:$t,message:{content:"wie oft noch, mach es selbst"}}'
    jq -nc --arg t "$(date -u -r $((now - 3500)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((now - 3500))" +%Y-%m-%dT%H:%M:%SZ)" \
      '{type:"user",timestamp:$t,message:{content:"FIRSTMATE SUPERVISION WAKE ab jetzt"}}'
    jq -nc --arg t "$(date -u -r $((now - 3400)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((now - 3400))" +%Y-%m-%dT%H:%M:%SZ)" \
      '{type:"user",timestamp:$t,message:{content:"thanks, ship it"}}'
    jq -nc '{type:"user",timestamp:"2020-01-01T00:00:00Z",message:{content:"schon wieder, from an old week"}}'
  } > "$tdir/session.jsonl"
  run_env "$RULES" add a-rule 'A rule.' >/dev/null
  run_env "$RULES" add a-rule 'A rule, restated.' >/dev/null
  printf '%s\n' '{"schema":"fm-rules-event.v1","at":"2999-01-01T00:00:00Z","event":"guard-block","check":"bang-interactive","hash":"x"}' \
    >> "$HOME_DIR/state/captain-rules/log.jsonl"

  out=$(run_env "$RULES" weekly-check) || fail 'weekly-check failed'
  assert_contains "$out" 'weekly report due' 'a home that never ran a report was not reminded'
  [ -z "$(run_env "$RULES" weekly-check)" ] || fail 'the reminder repeated within the same due week'

  out=$(run_env "$RULES" report --transcripts "$tdir" --now "$now") || fail "report failed: $out"
  assert_contains "$out" 'Rules: 1 total, 1 added, 1 repeated.' 'report miscounted rules'
  assert_contains "$out" '- a-rule: recorded again 1 time(s) this period, seen 2 in total, no check' 'report missed the repeat'
  assert_contains "$out" '- bang-interactive: 1' 'report missed the guard block'
  assert_contains "$out" '- a-rule (seen 2 times): A rule, restated.' 'report missed the unchecked repeat'
  assert_contains "$out" 'correction-like captain prompts in' 'report skipped the transcripts'
  assert_contains "$out" 'wie oft noch, mach es selbst' 'report missed a correction in the transcript'
  assert_not_contains "$out" 'SUPERVISION WAKE' 'report counted a wake as a captain correction'
  assert_not_contains "$out" 'from an old week' 'report counted a prompt from outside the window'
  assert_not_contains "$out" 'ship it' 'report counted a plain prompt'
  [ -z "$(run_env "$RULES" weekly-check)" ] || fail 'a fresh report did not quiet the weekly reminder'

  run_env "$RULES" weekly-arm >/dev/null || fail 'weekly-arm failed'
  shim="$HOME_DIR/state/captain-rules-weekly.check.sh"
  assert_present "$shim" 'weekly-arm wrote no check shim'
  [ "$(stat -c %a "$shim" 2>/dev/null || stat -f %Lp "$shim")" = 700 ] || fail 'the check shim is not mode 700'
  assert_present "$HOME_DIR/state/captain-rules-weekly.check-trust" 'weekly-arm did not register the check'
  out=$(env -u FM_HOME "$shim") || fail 'the armed shim failed'
  [ -z "$out" ] || fail 'the armed shim reminded right after a report'
  run_env "$RULES" weekly-disarm >/dev/null || fail 'weekly-disarm failed'
  assert_absent "$shim" 'weekly-disarm left the shim'
  assert_absent "$HOME_DIR/state/captain-rules-weekly.check-trust" 'weekly-disarm left the registration'
  pass 'the weekly report counts repeats, blocks, unchecked rules, and transcript corrections, and the check reminds once per due week'
}

test_store_records_repeats_and_checks
test_render_is_bounded
test_writes_refuse_in_a_secondmate_home
test_prompt_hook_captures_and_confirms
test_hooks_stand_down_outside_their_scope
test_registered_claude_entries_reach_the_script
test_briefs_carry_the_rules
test_report_and_weekly_check

echo "# fm-rules.test.sh: all assertions passed"
