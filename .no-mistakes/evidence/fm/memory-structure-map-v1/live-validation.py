import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path.cwd()
evidence = Path('/Users/yelen/.no-mistakes/evidence/01M5F31KR57FWVGPS1KRY8K810')
home = root / '.test-tmp/live-home'
for d in ('state', 'config', 'data', 'projects'):
    (home / d).mkdir(parents=True, exist_ok=True)
env = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TASKS_AXI_FILE', 'TASKS_AXI_BACKEND')}
env.update(FM_HOME=str(home), TMPDIR=str(root / '.test-tmp'))
records = []

def cmd(script, *args, text=None, expected=0, overrides=None):
    local = dict(env)
    local.update(overrides or {})
    p = subprocess.run([str(root / 'bin' / script), *args], input=text, text=True, capture_output=True, env=local, timeout=30)
    record = dict(command='bin/' + script + ' ' + ' '.join(args), stdin=text, exit=p.returncode, stdout=p.stdout, stderr=p.stderr)
    records.append(record)
    assert p.returncode == expected, record
    return p.stdout

try:
    cmd('fm-rules.sh', 'add', '--check', 'bang-interactive', 'no-bang', 'Use the clipboard and a real Terminal for sudo; never hand over a bang command.')
    cmd('fm-rules.sh', 'add', 'short-replies', 'Keep answers short.')
    assert 'Keep answers short.' in cmd('fm-rules.sh', 'render')
    cmd('fm-rules.sh', 'add', 'short-replies', 'Keep answers short.')
    assert 'short-replies' in cmd('fm-rules.sh', 'unchecked')
    cmd('fm-rules.sh', 'nocheck', 'short-replies', 'Brevity needs contextual judgment; no safe deterministic check.')
    assert not cmd('fm-rules.sh', 'unchecked')

    before = cmd('fm-rules.sh', 'list')
    cmd('fm-rules.sh', 'add', 'Bad Id', 'Must not save.', expected=3)
    cmd('fm-rules.sh', 'add', 'bad-comment', 'Do this <!-- seen=100 -->', expected=3)
    cmd('fm-rules.sh', 'add', 'oversized', 'This new correction must not fit.', expected=4, overrides={'FM_RULES_MAX_CHARS':'200'})
    assert before == cmd('fm-rules.sh', 'list')

    def add_one(i):
        return cmd('fm-rules.sh', 'add', f'parallel-{i}', f'Parallel correction {i}.')
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        list(pool.map(add_one, range(5)))
    listed = cmd('fm-rules.sh', 'list')
    assert all(f'parallel-{i}\tseen=1\tParallel correction {i}.' in listed for i in range(5))
    for kind in ('ship', 'scout'):
        args = ('--mode', 'local-only') if kind == 'ship' else ('--scout',)
        cmd('fm-brief.sh', 'validation-' + kind, 'validation-project', *args)
        brief = home / 'data' / ('validation-' + kind) / 'brief.md'
        out = brief.read_text()
        assert '# Captain rules' in out and 'Keep answers short.' in out
        assert all(f'Parallel correction {i}.' in out for i in range(5))
        shutil.copyfile(brief, evidence / (kind + '-brief.md'))
    cmd('fm-rules.sh', 'revoke', 'short-replies')
    assert 'Keep answers short.' not in cmd('fm-rules.sh', 'render')
    cmd('fm-brief.sh', 'validation-after-revoke', 'validation-project', '--scout')
    after = (home / 'data/validation-after-revoke/brief.md').read_text()
    assert 'Keep answers short.' not in after
    shutil.copyfile(home / 'config/captain-rules.md', evidence / 'persisted-rules.md')

    bad = [
        '! sudo darwin-rebuild switch',
        'no worries, run ! sudo darwin-rebuild switch',
        'never again - ! sudo x',
        'never again – ! sudo x',
        'never again — ! sudo x',
        'No worries run ! sudo -v',
        'Not only run ! sudo -v',
        'Never use the old command; run `! sudo -v` instead.',
        'Run this: `! gh auth login`',
        '! op signin', '! security add-generic-password -s x',
        '! passwd', '! ~/dotfiles/rebuild.sh',
    ]
    good = [
        'Never hand the captain a `! sudo` line.',
        'Use pbcopy, not ! sudo.',
        'Nie wieder `! gh auth login` schicken.',
        'Use pbcopy instead of ! gh auth login.',
        '! git status', 'Done! sudo is no longer needed.',
        'Paste sudo darwin-rebuild switch into a real Terminal window.',
    ]
    for text in bad:
        assert 'bang-interactive:' in cmd('fm-rule-guard.sh', 'scan', text=text+'\n', expected=1)
    for text in good:
        assert not cmd('fm-rule-guard.sh', 'scan', text=text+'\n')

    # The actual gate checkout must stand down even with isolated home state.
    assert not cmd('fm-rules.sh', 'session', text='{"source":"compact"}')
    assert not cmd('fm-rules.sh', 'prompt-hook', text=json.dumps({'prompt':'Ab jetzt nie wieder lange Antworten.'}))
    assert not cmd('fm-rule-guard.sh', '--claude', text=json.dumps({'session_id':'gate-proof', 'last_assistant_message':'never again - ! sudo x', 'stop_hook_active':False}))
    assert not (home / 'state/captain-rules/candidates').exists()
    assert not (home / 'state/captain-rules/guard-blocks').exists()

    due = cmd('fm-rules.sh', 'weekly-check')
    assert 'weekly report due' in due
    assert not cmd('fm-rules.sh', 'weekly-check')
    report = cmd('fm-rules.sh', 'report', '--transcripts', str(home / 'empty-transcripts'))
    assert 'short-replies: recorded again 1 time(s)' in report
    assert 'no-bang' not in report  # Not a repeated correction.
    (evidence / 'weekly-report.md').write_text(report)
    assert not cmd('fm-rules.sh', 'weekly-check')
    cmd('fm-rules.sh', 'weekly-arm')
    shim = home / 'state/captain-rules-weekly.check.sh'
    p = subprocess.run([str(shim)], env=env, capture_output=True, text=True, timeout=30)
    records.append(dict(command='isolated-home/state/captain-rules-weekly.check.sh', exit=p.returncode, stdout=p.stdout, stderr=p.stderr))
    assert p.returncode == 0 and not p.stdout
    cmd('fm-rules.sh', 'weekly-disarm')
    assert not shim.exists()
    (evidence / 'cli-result.txt').write_text('Candidate cf950172f075498f2eed5f7deab0ef16e22ce0b8: direct CLI checks completed. Rules persist across processes, concurrent writes survive, invalid and over-budget writes leave state unchanged, ship/scout briefs carry the rules, revocation updates new briefs, guard scan rejects adversarial handovers and permits quoted prohibitions, gate hooks stand down, report/reminder arm/disarm works. No real agent session was launched.\n')
finally:
    (evidence / 'cli-transcript.json').write_text(json.dumps(records, ensure_ascii=False, indent=2) + '\n')
