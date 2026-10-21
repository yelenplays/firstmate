# shellcheck shell=bash
# Shared derivation of one home's attention board from stored state.
# Usage: . bin/fm-board-lib.sh   (sources fm-classify-lib.sh, fm-pr-lib.sh, and
# fm-post-merge-lib.sh from the same directory)
#
# The board answers "what needs me" for one home by reading only durable
# records, every time it is asked: the canonical backlog JSON
# (bin/fm-fleet-snapshot.sh --backlog-json), each task's state/<id>.meta, the
# open-decision fold, latest event, and latest lifecycle event (note:,
# resolved:, and captain-held: skipped) of its state/<id>.status log
# (bin/fm-classify-lib.sh), the merge poll's merged marker (bin/fm-pr-lib.sh),
# post-merge watch records (bin/fm-post-merge-lib.sh), and main-sync records
# (bin/fm-main-sync.sh). It keeps no state of its own, never probes a pane, and
# never calls the network, so a missed one-shot signal cannot hide work: a ship
# whose `done: PR <url>` line nobody relayed is still ready to approve on the
# next read.
#
# fm_board_home_json <state> <backlog-json-file> prints one fm-board-home.v1
# object: {schema, items[]}. Each item carries group, id, title, kind, repo,
# reason, detail, url, since, and at (event epoch or null). Groups, in the
# order they need the captain:
#   needs_you  a live captain hold, an open needs-decision or blocked event, a
#              failed task, a ready branch that conflicts with main, or a
#              post-merge watch that is reverting or blocked
#   ready      an unmerged ship with a recorded or reported PR and a latest
#              lifecycle event of done (or none), or a local-only ship with a
#              done one, unless an earlier rule above requires attention; a
#              later note or unrelated resolution keeps it ready
#   working    every other task with task metadata, including PR-less ship
#              handoffs and in-flight backlog rows missing their task record
#   queued     queued backlog work and non-live captain holds, with why
#   merged     merged, but the post-merge watch has not confirmed it yet
#   live       merged and confirmed live by a passing witness
#   done       landed without a live target, reported scouts, and closed rows
# A post-merge record binds to its task incarnation through spawn_gen; a record
# from an earlier incarnation of a reused id is ignored.

FM_BOARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_BOARD_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$FM_BOARD_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-post-merge-lib.sh
. "$FM_BOARD_LIB_DIR/fm-post-merge-lib.sh"

# Print the last value of <key> in a key=value record; empty when absent.
fm_board_record_get() {  # <record> <key>
  [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] || return 0
  fm_post_merge_record_get "$1" "$2"
}

# Print the first forge change URL in <text> that bin/fm-pr-lib.sh accepts.
fm_board_first_pr_url() {  # <text>
  local word
  for word in $1; do
    case "$word" in
      http://*|https://*)
        word=${word%%[),.;\"\']}
        if fm_pr_url_parse "$word" >/dev/null 2>&1; then
          printf '%s\n' "$word"
          return 0
        fi
        ;;
    esac
  done
  return 1
}

# 0 when the merge poll recorded <url> merged for task <id>.
fm_board_pr_merged() {  # <state> <id> <url>
  ( fm_pr_url_parse "$3" >/dev/null 2>&1 \
    && fm_pr_poll_merge_already_notified "$1" "$2" \
      "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" )
}

# One JSON object per line for every task record (state/<id>.meta) except
# secondmate seats, whose children come from their own home's board.
fm_board_task_facts() {  # <state>
  local state=$1 meta id kind mode spawn_gen pr pr_head status open last verb note at life life_verb life_note
  local wait reported_pr merged sync sync_result sync_head sync_detail
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    fm_pr_task_id_valid "$id" || continue
    kind=$(fm_board_record_get "$meta" kind)
    [ "$kind" != secondmate ] || continue
    mode=$(fm_board_record_get "$meta" mode)
    spawn_gen=$(fm_board_record_get "$meta" spawn_gen)
    pr=$(fm_board_record_get "$meta" pr)
    pr_head=$(fm_board_record_get "$meta" pr_head)
    status="$state/$id.status"
    open=$(status_open_decisions "$status" "${kind:-ship}")
    last=$(last_status_line "$status")
    verb=
    note=
    at=
    if [ -n "$last" ]; then
      status_line_verb "$last" verb
      status_line_note "$last" note
      at=$(status_line_at_epoch "$last" 2>/dev/null) || at=
    fi
    # Readiness follows the last lifecycle event, so a note after done keeps
    # the ship waiting for approval and its reported PR URL.
    life=$(last_lifecycle_status_line "$status")
    life_verb=
    life_note=
    if [ -n "$life" ]; then
      status_line_verb "$life" life_verb
      status_line_note "$life" life_note
    fi
    wait=$(status_declared_wait_line "$status")
    reported_pr=
    if [ "$life_verb" = "done" ]; then
      reported_pr=$(fm_board_first_pr_url "$life_note") || reported_pr=
    fi
    merged=false
    if [ -n "${pr:-$reported_pr}" ] && fm_board_pr_merged "$state" "$id" "${pr:-$reported_pr}"; then
      merged=true
    fi
    sync="$state/$id.main-sync"
    sync_result=$(fm_board_record_get "$sync" result)
    sync_head=$(fm_board_record_get "$sync" head)
    sync_detail=$(fm_board_record_get "$sync" detail)
    jq -cn --arg id "$id" --arg kind "${kind:-ship}" --arg mode "$mode" \
      --arg spawn_gen "$spawn_gen" --arg pr "$pr" --arg pr_head "$pr_head" \
      --arg open "$open" --arg verb "$verb" --arg note "$note" --arg at "$at" \
      --arg life_verb "$life_verb" --arg life_note "$life_note" \
      --arg wait "$wait" --arg reported_pr "$reported_pr" --argjson merged "$merged" \
      --arg sync_result "$sync_result" --arg sync_head "$sync_head" --arg sync_detail "$sync_detail" '
      def nonempty: if . == "" then null else . end;
      {id:$id,kind:$kind,mode:($mode | nonempty),spawn_gen:($spawn_gen | nonempty),
       pr:($pr | nonempty),pr_head:($pr_head | nonempty),
       open:[$open | split("\n")[] | select(length > 0) | split("\t")
             | {key:.[0],verb:.[1],summary:(.[2] // "")}],
       last:{verb:($verb | nonempty),note:($note | nonempty),
             at:(if ($at | test("^[0-9]+$")) then ($at | tonumber) else null end)},
       life:{verb:($life_verb | nonempty),note:($life_note | nonempty)},
       wait:($wait | nonempty),reported_pr:($reported_pr | nonempty),merged:$merged,
       sync:(if $sync_result == "" then null
             else {result:$sync_result,head:($sync_head | nonempty),detail:($sync_detail | nonempty)} end)}'
  done
}

# One JSON object per line for every post-merge watch record.
fm_board_post_merge_facts() {  # <state>
  local state=$1 record id
  for record in "$state"/*.post-merge; do
    [ -f "$record" ] && [ ! -L "$record" ] && [ -r "$record" ] || continue
    [ "$(fm_post_merge_record_get "$record" version)" = fm-post-merge-v1 ] || continue
    id=$(fm_post_merge_record_get "$record" task)
    fm_pr_task_id_valid "$id" || continue
    jq -cn --arg id "$id" \
      --arg spawn_gen "$(fm_post_merge_record_get "$record" spawn_gen)" \
      --arg phase "$(fm_post_merge_record_get "$record" phase)" \
      --arg pr "$(fm_post_merge_record_get "$record" pr)" \
      --arg witness "$(fm_post_merge_record_get "$record" witness)" \
      --arg verdict "$(fm_post_merge_record_get "$record" witness_verdict)" \
      --arg merged_at "$(fm_post_merge_record_get "$record" merged_at)" '
      def nonempty: if . == "" then null else . end;
      {id:$id,spawn_gen:($spawn_gen | nonempty),phase:($phase | nonempty),pr:($pr | nonempty),
       witness:($witness | nonempty),witness_verdict:($verdict | nonempty),
       merged_at:(if ($merged_at | test("^[0-9]+$")) then ($merged_at | tonumber) else null end)}'
  done
}

# The grouping rules, applied to the backlog, task facts, and post-merge facts.
# shellcheck disable=SC2016  # jq program text: $row, $pm, and friends are jq variables.
FM_BOARD_JQ_DEFS='
  def trunc($n): tostring | gsub("\\s+"; " ") | if length > $n then .[:$n] + "…" else . end;
  def opt_trunc($n): if . == null then null else trunc($n) end;
  def pm_group:
    if .phase == "clear" then (if .witness_verdict == "pass" then "live" else "done" end)
    elif .phase == "checks" or .phase == "witness" then "merged"
    elif .phase == "reverting" or .phase == "blocked" then "needs_you"
    elif .phase == "reverted" then "queued"
    else "done" end;
  def pm_detail:
    if .phase == "clear" and .witness_verdict == "pass" then "live confirmed against " + (.witness // "its production URL")
    elif .phase == "clear" then "merged; checks green on the default branch, no live target"
    elif .phase == "checks" then "merged; checks on the default branch pending"
    elif .phase == "witness" then "merged; live check pending against " + (.witness // "its production URL")
    elif .phase == "reverting" then "merge found broken; revert under way"
    elif .phase == "blocked" then "post-merge watch blocked; needs review"
    elif .phase == "reverted" then "merge reverted; returned to the queue"
    else "post-merge watch " + (.phase // "unknown") end;
  def ready_url: .pr // .reported_pr;
  def task_item($row; $pm):
    ($row.title // .id) as $title
    | {id, title:($title | trunc(90)), kind, repo:($row.repo // null), since:($row.since // null),
       at:.last.at, url:ready_url, reason:null, detail:null}
    + (if $pm != null then
         {group:($pm | pm_group), reason:("post-merge " + ($pm.phase // "unknown")),
          detail:($pm | pm_detail), url:($pm.pr // ready_url)}
       elif $row != null and $row.captain_actionable == true then
         {group:"needs_you", reason:"decision", detail:(($row.hold_reason // "waiting for the captain") | trunc(160))}
       elif (.open | length) > 0 then
         (.open[-1]) as $o
         | {group:"needs_you", reason:$o.verb, detail:(($o.summary // "") | trunc(160))}
       elif .life.verb == "failed" then
         {group:"needs_you", reason:"failed", detail:((.life.note // "") | trunc(160))}
       elif .merged then
         {group:"merged", reason:"merged", detail:"merged; landing not confirmed yet"}
       elif .kind == "ship" and ready_url != null and (.life.verb == "done" or .life.verb == null) then
         (if .sync != null and .sync.result == "conflict" and (.sync.head == null or .sync.head == .pr_head) then
            {group:"needs_you", reason:"conflict",
             detail:(("ready, but conflicts with main" + (if .sync.detail then ": " + .sync.detail else "" end)) | trunc(160))}
          else
            {group:"ready", reason:"approval",
             detail:(if .sync != null and .sync.result == "synced" then "waiting for approval; kept current with main"
                     else "waiting for approval" end)}
          end)
       elif .kind == "ship" and .mode == "local-only" and .life.verb == "done" then
         {group:"ready", reason:"approval", detail:"local ready branch waiting for approval"}
       elif .life.verb == "done" and .kind == "ship" then
         {group:"working", reason:"handoff", detail:(("finished; landing step not started: " + (.life.note // "")) | trunc(160))}
       elif .life.verb == "done" then
         {group:"done", reason:"reported", detail:((.life.note // "finished") | trunc(160))}
       else
         {group:"working", reason:(.last.verb // "working"),
          detail:((.wait // (if .last.verb then (.last.note // "") else "no status yet" end)) | trunc(160))}
       end);
  def queued_item:
    {group:(if .captain_actionable == true then "needs_you" else "queued" end),
     id, title:((.title // .id) | trunc(90)), kind:(.kind // null), repo:(.repo // null),
     since:(.since // null), at:null, url:(.pr_url // null),
     reason:(if .captain_actionable == true then "decision"
             elif (.unresolved_blocker_ids // [] | length) > 0 then "blocked-by"
             elif .hold_kind != null then (.hold_kind)
             else "queued" end),
     detail:(if .captain_actionable == true then ((.hold_reason // "waiting for the captain") | trunc(160))
             elif (.unresolved_blocker_ids // [] | length) > 0 then "after " + (.unresolved_blocker_ids | join(", "))
             elif .hold_reason != null then (.hold_reason | trunc(160)) + (if .hold_until then " (until " + .hold_until + ")" else "" end)
             else null end)};
  def done_item($pm):
    {group:(if $pm != null then ($pm | pm_group) else "done" end),
     id, title:((.title // .id) | trunc(90)), kind:(.kind // null), repo:(.repo // null),
     since:(.completion.date // .since // null), at:null,
     url:(if $pm != null then ($pm.pr // .pr_url) else (.pr_url // .report_path // null) end),
     reason:(if $pm != null then "post-merge " + ($pm.phase // "unknown") else (.completion.verb // "done") end),
     detail:(if $pm != null then ($pm | pm_detail)
             else ((.local_note // .report_path // .pr_url // "closed") | trunc(160)) end)};
'

fm_board_home_json() {  # <state> <backlog-json-file>
  local state=$1 backlog=$2 tmp rc=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-board.XXXXXX") || return 1
  fm_board_task_facts "$state" > "$tmp/tasks.jsonl" || rc=1
  fm_board_post_merge_facts "$state" > "$tmp/post-merge.jsonl" || rc=1
  if [ "$rc" -eq 0 ]; then
    jq -n --slurpfile backlog "$backlog" --slurpfile tasks "$tmp/tasks.jsonl" \
      --slurpfile pms "$tmp/post-merge.jsonl" "$FM_BOARD_JQ_DEFS"'
      ($backlog[0].records // [] | map(select(.structured == true))) as $rows
      | def row($id): first($rows[] | select(.id == $id)) // null;
      def pm_for($id; $gen): first($pms[] | select(.id == $id and ($gen == null or .spawn_gen == $gen))) // null;
      ($tasks | map(.id)) as $task_ids
      | {schema:"fm-board-home.v1",
         items:(
           [ $tasks[] | . as $t | task_item(row($t.id); pm_for($t.id; $t.spawn_gen)) ]
           + [ $rows[] | select(.state == "in_flight" and ((.id as $id | $task_ids | index($id)) | not))
               | if .captain_actionable == true or .hold_kind != null then queued_item
                 else queued_item + {group:"working", reason:"no-record",
                   detail:"in flight with no task record"} end ]
           + [ $rows[] | select(.state == "queued") | queued_item ]
           + [ $rows[] | select(.state == "done") | . as $r | done_item(pm_for($r.id; null)) ])}' || rc=1
  fi
  rm -rf -- "$tmp"
  return "$rc"
}
