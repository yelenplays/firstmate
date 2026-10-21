import os, pathlib, subprocess, tempfile, shutil, json, shlex
root = pathlib.Path.cwd()
evidence = pathlib.Path(__file__).parent
lab = pathlib.Path(tempfile.mkdtemp(prefix='.fm-validation-', dir=root))
base = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
base['FM_HOME'] = str(lab)
base['NO_MISTAKES_GATE'] = '1'
logs, results = [], []

def run(args, data=None, code=0, env=None):
    command = [str(x) for x in args]
    p = subprocess.run(command, input=data, text=True, capture_output=True,
                       env=env or base, cwd=root, timeout=45)
    logs.append('$ ' + shlex.join(command) + (('\nstdin: ' + repr(data)) if data is not None else '')
                + '\n' + p.stdout + p.stderr + f'[exit {p.returncode}]\n')
    assert p.returncode == code, logs[-1]
    return p.stdout

rules = root / 'bin/fm-rules.sh'
guard = root / 'bin/fm-rule-guard.sh'
def r(*args, **kw):
    return run([rules, *args], **kw)
def saved(name, live=True):
    results.append({'name': name, 'result': 'pass', 'live': live})

try:
    run([root / 'bin/fm-lab-home.sh', 'create', lab])
    assert r('render') == ''
    r('add', '--check', 'bang-interactive', 'terminal-sudo',
      'Hand sudo steps over through pbcopy and a real Terminal window.')
    r('add', 'short-replies', 'Keep answers short.')
    r('add', 'short-replies', 'Keep answers short and concrete.')
    listing = r('list')
    assert 'short-replies\tseen=2\tKeep answers short and concrete.' in listing
    assert listing.count('short-replies') == 1
    assert 'short-replies' in r('unchecked')
    assert 'REPEATED WITHOUT A CHECK' in r('render')
    r('nocheck', 'short-replies', 'Requires judgment about the answer, not a fixed text pattern.')
    assert r('unchecked') == ''
    assert 'nocheck=' in r('list')
    saved('Record and repeat a correction; persist one updated rule and require a check or explanation')

    before = (lab / 'config/captain-rules.md').read_bytes()
    r('add', 'Bad Id', 'This must not be saved.', code=3)
    r('check', 'terminal-sudo', 'unknown-check', code=3)
    r('add', 'injected', 'text <!-- seen=99 -->', code=3)
    small = base | {'FM_RULES_MAX_CHARS': '200'}
    r('add', 'overflow', 'An additional correction must be refused without losing the existing rules.',
      env=small, code=4)
    assert (lab / 'config/captain-rules.md').read_bytes() == before
    assert 'overflow' not in r('list')
    saved('Reject malformed rules and context-budget overflow without changing persisted rules')

    rendered = r('render')
    for task, args in [('ship-demo', ['--mode', 'local-only']), ('scout-demo', ['--scout'])]:
        run([root / 'bin/fm-brief.sh', task, 'validation-project', *args])
        brief = (lab / 'data' / task / 'brief.md').read_text()
        assert '# Captain rules' in brief
        for text in ['Hand sudo steps over through pbcopy and a real Terminal window.',
                     'Keep answers short and concrete.']:
            assert text in rendered and text in brief
        assert "this brief's task scope and safety rules still win" in brief
        (evidence / f'{task}-brief.md').write_text(brief)
    (evidence / 'rendered-rules.txt').write_text(rendered)
    saved('Scaffold ship and scout instructions containing the complete central rule set')

    r('revoke', 'short-replies')
    assert 'short-replies' not in r('list')
    assert 'Keep answers short' not in r('render')
    r('revoke', 'short-replies', code=1)
    saved('Retract a stored correction and observe its removal from subsequent context')

    bad = ['! sudo darwin-rebuild switch', 'no worries, run ! sudo darwin-rebuild switch',
           'never again - ! sudo x', 'never again – ! sudo x', 'never again — ! sudo x',
           'Never use the old command; run `! sudo -v` instead.', 'Not only run ! sudo -v',
           'Nicht nur ! sudo -v']
    for text in bad:
        assert 'bang-interactive:' in run([guard, 'scan'], data=text + '\n', code=1)
    for text in ['Never hand the captain a `! sudo` line.', 'Use pbcopy, not ! sudo.',
                 'Never run ! sudo -v', 'sudo darwin-rebuild switch (pasted into Terminal)',
                 '! git status']:
        assert run([guard, 'scan'], data=text + '\n') == ''
    saved('Scan unsafe sudo handovers including spaced dashes while allowing negated rule quotations')

    oldbin = lab / 'before'
    oldbin.mkdir()
    old = subprocess.run(['git', 'show', 'ea554df989253dd2b73b218c6feb3203f221d125^:bin/fm-rule-guard.sh'],
                         cwd=root, capture_output=True, text=True, check=True).stdout
    (oldbin / 'fm-rule-guard.sh').write_text(old)
    for dep in ['fm-primary-scope-lib.sh', 'fm-gate-refuse-lib.sh']:
        shutil.copyfile(root / 'bin' / dep, oldbin / dep)
    run(['bash', oldbin / 'fm-rule-guard.sh', 'scan'], data='never again - ! sudo x\n', code=0)
    run([guard, 'scan'], data='never again - ! sudo x\n', code=1)
    saved('Reproduce the spaced-dash bypass on the prior guard and verify the new guard rejects it', live=False)

    state_before = sorted(str(x.relative_to(lab)) for x in (lab / 'state').rglob('*'))
    assert r('session', data='{}') == ''
    assert r('prompt-hook', data=json.dumps({'prompt': 'Ab jetzt nie wieder lange Antworten.'})) == ''
    assert run([guard, '--claude'], data=json.dumps({
        'last_assistant_message': 'never again - ! sudo x', 'session_id': 'isolated-gate-check'})) == ''
    assert state_before == sorted(str(x.relative_to(lab)) for x in (lab / 'state').rglob('*'))
    saved('Invoke primary-only hooks from the gate and observe no capture, context, or guard-state writes')

    r('weekly-arm')
    assert 'weekly report due' in run([lab / 'state/captain-rules-weekly.check.sh'])
    assert run([lab / 'state/captain-rules-weekly.check.sh']) == ''
    report = r('report', '--transcripts', str(lab / 'no-transcripts'))
    assert 'short-replies: recorded again 1 time(s)' in report
    assert 'revoked since' in report
    assert 'Rules: 1 total, 2 added, 1 repeated.' in report
    assert run([lab / 'state/captain-rules-weekly.check.sh']) == ''
    (evidence / 'weekly-report.md').write_text(report)
    r('weekly-disarm')
    assert not (lab / 'state/captain-rules-weekly.check.sh').exists()
    saved('Arm the weekly reminder, report repeated corrections, and silence reminders after reporting')
finally:
    (evidence / 'cli-scenarios.log').write_text('\n'.join(logs))
    (evidence / 'cli-scenario-results.json').write_text(json.dumps(results, indent=2) + '\n')
    shutil.rmtree(lab)
print(json.dumps(results, indent=2))
