#!/usr/bin/env bash
export FM_ROOT_OVERRIDE="/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5DAWCT0WRXAZY0TJ3N80XYQ/.ci-debug/tmp/fm-pr-check-security.L9gXGF/merge-authority-retirement-replacement/root" FM_TEST_GUARD_LOG="/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5DAWCT0WRXAZY0TJ3N80XYQ/.ci-debug/tmp/fm-pr-check-security.L9gXGF/merge-authority-retirement-replacement/guard.log"
"/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5DAWCT0WRXAZY0TJ3N80XYQ/bin/fm-pr-check.sh" task-a "https://github.com/o/r/pull/2" >/dev/null
# This test isolates poll-replacement authority from the separate post-merge
# handoff; retire the queued fixture's marker before simulating another merge.
awk '!/^post_merge_watch_required=/' "/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5DAWCT0WRXAZY0TJ3N80XYQ/.ci-debug/tmp/fm-pr-check-security.L9gXGF/merge-authority-retirement-replacement/home/state/task-a.meta" > "/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5DAWCT0WRXAZY0TJ3N80XYQ/.ci-debug/tmp/fm-pr-check-security.L9gXGF/merge-authority-retirement-replacement/home/state/task-a.meta.next"
mv "/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5DAWCT0WRXAZY0TJ3N80XYQ/.ci-debug/tmp/fm-pr-check-security.L9gXGF/merge-authority-retirement-replacement/home/state/task-a.meta.next" "/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5DAWCT0WRXAZY0TJ3N80XYQ/.ci-debug/tmp/fm-pr-check-security.L9gXGF/merge-authority-retirement-replacement/home/state/task-a.meta"
(
  FM_TEST_GH_GRAPHQL_STATE=OPEN FM_TEST_GH_GRAPHQL_MERGED=false \
  FM_TEST_GH_GRAPHQL_QUEUED=true \
  "/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5DAWCT0WRXAZY0TJ3N80XYQ/bin/fm-pr-merge.sh" task-a "https://github.com/o/r/pull/2" > "/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5DAWCT0WRXAZY0TJ3N80XYQ/.ci-debug/tmp/fm-pr-check-security.L9gXGF/merge-authority-retirement-replacement/replacement-merge.out" 2> "/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5DAWCT0WRXAZY0TJ3N80XYQ/.ci-debug/tmp/fm-pr-check-security.L9gXGF/merge-authority-retirement-replacement/replacement-merge.err"
  printf '%s\n' $? > "/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5DAWCT0WRXAZY0TJ3N80XYQ/.ci-debug/tmp/fm-pr-check-security.L9gXGF/merge-authority-retirement-replacement/replacement-merge.rc"
) &
printf '%s\n' "$!" > "/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5DAWCT0WRXAZY0TJ3N80XYQ/.ci-debug/tmp/fm-pr-check-security.L9gXGF/merge-authority-retirement-replacement/replacement-merge.pid"
