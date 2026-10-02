#!/usr/bin/env bash
# Behavioral tests for the per-owner GitHub account map
# (config/gh-account-by-owner) through bin/fm-pr-state.sh and the shared
# fm_gh_run helper in bin/fm-pr-lib.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pr-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-gh-account-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
command -v jq >/dev/null 2>&1 || fail "these tests need jq"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/config"
CALLS="$TMP_ROOT/calls"
TOKEN_SLASHPIPE=tok-slashpipe-secret
TOKEN_PRIVATE=tok-private-secret

# The fake gh hands out one token per logged-in account, records which token
# answered each forge call, and serves a clean open pull request.
cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
if [ "\$1 \$2" = "auth token" ]; then
  [ -z "\${GH_TOKEN-}" ] || { echo "ambient token leaked into the lookup" >&2; exit 9; }
  case "\$*" in
    *"--user Slashpipe"*) printf '%s\n' "$TOKEN_SLASHPIPE" ;;
    *"--user MarcoGC3"*) printf '%s\n' "$TOKEN_PRIVATE" ;;
    *) echo "no oauth token found for github.com account" >&2; exit 1 ;;
  esac
  exit 0
fi
printf '%s %s\n' "\${GH_TOKEN-none}" "\$1 \$2" >> "$CALLS"
case "\$*" in
  "pr view "*)
    jq -n '{state:"OPEN",mergedAt:null,isDraft:false,headRefOid:"c2eac54c17a1ddc2633ad51b83e21e5fe888142e",
      author:{login:"a",is_bot:false},mergeable:"MERGEABLE",reviewDecision:"APPROVED"}' \
      | jq -r "\${@: -1}"
    ;;
  "pr checks "*) echo '[]' | jq -r "\${@: -1}" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/gh"

run_state() {  # <url> -> output; status in RUN_STATUS
  RUN_STATUS=0
  : > "$CALLS"
  RUN_OUT=$(env -u GH_TOKEN FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$SCRIPT" "$1" 2>&1) || RUN_STATUS=$?
}

test_absent_map_keeps_the_ambient_account() {
  rm -f "$HOME_DIR/config/gh-account-by-owner"
  run_state https://github.com/SlashpipeCoding/tool/pull/7
  assert_equals "$RUN_STATUS" 0 "absent map must not change the read: $RUN_OUT"
  assert_no_grep "tok-" "$CALLS" "absent map must not set any token"
  pass "an absent map leaves every call on the active account"
}

test_mapped_owner_uses_its_account_token() {
  printf '# company tool\nslashpipecoding Slashpipe\nMarcoGC3 MarcoGC3\n' > "$HOME_DIR/config/gh-account-by-owner"
  run_state https://github.com/SlashpipeCoding/tool/pull/7
  assert_equals "$RUN_STATUS" 0 "mapped read failed: $RUN_OUT"
  assert_grep "$TOKEN_SLASHPIPE pr view" "$CALLS" "owner match is case-insensitive and uses Slashpipe"
  assert_no_grep "none " "$CALLS" "every call for the mapped owner carries its token"
  assert_not_contains "$RUN_OUT" "$TOKEN_SLASHPIPE" "the token is never printed"
  run_state https://github.com/MarcoGC3/private/pull/7
  assert_grep "$TOKEN_PRIVATE pr view" "$CALLS" "a private owner uses its own account"
  run_state https://github.com/someone-else/r/pull/7
  assert_grep "none pr view" "$CALLS" "an unmapped owner keeps the active account"
  pass "each mapped owner reads with its own account and others stay unchanged"
}

test_missing_token_refuses_without_fallback() {
  printf 'SlashpipeCoding Unknown-Acct\n' > "$HOME_DIR/config/gh-account-by-owner"
  run_state https://github.com/SlashpipeCoding/tool/pull/7
  [ "$RUN_STATUS" -ne 0 ] || fail "a mapped owner without a token must refuse"
  assert_contains "$RUN_OUT" "fm-gh-account: GitHub owner SlashpipeCoding is mapped to account Unknown-Acct" \
    "the refusal names the owner and account"
  assert_equals "$(wc -l < "$CALLS" | tr -d ' ')" 0 "no forge call runs under another account"
  pass "a missing account token refuses clearly with no fallback"
}

test_malformed_map_refuses() {
  printf 'SlashpipeCoding Slashpipe extra\n' > "$HOME_DIR/config/gh-account-by-owner"
  run_state https://github.com/SlashpipeCoding/tool/pull/7
  [ "$RUN_STATUS" -ne 0 ] || fail "a malformed map must refuse"
  assert_contains "$RUN_OUT" "fm-gh-account: malformed line" "the refusal names the malformed line"
  printf 'SlashpipeCoding Slashpipe\nslashpipecoding MarcoGC3\n' > "$HOME_DIR/config/gh-account-by-owner"
  run_state https://github.com/SlashpipeCoding/tool/pull/7
  [ "$RUN_STATUS" -ne 0 ] || fail "a conflicting map must refuse"
  assert_contains "$RUN_OUT" "mapped to both" "the refusal names the conflict"
  pass "malformed or conflicting maps refuse"
}

test_token_stays_inside_the_one_call() {
  printf 'SlashpipeCoding Slashpipe\n' > "$HOME_DIR/config/gh-account-by-owner"
  local out
  # shellcheck disable=SC2016  # The inner script expands its own variables.
  out=$(env -u GH_TOKEN FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" bash -c '
    . "$1/bin/fm-pr-lib.sh"
    fm_gh_run sh -c "printf \"%s\\n\" \"\$GH_TOKEN\"" repos/SlashpipeCoding/tool
    fm_gh_run sh -c "printf \"%s\\n\" \"\$GH_TOKEN\"" --repo slashpipecoding/tool
    fm_gh_owner_run "$(fm_gh_owner_from_args git@github.com:SlashpipeCoding/tool.git)" sh -c "printf \"%s\\n\" \"\$GH_TOKEN\""
    printf "after=%s\n" "${GH_TOKEN-unset}"' _ "$ROOT")
  assert_equals "$out" "$TOKEN_SLASHPIPE
$TOKEN_SLASHPIPE
$TOKEN_SLASHPIPE
after=unset" "token reaches only the one command, for path, --repo and ssh-remote forms"
  pass "the token is scoped to the one call"
}

test_absent_map_keeps_the_ambient_account
test_mapped_owner_uses_its_account_token
test_missing_token_refuses_without_fallback
test_malformed_map_refuses
test_token_stays_inside_the_one_call
