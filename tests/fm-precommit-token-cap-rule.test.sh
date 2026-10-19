#!/usr/bin/env bash
# Behavior tests for the pre-commit token cap: the cap rule mechanics.
#
# These cases own the 5000-token (20000-byte) rule itself - new files, the
# ratchet for already-oversized files, growth past the limit, renames,
# deletions, index-only measurement, and the refusal message. Exemption
# behavior lives in tests/fm-precommit-token-cap-exemptions.test.sh; the
# shared fixture wiring in tests/fm-precommit-token-cap-helpers.sh.

# shellcheck source=tests/fm-precommit-token-cap-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-precommit-token-cap-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-precommit-token-cap-rule)

test_new_oversized_file_is_blocked() {
  local dir out
  dir="$TMP_ROOT/new-blocked"
  make_cap_repo "$dir"
  big "$dir/new.txt" 20001
  git -C "$dir" add new.txt
  out=$(committed "add new.txt") && fail "a 20001-byte new file committed: $out"
  assert_contains "$out" "precommit-token-cap" "the refusal did not carry the cap prefix"
  assert_contains "$out" "new.txt: 20001 bytes = 5001 tokens (limit 5000)" "the listing did not show size and tokens"
  assert_contains "$out" "1. Split along existing responsibility boundaries" "split instruction 1 missing"
  assert_contains "$out" "2. Move helpers or sections into sibling files" "split instruction 2 missing"
  assert_contains "$out" "3. Keep a thin entry point" "split instruction 3 missing"
  assert_contains "$out" "4. For documentation, split by heading" "split instruction 4 missing"
  assert_contains "$out" "already-oversized existing file only has to stop growing" "the ratchet note is missing"
  pass "a new oversized staged file is refused with the full split message"
}

test_existing_oversized_unchanged_or_shrunk_passes() {
  local dir head_before head_after
  dir="$TMP_ROOT/unchanged-shrunk"
  make_cap_repo "$dir"
  seed_oversized "$dir" med.txt 25000
  head_before=$(git -C "$dir" rev-parse HEAD)
  big "$dir/med.txt" 25000 b
  : >"$dir/small.txt"
  git -C "$dir" add med.txt small.txt
  committed "same size edit passes" || fail "an existing oversized file staged at the same size was refused"
  head_after=$(git -C "$dir" rev-parse HEAD)
  [ "$head_before" != "$head_after" ] || fail "the same-size commit did not land (hook likely silent-skipped instead of passing)"
  big "$dir/med.txt" 24000
  git -C "$dir" add med.txt
  committed "shrunk edit passes" || fail "an existing oversized file staged smaller than HEAD was refused"
  wired_probe_refuses "$dir"
  pass "an existing oversized file passes at the same size and when shrunk"
}

test_existing_oversized_grown_is_blocked() {
  local dir out
  dir="$TMP_ROOT/grown-blocked"
  make_cap_repo "$dir"
  seed_oversized "$dir" med.txt 24000
  big "$dir/med.txt" 25000 b
  git -C "$dir" add med.txt
  out=$(committed "grown edit refused") && fail "an existing oversized file grew past the cap and committed: $out"
  assert_contains "$out" "med.txt: 25000 bytes = 6250 tokens" "the growth listing did not show the staged size"
  assert_contains "$out" "(grew from 24000 bytes = 6000 tokens at HEAD)" "the ratchet note did not show the HEAD size"
  pass "an existing oversized file that grows is refused and names its HEAD size"
}

test_crossing_the_limit_is_blocked() {
  local dir out
  dir="$TMP_ROOT/crossing"
  make_cap_repo "$dir"
  big "$dir/grows.txt" 10000
  git -C "$dir" add grows.txt
  git -C "$dir" commit -q -m small-enough-at-head
  big "$dir/grows.txt" 20001
  git -C "$dir" add grows.txt
  out=$(committed "crossing refused") && fail "a file crossing the cap committed: $out"
  assert_contains "$out" "grows.txt: 20001 bytes = 5001 tokens" "the crossing listing did not show size and tokens"
  pass "a staged file crossing the limit from below is refused even though it existed at HEAD"
}

test_rename_measures_against_the_source_head_size() {
  local dir out
  dir="$TMP_ROOT/rename"
  make_cap_repo "$dir"
  seed_oversized "$dir" lib/huge-old.txt 25000
  git -C "$dir" mv lib/huge-old.txt lib/huge-new.txt
  committed "pure rename passes" || fail "a pure rename of an existing oversized file was refused"
  head -c 1000 /dev/zero | tr '\0' 'x' >>"$dir/lib/huge-new.txt"
  git -C "$dir" add lib/huge-new.txt
  out=$(committed "rename+growth refused") && fail "a rename that grew past the source HEAD size committed: $out"
  assert_contains "$out" "lib/huge-new.txt" "the refusal did not name the rename's destination path"
  wired_probe_refuses "$dir"
  pass "renames ratchet against the source path's HEAD size"
}

test_staged_deletion_never_fails() {
  local dir
  dir="$TMP_ROOT/deletion"
  make_cap_repo "$dir"
  seed_oversized "$dir" med.txt 25000
  git -C "$dir" rm -q med.txt
  committed "delete oversized passes" || fail "removing an oversized file was refused by the cap"
  wired_probe_refuses "$dir"
  pass "a staged deletion of an oversized file commits"
}

test_only_staged_content_counts() {
  local dir out head_before head_after
  dir="$TMP_ROOT/index-not-worktree"
  make_cap_repo "$dir"
  big "$dir/file.txt" 1000
  git -C "$dir" add file.txt
  git -C "$dir" commit -q -m tiny
  big "$dir/file.txt" 26000
  git -C "$dir" add file.txt
  : >"$dir/file.txt"
  head_before=$(git -C "$dir" rev-parse HEAD)
  out=$(committed "index still counts 26000") && fail "a commit whose index blob exceeded the cap was allowed: $out"
  assert_contains "$out" "file.txt: 26000 bytes = 6500 tokens" "the verdict did not come from the index blob"
  from_head=$(git -C "$dir" cat-file -s "HEAD:file.txt")
  [ "$from_head" -eq 1000 ] || fail "the index blob was measured from HEAD or the working tree grew into the verdict: $from_head"
  # Staging the small working-tree content moves the index under the cap.
  git -C "$dir" add file.txt
  committed "small index passes" || fail "a commit with a capped-size index blob was refused"
  head_after=$(git -C "$dir" rev-parse HEAD)
  [ "$head_before" != "$head_after" ] || fail "the small-index commit did not move HEAD"
  pass "the cap measures the index blob, never the working tree"
}

test_untracked_oversized_file_is_ignored() {
  local dir
  dir="$TMP_ROOT/untracked"
  make_cap_repo "$dir"
  big "$dir/if-only-staged.txt" 30000
  : >"$dir/small.txt"
  git -C "$dir" add small.txt
  committed "untracked ignored" || fail "an untracked oversized file was counted when only a small file was staged"
  wired_probe_refuses "$dir"
  pass "oversized untracked files stay out of the verdict; staged files still fail"
}

test_multiple_failings_are_listed_in_one_message() {
  local dir out
  dir="$TMP_ROOT/multi"
  make_cap_repo "$dir"
  big "$dir/one.txt" 21000
  big "$dir/two.txt" 22000 b
  git -C "$dir" add one.txt two.txt
  out=$(committed "two files refused") && fail "two oversized new files committed: $out"
  assert_contains "$out" "2 staged file(s)" "the refusal did not count both files"
  assert_contains "$out" "one.txt: 21000 bytes = 5250 tokens" "one.txt was not listed"
  assert_contains "$out" "two.txt: 22000 bytes = 5500 tokens" "two.txt was not listed"
  pass "one message lists every failing file with its own token count"
}

test_new_oversized_file_is_blocked
test_existing_oversized_unchanged_or_shrunk_passes
test_existing_oversized_grown_is_blocked
test_crossing_the_limit_is_blocked
test_rename_measures_against_the_source_head_size
test_staged_deletion_never_fails
test_only_staged_content_counts
test_untracked_oversized_file_is_ignored
test_multiple_failings_are_listed_in_one_message

echo "# all fm-precommit-token-cap rule tests passed"
