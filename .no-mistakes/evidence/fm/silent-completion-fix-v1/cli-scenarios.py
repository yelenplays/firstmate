"""Drive real backlog and outcome CLIs in disposable homes; no model or backend stub."""
import json, os, pathlib, shutil, subprocess, tempfile

root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5DN3KN9FJ53VCC3H19YD5RQ')
lab = pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.', dir=root / '.local-test-tmp'))
env = os.environ.copy()
for key in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_GATE_REFUSE_BYPASS', 'FM_TEST_SEAM', 'FM_CREW_STATE_BIN', 'FM_SUPERVISION_ACTOR', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
    env.pop(key, None)
env['FM_HOME'] = str(lab / 'home')
log = open(evidence / 'cli-scenarios.log', 'w')

def run(script, *args, expected=0):
    cmd = ['bin/' + script, *args]
    p = subprocess.run(cmd, env=env, text=True, capture_output=True, timeout=45)
    log.write('$ ' + ' '.join(cmd) + '\n' + p.stdout + p.stderr + f'[exit {p.returncode}]\n')
    log.flush()
    assert p.returncode == expected, (cmd, p.returncode, p.stderr)
    return p.stdout

def rows():
    return [json.loads(s) for s in run('fm-branch-outcome.sh', 'list', '--recent', '100').splitlines()]

def add(task, kind):
    run('fm-tasks-axi.sh', 'add', task, 'Disposable completion delivery validation', '--kind', kind)

try:
    run('fm-lab-home.sh', 'create', str(lab / 'home'))
    # Public backlog transitions supply completion evidence, without deleting data or inventing a state-reader response.
    for task, kind in [('lab-scout', 'scout'), ('lab-ship', 'ship')]:
        add(task, kind)
        run('fm-tasks-axi.sh', 'done', task, '--note', 'Disposable task completed', '--no-prune')
        state = run('fm-crew-state.sh', task)
        assert state.startswith('state: done'), state
        for verdict in ('routine', 'captain'):
            run('fm-branch-outcome.sh', 'append', '--promote-finished', '--task', task,
                '--verdict', verdict, '--summary', f'{kind} finished: lab result ({verdict} supplied)')
    assert all(r['verdict'] == 'captain' for r in rows())
    run('fm-branch-outcome.sh', 'append', '--promote-finished', '--task', 'lab-scout',
        '--verdict', 'routine', '--silent', 'true', '--summary', 'Still busy, no changes')
    quiet_done = rows()[-1]
    assert quiet_done['verdict'] == 'captain' and not quiet_done['silent']
    assert 'read the finished result' in quiet_done['summary']
    log.write('OBSERVED: both closed task kinds override routine verdict; silent completion becomes a visible result pointer.\n')

    add('lab-open', 'scout')
    for quiet in ('false', 'true'):
        run('fm-branch-outcome.sh', 'append', '--promote-finished', '--task', 'lab-open',
            '--verdict', 'routine', '--silent', quiet, '--summary', 'Still working, no result')
    r = rows()
    assert [(x['verdict'], x['silent']) for x in r[-2:]] == [('routine', False), ('routine', True)]
    log.write('OBSERVED: unfinished task stays routine; no-change report stays silent.\n')

    add('lab-late', 'scout')
    seq = run('fm-branch-outcome.sh', 'append', '--promote-finished', '--task', 'lab-late',
              '--verdict', 'routine', '--summary', 'Result ready; completion transition follows').strip()
    assert rows()[-1]['verdict'] == 'routine'
    run('fm-tasks-axi.sh', 'done', 'lab-late', '--no-prune')
    newseq = run('fm-branch-outcome.sh', 'finished-handback', '--seqs', seq).strip()
    assert int(newseq) > int(seq)
    assert rows()[-1]['task'] == 'lab-late' and rows()[-1]['verdict'] == 'captain'
    assert run('fm-branch-outcome.sh', 'finished-handback', '--seqs', seq).strip() == ''
    run('fm-branch-outcome.sh', 'present')
    log.write('OBSERVED: completion after report creates one captain handback; replay does not duplicate it.\n')
    before = rows()
    run('fm-branch-report.sh', '--task', 'lab-scout', '--verdict', 'captain', '--summary', 'unauthorized write', expected=3)
    assert rows() == before
    log.write('OBSERVED: unauthorized branch-report CLI refuses with no appended outcome.\n')
finally:
    log.close()
    shutil.rmtree(lab)
