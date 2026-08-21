#!/usr/bin/env bash
# The structured decision record must satisfy the board's own call_item contract,
# because a record the board rejects is worse than no record: it fails at the
# moment the captain is waiting.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER="$ROOT/bin/fm-decision-record.sh"

TMP_ROOT=$(fm_test_tmproot fm-decision-record) || exit 1
export FM_STATE_OVERRIDE="$TMP_ROOT/state"

cleanup() { fm_test_cleanup; }
trap cleanup EXIT

rec() { "$OWNER" "$@" 2>&1; }

# The board validates call items with these predicates (bin/fm-bearings-board.sh).
# This asserts our OUTPUT against that contract, never the board's source bytes.
# The board exposes no validate-only entry point (build arms a Lavish session),
# so the contract is restated here; if the board's call_item predicate changes,
# update this copy with it.
board_accepts() {  # <json>
  printf '%s' "$1" | jq -e '
    def nonempty_string: type == "string" and length > 0;
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def repo_marker: has("repo") and (.repo == null or (.repo | type == "string"));
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    type == "object"
    and (.key | slug(128))
    and (.type == "decision" or .type == "merge" or .type == "credential")
    and repo_marker
    and (.title | nonempty_string)
    and (.options | type == "array")
    and ((.options | length) > 0 or .allow_freeform == true)
    and ([.options[] | type == "object" and (.value | slug(128))
          and (.label | nonempty_string) and optional_string("hint")] | all)
    and (optional_string("about")) and (optional_string("decide"))
    and (optional_string("detail")) and (optional_string("freeform_hint"))
    and ((has("close") | not) or (.close == "done" or .close == "release"))
    and ((has("allow_freeform") | not) or (.allow_freeform | type == "boolean"))
    and ((has("recommend_value") | not)
      or ((.recommend_value | slug(128))
        and (.recommend_value as $r | [.options[].value] | index($r) != null)))
    and (if .type == "merge" then (.risk | nonempty_string) else true end)
  ' >/dev/null 2>&1
}

test_record_satisfies_the_board_contract() {
  rec record ci-never-registers \
    --title "CI can never go green here. How should we close?" \
    --option declare-no-ci "Declare no_ci on the default branch" \
    --option abort-rerun "Abort and rerun once real CI exists" \
    --option accept-no-ci "Accept as done without CI" \
    --hint declare-no-ci "The mechanism the pipeline documents for zero-CI repos" \
    --recommend declare-no-ci \
    --about "PR 1 has no CI checks configured" \
    --detail "A question about how to finish a review." >/dev/null \
    || fail "recording a well-formed decision failed"

  local json; json=$("$OWNER" get ci-never-registers)
  board_accepts "$json" || fail "the board's own predicate rejected our record: $json"

  [ "$(printf '%s' "$json" | jq -r '.options | length')" = 3 ] \
    || fail "all three options should survive"
  [ "$(printf '%s' "$json" | jq -r '.recommend_value')" = declare-no-ci \
    ] || fail "the recommendation should be carried as data"
  [ "$(printf '%s' "$json" | jq -r '.options[0].hint')" != null ] \
    || fail "a hint attached to a declared option should survive"
  pass "a recorded decision satisfies the board's call_item contract verbatim"
}

test_repo_marker_is_always_present() {
  # repo_marker is has("repo"), so an omitted repo must still be recorded as null.
  local json; json=$("$OWNER" get ci-never-registers)
  printf '%s' "$json" | jq -e 'has("repo")' >/dev/null \
    || fail "repo must be present even when unspecified"
  [ "$(printf '%s' "$json" | jq -r '.repo')" = null ] \
    || fail "an unspecified repo should be null, not a string"
  pass "an unspecified repo is recorded as null so repo_marker still holds"
}

test_recommendation_must_name_a_real_option() {
  rec record bad-recommend --title T --option a "A" --recommend nope >/dev/null 2>&1 \
    && fail "a recommendation outside the options must be refused"
  pass "a recommendation that names no offered option is refused at the source"
}

test_options_are_required_unless_freeform() {
  rec record bare --title T >/dev/null 2>&1 \
    && fail "a decision with no options and no freeform must be refused"
  rec record freeform --title T --allow-freeform --freeform-hint "name a number" >/dev/null \
    || fail "--allow-freeform should stand in for options"
  board_accepts "$("$OWNER" get freeform)" \
    || fail "a freeform record must still satisfy the board"
  pass "options are required unless the record explicitly allows a freeform answer"
}

test_merge_requires_risk() {
  rec record m1 --type merge --title T --option go "Go" >/dev/null 2>&1 \
    && fail "a merge call without --risk must be refused"
  rec record m2 --type merge --title T --option go "Go" --risk "touches auth" >/dev/null \
    || fail "a merge call with --risk should be accepted"
  board_accepts "$("$OWNER" get m2)" || fail "the merge record must satisfy the board"
  pass "a merge call is refused without the risk the board requires"
}

test_duplicate_and_unknown_options_are_refused() {
  rec record dup --title T --option a "A" --option a "A again" >/dev/null 2>&1 \
    && fail "a duplicate option value must be refused"
  rec record hint-unknown --title T --option a "A" --hint b "no such option" >/dev/null 2>&1 \
    && fail "hinting an undeclared option must be refused"
  pass "duplicate options and hints for undeclared options are refused"
}

test_pr_url_must_be_https() {
  rec record badurl --title T --option a "A" --pr-url "http://example.com/1" >/dev/null 2>&1 \
    && fail "a non-https pr-url must be refused"
  pass "a pr-url that the board would reject is refused at the source"
}

test_status_line_carries_the_key_and_the_record() {
  local line; line=$("$OWNER" status-line ci-never-registers)
  case $line in
    "needs-decision [key=ci-never-registers]:"*) ;;
    *) fail "the status line must open with the keyed needs-decision verb: $line" ;;
  esac
  case $line in
    *"{options=declare-no-ci,abort-rerun,accept-no-ci}"*) ;;
    *) fail "the status line must name the options: $line" ;;
  esac
  case $line in
    *"{recommend=declare-no-ci}"*) ;;
    *) fail "the status line must name the recommendation: $line" ;;
  esac
  case $line in
    *"{record=state/decisions/ci-never-registers.call.json}"*) ;;
    *) fail "the status line must point at the record: $line" ;;
  esac
  pass "the status line names the key, options, recommendation, and record path"
}

test_list_is_a_splice_ready_array() {
  local arr; arr=$("$OWNER" list)
  printf '%s' "$arr" | jq -e 'type == "array" and length >= 3' >/dev/null \
    || fail "list must return an array of every open record: $arr"
  printf '%s' "$arr" | jq -e 'all(.[]; has("key") and has("options"))' >/dev/null \
    || fail "every listed item must be a call item"
  [ "$arr" = "$("$OWNER" list)" ] || fail "list must be stable across runs"
  pass "list returns a stable array ready to splice into a board payload"
}

test_clear_is_idempotent() {
  "$OWNER" clear m1 >/dev/null 2>&1
  local out; out=$("$OWNER" clear m2)
  case $out in cleared:*) ;; *) fail "clearing a present record should report cleared: $out" ;; esac
  out=$("$OWNER" clear m2)
  case $out in already-clear:*) ;; *) fail "clearing twice should be benign: $out" ;; esac
  pass "clearing a record is idempotent"
}


test_record_satisfies_the_board_contract
test_repo_marker_is_always_present
test_recommendation_must_name_a_real_option
test_options_are_required_unless_freeform
test_merge_requires_risk
test_duplicate_and_unknown_options_are_refused
test_pr_url_must_be_https
test_status_line_carries_the_key_and_the_record
test_list_is_a_splice_ready_array
test_clear_is_idempotent
