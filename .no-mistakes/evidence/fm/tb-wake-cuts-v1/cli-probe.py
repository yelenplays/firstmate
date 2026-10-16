import json, os, pathlib, subprocess, tempfile

root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M52MN8G8KBHHEBGDYWX4Q545/cli-transcript.log')
base = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
base.pop('NO_MISTAKES_GATE', None)
base['FM_GATE_REFUSE_BYPASS'] = '0'

with evidence.open('w') as log, tempfile.TemporaryDirectory(prefix='.token-burn-cli-', dir=root) as tmp:
    def run(args, *, env=None, stdin='', cwd=None):
        p = subprocess.run([str(x) for x in args], input=stdin, text=True, capture_output=True,
                           cwd=cwd or root, env=env or base, timeout=45)
        return p
    def record(label, p):
        log.write(f'\n=== {label} ===\nexit={p.returncode}\nstdout={p.stdout!r}\nstderr={p.stderr!r}\n')
        log.flush()
    def home_at(path):
        for directory in ('bin', 'state', 'config', 'data'):
            (path / directory).mkdir(parents=True, exist_ok=True)
        (path / 'AGENTS.md').write_text('# Isolated CLI validation home\n')
        p = run(['git', 'init', '-q', path])
        assert p.returncode == 0, p.stderr
        return {**base, 'FM_HOME': str(path), 'FM_ROOT_OVERRIDE': str(path)}

    home = pathlib.Path(tmp) / 'primary'
    slot = pathlib.Path(tmp) / '.treehouse' / 'project-pool' / '12' / 'firstmate'
    env = home_at(home)
    slot_env = home_at(slot)
    # Public nudge interface is a positive primary-seat control; no startup is run.
    p = run([root / 'bin/fm-sessionstart-nudge.sh'], env=env)
    record('Primary seat positive control: session-start nudge', p)
    assert p.returncode == 0 and 'FIRSTMATE_OP' in p.stdout
    for source in ('startup', 'compact'):
        inputs = [
            ('worker environment', {**env, 'FM_TASK_ID': 'token-burn-worker'}, root, '{}'),
            ('plain-clone worker slot cwd', env, slot, '{}'),
            ('worker slot hook payload at primary runner', env, root,
             json.dumps({'source': source, 'cwd': str(slot)}).replace('/', '\\/')),
        ]
        for label, run_env, cwd, payload in inputs:
            p = run([root / 'bin/fm-sessionstart-run.sh', '--source', source], env=run_env, cwd=cwd, stdin=payload)
            record(f'{source}: {label}', p)
            assert p.returncode == 0 and not p.stdout and not p.stderr
    (slot / '.fm-secondmate-home').write_text('copied-marker\n')
    p = run([root / 'bin/fm-sessionstart-run.sh', '--source', 'compact'],
            env={**slot_env, 'FM_TASK_ID': 'token-burn-worker'}, cwd=slot)
    record('Worker identity overrides copied secondmate marker', p)
    assert p.returncode == 0 and not p.stdout and not p.stderr
    assert not (home / 'state/.lock').exists() and not (slot / 'state/.lock').exists()
    log.write('No primary or worker session lock was created by worker hook calls.\n')
    p = run([root / 'bin/fm-sessionstart-nudge.sh'], env=slot_env, cwd=slot)
    record('Genuine marked slot home retains supervisor nudge', p)
    assert p.returncode == 0 and 'FIRSTMATE_OP' in p.stdout

    # Use the product queue writer, not a fabricated serialized wake row.
    def append(kind, key, payload):
        p = run(['bash', '-c', '. "$1"; fm_wake_append "$2" "$3" "$4"', '_',
                 root / 'bin/fm-wake-lib.sh', kind, key, payload], env=env)
        assert p.returncode == 0, p.stderr
    def offer(reason, eligible, rows=None):
        p = run(['node', root / 'bin/fm-branch-dispatch.mjs', 'offer'], env=env, stdin=reason+'\n')
        record(f'Dispatch offer: {reason}', p)
        fields = dict(line.split('=', 1) for line in p.stdout.splitlines())
        assert p.returncode == 0 and fields['eligible'] == str(eligible)
        if rows is not None:
            assert fields['rows'] == rows, fields
    offer('check: unfinished-execution', 0)  # Missing queue is unsafe, not an empty claim.
    (home / 'state/.wake-queue').touch()
    for reason in ('check: unfinished-execution', 'check: rearm-resurface'):
        offer(reason, 1, '')
    append('check', 'execution:demo', 'check: execution demo')
    for reason in ('check: unfinished-execution', 'check: rearm-resurface'):
        offer(reason, 1, '1')
    for reason in ('check: unfinished-execution failed', 'check: rearm-resurface-extra', 'check: credential required'):
        offer(reason, 0)
    append('check', 'auth', 'check: credential required')
    for reason in ('check: unfinished-execution', 'check: rearm-resurface'):
        offer(reason, 0)
    log.write('\nPersisted product queue (both rows remain available, offer does not consume them):\n')
    log.write((home / 'state/.wake-queue').read_text())
    log.write('\nAll direct CLI assertions passed; temporary homes removed on exit.\n')
print(evidence)
