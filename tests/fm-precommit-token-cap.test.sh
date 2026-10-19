#!/usr/bin/env bash
# Behavior tests for the pre-commit token cap (bin/fm-precommit-token-cap.sh).
#
# The suite drives git commit through the production wiring the same way a
# contributor runs it: fixture repos get the tracked bin script and
# .githooks/pre-commit copied in, `git config core.hooksPath .githooks` is set,
# and every pass/fail verdict comes from a real commit. Oversized seeds land
# via --no-verify, the same one-off a maintainer would need.
set -u

# A fleet pane carries GIT_CONFIG core.hooksPath; drop it so fixtures resolve
# their own hooksPath from config instead of the pane's.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-precommit-token-cap.sh"
WRAPPER="$ROOT/.githooks/pre-commit"
TMP_ROOT=$(fm_test_tmproot fm-precommit-token-cap)

fm_git_identity 'Captain Tests' 'captain@example.invalid'

big() { # <path> <bytes> [filler]: plain text of exactly <bytes> bytes, no NUL.
  mkdir -p "$(dirname "$1")"
  head -c "$2" /dev/zero | tr '\0' "${3:-a}" >"$1"
}

make_cap_repo() { # <dir>
  local dir=$1
  fm_git_init_commit "$dir"
  mkdir -p "$dir/bin"
  cp "$SCRIPT" "$dir/bin/"
  mkdir -p "$dir/.githooks"
  cp "$WRAPPER" "$dir/.githooks/"
  chmod 700 "$dir/bin/fm-precommit-token-cap.sh" "$dir/.githooks/pre-commit"
  git -C "$dir" config core.hooksPath .githooks
}

seed_oversized() { # <dir> <relpath> <bytes>
  big "$dir/$2" "$3"
  git -C "$dir" add "$2"
  git -C "$dir" commit -q --no-verify -m "seed $2"
}

committed() { # <dir> <message>: run a real commit; prints hook output; sets rc.
  git -C "$dir" commit -q -m "$1" 2>&1
}

wired_probe_refuses() { # <dir>: prove the cap is actually firing in this repo.
  big "$dir/cap-wired-probe.txt" 20001
  git -C "$dir" add cap-wired-probe.txt
  out=$(git -C "$dir" commit -qm probe 2>&1) &&
    fail "the token cap did not refuse the probe: $out"
  assert_contains "$out" "cap-wired-probe.txt" "the probe refusal did not name the probe"
  assert_contains "$out" "5001 tokens" "the probe refusal did not compute 20001/4 tokens"
  git -C "$dir" reset -q HEAD -- cap-wired-probe.txt
  rm "$dir/cap-wired-probe.txt"
}

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

test_lockfiles_are_skipped() {
  local dir
  dir="$TMP_ROOT/lockfiles"
  make_cap_repo "$dir"
  big "$dir/package-lock.json" 30000
  big "$dir/go.sum" 30000 b
  big "$dir/Cargo.lock" 30000 c
  git -C "$dir" add package-lock.json go.sum Cargo.lock
  committed "lockfiles pass" || fail "oversized lockfiles were refused: they must be skipped"
  wired_probe_refuses "$dir"
  pass "oversized lockfiles commit; the same repo still refuses a big script"
}

test_binary_blob_is_skipped() {
  local dir
  dir="$TMP_ROOT/binary"
  make_cap_repo "$dir"
  head -c 30000 /dev/zero >"$dir/big.bin"
  git -C "$dir" add big.bin
  committed "binary passes" || fail "an oversized binary file was refused: git's binary detection must skip it"
  wired_probe_refuses "$dir"
  pass "an oversized binary file commits; a text file the same size still refuses"
}

test_generated_markers_are_skipped() {
  local dir
  dir="$TMP_ROOT/generated"
  make_cap_repo "$dir"
  # 20-line and first-line marker variants both land in the first-20-lines window.
  {
    printf '/* @generated by fixture */\n'
    head -c 29984 /dev/zero | tr '\0' "g"
  } >"$dir/at-generated.txt"
  {
    printf '# DO NOT EDIT\n'
    head -c 29982 /dev/zero | tr '\0' "h"
  } >"$dir/do-not-edit.txt"
  {
    printf '// Code generated by fixture. DO NOT EDIT.\n'
    head -c 30000 /dev/zero | tr '\0' 'i'
  } >"$dir/code-generated.txt"
  git -C "$dir" add at-generated.txt do-not-edit.txt code-generated.txt
  committed "generated markers pass" || fail "files carrying a generated marker in their first lines were refused"
  wired_probe_refuses "$dir"
  pass "a generated marker on the first lines skips the cap; a plain file still refuses"
}

test_incidental_do_not_edit_prose_is_not_generated() {
  local dir out head_before header index=0
  for header in \
    '# When updating this file, DO NOT EDIT the table below.' \
    '# When updating this file, do not edit the table below.'; do
    dir="$TMP_ROOT/incidental-prose-$index"
    index=$((index + 1))
    make_cap_repo "$dir"
    head_before=$(git -C "$dir" rev-parse HEAD)
    {
      printf '%s\n' "$header"
      head -c 21000 /dev/zero | tr '\0' 'x'
    } >"$dir/handwritten.py"
    git -C "$dir" add handwritten.py
    out=$(committed "incidental instructions refused") && fail "incidental prose bypassed the cap: $out"
    assert_contains "$out" "handwritten.py" "the refusal did not name the authored file"
    [ "$(git -C "$dir" rev-parse HEAD)" = "$head_before" ] || fail "the refused commit changed HEAD"
  done
  pass "incidental do-not-edit prose does not exempt authored files"
}

test_unstaged_linguist_attributes_do_not_exempt_files() {
  local dir out head_before state
  for state in untracked modified; do
    dir="$TMP_ROOT/unstaged-attributes-$state"
    make_cap_repo "$dir"
    if [ "$state" = modified ]; then
      : >"$dir/.gitattributes"
      git -C "$dir" add .gitattributes
      committed "seed attributes" || fail "could not seed tracked attributes"
    fi
    head_before=$(git -C "$dir" rev-parse HEAD)
    big "$dir/handwritten.py" 21000
    git -C "$dir" add handwritten.py
    printf 'handwritten.py linguist-generated\n' >"$dir/.gitattributes"
    out=$(committed "unstaged exemption refused") && fail "unstaged attributes bypassed the cap: $out"
    assert_contains "$out" "handwritten.py: 21000 bytes" "the refusal did not name the staged oversized file"
    [ "$(git -C "$dir" rev-parse HEAD)" = "$head_before" ] || fail "the refused commit changed HEAD"
  done
  pass "untracked and modified attributes cannot exempt staged authored files"
}

test_filename_set_does_not_exempt_authored_files() {
  local dir out head_before
  dir="$TMP_ROOT/filename-set"
  make_cap_repo "$dir"
  head_before=$(git -C "$dir" rev-parse HEAD)
  big "$dir/set" 21000
  git -C "$dir" add set
  out=$(committed "authored set refused") && fail "the filename set bypassed the cap: $out"
  assert_contains "$out" "set: 21000 bytes = 5250 tokens" "the refusal did not name the oversized authored file"
  [ "$(git -C "$dir" rev-parse HEAD)" = "$head_before" ] || fail "the refused commit changed HEAD"
  pass "a filename matching an attribute value does not exempt authored files"
}

test_linguist_attributes_are_skipped() {
  local dir
  dir="$TMP_ROOT/linguist"
  make_cap_repo "$dir"
  printf 'vendor.js linguist-vendored\nautogen/** linguist-generated\n' >"$dir/.gitattributes"
  big "$dir/vendor.js" 30000
  mkdir -p "$dir/autogen"
  big "$dir/autogen/gen.c" 30000 b
  git -C "$dir" add .gitattributes vendor.js autogen/gen.c
  : >"$dir/.gitattributes"
  committed "linguist attrs pass" || fail "linguist-generated/vendored paths were refused"
  wired_probe_refuses "$dir"
  pass ".gitattributes linguist marks skip the cap; unmarked files still refuse"
}

test_linguist_true_spelling_exempts_files() {
  local dir
  dir="$TMP_ROOT/linguist-true"
  make_cap_repo "$dir"
  printf '*.gen linguist-generated=true\n*.vendor.js linguist-vendored=true\n' >"$dir/.gitattributes"
  git -C "$dir" add .gitattributes
  assert_equals true "$(git -C "$dir" check-attr --cached -z linguist-generated -- a.gen | tr '\0' '\n' | tail -n 1)" \
    "check-attr must report the explicit true spelling for the test to exercise it"
  big "$dir/a.gen" 21000
  big "$dir/b.vendor.js" 21000 b
  git -C "$dir" add a.gen b.vendor.js
  committed "explicit true linguist attrs pass" || fail "explicitly true linguist exemptions were refused"
  wired_probe_refuses "$dir"
  pass "linguist-generated=true and linguist-vendored=true exempt oversized files"
}

test_linguist_false_spelling_is_not_an_exemption() {
  local dir out head_before
  dir="$TMP_ROOT/linguist-false"
  make_cap_repo "$dir"
  head_before=$(git -C "$dir" rev-parse HEAD)
  printf '*.gen linguist-generated=false\n' >"$dir/.gitattributes"
  big "$dir/a.gen" 21000
  git -C "$dir" add .gitattributes a.gen
  out=$(committed "explicit false refused") && fail "linguist-generated=false exempted an oversized file: $out"
  assert_contains "$out" "a.gen: 21000 bytes = 5250 tokens" "the refusal did not name the oversized file"
  [ "$(git -C "$dir" rev-parse HEAD)" = "$head_before" ] || fail "the refused commit changed HEAD"
  pass "linguist-generated=false stays under the cap"
}

test_attribute_forced_binary_is_skipped() {
  local dir
  dir="$TMP_ROOT/forced-binary"
  make_cap_repo "$dir"
  printf '*.fbin -diff\n*.mm binary\n' >"$dir/.gitattributes"
  big "$dir/text.fbin" 21000
  big "$dir/text.mm" 21000 b
  git -C "$dir" add .gitattributes text.fbin text.mm
  committed "attribute-forced binary passes" || fail "attribute-forced binary files were refused"
  wired_probe_refuses "$dir"
  pass "diff-attribute-forced binary classification skips the cap; unmarked files still refuse"
}

test_binary_text_attribute_control() {
  local dir numstat
  dir="$TMP_ROOT/forced-text-nul"
  make_cap_repo "$dir"
  printf '*.ctext text\n' >"$dir/.gitattributes"
  { head -c 100 /dev/zero | tr '\0' 'n'; printf '\000'; head -c 21000 /dev/zero | tr '\0' 'o'; } >"$dir/nul.ctext"
  git -C "$dir" add .gitattributes nul.ctext
  # git itself still classes the NUL blob binary through numstat, so capture
  # that verdict before the commit consumes the staged diff.
  numstat=$(git -C "$dir" diff --cached --numstat | tr '\t' ' ')
  committed "text attribute does not force text classification" ||
    fail "a NUL blob was judged text-only because of the text attribute: the control failed"
  assert_contains "$numstat" "- - nul.ctext" "git's numstat did not report the NUL file binary, invalidating the control"
  wired_probe_refuses "$dir"
  pass "the text attribute never flips a NUL blob to text-only classification"
}

test_diff_set_forces_text_even_with_nul_bytes() {
  local dir out numstat
  dir="$TMP_ROOT/forced-text-diff"
  make_cap_repo "$dir"
  printf '*.ttext diff\n' >"$dir/.gitattributes"
  { printf '\000'; head -c 20999 /dev/zero | tr '\0' 'w'; } >"$dir/authored.ttext"
  git -C "$dir" add .gitattributes authored.ttext
  # git's own verdict lands in numstat, so capture it before the commit
  # consumes the staged diff.
  numstat=$(git -C "$dir" diff --cached --numstat -- authored.ttext | tr '\t' ' ')
  out=$(committed "forced-text refused") && fail "a set diff attribute exempted a NUL blob that git classes as text: $out"
  assert_contains "$numstat" "1 0 authored.ttext" "git itself did not class the forced-text blob as text, invalidating the control"
  assert_contains "$out" "authored.ttext: 21000 bytes" "the refusal did not name the forced-text staged file"
  pass "a set diff attribute forces text classification, so the NUL blob stays under the cap"
}

test_diff_driver_with_binary_true_is_skipped() {
  local dir numstat
  dir="$TMP_ROOT/binary-driver"
  make_cap_repo "$dir"
  git -C "$dir" config diff.custom.binary true
  printf '*.dat diff=custom\n' >"$dir/.gitattributes"
  big "$dir/generated.dat" 21000
  git -C "$dir" add .gitattributes generated.dat
  numstat=$(git -C "$dir" diff --cached --numstat -- generated.dat | tr '\t' ' ')
  committed "binary-driver passes" || fail "a file under a binary diff driver was refused although git classes it binary"
  assert_contains "$numstat" "- - generated.dat" "git's numstat did not report the driver file binary, invalidating the control"
  wired_probe_refuses "$dir"
  pass "a named diff driver with diff.<driver>.binary=true skips the cap; unmarked files still refuse"
}

test_diff_driver_binary_false_forces_text() {
  local dir out numstat
  dir="$TMP_ROOT/driver-false"
  make_cap_repo "$dir"
  git -C "$dir" config diff.grammar.binary false
  printf '*.grm diff=grammar\n' >"$dir/.gitattributes"
  { printf '\000'; head -c 20999 /dev/zero | tr '\0' 'p'; } >"$dir/authored.grm"
  git -C "$dir" add .gitattributes authored.grm
  numstat=$(git -C "$dir" diff --cached --numstat -- authored.grm | tr '\t' ' ')
  out=$(committed "driver-false refused") && fail "diff.<driver>.binary=false exempted a NUL blob that git classes as text: $out"
  assert_contains "$numstat" "1 0 authored.grm" "git itself did not class the false-driver blob as text, invalidating the control"
  assert_contains "$out" "authored.grm: 21000 bytes" "the refusal did not name the forced-text staged file"
  pass "diff.<driver>.binary=false forces text like a set diff attribute; the cap still refuses"
}

test_diff_driver_without_boolean_setting_falls_back_to_content() {
  local dir out numstat
  dir="$TMP_ROOT/driver-unconfigured"
  make_cap_repo "$dir"
  printf '*.myst diff=mystic\n' >"$dir/.gitattributes"
  { printf '\000'; head -c 20999 /dev/zero | tr '\0' 'q'; } >"$dir/nul.myst"
  big "$dir/plain.myst" 21000 r
  git -C "$dir" add .gitattributes nul.myst plain.myst
  numstat=$(git -C "$dir" diff --cached --numstat | tr '\t' ' ')
  out=$(committed "driver-fallback refused") && fail "an unconfigured diff-driver file was refused although git fell back to the content heuristic: $out"
  assert_contains "$numstat" "- - nul.myst" "git did not treat the NUL blob under an unconfigured driver as binary"
  assert_contains "$out" "plain.myst: 21000 bytes" "the refusal did not name the NUL-free file"
  assert_not_contains "$out" "nul.myst: " "the binary NUL blob was wrongly listed"
  # With the text file out of the way, only the NUL blob stays staged: the
  # heuristic marks it binary and the cap skips it.
  git -C "$dir" rm -q --cached plain.myst
  committed "driver-fallback nul passes" || fail "a NUL blob under an unconfigured driver was refused although git treats it binary"
  wired_probe_refuses "$dir"
  pass "an unconfigured diff driver falls back to git's NUL content heuristic"
}

test_unstaged_text_flip_cannot_reclassify_forced_text_files() {
  local dir out head_before
  dir="$TMP_ROOT/unstaged-text-flip"
  make_cap_repo "$dir"
  printf '*.ttext diff\n' >"$dir/.gitattributes"
  git -C "$dir" add .gitattributes
  git -C "$dir" commit -q --no-verify -m "seed attrs"
  head -c 21000 /dev/zero | tr '\0' 'w' >"$dir/authored.ttext"
  git -C "$dir" add authored.ttext
  head_before=$(git -C "$dir" rev-parse HEAD)
  out=$(committed "forced-text refused first") && fail "a staged forced-text file did not get refused: $out"
  assert_contains "$out" "authored.ttext: 21000 bytes" "the first refusal did not name the file"
  printf '*.ttext -diff\n' >"$dir/.gitattributes"
  head -c 21001 /dev/zero | tr '\0' 'w' >"$dir/authored.ttext"
  git -C "$dir" add authored.ttext
  out=$(committed "retry after unstaged flip") && fail "an unstaged -diff edit reclassified a staged forced-text file: $out"
  assert_contains "$out" "authored.ttext: 21001 bytes" "the second refusal did not name the file"
  [ "$(git -C "$dir" rev-parse HEAD)" = "$head_before" ] || fail "the refused commit changed HEAD"
  pass "worktree-only attribute flips cannot reclassify staged forced-text files"
}

test_unstaged_driver_assignment_cannot_exempt_staged_files() {
  local dir out head_before
  dir="$TMP_ROOT/unstaged-driver"
  make_cap_repo "$dir"
  head_before=$(git -C "$dir" rev-parse HEAD)
  git -C "$dir" config diff.custom.binary true
  printf '*.dat diff=custom\n' >"$dir/.gitattributes"
  big "$dir/generated.dat" 21000
  git -C "$dir" add generated.dat
  out=$(committed "unstaged driver refused") && fail "a worktree-only driver assignment exempted an oversized file: $out"
  assert_contains "$out" "generated.dat: 21000 bytes" "the refusal did not name the staged oversized file"
  [ "$(git -C "$dir" rev-parse HEAD)" = "$head_before" ] || fail "the refused commit changed HEAD"
  pass "worktree-only diff-driver assignments cannot exempt staged files"
}

test_unstaged_binary_attributes_do_not_exempt_files() {
  local dir out head_before
  dir="$TMP_ROOT/unstaged-binary-attr"
  make_cap_repo "$dir"
  head_before=$(git -C "$dir" rev-parse HEAD)
  printf 'handwritten.py -diff\n' >"$dir/.gitattributes"
  big "$dir/handwritten.py" 21000
  git -C "$dir" add handwritten.py
  out=$(committed "unstaged binary attr refused") && fail "unstaged attributes granted a binary exemption: $out"
  assert_contains "$out" "handwritten.py: 21000 bytes" "the refusal did not name the staged oversized file"
  [ "$(git -C "$dir" rev-parse HEAD)" = "$head_before" ] || fail "the refused commit changed HEAD"
  pass "worktree-only binary attribute assignments cannot exempt staged files"
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

test_filename_set_does_not_exempt_authored_files
test_new_oversized_file_is_blocked
test_existing_oversized_unchanged_or_shrunk_passes
test_existing_oversized_grown_is_blocked
test_crossing_the_limit_is_blocked
test_lockfiles_are_skipped
test_binary_blob_is_skipped
test_generated_markers_are_skipped
test_incidental_do_not_edit_prose_is_not_generated
test_unstaged_linguist_attributes_do_not_exempt_files
test_linguist_attributes_are_skipped
test_linguist_true_spelling_exempts_files
test_linguist_false_spelling_is_not_an_exemption
test_attribute_forced_binary_is_skipped
test_binary_text_attribute_control
test_diff_set_forces_text_even_with_nul_bytes
test_diff_driver_with_binary_true_is_skipped
test_diff_driver_binary_false_forces_text
test_diff_driver_without_boolean_setting_falls_back_to_content
test_unstaged_text_flip_cannot_reclassify_forced_text_files
test_unstaged_driver_assignment_cannot_exempt_staged_files
test_unstaged_binary_attributes_do_not_exempt_files
test_rename_measures_against_the_source_head_size
test_staged_deletion_never_fails
test_only_staged_content_counts
test_untracked_oversized_file_is_ignored
test_multiple_failings_are_listed_in_one_message

echo "# all fm-precommit-token-cap tests passed"
