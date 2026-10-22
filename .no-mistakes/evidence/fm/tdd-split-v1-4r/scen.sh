#!/usr/bin/env bash
# Fixture scenarios driving fm-dod-lib.sh's pre-PR gate (the function fm-pr-check.sh calls)
set -u
FMROOT=$1; OUT=$2
. "$FMROOT/bin/fm-dod-lib.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
SCHEMA="create table repos (id text primary key, working_path text not null unique);
create table runs (id text primary key, repo_id text not null, branch text not null, head_sha text not null, base_sha text not null, submitted_head_sha text, created_at integer not null);
create table agent_invocations (id text primary key, run_id text not null, step_name text not null, round integer, purpose text not null, model text, exit_status text not null, started_at integer not null);"
new_case() { # name -> sets C, WT, NM, META
  C=$(mktemp -d "${TMPDIR:-/tmp}/scen.XXXX"); WT=$C/wt; NM=$C/nm; META=$C/task.meta; mkdir -p $WT $NM
  git -C $WT init -q -b main; git -C $WT commit -q --allow-empty -m base
  git -C $WT update-ref refs/remotes/origin/main HEAD; git -C $WT checkout -q -b fm/x
  sqlite3 $NM/state.sqlite "$SCHEMA insert into repos values ('rid', '$C/project');"
  export NM_HOME=$NM
  printf 'kind=ship\nmode=no-mistakes\nbranch=fm/x\nproject=%s\nbase_branch=main\nmodel=claude-opus-5-5\n' "$C/project" > $META
}
commit_file() { mkdir -p "$WT/$(dirname $1)"; printf '%s\n' "$2" > "$WT/$1"; git -C $WT add -A; git -C $WT commit -q -m "$3"; git -C $WT rev-parse HEAD; }
run() { sqlite3 $NM/state.sqlite "insert into runs values ('$1','rid','fm/x','$3','base','$2',$4);"; }
inv() { sqlite3 $NM/state.sqlite "insert into agent_invocations values ('$1-$RANDOM$RANDOM','$1','$2',1,'$3','$4','${5:-ok}',1);"; }
gate() { local r; r=$(fm_test_ban_accept_done ship no-mistakes $WT "done: ready" $META 1) && echo "ACCEPT" || echo "REFUSE: $r"; }
check() { # name expect(ACCEPT|REFUSE) [needle]
  local got; got=$(gate); local ok=PASS
  case "$got" in "$2"*) ;; *) ok=FAIL ;; esac
  [ -z "${3:-}" ] || case "$got" in *"$3"*) ;; *) ok=FAIL ;; esac
  printf '%s | %s | %s\n' "$ok" "$1" "$got" | tee -a $OUT
}
: > $OUT

# 1 forged subject, no run -> accepted (never parsed)
new_case; commit_file tests/a.test.sh opus "no-mistakes(review): fake pipeline subject" >/dev/null
check "forged no-mistakes(review) subject by Opus worker, no recorded run" ACCEPT
# 2 plain subject recorded as Sonnet review-fix run -> refused
new_case; s=$(git -C $WT rev-parse HEAD); h=$(commit_file tests/a.test.sh x "Tighten parser") ; run r1 $s $h 1; inv r1 review review-fix claude-sonnet-5-5
check "plain-subject commit added by recorded Sonnet review-fix run" REFUSE "no test authoring on claude-sonnet-5-5"
# 3 read-only review turn excluded; Sol test step authored -> accepted
new_case; s=$(git -C $WT rev-parse HEAD); h=$(commit_file tests/a.test.sh x "x"); run r1 $s $h 1; inv r1 review review claude-sonnet-5-5; inv r1 test test-fix gpt-6.1-sol
check "Sonnet read-only review turn + Sol test-fix authored the test" ACCEPT
# 4 housekeeping document/lint invocation counted
new_case; s=$(git -C $WT rev-parse HEAD); h=$(commit_file tests/a.test.sh x "docs"); run r1 $s $h 1; inv r1 document document claude-sonnet-5-5
check "combined document/lint housekeeping on Sonnet added a test" REFUSE "claude-sonnet-5-5"
# 5 failed invocation counts
new_case; s=$(git -C $WT rev-parse HEAD); h=$(commit_file tests/a.test.sh x "x"); run r1 $s $h 1; inv r1 test test-fix gpt-6.1-sol; inv r1 test test claude-haiku-5-5 error
check "failed Haiku invocation in the run still taints its commits" REFUSE "claude-haiku-5-5"
# 6 run with no invocations -> unrecorded model
new_case; s=$(git -C $WT rev-parse HEAD); h=$(commit_file tests/a.test.sh x "x"); run r1 $s $h 1
check "run with no recorded invocation" REFUSE "an unrecorded model"
# 7 run-wide taint: Sonnet review-fix + Sol test in same run -> Sol's test commit refused
new_case; s=$(git -C $WT rev-parse HEAD); commit_file src.sh y "fix" >/dev/null; h=$(commit_file tests/a.test.sh x "sol test"); run r1 $s $h 1; inv r1 review review-fix claude-sonnet-5-5; inv r1 test test gpt-6.1-sol
check "run-wide: Sol test commit in a run that also had Sonnet review-fix" REFUSE "claude-sonnet-5-5"
# 8 rebase replay keeps attribution
new_case; s=$(git -C $WT rev-parse HEAD); h=$(commit_file tests/a.test.sh x "x"); run r1 $s $h 1; inv r1 review review-fix claude-sonnet-5-5
git -C $WT checkout -q main; commit_file other.txt base2 "base moves" >/dev/null; git -C $WT update-ref refs/remotes/origin/main HEAD; git -C $WT checkout -q fm/x; git -C $WT rebase -q main
check "worker rebase replays the Sonnet pipeline commit (new sha, same patch)" REFUSE "claude-sonnet-5-5"
# 9 rewrite by later Sol run inherits Sonnet authors
new_case; s=$(git -C $WT rev-parse HEAD); h=$(commit_file tests/a.test.sh x "x"); run r1 $s $h 1; inv r1 review review-fix claude-sonnet-5-5
s2=$h; printf 'x2\n' > $WT/tests/a.test.sh; git -C $WT commit -q -a --amend -m "rewritten"; h2=$(git -C $WT rev-parse HEAD); run r2 $s2 $h2 2; inv r2 test test-fix gpt-6.1-sol
check "later Sol run rewrites (amends) the Sonnet test commit" REFUSE "claude-sonnet-5-5"
# 10 Sonnet run that only replays Opus worker commit does not taint it
new_case; s=$(git -C $WT rev-parse HEAD); w=$(commit_file tests/a.test.sh opus "opus test"); run r1 $w $w 1; inv r1 review review-fix claude-sonnet-5-5
check "Sonnet run that adds nothing leaves the Opus worker's test commit alone" ACCEPT
# 11 commits only in gate repo
new_case; s=$(git -C $WT rev-parse HEAD); h=$(commit_file tests/a.test.sh x "x"); run r1 $s $h 1; inv r1 review review-fix claude-sonnet-5-5
mkdir -p $NM/repos; git clone -q --bare $WT $NM/repos/rid.git; git -C $WT reset -q --hard $s
mkdir -p $WT/tests; printf 'x\n' > $WT/tests/a.test.sh; git -C $WT add -A; GIT_COMMITTER_DATE='2001-01-01T00:00:00' git -C $WT commit -q -m "worker-side replay"
git -C $WT reflog expire --expire=now --all; git -C $WT gc -q --prune=now; git -C $WT cat-file -e $h 2>/dev/null && echo "(worker still has $h)" >> $OUT || echo "(worker copy lacks run head $h; gate repo has it: $(git -C $NM/repos/rid.git cat-file -t $h))" >> $OUT
check "run commits held only in gate repo NM_HOME/repos/<id>.git" REFUSE "claude-sonnet-5-5"
# 12 run commits in neither copy + Sonnet author -> unreadable, even Opus own commit
new_case; run r1 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 1; inv r1 review review-fix claude-sonnet-5-5
commit_file tests/a.test.sh opus "opus own test" >/dev/null
check "Sonnet run whose commits neither copy holds -> Opus own test refuses" REFUSE "unreadable no-mistakes history"
# 12b same but run author allowlisted -> accepted
new_case; run r1 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 1; inv r1 test test gpt-6.1-sol
commit_file tests/a.test.sh opus "opus own test" >/dev/null
check "Sol-only run whose commits neither copy holds -> Opus own test accepted" ACCEPT
# 13 no project= -> unreadable
new_case; commit_file tests/a.test.sh opus "opus own test" >/dev/null; sed -i '' '/^project=/d' $META
check "meta without project= and a DB present -> Opus own test refuses" REFUSE "unreadable no-mistakes history"
# 14 absent DB -> nothing attributed
new_case; commit_file tests/a.test.sh opus "opus own test" >/dev/null; rm $NM/state.sqlite
check "absent state database -> Opus own test accepted" ACCEPT
# 15 corrupt DB -> unreadable
new_case; commit_file tests/a.test.sh opus "opus own test" >/dev/null; printf 'garbage' > $NM/state.sqlite
check "corrupt state database -> Opus own test refuses" REFUSE "unreadable no-mistakes history"
# 16 another project's run on same branch neither authorizes nor refuses
new_case; s=$(git -C $WT rev-parse HEAD); h=$(commit_file tests/a.test.sh x "x"); sqlite3 $NM/state.sqlite "insert into repos values ('other','/elsewhere'); insert into runs values ('o1','other','fm/x','$h','base','$s',1); insert into agent_invocations values ('i','o1','review',1,'review-fix','claude-sonnet-5-5','ok',1);"
check "Sonnet run of another project on the same branch name" ACCEPT
# 17 stopped-daemon WAL db without -wal/-shm in read-only dir
new_case; s=$(git -C $WT rev-parse HEAD); h=$(commit_file tests/a.test.sh x "x"); run r1 $s $h 1; inv r1 review review-fix claude-sonnet-5-5
sqlite3 $NM/state.sqlite "pragma journal_mode=wal;" >/dev/null; rm -f $NM/state.sqlite-wal $NM/state.sqlite-shm; chmod 555 $NM
ls $NM >> $OUT
check "WAL database without -wal/-shm in read-only dir (stopped daemon)" REFUSE "claude-sonnet-5-5"
chmod 755 $NM
