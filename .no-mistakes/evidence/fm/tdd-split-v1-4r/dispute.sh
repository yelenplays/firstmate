#!/usr/bin/env bash
# usage: dispute.sh <fm-root> <control-exit> -> drives fm-tdd-split.sh dispute
set -u
R=$1; CEXIT=$2
L=$(mktemp -d "${TMPDIR:-/tmp}/tdd-lab.XXXX"); export FM_HOME=$L NM_HOME=$L/nm
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p $L/state $L/data/t1 $L/wt $L/nm
W=$L/wt; git -C $W init -q -b main; git -C $W commit -q --allow-empty -m base; git -C $W update-ref refs/remotes/origin/main HEAD; git -C $W checkout -q -b fm/t1
mkdir -p $W/tests; printf '[ -f feature.sh ]\n' > $W/tests/feature.test.sh; git -C $W add -A; git -C $W commit -q -m 'red tests'; SEAT=$(git -C $W rev-parse HEAD)
printf 'echo hi\n' > $W/feature.sh; git -C $W add -A; git -C $W commit -q -m implement; IMPL=$(git -C $W rev-parse HEAD)
printf '# brief\n\nFail-to-pass command: `for t; do bash "$t" || exit 1; done`\n' > $L/data/t1/brief.md
cat > $L/state/t1.meta <<M
kind=ship
mode=no-mistakes
worktree=$W
base_branch=main
branch=fm/t1
project=$L/project
model=claude-sonnet-5-5
test_ban_model=claude-sonnet-5-5
test_ban_since=$SEAT
tdd_split=implement
tdd_split_tests=$SEAT
tdd_split_impl_harness=claude
tdd_split_impl_model=claude-sonnet-5-5
tdd_split_dispute_head=0000000000000000000000000000000000000abc
M
printf 'blocked [key=test-dispute]: tests/feature.test.sh: it checks the wrong file\n' > $L/state/t1.status
cat > $L/control.sh <<C
#!/usr/bin/env bash
{ echo "control argv: \$*"; echo "meta at relaunch time:"; grep '^tdd_split' $L/state/t1.meta; } > $L/control.log
exit $CEXIT
C
chmod +x $L/control.sh
echo "--- meta before"; grep '^tdd_split' $L/state/t1.meta
FM_CONTROL_BIN=$L/control.sh "$R/bin/fm-tdd-split.sh" dispute t1; echo "exit=$?"
echo "--- seen by fm-control relaunch"; sed 's/--note .*/--note <...>/' $L/control.log
echo "--- meta after"; grep '^tdd_split' $L/state/t1.meta
echo "--- status tail"; tail -1 $L/state/t1.status
rm -rf $L
