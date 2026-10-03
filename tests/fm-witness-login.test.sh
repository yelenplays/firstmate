#!/usr/bin/env bash
# Behavior tests for bin/fm-witness-login.sh: a witness types its browser logins
# by name, and no login value reaches anything the witness reads.
#
# A fake chrome-devtools-axi echoes the arguments it received to stdout and to
# stderr, the way a browser tool's snapshot can show a filled field, so the
# suite sees both what the tool was given and what the witness was shown.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOGIN="$ROOT/bin/fm-witness-login.sh"
TMP_ROOT=$(fm_test_tmproot fm-witness-login)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOGINS="$HOME_DIR/config/witness-logins.env"
mkdir -p "$HOME_DIR/config"

cat > "$FAKEBIN/chrome-devtools-axi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_BROWSER_LOG"
echo "tool saw: $*"
echo "tool warned: $*" >&2
exit "${FAKE_BROWSER_EXIT:-0}"
EOF
chmod +x "$FAKEBIN/chrome-devtools-axi"

login() {
  FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" FAKE_BROWSER_LOG="$TMP_ROOT/browser.log" "$LOGIN" "$@"
}

write_logins() {
  printf '# witness logins\nSHOP_ADMIN=hunter2-admin\nSHOP_ADMIN_PIN=hunter2\n\nEMPTY_ONE=\n' > "$LOGINS"
  chmod 600 "$LOGINS"
}

test_names_never_show_values() {
  local out
  write_logins
  out=$(login names 2>&1) || fail "names failed: $out"
  assert_equals "SHOP_ADMIN"$'\n'"SHOP_ADMIN_PIN" "$out" "names did not list exactly the configured logins"
  rm -f "$LOGINS"
  out=$(login names 2>&1) || fail "names failed with no logins file: $out"
  assert_equals "" "$out" "names printed something with no logins file"
  pass "fm-witness-login: names lists login names only, and nothing when none are configured"
}

test_fill_types_by_name_and_redacts() {
  local out err
  write_logins
  : > "$TMP_ROOT/browser.log"
  out=$(login fill @g1:3 SHOP_ADMIN 2>"$TMP_ROOT/err") || fail "fill failed: $out"
  err=$(cat "$TMP_ROOT/err")
  assert_equals "fill @g1:3 hunter2-admin" "$(cat "$TMP_ROOT/browser.log")" "the browser tool was not given the login's value"
  assert_equals "tool saw: fill @g1:3 <secret>SHOP_ADMIN</secret>" "$out" "stdout was not redacted by name"
  assert_equals "tool warned: fill @g1:3 <secret>SHOP_ADMIN</secret>" "$err" "stderr was not redacted by name"
  out=$(login fill @g1:4 SHOP_ADMIN_PIN 2>&1) || fail "fill of the shorter login failed: $out"
  assert_not_contains "$out" "hunter2" "a value that is part of another leaked"
  out=$(login fill @g1:3 NOPE 2>&1) && fail "fill accepted an unknown login: $out"
  assert_contains "$out" "no login named 'NOPE'" "an unknown login was not named"
  out=$(login fill g1:3 SHOP_ADMIN 2>&1) && fail "fill accepted a target that is not an element ref: $out"
  pass "fm-witness-login: fill types a login by name and the witness sees only its name"
}

test_run_redacts_and_keeps_status() {
  local out status=0
  write_logins
  out=$(login run snapshot 2>&1) || fail "run failed: $out"
  assert_equals "tool saw: snapshot"$'\n'"tool warned: snapshot" "$out" "run changed output with no value in it"
  out=$(FAKE_BROWSER_EXIT=4 login run eval 'document.title' 2>&1) || status=$?
  expect_code 4 "$status" "run did not keep the browser tool's exit status"
  out=$(login run fill @g1:3 hunter2-admin 2>&1) && fail "run accepted a login value typed by hand: $out"
  assert_contains "$out" "contains the value of login SHOP_ADMIN" "a typed value was not refused by name"
  assert_not_contains "$out" "hunter2-admin" "the refusal echoed the value"
  pass "fm-witness-login: run redacts, keeps the exit status, and refuses a value typed by hand"
}

test_unsafe_logins_file_is_refused() {
  local out
  write_logins
  chmod 644 "$LOGINS"
  out=$(login names 2>&1) && fail "a readable-by-others logins file was accepted: $out"
  assert_contains "$out" "must have mode 0600" "a loose mode was not named"
  write_logins
  printf 'lower_case=x\n' >> "$LOGINS"
  out=$(login names 2>&1) && fail "an invalid login name was accepted: $out"
  assert_contains "$out" "invalid login name" "an invalid name was not named"
  rm -f "$LOGINS"
  printf 'SHOP_ADMIN=x\n' > "$TMP_ROOT/real.env"
  chmod 600 "$TMP_ROOT/real.env"
  ln -s "$TMP_ROOT/real.env" "$LOGINS"
  out=$(login names 2>&1) && fail "a symlinked logins file was accepted: $out"
  assert_contains "$out" "not a regular file" "a symlinked logins file was not named"
  rm -f "$LOGINS"
  pass "fm-witness-login: a logins file that is not private and well formed is refused"
}

test_names_never_show_values
test_fill_types_by_name_and_redacts
test_run_redacts_and_keeps_status
test_unsafe_logins_file_is_refused
