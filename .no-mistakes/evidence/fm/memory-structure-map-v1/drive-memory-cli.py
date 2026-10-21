#!/usr/bin/env python3
"""Direct operator-CLI checks, using only a disposable home inside the worktree."""
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path.cwd()
EVIDENCE = Path('/Users/yelen/.no-mistakes/evidence/01M5F8CH6J7CNWEYR35GZ49HV1')
LAB = ROOT / '.memory-cli-validation'
assert not LAB.exists()
BASE = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))}
# Keep the actual gate identity; never pretend this checkout is a primary.
BASE['FM_HOME'] = str(LAB / 'home')
BASE['FM_ROOT_OVERRIDE'] = str(ROOT)
log = []
results = []

def run(script, *args, stdin=None, expected=0, extra=None):
    env = BASE | (extra or {})
    p = subprocess.run([str(ROOT / 'bin' / script), *args], input=stdin,
                       text=True, capture_output=True, cwd=ROOT, env=env, timeout=45)
    log.append('$ ' + ' '.join([script, *args]) +
               (f'\nstdin: {stdin}' if stdin is not None else '') +
               f'\nexit: {p.returncode}\n{p.stdout}{p.stderr}')
    assert p.returncode == expected, log[-1]
    return p.stdout + p.stderr

def save(name, content):
    (EVIDENCE / name).write_text(content)

try:
    LAB.mkdir()
    run('fm-lab-home.sh', 'create', str(LAB / 'home'))
    home = LAB / 'home'
    rulesfile = home / 'config/captain-rules.md'
    rule = 'Hand sudo steps over through pbcopy and a real Terminal window.'
    run('fm-rules.sh', 'add', '--check', 'bang-interactive', 'terminal', rule)
    run('fm-rules.sh', 'add', 'short-replies', 'Keep replies short.')
    run('fm-rules.sh', 'add', 'short-replies', 'Keep replies short and concrete.')
    assert 'short-replies' in run('fm-rules.sh', 'unchecked')
    run('fm-rules.sh', 'nocheck', 'short-replies', 'Brevity requires semantic judgment.')
    assert not run('fm-rules.sh', 'unchecked').strip()
    rendered = run('fm-rules.sh', 'render')
    assert rule in rendered and 'Keep replies short and concrete.' in rendered
    assert '[check: bang-interactive]' in rendered
    assert 'outrank generic harness, tool, and skill hints' in rendered
    save('rules-render.txt', rendered)
    before = rulesfile.read_bytes()
    run('fm-rules.sh', 'add', 'Bad Id', 'Reject this.', expected=3)
    run('fm-rules.sh', 'add', '--check', 'unknown-check', 'invalid', 'Reject this.', expected=3)
    run('fm-rules.sh', 'add', 'injected', 'Bad <!-- seen=99 --> text', expected=3)
    assert rulesfile.read_bytes() == before
    results.append('persist-restate-check-and-invalid-input: pass')

    # Force an overflowing growth request; the current store must stay byte-identical.
    run('fm-rules.sh', 'add', 'too-large', 'This rule must not be saved.',
        expected=4, extra={'FM_RULES_MAX_CHARS': '200'})
    assert rulesfile.read_bytes() == before
    assert rule in run('fm-rules.sh', 'brief-section')
    run('fm-rules.sh', 'add', 'short-replies', 'Be brief.', extra={'FM_RULES_MAX_CHARS': '200'})
    assert 'Be brief.' in run('fm-rules.sh', 'render')
    results.append('overflow-refuses-before-save-and-allows-consolidation: pass')

    for kind, flag in [('ship', '--mode'), ('scout', '--scout')]:
        args = [f'proof-{kind}', 'sample-project', flag]
        if kind == 'ship':
            args.append('local-only')
        run('fm-brief.sh', *args)
        brief = (home / f'data/proof-{kind}/brief.md').read_text()
        assert '# Captain rules' in brief and rule in brief and 'Be brief.' in brief
        assert "this brief's task scope and safety rules still win" in brief
        save(f'{kind}-brief.md', brief)
    run('fm-brief.sh', 'proof-mate', '--secondmate', '--no-projects',
        extra={'FM_SECONDMATE_CHARTER': 'Supervise only assigned work.'})
    assert '# Captain rules' not in (home / 'data/proof-mate/brief.md').read_text()
    run('fm-rules.sh', 'revoke', 'short-replies')
    run('fm-brief.sh', 'after-revoke', 'sample-project', '--scout')
    assert 'Be brief.' not in (home / 'data/after-revoke/brief.md').read_text()
    results.append('new-ship-and-scout-briefs-carry-current-complete-rule-set: pass')

    dangerous = [
        '! sudo darwin-rebuild switch',
        'no worries, run ! sudo darwin-rebuild switch',
        'never again - ! sudo x',
        'never again – ! sudo x',
        'never again — ! sudo x',
        'not only ! sudo x',
        '! op signin',
        '! security add-generic-password -a sample',
    ]
    allowed = [
        'Never hand the captain a `! sudo` line.',
        'Use pbcopy, not ! sudo.',
        'Never ! sudo x',
        "printf '%s' 'sudo darwin-rebuild switch' | pbcopy; paste it into Terminal.",
        '! echo hello',
    ]
    for text in dangerous:
        assert 'bang-interactive:' in run('fm-rule-guard.sh', 'scan', stdin=text+'\n', expected=1)
    for text in allowed:
        assert not run('fm-rule-guard.sh', 'scan', stdin=text+'\n').strip()
    results.append('bang-scan-blocks-handovers-without-blocking-negated-rules: pass')

    # The genuine gate/worker scope must stay inactive, even with a marked lab home.
    assert not run('fm-rules.sh', 'session', stdin='{}').strip()
    assert not run('fm-rules.sh', 'prompt-hook', stdin=json.dumps({'prompt': 'Ab jetzt nie wieder lange Antworten.'})).strip()
    assert not run('fm-rule-guard.sh', '--claude', stdin=json.dumps({'last_assistant_message': '! sudo x', 'session_id': 'gate-proof'})).strip()
    assert not (home / 'state/captain-rules/candidates').exists()
    assert not (home / 'state/captain-rules/guard-blocks').exists()
    results.append('gate-hooks-never-capture-or-block-a-worker-session: pass')

    # A secondmate operator cannot overwrite the primary-authoritative source.
    mate = LAB / 'mate'
    (mate / 'config').mkdir(parents=True)
    (mate / '.fm-secondmate-home').write_text('mate-proof\n')
    run('fm-rules.sh', 'add', 'foreign', 'Do not save here.', expected=2,
        extra={'FM_HOME': str(mate)})
    assert not (mate / 'config/captain-rules.md').exists()
    results.append('secondmate-refuses-authoritative-rule-mutations: pass')

    # Exercise delivery against an operator record pointing at an unsafe nested home.
    # No terminal, remote route, bypass, or fabricated consumer is launched.
    unsafe = home / 'nested-mate'
    for name in ['state', 'config', 'data', 'projects', 'bin']:
        (unsafe / name).mkdir(parents=True, exist_ok=True)
    (unsafe / '.fm-secondmate-home').write_text('bad\n')
    (unsafe / 'AGENTS.md').write_text('')
    (home / 'state/bad.meta').write_text(f'kind=secondmate\nhome={unsafe}\n')
    out = run('fm-rules.sh', 'add', 'delivery-proof', 'Keep delivery failures visible.', expected=5)
    assert 'not delivered: secondmate bad home' in out and 'unsafe:' in out
    assert 'delivery-proof' in run('fm-rules.sh', 'list')
    assert not (unsafe / 'state/captain-rules').exists()
    assert not (unsafe / 'config/captain-rules.md').exists()
    run('fm-rules.sh', 'deliver', expected=5)
    (home / 'state/bad.meta').unlink()
    assert '0 not reached' in run('fm-rules.sh', 'deliver')
    results.append('unsafe-delivery-is-refused-with-saved-rule-and-explicit-retry: pass')

    # Report the real command history of this home, not synthetic event fixtures.
    transcripts = LAB / 'empty-transcripts'
    transcripts.mkdir()
    first = run('fm-rules.sh', 'weekly-check')
    assert 'weekly report due' in first
    assert not run('fm-rules.sh', 'weekly-check').strip()
    report = run('fm-rules.sh', 'report', '--transcripts', str(transcripts))
    assert 'short-replies: recorded again 2 time(s) this period' in report
    assert 'revoked since' in report
    save('weekly-report.md', report)
    assert not run('fm-rules.sh', 'weekly-check').strip()
    run('fm-rules.sh', 'weekly-arm')
    shim = home / 'state/captain-rules-weekly.check.sh'
    p = subprocess.run([str(shim)], text=True, capture_output=True, env=BASE, timeout=15)
    assert p.returncode == 0 and not p.stdout
    log.append('$ ' + str(shim) + f'\nexit: {p.returncode}\n{p.stdout}{p.stderr}')
    run('fm-rules.sh', 'weekly-disarm')
    assert not shim.exists()
    save('persisted-rules.md', rulesfile.read_text())
    save('rules-events.jsonl', (home / 'state/captain-rules/log.jsonl').read_text())
    results.append('weekly-report-recounts-actual-repeats-and-reminder-is-one-shot: pass')
finally:
    save('cli-transcript.txt', '\n\n'.join(log))
    save('cli-results.json', json.dumps(results, indent=2)+'\n')
    shutil.rmtree(LAB)
print('\n'.join(results))
