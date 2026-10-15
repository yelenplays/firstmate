#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/environment.sh"
fm_test_sanitize_environment
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the OPEN
# DECISIONS section bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path). The section is pure wiring around
# fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
# open/resolved statement); these tests exercise the real drain script over
# crafted status logs and assert on its printed output, not on the fold's own
# source text.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
GRANT="$ROOT/bin/fm-wake-grant.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-tests)

test_buried_decision_still_surfaces() {
  local dir state out
  dir=$(make_case buried)
  state="$dir/state"
  out="$dir/drain.out"
  # The needs-decision line sits under later routine and unrelated-key lines,
  # exactly the burial scenario the fix targets: last-line-only reads would
  # show "resolved [key=other]" and hide the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"
  printf 'working: continuing other work\n' >> "$state/task1.status"
  printf 'resolved [key=other]: unrelated decision closed\n' >> "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried decision"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null || fail "buried decision produced no OPEN DECISIONS section"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "buried needs-decision was not surfaced with its task, key, and note"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "open section is missing the answerer-closes hint"
  pass "a needs-decision buried under later routine/other-key lines still reports as open"
}

test_explicit_resolution_closes_it() {
  local dir state out
  dir=$(make_case resolved)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task2.status"
  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task2.status"
  printf 'done: shipped\n' >> "$state/task2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an explicit resolution"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  pass "an explicit resolved [key=X] closes the keyed decision"
}

test_reserved_key_namespace_is_owned_by_its_library() {
  local dir state out
  dir=$(make_case reserved-key)
  state="$dir/state"
  out="$dir/drain.out"
  # `pending-reply-<id>` names a decision bin/fm-pending-reply-lib.sh raises and
  # is the only writer that closes it. Every writer reaches this same stream - a
  # local mate appends into it directly, and a remote mate's lines are mirrored
  # into it verbatim - so another writer must not be able to take that key over
  # or clear it just by naming it.
  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\n' > "$state/task9.status"
  printf 'blocked [key=pending-reply-abcdef0123456789]: shipping is blocked on infra\n' >> "$state/task9.status"
  printf 'resolved [key=pending-reply-abcdef0123456789]: all good now\n' >> "$state/task9.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on reserved-key lines"

  grep -F 'pending-reply-id=abcdef0123456789' "$out" >/dev/null \
    || fail "a foreign resolution cleared a reserved decision it does not own: $(cat "$out")"
  if grep -F 'shipping is blocked on infra' "$out" >/dev/null; then
    fail "a foreign line took over a reserved decision key: $(cat "$out")"
  fi

  # The owner's own resolution, which speaks that namespace's vocabulary, closes it.
  printf 'resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=ios pending-reply-id=abcdef0123456789 via=status\n' >> "$state/task9.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the owner closed its decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the owner's own resolution did not close its reserved decision: $(cat "$out")"
  fi
  pass "a reserved decision key can only be opened or closed by its owning library"
}

test_later_unrelated_terminal_line_does_not_close_it() {
  local dir state out
  dir=$(make_case unrelated-terminal)
  state="$dir/state"
  out="$dir/drain.out"
  # A later done: with no matching [key=...] token opens/closes only the
  # "default" key; it must never clear the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task3.status"
  printf 'done: unrelated later milestone\n' >> "$state/task3.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unrelated terminal line"

  grep -F 'task3' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "a later unrelated terminal line incorrectly cleared the open decision"
  pass "a later unrelated terminal line never clears an open decision"
}

test_no_open_decisions_prints_nothing() {
  local dir state out
  dir=$(make_case none-open)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task4.status"
  printf 'resolved: shipped clean\n' > "$state/task5.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with no open decisions"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the empty case printed an OPEN DECISIONS section: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty case with no queued wakes was not silent: $(cat "$out")"
  pass "no open decisions across the fleet prints nothing"
}

test_open_decision_surfaces_even_with_an_unrelated_queued_wake() {
  local dir state out
  dir=$(make_case fleet-wide)
  state="$dir/state"
  out="$dir/drain.out"
  # task6 has a buried, still-open decision but generates NO new queue record
  # this turn; task7 is what actually wakes the drain. The fleet-wide scan
  # must still catch task6's decision alongside task7's own raw row.
  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$state/task6.status"
  printf 'working: continuing\n' >> "$state/task6.status"
  printf 'blocked: waiting on credentials\n' > "$state/task7.status"
  append_wake "$state" signal task7.status "blocked: waiting on credentials" \
    || fail "queueing the unrelated wake failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a mixed fleet"

  grep "$(printf '\tsignal\ttask7.status\t')" "$out" >/dev/null || fail "task7's own raw row is missing"
  grep -F 'task6' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "task6's buried decision was not surfaced even though only task7 queued a wake"
  pass "the open-decision section is fleet-wide, not scoped to this drain's own queued records"
}

test_buried_decision_surfaces_on_the_empty_queue_fast_path() {
  local dir state out
  dir=$(make_case empty-queue-fast-path)
  state="$dir/state"
  out="$dir/drain.out"
  # No wake is queued at all (the empty-queue exit), but the decision is still
  # open on disk - session-start relies on exactly this path.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task8.status"
  printf 'working: continuing\n' >> "$state/task8.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

  grep -F 'task8' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "the empty-queue fast path did not surface a still-open decision"
  pass "a buried open decision surfaces even when the wake queue itself is empty"
}

test_status_symlink_is_not_followed() {
  local dir state out
  dir=$(make_case status-symlink)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/outside"
  printf 'needs-decision [key=local]: keep this visible\n' > "$state/local.status"
  printf 'needs-decision [key=foreign]: do not expose this\n' > "$dir/outside/foreign.status"
  ln -s ../outside/foreign.status "$state/linked.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a symlinked status file"

  grep -F 'local [key=local] needs-decision: keep this visible' "$out" >/dev/null \
    || fail "the valid local decision did not surface alongside a rejected status symlink"
  if grep -F 'do not expose this' "$out" >/dev/null; then
    fail "the fleet scan followed a status symlink outside the state directory"
  fi
  pass "the fleet-wide decision scan does not follow status symlinks"
}

# The per-item cut now comes from bin/fm-line-cap-lib.sh, shared with the
# session-start digest's status tails so one truncation marker means the same
# thing wherever an agent meets it. This pins the drain's own end of that
# contract: the lede survives, the marker appears, and the item still fits the
# section's per-item budget including the newline it is charged for.
test_over_long_decision_note_is_capped_with_a_marker() {
  local dir state out line longest
  dir=$(make_case long-note)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=api-shape]: pick REST or RPC'
    awk 'BEGIN { while (i++ < 200) printf " and-then-some" }'
    printf '\n'
  } > "$state/task-long.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an over-long decision note"

  line=$(grep -F 'task-long' "$out")
  case "$line" in
    'task-long [key=api-shape] needs-decision: pick REST or RPC'*' [truncated]') : ;;
    *) fail "an over-long decision note was not capped with its lede intact: $line" ;;
  esac
  longest=${#line}
  [ "$longest" -le 219 ] || fail "a capped decision item ran $longest characters past its per-item budget"

  printf 'needs-decision [key=short]: brief enough to keep whole\n' > "$state/task-short.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a short decision note"
  grep -F 'task-short [key=short] needs-decision: brief enough to keep whole' "$out" >/dev/null \
    || fail "a decision note already under the cap was altered"
  if grep -F 'brief enough to keep whole [truncated]' "$out" >/dev/null; then
    fail "a decision note already under the cap was marked truncated"
  fi

  pass "an over-long open decision is cut to its per-item budget with the shared truncation marker"
}

test_repeat_drain_shows_count_and_only_new_or_changed_keys() {
  local dir state out
  dir=$(make_case repeat-presentation)
  state="$dir/state"
  out="$dir/drain.out"
  # Retro 2026-10-14 point 2: every wake re-printed every still-open decision,
  # mostly old and already known. The first presentation lists them; a later
  # drain with nothing new prints the count alone and points at --decisions.
  printf 'needs-decision [key=old-a]: an old known decision\n' > "$state/task-a.status"
  printf 'needs-decision [key=old-b]: another old known decision\n' > "$state/task-b.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "first drain failed"
  grep -F 'task-a [key=old-a] needs-decision: an old known decision' "$out" >/dev/null \
    || fail "the first presentation did not list a decision: $(cat "$out")"
  grep -F 'task-b [key=old-b]' "$out" >/dev/null || fail "the first presentation dropped a decision"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "repeat drain failed"
  if grep -F '[key=old-a]' "$out" >/dev/null || grep -F '[key=old-b]' "$out" >/dev/null; then
    fail "a repeat drain re-listed already presented, unchanged decisions: $(cat "$out")"
  fi
  grep -F 'OPEN DECISIONS: 2 still open, none new or changed since the last presentation' "$out" >/dev/null \
    || fail "a repeat drain did not report the open count: $(cat "$out")"
  grep -F 'bin/fm-wake-drain.sh --decisions' "$out" >/dev/null \
    || fail "the count line does not name the full-list flag: $(cat "$out")"

  # A new key and a changed note on a known key both count as news.
  printf 'needs-decision [key=new-c]: a brand new decision\n' > "$state/task-c.status"
  printf 'needs-decision [key=old-a]: the old decision, re-asked differently\n' >> "$state/task-a.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain after news failed"
  grep -F 'OPEN DECISIONS (3 still open; 2 new or changed since the last presentation' "$out" >/dev/null \
    || fail "the header did not carry the open and new counts: $(cat "$out")"
  grep -F 'task-c [key=new-c] needs-decision: a brand new decision' "$out" >/dev/null \
    || fail "a new key was not listed: $(cat "$out")"
  grep -F 'task-a [key=old-a] needs-decision: the old decision, re-asked differently' "$out" >/dev/null \
    || fail "a changed note on a known key was not listed: $(cat "$out")"
  if grep -F '[key=old-b]' "$out" >/dev/null; then
    fail "an unchanged known decision was re-listed beside the news: $(cat "$out")"
  fi
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "listed news lost the answerer-closes hint"

  # The explicit flag lists every open decision, including the known ones.
  FM_STATE_OVERRIDE="$state" "$DRAIN" --decisions > "$out" || fail "drain --decisions failed"
  for key in old-a old-b new-c; do
    grep -F "[key=$key]" "$out" >/dev/null || fail "--decisions omitted $key: $(cat "$out")"
  done

  # A decision that closes and later re-opens with the same words is news again.
  printf 'resolved [key=old-b]: settled\n' >> "$state/task-b.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain after a resolution failed"
  grep -F 'OPEN DECISIONS: 2 still open' "$out" >/dev/null || fail "a resolution did not lower the count: $(cat "$out")"
  printf 'needs-decision [key=old-b]: another old known decision\n' >> "$state/task-b.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain after a re-open failed"
  grep -F 'task-b [key=old-b] needs-decision: another old known decision' "$out" >/dev/null \
    || fail "a re-opened decision was treated as already known: $(cat "$out")"
  pass "a repeat drain prints the open count plus only new or changed keys; --decisions lists all"
}

test_wake_triage_passes_the_full_list_flag_through() {
  local dir state out
  dir=$(make_case triage-decisions-flag)
  state="$dir/state"
  out="$dir/triage.out"
  printf 'needs-decision [key=known]: a known decision\n' > "$state/task-t.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > /dev/null || fail "seed drain failed"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-triage.sh" > "$out" || fail "triage failed"
  if grep -F '[key=known]' "$out" >/dev/null; then
    fail "default triage re-listed a known decision: $(cat "$out")"
  fi
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-triage.sh" --decisions > "$out" || fail "triage --decisions failed"
  grep -F 'task-t [key=known] needs-decision: a known decision' "$out" >/dev/null \
    || fail "triage --decisions did not list the full set: $(cat "$out")"
  pass "fm-wake-triage.sh --decisions passes the full-list flag through to the drain"
}

# The known-decision ledger is main's: a branch drain that presents a decision
# must not let main's next default drain reduce it to a count main never saw
# the text behind.
test_branch_drain_leaves_the_decision_unknown_to_main() {
  local dir state out
  dir=$(make_case branch-then-main)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=merge]: merge PR 9 now or hold?\n' > "$state/task-x.status"
  append_wake "$state" signal task-x.status 'signal: task-x.status' \
    || fail "could not queue the branch-owned status signal"
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" open-decisions-branch \
    || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish open-decisions-branch 1 \
    || fail "branch grant publication failed"

  for round in 1 2; do
    FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$out" 2>/dev/null \
      || fail "branch drain $round failed"
    grep -F 'task-x [key=merge] needs-decision: merge PR 9 now or hold?' "$out" >/dev/null \
      || fail "branch drain $round did not list the open decision: $(cat "$out")"
  done

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null || fail "main drain failed"
  grep -F 'task-x [key=merge] needs-decision: merge PR 9 now or hold?' "$out" >/dev/null \
    || fail "main's drain only counted a decision just the branch was shown: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null || fail "repeat main drain failed"
  grep -F 'OPEN DECISIONS: 1 still open, none new or changed since the last presentation' "$out" >/dev/null \
    || fail "main's repeat drain re-listed a decision main was already shown: $(cat "$out")"
  pass "a branch drain lists every open decision and leaves main's known-decision ledger alone"
}

test_buried_decision_still_surfaces
test_over_long_decision_note_is_capped_with_a_marker
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed
test_repeat_drain_shows_count_and_only_new_or_changed_keys
test_wake_triage_passes_the_full_list_flag_through
test_branch_drain_leaves_the_decision_unknown_to_main
