#!/usr/bin/env python3
"""Drive real startup-hook and wake-routing CLIs without a model or primary."""
import json
import os
from pathlib import Path
import shutil
import subprocess

repo = Path.cwd()
scratch = repo / '.test-phase-tmp' / 'live-cli'
base = 'e33bc201a15300f86f9b5393faa35abc1815db23'
env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'NO_MISTAKES_', 'TASKS_AXI_'))}
env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_COUNT='0', TMPDIR=str(repo / '.test-phase-tmp'))

def run(args, *, cwd=repo, extra=None, stdin=''):
    return subprocess.run([str(a) for a in args], cwd=cwd, env=env | (extra or {}), input=stdin, text=True, capture_output=True, timeout=30)

def home(path, control=False):
    path.mkdir(parents=True)
    p = run(['git', 'init', '-q', path])
    assert p.returncode == 0, p.stderr
    (path / 'AGENTS.md').write_text('# Isolated CLI verification home\n')
    (path / 'state').mkdir()
    if control:
        shutil.copytree(repo / 'bin', path / 'bin')
        for name in ('fm-sessionstart-run.sh', 'fm-primary-scope-lib.sh'):
            p = run(['git', 'show', f'{base}:bin/{name}'])
            assert p.returncode == 0, p.stderr
            (path / 'bin' / name).write_text(p.stdout)
    else:
        (path / 'bin').symlink_to(repo / 'bin', target_is_directory=True)
    return path

def hook(root, *, task='', cwd=repo, payload=None, source='startup'):
    return run([root / 'bin/fm-sessionstart-run.sh', '--source', source], cwd=cwd,
        extra={'FM_ROOT_OVERRIDE': str(root), 'FM_HOME': str(root), 'FM_TASK_ID': task},
        stdin=json.dumps(payload or {}))

try:
    scratch.mkdir(parents=True)
    current = home(scratch / 'current')
    control = home(scratch / 'control', control=True)
    slot = home(scratch / '.treehouse/demo-pool/12/firstmate')
    print('Candidate:', run(['git', 'rev-parse', 'HEAD']).stdout.strip())
    print('BASELINE worker startup continuation (actual base scripts, isolated home):')
    p = hook(control, task='measurement', source='resume')
    print(f'  exit={p.returncode}; stdout={p.stdout.strip()!r}; stderr={p.stderr.strip()!r}')
    assert p.returncode == 0 and 'session-start' in p.stdout, 'baseline did not reproduce the worker-context leak'
    print('CURRENT supervisor continuation (positive control; same home shape and process):')
    p = hook(current, source='resume')
    print(f'  exit={p.returncode}; stdout={p.stdout.strip()!r}; stderr={p.stderr.strip()!r}')
    assert p.returncode == 0 and 'session-start' in p.stdout
    cases = [
        ('explicit worker identity', current, {'task': 'measurement'}),
        ('worker cwd with primary-installed runner', current, {'cwd': slot}),
        ('plain-clone Treehouse slot', slot, {}),
        ('worker cwd in compact hook payload', current, {'payload': {'source': 'compact', 'cwd': str(slot)}, 'source': 'compact'}),
    ]
    for label, root, kwargs in cases:
        before = sorted(str(p.relative_to(root / 'state')) for p in (root / 'state').rglob('*'))
        p = hook(root, **kwargs)
        after = sorted(str(p.relative_to(root / 'state')) for p in (root / 'state').rglob('*'))
        print(f'CURRENT {label}: exit={p.returncode}; stdout_bytes={len(p.stdout.encode())}; stderr_bytes={len(p.stderr.encode())}; home_state_before={before}; home_state_after={after}')
        assert p.returncode == 0 and not p.stdout and not p.stderr and before == after
    (slot / '.fm-secondmate-home').write_text('mate\n')
    p = hook(slot, task='measurement')
    print(f'CURRENT worker identity with copied secondmate marker: exit={p.returncode}; stdout_bytes={len(p.stdout.encode())}; state_entries={list((slot / "state").iterdir())}')
    assert p.returncode == 0 and not p.stdout and not p.stderr and not list((slot / 'state').iterdir())
    p = hook(slot, source='resume')
    print(f'CURRENT genuine marked slot supervisor: exit={p.returncode}; stdout={p.stdout.strip()!r}')
    assert p.returncode == 0 and 'session-start' in p.stdout

    route = scratch / 'routing'
    p = run([repo / 'bin/fm-lab-home.sh', 'create', route])
    assert p.returncode == 0, p.stderr
    routing = {'FM_HOME': str(route)}
    def append(kind, key, message):
        p = run(['bash', '-c', '. "$1"; fm_wake_append "$2" "$3" "$4"', '_', repo / 'bin/fm-wake-lib.sh', kind, key, message], extra=routing)
        assert p.returncode == 0, p.stderr
    def offer(message, expected):
        p = run(['node', repo / 'bin/fm-branch-dispatch.mjs', 'offer'], extra=routing, stdin=message + '\n')
        print(f'ROUTING {message!r}: exit={p.returncode}\n{p.stdout.rstrip()}')
        assert p.returncode == 0 and p.stdout.splitlines()[0] == f'eligible={expected}', p.stderr
        return p.stdout
    append('check', 'execution:measurement', 'check: execution measurement')
    print('Real producer wake queue:', (route / 'state/.wake-queue').read_text().strip())
    for trigger in ('check: unfinished-execution', 'check: rearm-resurface'):
        out = offer(trigger, 1)
        assert 'rows=1\n' in out and 'unscoped=1' in out
    for trigger in ('check: credential required', 'check: unfinished-execution failed', 'check: rearm-resurface-extra'):
        offer(trigger, 0)
    append('check', 'auth', 'check: credential required')
    for trigger in ('check: unfinished-execution', 'check: rearm-resurface'):
        offer(trigger, 0)
    print('Credential check stays queued:', (route / 'state/.wake-queue').read_text().strip())
    empty = scratch / 'empty'
    p = run([repo / 'bin/fm-lab-home.sh', 'create', empty])
    assert p.returncode == 0, p.stderr
    routing = {'FM_HOME': str(empty)}
    # The persisted queue contract distinguishes an empty queue from a missing queue.
    (empty / 'state/.wake-queue').touch()
    for trigger in ('check: unfinished-execution', 'check: rearm-resurface'):
        assert 'status=empty' in offer(trigger, 1)
    # A malformed persisted queue is an intentional corruption/recovery input.
    (empty / 'state/.wake-queue').write_text('broken\n')
    assert 'corrupted=1' in offer('check: unfinished-execution', 0)
    print('No model, fake harness, default session, or production home was used; model classification and primary delivery remain untested.')
finally:
    shutil.rmtree(scratch, ignore_errors=True)
    print('Removed isolated CLI homes and baseline copies.')
