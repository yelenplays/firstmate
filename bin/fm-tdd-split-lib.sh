# shellcheck shell=bash
# fm-tdd-split-lib.sh - single owner of the tdd-split ship profile: an
# allowlisted test seat writes failing tests first, then the same task is
# relaunched onto the cheap implementer its dispatch rule resolved, which may
# not change those tests.
# Sourced by bin/fm-dod-lib.sh, so every ship done: gate and bin/fm-spawn.sh
# see it; it uses that library's test-authoring helpers and
# bin/fm-classify-lib.sh's status-line readers at call time.
#
# The profile, end to end:
#   1. `bin/fm-spawn.sh <id> <project> --mode ... --harness <h> --model <m>
#      --effort <e> --tdd-split` launches a fresh ship whose --harness, --model,
#      and --effort name the IMPLEMENTER, the profile the dispatch rule resolved.
#      Its model must be outside the test-author allowlist, and the brief must
#      declare the fail-to-pass command (fm_tdd_split_check_command). The spawn
#      launches the test seat FM_TDD_SPLIT_SEAT_* instead, records
#      tdd_split=tests, tdd_split_impl_harness=, tdd_split_impl_model=, and
#      tdd_split_impl_effort= in state/<id>.meta, and appends
#      fm_tdd_split_seat_overlay to the launch brief.
#   2. The seat commits tests only and reports `done: tests-ready <sha>`.
#      fm_tdd_split_accept_done requires a tests-ready note and a clean worker
#      copy whose first-seat net diff against the merge-base changes at least
#      one file and only test paths (fm_tdd_split_seat_path_ok); step 5 covers
#      a returned seat. The gate checks the
#      current HEAD, not the optional SHA text in the note.
#   3. Firstmate runs `bin/fm-tdd-split.sh handoff <id>` on that report. It
#      re-checks step 2 and verifies the branch's tests fail without the
#      implementation before relaunching onto the recorded implementer and
#      recording tdd_split=implement. That script's header owns the isolated
#      red-run procedure and its limits, including after a return to the seat.
#   4. The handoff records test_ban_since=<seat HEAD>. From here the task is an
#      ordinary banned ship on the implementer; bin/fm-dod-lib.sh's
#      test-authoring block owns lock enforcement and its scope, including
#      after an allowlisted takeover.
#   5. Two ways lead back to the seat, both through bin/fm-tdd-split.sh. The
#      implementer that finds a handed-over test wrong reports
#      `blocked [key=test-dispute]: <test>: <reason>`; firstmate either answers
#      it with bin/fm-send.sh --resolve-key or accepts it with `dispute <id>`.
#      A brief that declares the optional mutation command
#      (fm_tdd_split_mutation_command) gets `mutation <id>` on the
#      implementer's done:, which runs it and on surviving mutants sends the
#      task back the same way. Either route records tdd_split=tests and
#      tdd_split_dispute_head=<implementer HEAD> and relaunches the seat, which
#      from that head may again change tests only, and then hands over again
#      from step 3.
#
# Supported boundary: this profile automates test-seat launch, handoff, and
# the routes back to the seat. Model escalation after failed rounds belongs to
# bin/fm-escalate.sh, and the task's selected delivery path owns validation
# afterward. The test lock is completion/pre-PR enforcement under
# fm-dod-lib.sh, not a filesystem write restriction. tests/fm-tdd-split.test.sh,
# tests/fm-control-relaunch.test.sh, and tests/fm-pr-check-security.test.sh
# cover the handoff and lock boundaries.

# The test seat: Opus at medium effort on Claude Code.
# shellcheck disable=SC2034 # read by bin/fm-spawn.sh and bin/fm-tdd-split.sh.
FM_TDD_SPLIT_SEAT_HARNESS=claude
FM_TDD_SPLIT_SEAT_MODEL=claude-opus-5-5
FM_TDD_SPLIT_SEAT_EFFORT=medium
FM_TDD_SPLIT_CHECK_LABEL='Fail-to-pass command:'
FM_TDD_SPLIT_MUTATION_LABEL='Mutation command:'
FM_TDD_SPLIT_DISPUTE_KEY=test-dispute
FM_TDD_SPLIT_READY_VERB=tests-ready

# The fail-to-pass command a brief declares on exactly one line of its own,
# outside fenced blocks, as `Fail-to-pass command: `<command>``. Firstmate
# writes it, never the worker. bin/fm-tdd-split.sh's header owns the execution
# environment and test-file arguments. Prints the command; 1 when the brief
# declares none, more than one, or one that is not a single code span.
fm_tdd_split_check_command() {  # <brief>
  fm_tdd_split_brief_command "${1:-}" "$FM_TDD_SPLIT_CHECK_LABEL"
}

# The optional mutation command a brief declares the same way, as
# `Mutation command: `<command>``: a project's mutation-testing run, such as
# mutmut, Stryker, or cargo-mutants, that exits non-zero when too many mutants
# survive the tests. 1 when the brief declares none, more than one, or one that
# is not a single code span.
fm_tdd_split_mutation_command() {  # <brief>
  fm_tdd_split_brief_command "${1:-}" "$FM_TDD_SPLIT_MUTATION_LABEL"
}

# The one `<label> `<command>`` line of a brief, outside fenced blocks.
fm_tdd_split_brief_command() {  # <brief> <label>
  local lines
  [ -f "${1:-}" ] || return 1
  lines=$(awk -v label="$2" '
    /^[ \t]*(```|~~~)/ { fenced = !fenced; next }
    fenced { next }
    index($0, label) == 1 {
      rest = substr($0, length(label) + 1)
      sub(/^[ \t]+/, "", rest); sub(/[ \t]+$/, "", rest)
      if (rest ~ /^`[^`]+`$/) print substr(rest, 2, length(rest) - 2)
      else print "\001"
    }
  ' "$1")
  [ -n "$lines" ] && [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" = 1 ] || return 1
  case "$lines" in *$'\001'*) return 1 ;; esac
  printf '%s\n' "$lines"
}

# 0 when <path> may change on the test seat: a test file under the ban's
# heuristic, or an end-to-end test the ban spares.
fm_tdd_split_seat_path_ok() {  # <path>
  local lower
  fm_test_ban_path_is_test "$1" && return 0
  lower=$(printf '%s' "/$1" | tr '[:upper:]' '[:lower:]')
  case "$lower" in *e2e*|*end-to-end*|*end_to_end*) return 0 ;; esac
  return 1
}

# Prints the files the worker copy's commits change since their merge-base
# with the base, or since <since> when given, one per line. 1 with a one-line
# reason on stdout when the base or <since> cannot be resolved.
fm_tdd_split_changed_files() {  # <worktree> [<base-branch>] [<since>]
  local wt=$1 base_ref mb
  if [ -n "${3:-}" ]; then
    git -C "$wt" rev-parse --verify --quiet "$3^{commit}" >/dev/null 2>&1 || {
      printf '%s\n' "tdd-split check cannot find the disputed head $3 in the worker copy"
      return 1
    }
    git -C "$wt" diff --no-renames --name-only "$3" HEAD 2>/dev/null
    return 0
  fi
  if ! base_ref=$(fm_test_ban_base_ref "$wt" "${2:-}"); then
    printf '%s\n' "tdd-split check cannot resolve the base branch${2:+ origin/$2} in the worker copy"
    return 1
  fi
  if ! mb=$(git -C "$wt" merge-base "$base_ref" HEAD 2>/dev/null); then
    printf '%s\n' "tdd-split check found no merge-base between HEAD and $base_ref"
    return 1
  fi
  git -C "$wt" diff --no-renames --name-only "$mb" HEAD 2>/dev/null
}

# 0 when the test seat's worker copy can be handed over: clean, and its commits
# since the base change at least one file and only test files. A seat sent back
# by a dispute or the mutation gate is measured from tdd_split_dispute_head=
# instead, and may hand over unchanged when it finds the tests right. 1 with a
# one-line reason on stdout otherwise; nothing on stdout on success.
fm_tdd_split_seat_ready() {  # <worktree> <meta>
  local wt=$1 meta=$2 files path since others=
  if [ -z "$wt" ] || [ ! -d "$wt" ] || ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    printf '%s\n' "tdd-split check cannot read the worker copy"
    return 1
  fi
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    printf '%s\n' "tdd-split test seat has uncommitted changes; commit the tests and report $FM_TDD_SPLIT_READY_VERB again"
    return 1
  fi
  since=$(fm_dod_meta_value "$meta" tdd_split_dispute_head)
  files=$(fm_tdd_split_changed_files "$wt" "$(fm_dod_meta_value "$meta" base_branch)" "$since") || {
    printf '%s\n' "$files"
    return 1
  }
  [ -n "$files" ] || [ -n "$since" ] || {
    printf '%s\n' "tdd-split test seat committed no tests since the base"
    return 1
  }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    fm_tdd_split_seat_path_ok "$path" || others="$others $path"
  done <<<"$files"
  [ -z "$others" ] || {
    printf '%s\n' "tdd-split test seat changed files that are not tests${since:+ since $since}:$others; the seat writes tests only, so revert those changes and report $FM_TDD_SPLIT_READY_VERB again"
    return 1
  }
  return 0
}

# 0 when <meta> is a task record on its tdd-split test seat.
fm_tdd_split_on_seat() {  # <meta>
  [ -n "${1:-}" ] && [ -f "$1" ] && [ "$(fm_dod_meta_value "$1" tdd_split)" = tests ]
}

# The done gate for a ship whose meta records tdd_split=tests. 0 when the gate
# does not apply or passes; 1 with a one-line reason on stdout when refused.
fm_tdd_split_accept_done() {  # <kind> <worktree> <line> <meta>
  local kind=$1 wt=$2 line=$3 meta=$4 note
  [ "$kind" = ship ] || return 0
  fm_tdd_split_on_seat "$meta" || return 0
  [ "$(status_line_verb "$line")" = "done" ] || return 0
  note=$(status_line_note "$line")
  case "$note" in
    "$FM_TDD_SPLIT_READY_VERB"|"$FM_TDD_SPLIT_READY_VERB "*) ;;
    *)
      printf '%s\n' "tdd-split test seat: report \`done: $FM_TDD_SPLIT_READY_VERB <sha>\` once the failing tests are committed; implementing and shipping belong to the implementer seat"
      return 1 ;;
  esac
  fm_tdd_split_seat_ready "$wt" "$meta"
}

# The launch section the test seat receives. <command> is the brief's
# fail-to-pass command; <impl-model> names the implementer that takes over.
fm_tdd_split_seat_overlay() {  # <command> <impl-model>
  cat <<SECTION

# Tests-first seat (tdd-split)
This worker is the test seat of a tdd-split ship; this section supersedes any instruction in this brief, a promotion, or the project's own files that asks you to implement, validate, push, or ship the change, including its Definition of done.
From the brief's intent and the existing code's interfaces, write the tests that pin the required behavior: acceptance tests for new behavior and a reproducing test for a bug.
Change no file that is not a test: no production code, documentation, or configuration.
Each test must fail on the current code because the required behavior is missing, and pass once the change is implemented as specified.
Before the handover firstmate runs \`$1\` from the root of a clean clone of your HEAD, with the test files you changed as its arguments, and refuses the handover unless that command exits non-zero.
Run the same command yourself first; a test that fails only because it cannot run, such as a syntax error or a missing helper, does not count as failing.
Commit the tests, report \`done: $FM_TDD_SPLIT_READY_VERB <sha>\` naming your HEAD, and stop; do not run no-mistakes, push, or open a PR.
After the handover the task continues on $2, which must make your tests pass and cannot change them.
SECTION
}
