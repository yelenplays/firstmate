#!/usr/bin/env bash
# usage: drive.sh <fm-root> <wt> <meta> [patterns]
set -u
. "$1/bin/fm-dod-lib.sh"
[ -n "${PATTERNS:-}" ] && FM_TEST_AUTHOR_MODEL_PATTERNS=$PATTERNS
echo "== history =="; fm_test_ban_nm_history "$(fm_dod_meta_value "$3" branch)" "$(fm_dod_meta_value "$3" project)"; echo "history rc=$?"
echo "== refused test files (sha step author path) =="
fm_test_ban_pipeline_fixer_tests "$2" "$3"
echo "== gate verdict =="
fm_test_ban_accept_done ship no-mistakes "$2" "done: pr ready" "$3" 1 && echo ACCEPT || echo "REFUSE rc=1"
