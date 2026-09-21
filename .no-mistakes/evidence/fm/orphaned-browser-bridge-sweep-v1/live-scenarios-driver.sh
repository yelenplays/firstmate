#!/usr/bin/env bash
# Live end-to-end scenarios for the orphaned browser bridge sweep, driven
# through the real bin/fm-bootstrap.sh (mutate) and its detect-only/report path.
set -u
. "$SCRATCH/harness.sh"

FAILED=0
check() { # <label> <command...>
  local label=$1; shift
  if "$@"; then echo "  PASS: $label"; else echo "  FAIL: $label"; FAILED=1; fi
}
check_grep() { # <label> <needle> <haystack-file>
  local label=$1 needle=$2 file=$3
  if grep -qF -- "$needle" "$file"; then echo "  PASS: $label"; else echo "  FAIL: $label (missing: $needle)"; FAILED=1; fi
}
check_nogrep() {
  local label=$1 needle=$2 file=$3
  if grep -qF -- "$needle" "$file"; then echo "  FAIL: $label (unexpected: $needle)"; FAILED=1; else echo "  PASS: $label"; fi
}
check_file_absent() { [ ! -e "$1" ] && echo "  PASS: $2" || { echo "  FAIL: $2"; FAILED=1; }; }
check_file_present() { [ -e "$1" ] && echo "  PASS: $2" || { echo "  FAIL: $2"; FAILED=1; }; }

ALL_PIDS=()
cleanup_all() {
  local p
  for p in "${ALL_PIDS[@]:-}"; do [ -n "$p" ] && kill -KILL "$p" 2>/dev/null; done
  for p in "${BRIDGE_GROUPS[@]:-}"; do [ -n "$p" ] && kill -KILL -- "-$p" 2>/dev/null; done
  stop_generator
}
trap cleanup_all EXIT

BRIDGE_GROUPS=()
register_tree() { # <bridge pid> <children-file>
  local bp=$1 f=$2 k
  ALL_PIDS+=("$bp"); BRIDGE_GROUPS+=("$bp")
  while IFS= read -r k; do [ -n "$k" ] && ALL_PIDS+=("$k"); done < "$f"
}

start_generator

rm -rf "$SCRATCH/home" "$SCRATCH/root" "$AXI"
mkdir -p "$SCRATCH/home/config" "$SCRATCH/home/state" "$SCRATCH/home/data" "$SCRATCH/root" "$AXI/sessions"
git -C "$SCRATCH/root" init -q -b main >/dev/null 2>&1
git -C "$SCRATCH/root" config user.email t@t; git -C "$SCRATCH/root" config user.name t
echo hi > "$SCRATCH/root/README.md"; git -C "$SCRATCH/root" add -A; git -C "$SCRATCH/root" commit -qm init

echo "###############################################################"
echo "# SCENARIO 1 - an orphaned bridge tree is reaped by a real mutating bootstrap run"
echo "###############################################################"
ID1=fmtest-live-orphan-$RANDOM
P1=$SCRATCH/zk-axi-profile-$ID1
mkdir -p "$P1/Default" && echo cookie > "$P1/Default/Cookies"
BP1=$(start_bridge c1 "$ID1" s-orphan "$P1") || { echo "could not start fixture"; exit 1; }
KIDS1=$(cat "$SCRATCH/cases/c1/children")
register_tree "$BP1" "$SCRATCH/cases/c1/children"
echo "fixture bridge pid=$BP1 pgid=$(ps -p "$BP1" -o pgid= | tr -d ' ') task=$ID1 profile=$P1"
echo "fixture children (incl. one TERM-ignoring member and two with odd command whitespace):"
for k in $KIDS1; do echo "  pid=$k cmd=$(ps -p "$k" -o command= | cut -c1-90)"; done
run_bootstrap 0 > "$SCRATCH/s1.out"
echo "--- BROWSER_BRIDGES transcript ---"; grep BROWSER_BRIDGES "$SCRATCH/s1.out" || echo "(none)"
wait_gone "$BP1"
surv=0; for k in $KIDS1; do alive "$k" && surv=$((surv+1)); done
check_grep "reap line names the orphaned bridge pid"     "reaping orphaned bridge pid=$BP1" "$SCRATCH/s1.out"
check_grep "reap line names the process group"          "pgid=$BP1" "$SCRATCH/s1.out"
check_grep "reap line names the owning task"            "task=$ID1" "$SCRATCH/s1.out"
check_grep "reap line names the bridge age"             "age=" "$SCRATCH/s1.out"
check_grep "reap line names the profile dir"            "profile=$P1" "$SCRATCH/s1.out"
check_nogrep "no partially-survived warning"            "partially survived" "$SCRATCH/s1.out"
check "bridge process is gone"                          test "$(alive "$BP1" && echo yes || echo no)" = no
check "every descendant is gone (incl. TERM-ignorer and whitespace members)" test "$surv" -eq 0
check_grep "profile removal is reported"                "removed browser profile dir" "$SCRATCH/s1.out"
check_file_absent "$P1" "orphaned profile dir removed"

echo
echo "###############################################################"
echo "# SCENARIO 2 - a read-only (detect-only) session start reports the orphan and touches nothing"
echo "###############################################################"
ID2=fmtest-live-report-$RANDOM
P2=$SCRATCH/zk-axi-profile-$ID2
mkdir -p "$P2"
BP2=$(start_bridge c2 "$ID2" s-report "$P2") || { echo "could not start fixture"; exit 1; }
KIDS2=$(cat "$SCRATCH/cases/c2/children")
register_tree "$BP2" "$SCRATCH/cases/c2/children"
echo "fixture bridge pid=$BP2 task=$ID2 profile=$P2"
run_bootstrap 1 > "$SCRATCH/s2.out"
echo "--- BROWSER_BRIDGES transcript ---"; grep BROWSER_BRIDGES "$SCRATCH/s2.out" || echo "(none)"
check_grep "report line names the orphaned bridge"      "orphaned bridge pid=$BP2" "$SCRATCH/s2.out"
check_grep "report line is marked report-only"          "not reaped (report-only run)" "$SCRATCH/s2.out"
check_grep "report line names the profile"              "profile=$P2" "$SCRATCH/s2.out"
check "report run did not signal the bridge"            alive "$BP2"
check_file_present "$P2" "report run did not remove the profile"
run_bootstrap 0 > "$SCRATCH/s2b.out"
wait_gone "$BP2"
check "a later mutating run reaps what the report found" test "$(alive "$BP2" && echo yes || echo no)" = no
check_file_absent "$P2" "the later mutating run removes the profile"

echo
echo "###############################################################"
echo "# SCENARIO 3 (adversarial) - a bridge whose owning task is alive is never touched"
echo "###############################################################"
ID3=fmtest-live-alive-$RANDOM
BP3=$(start_bridge c3 "$ID3" s-live) || { echo "could not start fixture"; exit 1; }
KIDS3=$(cat "$SCRATCH/cases/c3/children")
register_tree "$BP3" "$SCRATCH/cases/c3/children"
env FM_TASK_ID="$ID3" python3 -c 'import time;time.sleep(600)' >/dev/null 2>&1 &
CARRIER3=$!; ALL_PIDS+=("$CARRIER3")
sleep 0.3
echo "fixture bridge pid=$BP3 task=$ID3 ; live carrier pid=$CARRIER3"
run_bootstrap 0 > "$SCRATCH/s3.out"
echo "--- BROWSER_BRIDGES transcript ---"; grep BROWSER_BRIDGES "$SCRATCH/s3.out" || echo "(none)"
check_nogrep "the sweep did not reap the live-owner bridge" "reaping orphaned bridge pid=$BP3" "$SCRATCH/s3.out"
check "the live-owner bridge still runs"                alive "$BP3"

echo
echo "###############################################################"
echo "# SCENARIO 4 (adversarial) - an unattributable bridge is refused, reported, never killed"
echo "###############################################################"
BP4=$(start_bridge c4 "" s-foreign) || { echo "could not start fixture"; exit 1; }
KIDS4=$(cat "$SCRATCH/cases/c4/children")
register_tree "$BP4" "$SCRATCH/cases/c4/children"
echo "fixture bridge pid=$BP4 (no FM_TASK_ID, session name matches no recorded task)"
run_bootstrap 0 > "$SCRATCH/s4.out"
echo "--- BROWSER_BRIDGES transcript ---"; grep BROWSER_BRIDGES "$SCRATCH/s4.out" || echo "(none)"
check_grep "the refusal line names the bridge"          "left bridge pid=$BP4" "$SCRATCH/s4.out"
check_grep "the refusal names the attribution gap"      "not attributable" "$SCRATCH/s4.out"
check "the unattributable bridge still runs"            alive "$BP4"

echo
echo "###############################################################"
echo "# SCENARIO 5 (adversarial) - a shared profile is kept while a live consumer names it"
echo "###############################################################"
ID5=fmtest-live-shared-$RANDOM
P5=$SCRATCH/zk-axi-profile-$ID5
mkdir -p "$P5"
python3 -c 'import time;time.sleep(600)' "--user-data-dir=$P5" >/dev/null 2>&1 &
HOLDER5=$!; ALL_PIDS+=("$HOLDER5")
sleep 0.3
BP5=$(start_bridge c5 "$ID5" s-shared "$P5") || { echo "could not start fixture"; exit 1; }
KIDS5=$(cat "$SCRATCH/cases/c5/children")
register_tree "$BP5" "$SCRATCH/cases/c5/children"
echo "fixture bridge pid=$BP5 task=$ID5 ; separate live holder pid=$HOLDER5 naming the same profile"
run_bootstrap 0 > "$SCRATCH/s5.out"
echo "--- BROWSER_BRIDGES transcript ---"; grep BROWSER_BRIDGES "$SCRATCH/s5.out" || echo "(none)"
wait_gone "$BP5"
check "the orphaned tree is still reaped"               test "$(alive "$BP5" && echo yes || echo no)" = no
check_grep "the shared profile is reported as still in use" "a live process still names it" "$SCRATCH/s5.out"
check_file_present "$P5" "the shared profile dir was not deleted"
kill -KILL "$HOLDER5" 2>/dev/null

echo
echo "###############################################################"
echo "# SCENARIO 6 - stale bridge pid files are cleaned; live and unreadable ones stay"
echo "###############################################################"
ID6=fmtest-live-pidfiles-$RANDOM
BP6=$(start_bridge c6 "$ID6" s-pidfiles) || { echo "could not start fixture"; exit 1; }
KIDS6=$(cat "$SCRATCH/cases/c6/children")
register_tree "$BP6" "$SCRATCH/cases/c6/children"
mkdir -p "$AXI/sessions/dead-one" "$AXI/sessions/reused-one" "$AXI/sessions/live-one" "$AXI/sessions/broken-one"
printf '{"pid":99999,"port":9555}\n' > "$AXI/sessions/dead-one/bridge.pid"
printf '{"pid":%s,"port":9556}\n' "$CARRIER3" > "$AXI/sessions/reused-one/bridge.pid"
printf '{"pid":%s,"port":9557}\n' "$BP3" > "$AXI/sessions/live-one/bridge.pid"
printf 'not json\n' > "$AXI/sessions/broken-one/bridge.pid"
run_bootstrap 1 > "$SCRATCH/s6r.out"
echo "--- report-only BROWSER_BRIDGES transcript ---"; grep BROWSER_BRIDGES "$SCRATCH/s6r.out" || echo "(none)"
check_grep "report-only names the stale pid files"      "stale bridge pid file" "$SCRATCH/s6r.out"
check_grep "report-only names the unreadable pid file"  "unreadable bridge pid file" "$SCRATCH/s6r.out"
check_file_present "$AXI/sessions/dead-one/bridge.pid" "report-only removed nothing"
run_bootstrap 0 > "$SCRATCH/s6m.out"
echo "--- mutating BROWSER_BRIDGES transcript ---"; grep BROWSER_BRIDGES "$SCRATCH/s6m.out" || echo "(none)"
check_file_absent "$AXI/sessions/dead-one/bridge.pid"   "dead-pid file removed"
check_file_absent "$AXI/sessions/reused-one/bridge.pid" "reused-pid file removed"
check_file_present "$AXI/sessions/live-one/bridge.pid"  "live bridge pid file kept (points at the still-alive live-owner bridge)"
check_file_present "$AXI/sessions/broken-one/bridge.pid" "unreadable pid file kept"
kill -KILL "$BP6" 2>/dev/null; kill -KILL -- "-$BP6" 2>/dev/null

echo
echo "###############################################################"
echo "# SCENARIO 7 - a fixture bootstrap cannot see the host's real bridge state"
echo "###############################################################"
FH=$SCRATCH/fakehome
mkdir -p "$FH/.chrome-devtools-axi/sessions/host-leftover"
printf '{"pid":99999,"port":9555}\n' > "$FH/.chrome-devtools-axi/sessions/host-leftover/bridge.pid"
echo "a stale bridge.pid exists at \$fakeHOME/.chrome-devtools-axi/sessions/host-leftover/bridge.pid"
WITH_DEFAULTS=$(HOME="$FH" FM_BACKEND=tmux FM_HOME="$SCRATCH/home" FM_ROOT_OVERRIDE="$SCRATCH/root" \
  FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 bash "$REPO/bin/fm-bootstrap.sh" 2>&1 | grep BROWSER_BRIDGES || true)
echo "--- with the hook unset (real default state dir), BROWSER_BRIDGES says: ---"
printf '%s\n' "${WITH_DEFAULTS:-(none)}"
ISOLATED=$(HOME="$FH" FM_BACKEND=tmux FM_HOME="$SCRATCH/home" FM_ROOT_OVERRIDE="$SCRATCH/root" \
  FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 \
  FM_BROWSER_BRIDGE_PROC_TABLE=/dev/null FM_CHROME_AXI_STATE_DIR=/dev/null \
  bash "$REPO/bin/fm-bootstrap.sh" 2>&1 | grep BROWSER_BRIDGES || true)
echo "--- with the test-boundary hooks pinned (as tests/environment.sh sets them) ---"
printf '%s\n' "${ISOLATED:-(none)}"
check_grep "the default path does see the host-state leftover (proves the fixture is real)" \
  "stale bridge pid file" <(printf '%s\n' "$WITH_DEFAULTS")
check "the test boundary silences it" test -z "$ISOLATED"

echo
echo "###############################################################"
echo "# SCENARIO 8 (adversarial) - a reused/recycled pid never matches its recorded tree command,"
echo "#                            so it is never signalled"
echo "###############################################################"
ID8=fmtest-live-guard-$RANDOM
BP8=$(start_bridge c8 "$ID8" s-guard) || { echo "could not start fixture"; exit 1; }
KIDS8=$(cat "$SCRATCH/cases/c8/children")
register_tree "$BP8" "$SCRATCH/cases/c8/children"
python3 -c 'import time;time.sleep(600)' >/dev/null 2>&1 &
FAKE8=$!; ALL_PIDS+=("$FAKE8")
sleep 0.2
echo "fixture bridge pid=$BP8 task=$ID8"
echo "unrelated live pid=$FAKE8 (real command: $(ps -p "$FAKE8" -o command= | cut -c1-60))"
echo "the sweep's process table is rigged to present pid $FAKE8 as a tree member whose recorded"
echo "command is 'python3 chrome-devtools-axi-bridge-ghost.js' - a simulated pid recycle"
stop_generator
GUARD_FAKE_PID=$FAKE8 GUARD_BRIDGE_PID=$BP8 start_generator
run_bootstrap 0 > "$SCRATCH/s8.out"
echo "--- BROWSER_BRIDGES transcript ---"; grep BROWSER_BRIDGES "$SCRATCH/s8.out" || echo "(none)"
check "the mismatched pid was NOT signalled" test "$(alive "$FAKE8" && echo yes || echo no)" = yes
stop_generator
start_generator

echo
echo "###############################################################"
echo "# SCENARIO 9 - a bridge whose task left a recorded but now-missing endpoint is reaped"
echo "###############################################################"
ID9=fmtest-live-meta-$RANDOM
P9=$SCRATCH/zk-axi-profile-$ID9
mkdir -p "$P9"
printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nkind=ship\n' "$ID9" "$ID9" > "$SCRATCH/home/state/$ID9.meta"
BP9=$(start_bridge c9 "$ID9" s-meta "$P9") || { echo "could not start fixture"; exit 1; }
KIDS9=$(cat "$SCRATCH/cases/c9/children")
register_tree "$BP9" "$SCRATCH/cases/c9/children"
echo "fixture bridge pid=$BP9 task=$ID9"
echo "recorded endpoint: $SCRATCH/home/state/$ID9.meta -> firstmate:fm-$ID9 (does not exist)"
run_bootstrap 0 > "$SCRATCH/s9.out"
echo "--- BROWSER_BRIDGES transcript ---"; grep BROWSER_BRIDGES "$SCRATCH/s9.out" || echo "(none)"
wait_gone "$BP9"
check "the recorded-endpoint bridge was reaped" test "$(alive "$BP9" && echo yes || echo no)" = no
check_grep "the reap names the task" "task=$ID9" "$SCRATCH/s9.out"
check_file_absent "$P9" "the recorded-endpoint bridge's profile was removed"
rm -f "$SCRATCH/home/state/$ID9.meta"

echo
echo "###############################################################"
if [ "$FAILED" -eq 0 ]; then echo "ALL SCENARIOS PASSED"; else echo "SOME SCENARIO CHECKS FAILED"; fi
