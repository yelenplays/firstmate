#!/usr/bin/env bash
# Shared fixtures for the pre-commit token cap tests.
#
# Owners: tests/fm-precommit-token-cap-rule.test.sh (cap-rule mechanics) and
# tests/fm-precommit-token-cap-exemptions.test.sh (skip exemptions). This file
# is not a test; it wires the production script the same way a contributor
# runs it: fixture repos get the tracked bin script and .githooks/pre-commit
# copied in, `git config core.hooksPath .githooks` is set, and every pass/fail
# verdict comes from a real commit. Oversized seeds land via --no-verify, the
# same one-off a maintainer would need.
set -u

# A fleet pane carries GIT_CONFIG core.hooksPath; drop it so fixtures resolve
# their own hooksPath from config instead of the pane's.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-precommit-token-cap.sh"
WRAPPER="$ROOT/.githooks/pre-commit"

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
