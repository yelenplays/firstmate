#!/usr/bin/env bash
# tests/fm-relaunch-worktree-lib.test.sh - which clone a relaunched task's
# recorded worktree may belong to (bin/fm-relaunch-worktree-lib.sh).
#
# The end-to-end relaunch behavior is pinned in tests/fm-control-relaunch.test.sh;
# this file pins the lib's own contract: origin canonicalization, the GitHub
# identity fallback and its refusal when GitHub cannot answer, the ship-only
# branch requirement, and that nothing it inspects is written.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-relaunch-worktree-lib.sh
. "$ROOT/bin/fm-relaunch-worktree-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-relaunch-worktree-lib)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
ORIG_PATH=$PATH

key_of() {  # <url> <expected-key>
  assert_equals "$2" "$(fm_relaunch_origin_key "$1")" "origin key of $1"
}

test_origin_keys_compare_one_repository_across_spellings() {
  key_of https://github.com/Lay-Distribution/Site.git github.com/lay-distribution/site
  key_of git@github.com:Lay-Distribution/Site github.com/lay-distribution/site
  key_of ssh://git@GitHub.com:22/lay-distribution/site.git/ github.com/lay-distribution/site
  key_of https://user@gitlab.example.com/Group/Sub/Project.git gitlab.example.com/Group/Sub/Project
  fm_relaunch_origin_same_repository https://github.com/Owner/Repo.git git@github.com:owner/repo \
    || fail "two spellings of one GitHub address must be one repository: $FM_RELAUNCH_WORKTREE_ERROR"
  if fm_relaunch_origin_same_repository https://gitlab.example.com/Group/Project.git https://gitlab.example.com/group/project.git; then
    fail "a non-GitHub path must not be assumed case-insensitive"
  fi
  assert_contains "$FM_RELAUNCH_WORKTREE_ERROR" "are different repositories" "a non-GitHub mismatch names the reason"
  pass "fm-relaunch-worktree-lib: origin keys equate spellings of one repository and nothing more"
}

test_local_origins_key_on_their_physical_location() {
  mkdir -p "$TMP_ROOT/bare.git"
  ln -s "$TMP_ROOT/bare.git" "$TMP_ROOT/alias.git"
  fm_relaunch_origin_same_repository "file://$TMP_ROOT/bare.git" "$TMP_ROOT/alias.git" \
    || fail "a file: URL and a symlinked path to one bare repository must match: $FM_RELAUNCH_WORKTREE_ERROR"
  pass "fm-relaunch-worktree-lib: local origins compare by physical location"
}

test_github_fallback_refuses_when_github_cannot_answer() {
  cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
echo "error connecting to api.github.com" >&2
exit 1
SH
  chmod +x "$FAKEBIN/gh"
  if PATH="$FAKEBIN:$ORIG_PATH" fm_relaunch_origin_same_repository \
      https://github.com/old-owner/site.git https://github.com/new-org/site.git; then
    fail "an unanswered GitHub lookup must never count as the same repository"
  fi
  assert_contains "$FM_RELAUNCH_WORKTREE_ERROR" "GitHub could not be asked" "the refusal names why it could not prove identity"
  rm -f "$FAKEBIN/gh"
  pass "fm-relaunch-worktree-lib: a GitHub identity that cannot be proven refuses"
}

# A recorded project clone and a second clone of the same origin whose linked
# worktree sits on fm/t1 with a commit only it has.
make_clones() {  # <dir>
  local dir=$1 origin
  fm_git_init_commit "$dir/proj"
  fm_git_add_origin "$dir/proj" "$dir/proj.origin.git"
  origin=$(git -C "$dir/proj" remote get-url origin)
  git clone --quiet "$origin" "$dir/other"
  git -C "$dir/other" worktree add --quiet -b fm/t1 "$dir/wt"
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --allow-empty -m unlanded
}

test_owner_is_the_project_for_its_own_worktree() {
  local dir="$TMP_ROOT/own"
  fm_git_worktree "$dir/proj" "$dir/wt" fm/t1
  fm_relaunch_worktree_owner ship "$dir/proj" "$dir/wt" fm/t1 \
    || fail "a worktree of the recorded project must resolve: $FM_RELAUNCH_WORKTREE_ERROR"
  assert_equals "$dir/proj" "$FM_RELAUNCH_WORKTREE_OWNER" "the recorded project owns its own worktree"
  pass "fm-relaunch-worktree-lib: the recorded project owns its own worktree unchanged"
}

test_owner_is_the_other_clone_only_on_the_task_branch() {
  local dir="$TMP_ROOT/foreign" other_real head before_refs
  make_clones "$dir"
  other_real=$(cd "$dir/other" && pwd -P)
  head=$(git -C "$dir/wt" rev-parse HEAD)
  before_refs=$(git -C "$dir/other" for-each-ref refs/heads; git -C "$dir/proj" for-each-ref refs/heads)

  fm_relaunch_worktree_owner ship "$dir/proj" "$dir/wt" fm/t1 \
    || fail "a same-repository clone's worktree on the task branch must resolve: $FM_RELAUNCH_WORKTREE_ERROR"
  assert_equals "$other_real" "$FM_RELAUNCH_WORKTREE_OWNER" "the clone that holds the worktree owns it"

  fm_relaunch_worktree_owner scout "$dir/proj" "$dir/wt" '' \
    || fail "a scout carries no branch, so only the repository is proven: $FM_RELAUNCH_WORKTREE_ERROR"

  if fm_relaunch_worktree_owner ship "$dir/proj" "$dir/wt" fm/other; then
    fail "a ship worktree off the task branch must refuse"
  fi
  assert_contains "$FM_RELAUNCH_WORKTREE_ERROR" "rather than the task's branch 'fm/other'" "the branch refusal names both branches"
  [ -z "$FM_RELAUNCH_WORKTREE_OWNER" ] || fail "a refusal must not leave an owner behind"

  git -C "$dir/other" remote remove origin
  if fm_relaunch_worktree_owner ship "$dir/proj" "$dir/wt" fm/t1; then
    fail "a clone with no origin cannot be proven to be the same repository"
  fi
  assert_contains "$FM_RELAUNCH_WORKTREE_ERROR" "has no origin" "the missing-origin refusal names the reason"

  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head" ] || fail "the check must never move the branch"
  git -C "$dir/other" remote add origin "$(git -C "$dir/proj" remote get-url origin)"
  [ "$(git -C "$dir/other" for-each-ref refs/heads; git -C "$dir/proj" for-each-ref refs/heads)" = "$before_refs" ] \
    || fail "the check must never write a ref in either clone"
  pass "fm-relaunch-worktree-lib: another clone owns the worktree only for one repository and the task branch"
}

test_origin_keys_compare_one_repository_across_spellings
test_local_origins_key_on_their_physical_location
test_github_fallback_refuses_when_github_cannot_answer
test_owner_is_the_project_for_its_own_worktree
test_owner_is_the_other_clone_only_on_the_task_branch
