import os, pathlib, subprocess, shlex, shutil
ROOT = pathlib.Path('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5D2RPHXYRTJA4Q4SZ8PDKEW')
EVIDENCE = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5D2RPHXYRTJA4Q4SZ8PDKEW')
LAB = ROOT / '.test-tmp/manual-home'
env = {k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('TASKS_AXI_'))}
env.update(FM_HOME=str(LAB), TMPDIR=str(ROOT / '.test-tmp'))
log = open(EVIDENCE / 'rules-cli-transcript.txt', 'w')
def run(args, expected=0, stdin=None):
    p = subprocess.run(args, cwd=ROOT, env=env, input=stdin, text=True, capture_output=True, timeout=45)
    log.write('$ ' + shlex.join([str(a) for a in args]) + '\n')
    if stdin is not None: log.write('stdin: ' + repr(stdin) + '\n')
    log.write(p.stdout + p.stderr + f'[exit {p.returncode}]\n\n'); log.flush()
    assert p.returncode == expected, (args, p.returncode, p.stderr)
    return p.stdout
R = 'bin/fm-rules.sh'
G = 'bin/fm-rule-guard.sh'
try:
    run(['bin/fm-lab-home.sh', 'create', str(LAB)])
    assert not run([R, 'render'])
    run([R, 'add', 'terminal-handoff', 'Use pbcopy and a real Terminal for sudo steps.'])
    assert 'seen=1' in run([R, 'list'])
    run([R, 'add', 'terminal-handoff', 'Put sudo commands on the clipboard, use a real Terminal, and verify the result.'])
    assert 'seen=2' in run([R, 'list'])
    assert 'terminal-handoff' in run([R, 'unchecked'])
    assert 'REPEATED WITHOUT A CHECK' in run([R, 'render'])
    run([R, 'check', 'terminal-handoff', 'missing-check'], expected=3)
    run([R, 'check', 'terminal-handoff', 'bang-interactive'])
    assert not run([R, 'unchecked'])
    assert '[check: bang-interactive]' in run([R, 'render'])
    run([R, 'add', 'concise-replies', 'Keep replies concise.'])
    run([R, 'add', 'concise-replies', 'Keep replies concise.'])
    run([R, 'nocheck', 'concise-replies', 'Length alone cannot judge whether necessary context was omitted.'])
    assert not run([R, 'unchecked'])
    before = run([R, 'list'])
    run([R, 'add', 'Invalid Id', 'Do not record me.'], expected=3)
    run([R, 'add', 'bad-comment', 'Text <!-- seen=99 -->'], expected=3)
    assert before == run([R, 'list'])
    for task, options in [('rules-ship', ['--mode','no-mistakes']), ('rules-scout', ['--scout'])]:
        run(['bin/fm-brief.sh', task, 'sample-project'] + options)
        brief = LAB / 'data' / task / 'brief.md'
        text = brief.read_text()
        assert '# Captain rules' in text and 'Put sudo commands on the clipboard' in text
        assert "this brief's task scope and safety rules still win" in text
        shutil.copyfile(brief, EVIDENCE / (task + '-brief.md'))
    for text in ['! sudo darwin-rebuild switch', 'Run this: `! gh auth login`', '! security add-generic-password -s x', '> ! op signin', 'no worries, run ! sudo darwin-rebuild switch', 'No worries you can now run ! sudo darwin-rebuild switch', 'No worries now run ! sudo darwin-rebuild switch']:
        assert 'bang-interactive:' in run([G, 'scan'], expected=1, stdin=text+'\n')
    for text in ['Never hand the captain a `! sudo` line.', 'Use pbcopy, not ! sudo.', 'Do not ever run ! sudo -v', 'Nie wieder `! gh auth login` schicken.', '! git status', 'sudo darwin-rebuild switch (pasted into Terminal)']:
        assert not run([G, 'scan'], stdin=text+'\n')
    assert 'weekly report due' in run([R, 'weekly-check'])
    assert not run([R, 'weekly-check'])
    # No fabricated transcripts: this report reads the history produced above.
    (LAB / 'transcripts').mkdir()
    report = run([R, 'report', '--transcripts', str(LAB / 'transcripts')])
    assert '2 total, 2 added, 2 repeated' in report
    assert 'terminal-handoff: recorded again 1 time(s)' in report
    assert 'concise-replies: recorded again 1 time(s)' in report
    (EVIDENCE / 'weekly-report.md').write_text(report)
    assert not run([R, 'weekly-check'])
    run([R, 'weekly-arm'])
    assert not run([str(LAB / 'state/captain-rules-weekly.check.sh')])
    run([R, 'weekly-disarm'])
    assert not (LAB / 'state/captain-rules-weekly.check.sh').exists()
    # A secondmate may read its inherited source but may not fork it.
    (LAB / '.fm-secondmate-home').write_text('rules-mate\n')
    run([R, 'add', 'rogue-rule', 'Do not record me.'], expected=2)
    assert before == run([R, 'list'])
    (LAB / '.fm-secondmate-home').unlink()
    run([R, 'revoke', 'concise-replies'])
    assert 'concise-replies' not in run([R, 'list'])
    run([R, 'revoke', 'concise-replies'], expected=1)
    log.write('All manual CLI assertions satisfied. Disposable home removed in finally.\n')
finally:
    shutil.rmtree(LAB, ignore_errors=True)
    log.close()
