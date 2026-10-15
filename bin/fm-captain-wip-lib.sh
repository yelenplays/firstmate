#!/usr/bin/env bash
# fm-captain-wip-lib.sh - the captain's WIP limit and the live-call count it is
# measured against. Sourced, never executed: bin/fm-captain-hold.sh applies it
# as the brake on `hold`, and bin/fm-bearings-board.sh shows Captain's Call
# against it.
#
# At most FM_CAPTAIN_WIP_LIMIT things may wait on the captain at once -
# decisions, PRs to approve, credentials - and every one of them is a task held
# for the captain. Running workers never count. The captain fixed the limit at
# 3, so it is a constant here rather than configuration.
#
# A call counts while it is live: the canonical hold_bucket classification in
# bin/fm-fleet-snapshot.sh, which is also what puts a hold on the board's
# Captain's Call, so a hold deferred with --until, blocked by unfinished work,
# or aged out of the default view never counts. The count reads one home's
# markdown backlog through that same parser (`--backlog-json`); the fleet-wide
# picture across homes is the board's, built from the bearings snapshot.

FM_CAPTAIN_WIP_LIMIT=3

# Print `<task-id><TAB><title>` for every live captain call in <backlog-file>,
# in backlog order, leaving out <exclude-id> when given. An absent backlog
# prints nothing. Returns nonzero only when the backlog cannot be parsed.
fm_captain_live_calls() {  # <fleet-snapshot-script> <backlog-file> [<exclude-id>]
  local snapshot=$1 backlog=$2 exclude=${3-} json
  json=$("$snapshot" --backlog-json "$backlog" 2>/dev/null) || return 1
  jq -r --arg exclude "$exclude" '
    .records[]
    | select(.hold_bucket == "live" and .id != $exclude)
    | [.id, (.title // .id)] | @tsv
  ' <<< "$json"
}
