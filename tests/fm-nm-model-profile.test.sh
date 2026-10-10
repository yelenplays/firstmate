#!/usr/bin/env bash
# Read-only current-run immutable-model attribution, independent of disk config.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$ROOT/bin/fm-nm-run-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-model-profile)
WT="$TMP_ROOT/repo"
export NM_HOME="$TMP_ROOT/nm"
mkdir -p "$WT" "$NM_HOME"
git init -q -b own-model-trial "$WT"
status=$'run:\n  id: OWN_RUN\n  branch: own-model-trial\n  status: running'
profile() { fm_nm_saved_model_profile "$WT" "$1"; }
profile $'runs_on_current_branch: 0\nruns[1]{id,branch,status,head,pr}:\n  OTHER,other-branch,running,abcdef0,""' >/dev/null || fail 'empty current branch read another branch'
[ ! -e "$NM_HOME/state.sqlite" ] || fail 'read-only absent query created a database'
profile "$status" >/dev/null 2>&1 && fail 'missing active-run database was guessed'
python3 - "$NM_HOME/state.sqlite" <<'PY'
import json, sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('CREATE TABLE runs (id TEXT PRIMARY KEY, branch TEXT, pi_profile TEXT)')
    db.execute('INSERT INTO runs VALUES (?,?,?)', ('OWN_RUN', 'own-model-trial', json.dumps({'model':'openai-codex/gpt-6.1-sol','effort':'high'})))
    db.execute('INSERT INTO runs VALUES (?,?,?)', ('OTHER', 'other-branch', 'not-readable-as-a-profile'))
PY
out=$(profile "$status") || fail 'saved profile not readable'
assert_equals pinned "$(jq -r .state <<<"$out")" 'saved pin has explicit attribution'
assert_equals openai-codex/gpt-6.1-sol "$(jq -r .selected.model <<<"$out")" 'saved model survives unrelated config'
profile "${status/own-model-trial/other-branch}" >/dev/null 2>&1 && fail 'wrong branch accepted a model pin'
profile "${status/OWN_RUN/OTHER}" >/dev/null 2>&1 && fail 'another branch record accepted a model pin'
assert_equals absent "$(profile "${status/running/completed}" | jq -r .state)" 'terminal history does not replace new-run config'
python3 - "$NM_HOME/state.sqlite" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('UPDATE runs SET pi_profile = NULL WHERE id = ?', ('OWN_RUN',))
PY
assert_equals unpinned "$(profile "$status" | jq -r .state)" 'native unpinned chain remains explicit'
python3 - "$NM_HOME/state.sqlite" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('UPDATE runs SET pi_profile = ? WHERE id = ?', ('{"model":"unknown","effort":null}', 'OWN_RUN'))
PY
profile "$status" >/dev/null 2>&1 && fail 'malformed native profile was invented'
pass 'immutable model metadata is read-only, current-run scoped and safely refused when uninspectable'
