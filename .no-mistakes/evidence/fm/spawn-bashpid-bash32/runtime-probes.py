#!/usr/bin/env python3
"""Targeted real-process probes; no mocked commands or fleet access.
BASHPID is unset on Bash 5.3; this does not emulate all of Bash 3.2.
"""
import ctypes
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path.cwd()
LIB = ROOT / 'bin/fm-timeout-lib.sh'
# Adopt only descendants of this validation driver, so orphan probes are reaped.
assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0
ENV = {k: v for k, v in os.environ.items()
       if not k.startswith(('FM_', 'TASKS_AXI_', 'BD_')) and k != 'BASH_ENV'}

def run(args, expected=0, env=None):
    print('$ ' + ' '.join(str(x) for x in args), flush=True)
    started = time.monotonic()
    p = subprocess.run(args, env=env or ENV, text=True, capture_output=True, timeout=15)
    print(json.dumps(dict(stdout=p.stdout, stderr=p.stderr, status=p.returncode,
                          elapsed_s=round(time.monotonic()-started, 3))), flush=True)
    assert p.returncode == expected, (p.returncode, expected)
    return p

def reap():
    while True:
        try:
            pid, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if not pid:
            return
        print(f'reaped child pid={pid} status={status}', flush=True)

def gone(pid):
    until = time.monotonic() + 4
    while time.monotonic() < until:
        reap()
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            print(f'process pid={pid} is absent', flush=True)
            return
        time.sleep(.05)
    raise AssertionError(f'process survived: {pid}')

with tempfile.TemporaryDirectory(prefix='.timeout-live.', dir=ROOT) as scratch:
    scratch = Path(scratch)
    lab = scratch / 'lab'
    run(['bash', 'bin/fm-lab-home.sh', 'create', str(lab)])
    shutil.copyfile(ROOT / '.tasks.toml', lab / '.tasks.toml')
    env = dict(ENV, FM_HOME=str(lab), FM_TASKS_AXI_TIMEOUT='5')
    print('\nSCENARIO: Real backlog mutation/list through bounded consumer with BASHPID absent', flush=True)
    run(['bash', 'bin/fm-tasks-axi.sh', 'add', 'timeout-proof', 'Portable bounded task', '--kind', 'ship', '--repo', 'timeout-lab'], env=env)
    # These are Firstmate's actual lifecycle-consumer APIs, with real tasks-axi.
    run(['bash', '-u', '-c', '''unset BASHPID
. "$1/bin/fm-tasks-axi-lib.sh"
. "$1/bin/fm-backlog-transition-lib.sh"
fm_backlog_row_list "$2/data"
fm_backlog_start "$2/data" timeout-proof || exit $?
fm_backlog_row_list "$2/data" --state in_flight
''', '_', str(ROOT), str(lab)], env=env)
    p = run(['bash', 'bin/fm-tasks-axi.sh', 'show', 'timeout-proof', '--full'], env=env)
    assert 'In flight' in p.stdout or 'in_flight' in p.stdout

    print('\nSCENARIO: Missing BASHPID preserves output, status, and exec identity', flush=True)
    for mode in ('direct', 'subshell'):
        marker = scratch / f'{mode}-caller'
        script = '''. "$1"
probe() {
  printf '%s' "$BASHPID" > "$2"
  unset BASHPID
  fm_exec_timed 5 1 bash -c 'printf "command_parent=%s\\n" "$PPID"; echo portable-stderr >&2; exit 7'
}
case "$3" in direct) probe "$@";; subshell) (probe "$@");; esac
'''
        p = run(['bash', '-u', '-c', script, '_', str(LIB), str(marker), mode], expected=7)
        caller = marker.read_text()
        print(f'{mode}: original caller pid={caller}; {p.stdout.strip()}', flush=True)
        assert p.stdout.strip() == f'command_parent={caller}'
        assert p.stderr == 'portable-stderr\n'

    print('\nSCENARIO: Missing BASHPID still kills TERM-resistant process group after deadline/grace', flush=True)
    marker = scratch / 'deadline-pids'
    cmd = '''trap '' TERM
sleep 30 &
echo "$$ $!" > "$1"
wait
'''
    t = time.monotonic()
    run(['bash', '-u', '-c', 'unset BASHPID; . "$1"; fm_exec_timed 1 1 bash -c "$2" _ "$3"', '_', str(LIB), cmd, str(marker)], expected=124)
    assert 1.9 <= time.monotonic() - t < 8
    for pid in map(int, marker.read_text().split()):
        gone(pid)

    print('\nSCENARIO: Owner dies before watchdog startup; missing BASHPID must not adopt new parent as owner', flush=True)
    marker = scratch / 'startup-child'
    p = run(['bash', '-u', '-c', '''. "$1"
unset BASHPID
(
  sleep 0.3
  fm_exec_timed 30 1 bash -c 'trap "" TERM; echo $$ > "$1"; exec sleep 30' _ "$2"
) >/dev/null 2>&1 &
echo "watchdog=$!"
exit 0
''', '_', str(LIB), str(marker)])
    watchdog = int(p.stdout.strip().split('=')[1])
    gone(watchdog)
    if marker.exists():
        gone(int(marker.read_text()))
    else:
        print('bounded command terminated before writing its startup marker', flush=True)
    print('\nAll real-process probes completed; disposable home removed on exit.', flush=True)
