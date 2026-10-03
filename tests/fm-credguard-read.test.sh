#!/usr/bin/env bash
# shellcheck disable=SC2016
# Behavior tests for the credential read guard (docs/credguard.md).
#
# bin/fm-credguard-read.mjs is the single owner of the decision. This suite
# drives its exported decide() through a deny and an allow table (ported from
# korallis/agent-stack test/credguard-read.test.js, Apache-2.0, see NOTICE),
# then the CLI's per-runtime output contract, key-names-only mode, the local
# path list, and the rule that the guard never blocks on its own error.
# Fake paths and a throwaway HOME only: no real credential file is read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-credguard-read.mjs"
command -v node >/dev/null 2>&1 || { pass "node not installed, skipping"; exit 0; }

T=$(fm_test_tmproot fm-credguard-read) || fail "could not create a temp root"
EMPTY_LIST="$T/no-local-list"

# --- decision tables ---------------------------------------------------------

test_decision_tables() {
  local out
  out=$(GUARD="$GUARD" T="$T" node --input-type=module - 2>&1 <<'JS'
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
const g = await import(pathToFileURL(process.env.GUARD).href);
const root = process.env.T, home = "/home/seat", cwd = "/work/app";
const SECRETS = "~/.config/fm-test/secrets/**";
const PATS = [...g.DEFAULT_PATTERNS, SECRETS];
let bad = 0;
const want = (label, got, expected) => { if (got !== expected) { bad++; console.log(`MISMATCH ${label}: expected ${expected ? "deny" : "allow"}`); } };
const call = (runtime, tool_name, tool_input, opts = {}) =>
  g.decide(runtime, { tool_name, tool_input, cwd: opts.cwd ?? cwd }, { home: opts.home ?? home, pats: opts.pats ?? PATS }).deny;
const bash = (command, opts) => call("claude", "Bash", { command }, opts);

// Commands that would print a credential file or an environment.
for (const c of [
  "cat /work/app/.preview-db-runtime-url", "cat ~/.config/fm-test/secrets/preview/db-runtime-url",
  "cat .env", "cat ./.env.local", "head -3 .env.production", "tail -n 5 ../api/.env", "less .env", "bat .env",
  "jq . certs/server.pem", "grep DATABASE_URL .env", "rg TOKEN .env.local", "awk -F= '{print $2}' .env",
  "sed -n 1,5p .env", "sed 's/x/y/' .env", "xxd .env", "od -c .env", "strings key.pem", "base64 .env",
  "cut -d= -f2 .env", "cut -d= -f1 .env", "sort .env", "diff .env .env.local", "cat $HOME/.config/fm-test/secrets/x.env",
  "cat ${HOME}/.config/fm-test/secrets/x.env", "cat prod.env", "cat .env*", "cat config/*.pem",
  'echo "$(cat .env)"', "echo $(< .env)", "echo `cat .env`", "cat < .env", "tee < .env",
  "cp .env /dev/stdout", "cp .env /dev/fd/1", "cp .env /dev/fd/2", "cp .env /dev/tty", "dd if=.env", "dd if=.env of=/dev/fd/1", "dd if=.env of=/dev/fd/2", "git show HEAD:.env", "git diff .env", "git log -p -- .env",
  'bash -c "cat .env"', "sh -c 'head .env'", "eval cat .env", "sudo cat /etc/app/.env", "FOO=1 cat .env", "timeout 5 cat .env",
  "source .env && echo $DATABASE_URL", ". ./.env; printenv", "set -a; . .env; set +a; env", "source .env; export -p",
  "source .env && printf '%s' \"$TOKEN\"", "cd /tmp && cat .env | grep URL", "export $(grep -v '^#' .env | xargs)",
  "grep -e URL .env", "grep -A 2 URL .env",
  "(cat .env)", "( head .env )", "{ cat .env; }", "if cat .env; then :; fi", 'bash --noprofile --norc -lc "cat .env"',
  "sh -ec 'cat .env'", "env -u UNUSED cat .env", "env -i PATH=/bin cat .env", 'env -S "cat .env"', "timeout -s KILL 5 cat .env",
  "cat <<EOF\n$(cat .env)\nEOF", "grep -- -l .env", "grep -e -l .env", "rg -- -q .env",
  "source .env; declare -p FIXTURE_KEY", "source .env; declare -px",
  "jq -n --rawfile secret .env '$secret'", "jq --from-file f.jq .env", "rg --regexp TOKEN -- .env", "jq -r .key key.pem",
  // firstmate defaults and macOS additions
  "cat ~/.ssh/id_ed25519", "cat ~/.aws/credentials", "cat ~/.netrc", "cat ~/.codex/auth.json", "cat ~/.config/gh/hosts.yml",
  "gtimeout 5 cat .env", "ditto .env /dev/stdout", 'osascript -e "do shell script \\"cat .env\\""',
  'python3 -c "print(open(\\".env\\").read())"',
  // environments
  "env", "printenv", "printenv API_TOKEN", "ps eww", "export -p", "declare -x", "set", "cat /proc/1/environ",
  "launchctl getenv OPENAI_API_KEY", "N=OPENAI_API_KEY; printenv \"$N\"", "N=OPENAI_API_KEY; launchctl getenv \"$N\"",
]) want(`deny ${JSON.stringify(c)}`, bash(c), true);

// Using credentials without printing them, and ordinary commands.
for (const c of [
  "grep -r TODO .", "cat README.md", "ls .env*", "ls -la", "cat .env.example", "cat .env.sample", "head .env.template",
  "set -a; . .env; set +a; npm run migrate", "source .env && npm test", "source .env && echo done", "npm run dev -- --env-file .env",
  "docker run --env-file .env img", "grep -q '^DATABASE_URL=' .env && echo present", "grep -c KEY .env", "grep -l KEY -r .",
  "rg -l TOKEN", "wc -l .env", "shasum -a 256 .env", "test -f .env && echo yes", "stat .env",
  "cp .env .env.bak", "mv .env.local .env", "sed -i '' 's/old/new/' .env", "echo 'X=1' >> .env", "printf 'K=v\\n' > .env.local",
  "grep -q FIXTURE_KEY < .env", "source .env; set -e; true", "grep -- .env README.md",
  "cat <<'EOF'\n$(cat .env)\nEOF", "echo 'do not cat .env'", "grep -rn 'runtime-url' docs/",
  "node scripts/migrate.js", "cat src/app.ts", "cat package.json | jq .scripts", "sed -n '/.env/p' docs/setup.md",
  "cat ~/.ssh/id_ed25519.pub", "printenv PATH", "N=PATH; printenv \"$N\"", "ps aux", "ps -ef", "compgen -e", "launchctl getenv PATH", "N=PATH; launchctl getenv \"$N\"", 
  `${process.env.GUARD} --keys .env`,
]) want(`allow ${JSON.stringify(c)}`, bash(c), false);

// Globs, links, copies and variables resolve against a real directory.
const w = fs.mkdtempSync(path.join(root, "glob-")), d = path.join(w, "app");
fs.mkdirSync(d); fs.writeFileSync(path.join(d, ".env"), "FIXTURE_KEY=x\n"); fs.writeFileSync(path.join(d, "notes.txt"), "hi\n");
const inW = (c) => bash(c, { cwd: w, home: w });
want("glob * skips dotfiles", inW("cat app/*"), false);
for (const c of ["shopt -s dotglob; cat app/*", "cat app/.*", "cat app/.e*", "cat app/.en?", "cat app/.[e]nv", "cd app; cat .env",
  "cp app/.env /tmp/n.txt; cat /tmp/n.txt", "ln -s app/.env n && cat n", "cat $'app/\\x2eenv'", "cat app/.{e,x}nv",
  "F=app/.env; cat $F", "D=app; cat ${D}/.env", "F=app/.env bash -c 'cat \"$F\"'"]) want(`deny in dir ${JSON.stringify(c)}`, inW(c), true);
for (const c of ["cd app && cat notes.txt", "cp app/notes.txt n && cat n", "cat app/.{x,y}nv", "F=app/.env; F=app/notes.txt; cat \"$F\""])
  want(`allow in dir ${JSON.stringify(c)}`, inW(c), false);
want("case fold on macOS only", bash("cat .ENV"), process.platform === "darwin");

// File-read and search tools, per harness payload shape.
want("claude Read .env", call("claude", "Read", { file_path: "/work/app/.env" }), true);
want("claude Read .env.example", call("claude", "Read", { file_path: "/work/app/.env.example" }), false);
want("claude Read README", call("claude", "Read", { file_path: "/work/app/README.md" }), false);
want("claude Grep names-only default", call("claude", "Grep", { pattern: "URL", path: "/work/app/.env" }), false);
want("claude Grep content", call("claude", "Grep", { pattern: "URL", path: "/work/app/.env", output_mode: "content" }), true);
want("claude Grep glob content", call("claude", "Grep", { pattern: "URL", path: ".", glob: ".env*", output_mode: "content" }), true);
want("claude Write .env", call("claude", "Write", { file_path: "/work/app/.env", content: "X=1" }), false);
want("devin exec", call("devin", "exec", { command: "cat .env" }), true);
want("devin read", call("devin", "read", { file_path: "/work/app/.env" }), true);
want("devin grep prints lines", call("devin", "grep", { pattern: "URL", path: "/work/app/.env" }), true);
want("codex Bash", call("codex", "Bash", { command: "cat .env" }), true);
want("kimi Bash with its own cwd", g.decide("kimi", { tool_name: "Bash", tool_input: { command: "cat .env", cwd: d } }, { home, pats: PATS }).deny, true);
want("kimi Read path", call("kimi", "Read", { path: "/work/app/.env" }), true);
want("grok toolInput command", g.decide("grok", { toolName: "run_terminal_command", toolInput: { command: "cat .env" }, cwd }, { home, pats: PATS }).deny, true);
want("pi read relative path", g.decide("pi", { tool_name: "read", tool_input: { path: ".env" }, cwd }, { home, pats: PATS }).deny, true);
want("pi bash", g.decide("pi", { tool_name: "bash", tool_input: { command: "cat .env" }, cwd }, { home, pats: PATS }).deny, true);
want("unknown tool without a command", call("claude", "WebFetch", { url: "https://example.com/.env" }), false);

// The deny reason names the file and the key-names-only command.
const r = g.decide("claude", { tool_name: "Bash", tool_input: { command: "cat /home/seat/app/.env" }, cwd }, { home, pats: PATS }).reason;
if (!/blocked, because this would print ~\/app\/\.env \(a credential file, pattern \*\*\/\.env\)/.test(r) || !r.includes("--keys ~/app/.env")) {
  bad++; console.log("MISMATCH deny reason:\n" + r);
}
const envReason = g.decide("claude", { tool_name: "Bash", tool_input: { command: "env" }, cwd }, { home, pats: PATS }).reason;
if (!/compgen -e/.test(envReason)) { bad++; console.log("MISMATCH env reason:\n" + envReason); }

// Key names only.
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
if (!eq(g.keyNames("# c\nA=1\nexport B_2 = x\n  C=\nnot a pair\nD"), ["A", "B_2", "C"])) { bad++; console.log("MISMATCH keyNames pairs"); }
if (!eq(g.keyNames("-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC=\n-----END PRIVATE KEY-----\n"), [])) { bad++; console.log("MISMATCH keyNames pem"); }

// The local path list.
const list = path.join(root, "paths"); fs.writeFileSync(list, "# local\n~/.config/project-x/**\n**/*.kubeconfig\n");
const local = g.patterns({ FM_CREDGUARD_READ_PATHS: list }, home);
want("local dir pattern", bash("cat ~/.config/project-x/db.url", { pats: local }), true);
want("local glob pattern", bash("cat cluster.kubeconfig", { pats: local }), true);
want("not protected without the list", bash("cat ~/.config/project-x/db.url", { pats: g.DEFAULT_PATTERNS }), false);
if (!eq(g.patterns({ FM_CREDGUARD_READ_PATHS: path.join(root, "absent") }, home), g.DEFAULT_PATTERNS)) { bad++; console.log("MISMATCH absent list"); }
if (g.patternsFile({ XDG_CONFIG_HOME: "/x" }, home) !== "/x/firstmate/credguard-read-paths") { bad++; console.log("MISMATCH list location"); }

console.log(bad ? `FAILED ${bad}` : "ALL OK");
process.exitCode = bad ? 1 : 0;
JS
)
  case "$out" in
    *"ALL OK"*) pass "decision tables: every deny and allow case holds" ;;
    *) fail "decision tables"$'\n'"$out" ;;
  esac
}

# --- CLI output contract -----------------------------------------------------

run_guard() {  # <runtime> <json> -> sets RC OUT ERR
  local errf="$T/stderr"
  OUT=$(printf '%s' "$2" | HOME="$T" FM_CREDGUARD_READ_PATHS="$EMPTY_LIST" "$GUARD" --runtime "$1" 2>"$errf")
  RC=$?
  ERR=$(cat "$errf")
}

test_claude_json_deny() {
  run_guard claude '{"tool_name":"Bash","tool_input":{"command":"cat .env"},"cwd":"/work/app"}'
  expect_code 0 "$RC" "claude deny exit"
  assert_contains "$OUT" '"permissionDecision":"deny"' "claude deny is a JSON decision on stdout"
  assert_contains "$OUT" '"hookEventName":"PreToolUse"' "claude deny names the event"
  assert_equals "" "$ERR" "claude deny writes nothing to stderr"
  pass "claude: deny is a PreToolUse JSON decision with exit 0"
}

test_exit2_runtimes_deny() {
  local rt
  for rt in codex devin kimi pi omp opencode; do
    run_guard "$rt" '{"tool_name":"Bash","tool_input":{"command":"cat .env"},"cwd":"/work/app"}'
    expect_code 2 "$RC" "$rt deny exit"
    assert_equals "" "$OUT" "$rt deny writes nothing to stdout"
    assert_contains "$ERR" "firstmate credential guard: blocked" "$rt deny reason on stderr"
  done
  pass "codex, devin, kimi, pi, omp, opencode: deny is exit 2 with the reason on stderr"
}

test_cursor_and_gemini_json_denies() {
  run_guard cursor '{"tool_name":"Shell","tool_input":{"command":"cat .env"},"cwd":"/work/app"}'
  expect_code 0 "$RC" "cursor deny exit"
  assert_contains "$OUT" '"permission":"deny"' "Cursor receives its own deny response"
  assert_equals "" "$ERR" "Cursor deny writes nothing to stderr"
  run_guard gemini '{"tool_name":"run_shell_command","tool_input":{"command":"cat .env"},"cwd":"/work/app"}'
  expect_code 0 "$RC" "Gemini deny exit"
  assert_contains "$OUT" '"decision":"deny"' "Gemini receives a BeforeTool deny response"
  assert_equals "" "$ERR" "Gemini deny writes nothing to stderr"
  pass "Cursor and Gemini receive native JSON deny responses"
}

test_grok_deny() {
  run_guard grok '{"toolName":"bash","toolInput":{"command":"cat .env"},"cwd":"/work/app"}'
  expect_code 2 "$RC" "grok deny exit"
  assert_contains "$OUT" '"decision":"deny"' "grok deny decision on stdout"
  assert_contains "$ERR" "firstmate credential guard: blocked" "grok deny reason on stderr"
  pass "grok: deny is a decision object on stdout plus exit 2"
}

test_allow_is_silent() {
  local rt
  for rt in claude codex devin kimi grok pi omp opencode cursor gemini; do
    run_guard "$rt" '{"tool_name":"Bash","tool_input":{"command":"npm test"},"cwd":"/work/app"}'
    expect_code 0 "$RC" "$rt allow exit"
    assert_equals "" "$OUT$ERR" "$rt allow is silent"
  done
  pass "every runtime: allow is exit 0 with no output"
}

test_never_blocks_on_own_error() {
  local rt input
  for rt in claude codex grok pi; do
    for input in '' 'not json' '{"tool_name":'; do
      run_guard "$rt" "$input"
      expect_code 0 "$RC" "$rt on bad input '$input'"
      assert_equals "" "$OUT" "$rt on bad input prints no decision"
    done
  done
  pass "bad input never blocks a tool call"
}

test_unknown_runtime_is_usage_error() {
  local rc=0
  printf '{}' | "$GUARD" --runtime nope >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "unknown runtime"
  pass "an unknown runtime is a usage error, not a silent allow"
}

test_keys_mode_prints_no_values() {
  local f="$T/fixture.env" out rc=0
  printf 'FIXTURE_KEY=synthetic-value-4411\nexport OTHER_TOKEN="also-secret"\nPLAIN LINE\n# COMMENT=x\n' > "$f"
  out=$("$GUARD" --keys "$f") || rc=$?
  expect_code 0 "$rc" "--keys exit"
  assert_equals $'FIXTURE_KEY\nOTHER_TOKEN' "$out" "--keys prints the names"
  assert_not_contains "$out" "synthetic" "--keys prints no value"
  assert_not_contains "$out" "also-secret" "--keys prints no quoted value"
  assert_not_contains "$out" "PLAIN" "--keys prints no line without a name"
  rc=0
  "$GUARD" --keys "$T/absent.env" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "--keys on a missing file"
  pass "--keys prints key names only and never a value"
}

test_local_list_reaches_cli() {
  local list="$T/local-paths"
  printf '**/*.kubeconfig\n' > "$list"
  OUT=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"cat a.kubeconfig"},"cwd":"/work"}' |
    HOME="$T" FM_CREDGUARD_READ_PATHS="$list" "$GUARD" --runtime codex 2>/dev/null)
  RC=$?
  expect_code 2 "$RC" "local list pattern denies through the CLI"
  pass "the local path list reaches the hook CLI"
}

test_decision_tables
test_claude_json_deny
test_exit2_runtimes_deny
test_cursor_and_gemini_json_denies
test_grok_deny
test_allow_is_silent
test_never_blocks_on_own_error
test_unknown_runtime_is_usage_error
test_keys_mode_prints_no_values
test_local_list_reaches_cli
