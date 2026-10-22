import json, os, pathlib, subprocess, tempfile, time

root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5GE0ZB9KGFFYFN1WFXY7KKZ/disabled-slack-cli.log')
env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))}
# Keep the genuine PATH and installed Slack transport; no doubles or API overrides.
env['TMPDIR'] = str(root / '.test-tmp')
with evidence.open('w') as log, tempfile.TemporaryDirectory(prefix='fm-lab.', dir=root / '.test-tmp') as directory:
    home = pathlib.Path(directory)
    env['FM_HOME'] = str(home)
    def run(script, *args, expected=0, output=None):
        command = [str(root / 'bin' / script), *args]
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=40)
        log.write('$ FM_HOME=<disposable-worktree-home> bin/' + script + ' ' + ' '.join(args) + '\n')
        log.write(result.stdout + result.stderr + f'[exit {result.returncode}]\n\n')
        log.flush()
        assert result.returncode == expected, (script, args, result.stdout, result.stderr)
        if output is not None:
            assert result.stdout == output, (args, result.stdout, output)
        return result.stdout
    run('fm-lab-home.sh', 'create', directory)
    config = home / 'config/slack-bridge'
    base = ('report-channel=C0LABREPORT\ndecisions-channel=C0LABDECISION\n'
            'updates-channel=C0LABUPDATES\ncaptain-user=U0LABCAPTAIN\ndigest-hour=0\n')
    run('fm-slack-bridge.sh', 'post', 'report', 'No config', output='slack bridge off: no config/slack-bridge\n')
    config.write_text(base + 'outbound=off\n')
    run('fm-slack-bridge.sh', 'settings', output='bridge=off\n')
    for kind in ('decision', 'ready', 'report', 'finished', 'merged', 'live', 'stuck', 'digest'):
        args = ['post', kind, '--title', 'Disposable lab validation']
        if kind == 'digest':
            args += ['--line', 'No updates should be sent']
        run('fm-slack-bridge.sh', *args, output='slack outbound off\n')
    run('fm-slack-bridge.sh', 'post', 'finished', '--task', 'no-such-task', '--title', 'Task-bound attempt', output='slack outbound off\n')
    run('fm-slack-bridge.sh', 'post', 'decision', '--', 'Legacy free-text attempt', output='slack outbound off\n')
    run('fm-updates.sh', 'tick', output='')
    run('fm-updates.sh', 'digest', expected=1, output='')
    assert not (home / 'state/slack-bridge/posts').exists()
    assert not (home / 'state/slack-bridge/outcomes').exists()
    assert not (home / 'state/updates/digest-last').exists()
    log.write('Observed persisted state: no post ledger, no outcome ledger, no digest receipt.\n\n')
    # Explicitly distinguish manually supplied persisted protocol data from a real launched worker.
    log.write('The following uses synthetic persisted task input, NOT a live worker/merge/chat scenario.\n')
    (home / 'state/finished-task.meta').write_text(f'kind=ship\nmode=local-only\nproject={home}/projects/lab\nspawn_gen=lab-1\n')
    (home / 'state/finished-task.status').write_text(f'done [at={int(time.time()) - 90000}]: result ready\n')
    run('fm-updates.sh', 'tick', output='')
    run('fm-updates.sh', 'settle', 'finished-task', output='')
    scan = run('fm-updates.sh', 'scan')
    assert scan == 'cleanup-due finished-task: finished; tell the captain in chat if not yet, then run bin/fm-teardown.sh finished-task\n'
    for invalid in ('maybe', 'OFF', ''):
        config.write_text(base + f'outbound={invalid}\n')
        result = run('fm-slack-bridge.sh', 'post', 'report', 'Must refuse', expected=1)
    config.write_text(base + 'outbound=off\n')
    assert not (home / 'state/slack-bridge/posts').exists()
    log.write('All disposable home data removed by the driver on exit. No Slack setup verification or network posting was requested.\n')
print(str(evidence))
