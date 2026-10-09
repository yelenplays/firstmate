#!/usr/bin/env bash
# Behavior tests for the never-use model list (config/model-denylist.json;
# bin/fm-model-denylist-lib.sh) at the worker launch boundary.
#
# Each spawn case drives the real fm-spawn.sh through the shared fake tmux,
# which records the launch command; a refused launch must leave no task record
# and no recorded launch. The Jev-side behavior is covered where each caller's
# own suite lives: tests/fm-jev.test.sh, tests/fm-jev-model-proposal.test.sh,
# and tests/fm-dispatch-resolve.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-model-denylist)
unset LAVISH_AXI_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN PI_CODING_AGENT_DIR OPENAI_API_KEY

# make_runner_fakes <fakebin>: signed-in claude and a Pi that lists its help.
make_runner_fakes() {
  local fakebin=$1
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --help) printf '%s\n' 'Pi 0.86.1' 'Options: --help --tui-mode <mode>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/claude" "$fakebin/pi"
}

# new_case <name> -> sets CASE HOME_DIR PROJ WT FAKEBIN NM_DIR
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  NM_DIR="$CASE/no-mistakes"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  make_runner_fakes "$FAKEBIN"
  fm_test_spawn_home "$HOME_DIR" claude
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  mkdir -p "$HOME_DIR/user-home" "$NM_DIR"
  : > "$CASE/launch.log"
}

write_denylist() {
  cat > "$HOME_DIR/config/model-denylist.json" <<'JSON'
{"never": [
  {"pattern": "*kimi*", "reason": "Kimi is ruled out"},
  {"pattern": "gpt-*-luna*", "reason": "Luna is banned"}
]}
JSON
}

# spawn_ship <id> <mode> [fm-spawn args...]: a ship spawn whose brief already exists.
spawn_ship() {
  local id=$1 mode=$2
  shift 2
  [ -f "$HOME_DIR/data/$id/brief.md" ] || fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" NM_HOME="$NM_DIR" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode "$mode" --yolo off "$@"
}

# assert_refused_before_launch <id> <out> <needle>
assert_refused_before_launch() {
  local id=$1 out=$2 needle=$3
  assert_contains "$out" "$needle" "the refusal should say: $needle"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
}

test_absent_list_keeps_launches_unchanged() {
  local out rc
  new_case absent
  out=$(spawn_ship deny-absent no-mistakes claude --model kimi-coding/k3); rc=$?
  expect_code 0 "$rc" "with no list a launch is not checked: $out"
  assert_grep "kimi-coding/k3" "$CASE/launch.log" "with no list the requested model is launched"
  pass "an absent list leaves every launch unchanged"
}

test_banned_model_refuses_every_launch_shape() {
  local out rc
  new_case banned
  write_denylist
  out=$(spawn_ship deny-pi no-mistakes pi --model openai-codex/gpt-6-luna); rc=$?
  expect_code 1 "$rc" "a banned explicit model must refuse"
  assert_refused_before_launch deny-pi "$out" "worker model 'openai-codex/gpt-6-luna' is on the never-use model list: rule 'gpt-*-luna*' - Luna is banned"

  out=$(spawn_ship deny-kimi no-mistakes kimi); rc=$?
  expect_code 1 "$rc" "a harness whose default model is banned must refuse"
  assert_refused_before_launch deny-kimi "$out" "worker model 'kimi' is on the never-use model list: rule '*kimi*' - Kimi is ruled out"

  out=$(spawn_ship deny-raw no-mistakes "pi --model kimi-coding/k3"); rc=$?
  expect_code 1 "$rc" "a raw launch command pinning a banned model must refuse"
  assert_refused_before_launch deny-raw "$out" "raw launch model 'kimi-coding/k3' is on the never-use model list"

  out=$(spawn_ship deny-ok no-mistakes claude --model claude-opus-5-5); rc=$?
  expect_code 0 "$rc" "an allowed model still launches with a list present: $out"
  assert_grep "claude-opus-5-5" "$CASE/launch.log" "the allowed model is launched"
  pass "a banned model refuses an explicit, harness-default, or raw launch before anything exists"
}

test_brief_and_reviewer_pins_refuse() {
  local out rc
  new_case pins
  write_denylist
  fm_test_spawn_brief "$HOME_DIR" deny-brief "Ship the fix and run \`no-mistakes axi run --model kimi-coding/k3\` for the review."
  out=$(spawn_ship deny-brief no-mistakes claude --model claude-opus-5-5); rc=$?
  expect_code 1 "$rc" "a brief pinning a banned reviewer model must refuse"
  assert_refused_before_launch deny-brief "$out" "model pinned in $HOME_DIR/data/deny-brief/brief.md 'kimi-coding/k3' is on the never-use model list"

  cat > "$NM_DIR/config.yaml" <<'YAML'
agent: [claude, pi]
# - --model kimi-coding/old  (a comment never counts)
agent_args_override:
  claude:
    - --model
    - claude-opus-5-5
  pi:
    - --provider
    - openai-codex
    - --model
    - openai-codex/gpt-6-luna
YAML
  out=$(spawn_ship deny-nm no-mistakes claude --model claude-opus-5-5); rc=$?
  expect_code 1 "$rc" "a no-mistakes ship must refuse while the pipeline pins a banned reviewer"
  assert_refused_before_launch deny-nm "$out" "no-mistakes reviewer model in $NM_DIR/config.yaml 'openai-codex/gpt-6-luna' is on the never-use model list: rule 'gpt-*-luna*'"

  out=$(spawn_ship deny-direct direct-PR claude --model claude-opus-5-5); rc=$?
  expect_code 0 "$rc" "a direct-PR ship runs no pipeline reviewer, so the pipeline pin does not block it: $out"

  printf 'agent_config:\n  pi:\n    model: opencode-go/kimi-k2\n' > "$NM_DIR/config.yaml"
  next_worktree nm-model
  out=$(spawn_ship deny-nm-model no-mistakes claude --model claude-opus-5-5); rc=$?
  expect_code 1 "$rc" "a model: key pinning a banned reviewer must refuse"
  assert_refused_before_launch deny-nm-model "$out" "'opencode-go/kimi-k2' is on the never-use model list"
  pass "a brief or no-mistakes reviewer pin naming a banned model refuses the ship"
}

test_provider_split_pins_refuse() {
  local out rc
  new_case provider
  write_denylist
  out=$(spawn_ship deny-raw-provider no-mistakes "pi --provider kimi-coding --model k3"); rc=$?
  expect_code 1 "$rc" "a raw launch splitting a banned model across --provider and --model must refuse"
  assert_refused_before_launch deny-raw-provider "$out" "raw launch model 'kimi-coding/k3' is on the never-use model list"

  fm_test_spawn_brief "$HOME_DIR" deny-brief-provider $'Run the review:\n\n```sh\nno-mistakes axi run --provider kimi-coding --model k3\n```'
  out=$(spawn_ship deny-brief-provider no-mistakes claude --model claude-opus-5-5); rc=$?
  expect_code 1 "$rc" "a brief command line splitting a banned model across --provider and --model must refuse"
  assert_refused_before_launch deny-brief-provider "$out" "'kimi-coding/k3' is on the never-use model list"

  printf 'agent_args_override:\n  pi: [--provider, kimi-coding, --model, k3]\n' > "$NM_DIR/config.yaml"
  out=$(spawn_ship deny-nm-flow no-mistakes claude --model claude-opus-5-5); rc=$?
  expect_code 1 "$rc" "an inline agent_args_override list splitting a banned model must refuse"
  assert_refused_before_launch deny-nm-flow "$out" "no-mistakes reviewer model in $NM_DIR/config.yaml 'kimi-coding/k3' is on the never-use model list"

  printf 'agent_args_override:\n  pi:\n    - --provider\n    - kimi-coding\n    - --model\n    - k3\n  claude:\n    - --model\n    - claude-opus-5-5\n' > "$NM_DIR/config.yaml"
  out=$(spawn_ship deny-nm-block no-mistakes claude --model claude-opus-5-5); rc=$?
  expect_code 1 "$rc" "a block agent_args_override list splitting a banned model must refuse"
  assert_refused_before_launch deny-nm-block "$out" "'kimi-coding/k3' is on the never-use model list"

  printf 'agent_config:\n  pi:\n    provider: kimi-coding\n    model: k3\n  claude:\n    model: claude-opus-5-5\n' > "$NM_DIR/config.yaml"
  out=$(spawn_ship deny-nm-keys no-mistakes claude --model claude-opus-5-5); rc=$?
  expect_code 1 "$rc" "provider: and model: keys in one block naming a banned model must refuse"
  assert_refused_before_launch deny-nm-keys "$out" "'kimi-coding/k3' is on the never-use model list"
  : > "$NM_DIR/config.yaml"
  fm_test_spawn_brief "$HOME_DIR" deny-brief-continued $'Run the review:\n\n```sh\nno-mistakes axi run \\\n  --model kimi-y\n```'
  out=$(spawn_ship deny-brief-continued no-mistakes claude --model claude-opus-5-5); rc=$?
  expect_code 1 "$rc" "a backslash-continued brief command pinning a banned model must refuse"
  assert_refused_before_launch deny-brief-continued "$out" "'kimi-y' is on the never-use model list"

  fm_test_spawn_brief "$HOME_DIR" deny-brief-subcommand $'Launch the sub-run:\n\n```sh\nopencode run --model moonshotai/kimi-k2 "do it"\n```'
  out=$(spawn_ship deny-brief-subcommand no-mistakes claude --model claude-opus-5-5); rc=$?
  expect_code 1 "$rc" "a harness subcommand launch in the brief pinning a banned model must refuse"
  assert_refused_before_launch deny-brief-subcommand "$out" "'moonshotai/kimi-k2' is on the never-use model list"
  pass "a model split across --provider and --model, or provider: and model:, is checked as provider/model"
}

test_short_model_flag_pins_refuse() {
  local out rc
  new_case short
  write_denylist
  out=$(spawn_ship deny-raw-short no-mistakes "codex exec -m kimi-x"); rc=$?
  expect_code 1 "$rc" "a raw codex launch pinning a banned model with -m must refuse"
  assert_refused_before_launch deny-raw-short "$out" "raw launch model 'kimi-x' is on the never-use model list"

  fm_test_spawn_brief "$HOME_DIR" deny-brief-short $'Launch the sub-run:\n\n```sh\ncodex exec -m kimi-x task\n```'
  out=$(spawn_ship deny-brief-short no-mistakes claude --model claude-opus-5-5); rc=$?
  expect_code 1 "$rc" "a brief codex exec line pinning a banned model with -m must refuse"
  assert_refused_before_launch deny-brief-short "$out" "model pinned in $HOME_DIR/data/deny-brief-short/brief.md 'kimi-x' is on the never-use model list"

  printf 'agent_args_override:\n  codex: [-m, kimi-x]\n' > "$NM_DIR/config.yaml"
  out=$(spawn_ship deny-nm-short no-mistakes claude --model claude-opus-5-5); rc=$?
  expect_code 1 "$rc" "an agent_args_override codex list pinning a banned model with -m must refuse"
  assert_refused_before_launch deny-nm-short "$out" "no-mistakes reviewer model in $NM_DIR/config.yaml 'kimi-x' is on the never-use model list"
  pass "-m pins a model for codex, opencode, and kimi launches, briefs, and reviewer lists"
}

test_mentions_and_comments_are_not_pins() {
  local out rc
  new_case mentions
  write_denylist
  fm_test_spawn_brief "$HOME_DIR" deny-prose "$(printf '%s\n' \
    "Reproduce the incident, but do not pass \`--model kimi-coding/k3\` to anything; run \`no-mistakes axi run\` with its default reviewer." \
    "no-mistakes reviewers must never get --model kimi-coding/k3." \
    "kimi is banned, so never pass --model kimi-coding/k3")"
  cat > "$NM_DIR/config.yaml" <<'YAML'
agent: [pi] # was --model kimi-coding/k3
agent_args_override:
  # pi: [--provider, kimi-coding, --model, k3]
  pi:
    # - --model
    # - kimi-coding/k3
    - --provider
    - openai-codex
    - --model
    - gpt-6.1-sol # replaced kimi-coding/k3
YAML
  out=$(spawn_ship deny-prose no-mistakes claude --model claude-opus-5-5); rc=$?
  expect_code 0 "$rc" "prose that forbids a banned model and commented YAML must not refuse: $out"
  assert_grep "claude-opus-5-5" "$CASE/launch.log" "the allowed model is launched"
  pass "prose mentioning a banned model and YAML comments, whole-line or trailing, are not pins"
}

test_malformed_list_refuses() {
  local out rc
  new_case malformed
  printf '{"never": [{"pattern": "kimi"}]}' > "$HOME_DIR/config/model-denylist.json"
  out=$(spawn_ship deny-bad no-mistakes claude --model claude-opus-5-5); rc=$?
  expect_code 1 "$rc" "a malformed list must refuse rather than launch unchecked"
  assert_refused_before_launch deny-bad "$out" "every never entry needs a one-line reason"
  pass "a malformed list refuses every launch"
}

# next_worktree <name>: a fresh copy for a further launch in the same case.
next_worktree() {
  WT="$CASE/wt-$1"
  git -C "$PROJ" worktree add --quiet -b "wt-${CASE##*/}-$1" "$WT"
}

test_library_matching_and_summary() {
  local dir summary
  dir="$TMP_ROOT/lib"
  mkdir -p "$dir"
  (
    # shellcheck source=bin/fm-model-denylist-lib.sh
    . "$ROOT/bin/fm-model-denylist-lib.sh"
    fm_model_denylist_load "$dir" || fail "an absent list must load"
    fm_model_denylist_check model kimi-coding/k3 || fail "an absent list bans nothing"
    [ -z "$(fm_model_rules_summary)" ] || fail "an absent list has no summary"
    printf '%s' '{"never":[{"pattern":"gpt-*-luna*","reason":"Luna is banned"}],"rules":["Opus does judgment work."]}' \
      > "$dir/model-denylist.json"
    fm_model_denylist_load "$dir" || fail "a valid list must load: $FM_MODEL_DENYLIST_ERROR"
    fm_model_denylist_check model OpenAI-Codex/GPT-6-Luna && fail "a suffix after a slash matches, ignoring case"
    fm_model_denylist_check model openai-codex/gpt-6.1-sol || fail "an unlisted model passes"
    summary=$(fm_model_rules_summary)
    assert_contains "$summary" "Never use gpt-*-luna* (Luna is banned). Opus does judgment work." "the summary lists bans then rules"
    summary=$(FM_MODEL_RULES_SUMMARY_MAX=40 fm_model_rules_summary)
    [ "$(printf '%s' "$summary" | wc -c | tr -d ' ')" -le 40 ] || fail "the summary honors its byte cap: $summary"
    fm_model_option_looks_like_model "Sol 6.1 high" || fail "a Sol option names a model"
    fm_model_option_looks_like_model "solution draft" && fail "an ordinary word is not a model"
    assert_equals "$(fm_model_denylist_command_pins "no-mistakes axi run --provider kimi-coding --model k3")" "kimi-coding/k3" "a command line combines --provider with --model"
    assert_equals "$(fm_model_denylist_command_pins "pi --model=openai-codex/gpt-6-luna --provider=openai-codex")" "openai-codex/gpt-6-luna" "a model already carrying its provider is not prefixed twice"
    assert_equals "$(fm_model_denylist_command_pins "no-mistakes axi run # --model kimi-coding/k3")" "" "a shell comment is not a pin"
    assert_equals "$(fm_model_denylist_brief_pins 'opencode run --model moonshotai/kimi-k2 "do it"')" "moonshotai/kimi-k2" "opencode run is a launch"
    assert_equals "$(fm_model_denylist_brief_pins 'codex exec --model kimi-x task')" "kimi-x" "codex exec is a launch"
    assert_equals "$(fm_model_denylist_command_pins '- opencode run -m=moonshotai/kimi-k2')" "moonshotai/kimi-k2" "-m= is the model flag for opencode"
    assert_equals "$(fm_model_denylist_command_pins 'claude -m kimi-x')" "" "-m is not a model flag for other harnesses"
    assert_equals "$(fm_model_denylist_brief_pins $'kimi is banned, so never pass --model kimi-coding/k3\nno-mistakes reviewers must never get --model kimi-coding/k3.\ncodex exec tasks must avoid --model kimi-x')" "" "prose starting with a binary name is not a launch"
    assert_equals "$(fm_model_denylist_brief_pins $'Never pass `--model kimi-coding/k3`.\n- `no-mistakes axi run --model claude-opus-5-5`\n$ pi --provider openai-codex --model gpt-6.1-sol')" \
      $'claude-opus-5-5\nopenai-codex/gpt-6.1-sol' "only launch command lines in prose are pins"

    exit 0
  ) || fail "library checks failed"
  pass "the library matches suffixes case-insensitively, summarizes within its cap, and recognizes model options"
}

test_absent_list_keeps_launches_unchanged
test_banned_model_refuses_every_launch_shape
test_brief_and_reviewer_pins_refuse
test_provider_split_pins_refuse
test_short_model_flag_pins_refuse
test_mentions_and_comments_are_not_pins
test_malformed_list_refuses
test_library_matching_and_summary
