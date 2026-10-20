#!/usr/bin/env python3
"""Drive the production rules CLI, without a test seam, mock, or scope override."""
import concurrent.futures
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5DCW6HK6A3DMX54XM7BNFSH')
EVIDENCE = Path('/Users/yelen/.no-mistakes/evidence/01M5DCW6HK6A3DMX54XM7BNFSH')
transcript = []
results = []

def record(text):
    transcript.append(text)
    print(text, flush=True)

def scenario(name, body):
    record('\n=== ' + name + ' ===')
    try:
        body()
        results.append({'name': name, 'result': 'pass', 'live': True})
    except Exception as exc:
        results.append({'name': name, 'result': 'fail', 'live': True, 'reason': str(exc)})
        raise

with tempfile.TemporaryDirectory(prefix='.fm-rules-live-', dir=ROOT) as tmp:
    lab = Path(tmp)
    (lab / 'tmp').mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))}
    env['TMPDIR'] = str(lab / 'tmp')
    primary, mate = lab / 'primary', lab / 'mate'
    
    def run(args, *, home=primary, data=None, expect=0, extra=None):
        e = dict(env, FM_HOME=str(home))
        if extra:
            e.update(extra)
        argv = [str(x) for x in args]
        proc = subprocess.run(argv, cwd=ROOT, env=e, input=data, text=True, capture_output=True, timeout=40)
        record('$ FM_HOME=' + str(home) + ' ' + shlex.join(argv))
        if data is not None:
            record('stdin: ' + repr(data))
        if proc.stdout:
            record(proc.stdout.rstrip())
        if proc.stderr:
            record('stderr: ' + proc.stderr.rstrip())
        record('exit: ' + str(proc.returncode))
        assert proc.returncode == expect, (argv, expect, proc.returncode, proc.stderr)
        return proc.stdout

    def rules(*args, **kwargs):
        return run(['bin/fm-rules.sh', *args], **kwargs)

    def persist():
        run(['bin/fm-lab-home.sh', 'create', primary])
        assert rules('render') == ''
        rules('add', '--check', 'bang-interactive', 'terminal-only', 'Never hand the captain a ! sudo line; use pbcopy and a real Terminal window.')
        rules('add', 'short-replies', 'Keep replies to two sentences.')
        rules('add', 'short-replies', 'Keep replies to two short sentences.')
        assert 'short-replies\tseen=2' in rules('unchecked')
        assert 'REPEATED WITHOUT A CHECK' in rules('render')
        rules('nocheck', 'short-replies', 'Sentence quality needs judgment; an abbreviation-aware check is not available yet.')
        assert rules('unchecked') == ''
        text = rules('list')  # new process, persistent store rather than conversation memory
        assert 'seen=2 nocheck=' in text and text.count('short-replies') == 1
        rendered = rules('render')
        assert 'two short sentences.' in rendered and '[check: bang-interactive]' in rendered
        (EVIDENCE / 'rules-rendered.txt').write_text(rendered)
        (EVIDENCE / 'rules-store.md').write_bytes((primary / 'config/captain-rules.md').read_bytes())
    
    def concurrent_writes():
        commands = [['bin/fm-rules.sh', 'add', 'parallel-' + str(i), 'Parallel correction ' + str(i) + '.'] for i in range(1, 7)]
        commands += [['bin/fm-rules.sh', 'add', 'short-replies', 'Keep replies to two short sentences.'] for _ in range(3)]
        def invoke(args):
            p = subprocess.run(args, cwd=ROOT, env=dict(env, FM_HOME=str(primary)), text=True, capture_output=True, timeout=40)
            return args, p
        with concurrent.futures.ThreadPoolExecutor(max_workers=9) as pool:
            completed = list(pool.map(invoke, commands))
        for args, p in completed:
            record('$ concurrently: ' + shlex.join(args))
            record(p.stdout.rstrip() + ('\nstderr: ' + p.stderr if p.stderr else '') + '\nexit: ' + str(p.returncode))
            assert p.returncode == 0
        listing = rules('list')
        assert len(listing.splitlines()) == 8 and 'short-replies\tseen=5' in listing
        for i in range(1, 7):
            assert 'parallel-' + str(i) + '\tseen=1' in listing

    def budget():
        home = lab / 'budget'
        run(['bin/fm-lab-home.sh', 'create', home])
        for i in range(20):
            path = home / 'config/captain-rules.md'
            before = path.read_bytes() if path.exists() else None
            before_log = (home / 'state/captain-rules/log.jsonl').read_bytes() if (home / 'state/captain-rules/log.jsonl').exists() else b''
            p = subprocess.run(['bin/fm-rules.sh', 'add', 'rule-' + str(i), ('Keep this full correction in every context. ' * 4) + 'end-' + str(i)], cwd=ROOT, env=dict(env, FM_HOME=str(home), FM_RULES_MAX_CHARS='1000'), text=True, capture_output=True, timeout=40)
            record('$ FM_RULES_MAX_CHARS=1000 bin/fm-rules.sh add rule-' + str(i) + ' <full correction>\n' + p.stdout + p.stderr + 'exit: ' + str(p.returncode))
            if p.returncode == 4:
                assert i >= 2 and path.read_bytes() == before
                assert (home / 'state/captain-rules/log.jsonl').read_bytes() == before_log
                assert 'not saved' in p.stderr and 'consolidate' in p.stderr
                assert 'rule-' + str(i) + '\t' not in rules('list', home=home)
                # The first repeat also adds the unchecked-repeat instruction block;
                # a shorter text alone can still grow the complete projection.
                rules('add', 'rule-0', 'Consolidated rule.', home=home, extra={'FM_RULES_MAX_CHARS': '1000'}, expect=4)
                assert path.read_bytes() == before
                rules('nocheck', 'rule-0', 'This prose-only correction needs judgment.', home=home)
                rules('add', 'rule-0', 'Consolidated rule.', home=home, extra={'FM_RULES_MAX_CHARS': '1000'})
                break
            assert p.returncode == 0
        else:
            raise AssertionError('The write budget was never enforced')
        before = path.read_bytes()
        rules('add', 'Bad Id', 'Bad.', home=home, expect=3)
        rules('add', '--check', 'missing-check', 'bad-check', 'Bad.', home=home, expect=3)
        assert path.read_bytes() == before
        whole = rules('render', home=home, extra={'FM_RULES_MAX_CHARS': '200'})
        assert 'end-1' in whole
        (EVIDENCE / 'budget-rendered.txt').write_text(whole)

    def briefs():
        for kind in ('ship', 'scout'):
            flags = ['--mode', 'no-mistakes'] if kind == 'ship' else ['--scout']
            run(['bin/fm-brief.sh', 'rules-' + kind, 'sample-project', *flags])
            path = primary / 'data' / ('rules-' + kind) / 'brief.md'
            text = path.read_text()
            section = text.split('# Captain rules\n', 1)[1].split('\n# ', 1)[0]
            assert section.count('Parallel correction ') == 6
            assert 'two short sentences.' in section and 'Never hand the captain' in section
            assert "this brief's task scope and safety rules still win" in section
            (EVIDENCE / (kind + '-brief.md')).write_bytes(path.read_bytes())
            record('Generated public contract, # Captain rules (' + kind + '):\n' + section)
        run(['bin/fm-brief.sh', 'rules-charter', '--secondmate', '--no-projects'], extra={'FM_SECONDMATE_CHARTER': 'Supervise assigned work only.'})
        assert '# Captain rules' not in (primary / 'data/rules-charter/brief.md').read_text()

    def inheritance():
        run(['bin/fm-lab-home.sh', 'create', mate])
        (mate / '.fm-secondmate-home').write_text('rules-mate\n')
        command = '. bin/fm-config-inherit-lib.sh; propagate_secondmate_inheritance "$1" "$2"'
        run(['bash', '-c', command, 'inherit-rules', primary, mate])
        assert (primary / 'config/captain-rules.md').read_bytes() == (mate / 'config/captain-rules.md').read_bytes()
        assert 'seen=5' in rules('list', home=mate)
        rules('add', 'rogue-rule', 'Local unauthorized override.', home=mate, expect=2)
        rules('revoke', 'terminal-only')
        run(['bash', '-c', command, 'inherit-rules', primary, mate])
        assert 'terminal-only' not in rules('list', home=mate)
        rules('add', '--check', 'bang-interactive', 'terminal-only', 'Use pbcopy and a real Terminal window for sudo steps.')
        run(['bash', '-c', command, 'inherit-rules', primary, mate])
        assert (primary / 'config/captain-rules.md').read_bytes() == (mate / 'config/captain-rules.md').read_bytes()
        (EVIDENCE / 'secondmate-store.md').write_bytes((mate / 'config/captain-rules.md').read_bytes())

    def scan():
        cases = [
            ('! sudo darwin-rebuild switch', 1),
            ('Run this: `! gh auth login`', 1),
            ('Then: ! ~/dotfiles/rebuild.sh', 1),
            ('(! security add-generic-password -s x)', 1),
            ('> ! op signin', 1),
            ('no worries, run ! sudo darwin-rebuild switch', 1),
            ('No worries now run ! sudo -v', 1),
            ('No worries you can now run ! sudo -v', 1),
            ('Kein Problem: `! sudo -v`', 1),
            ("don't forget ! sudo -v", 1),
            ('Never use the old command; run `! sudo -v` instead.', 1),
            ('Never hand the captain a `! sudo` line.', 0),
            ('Use pbcopy, not ! sudo.', 0),
            ('Never run ! sudo -v', 0),
            ('Do not ever run ! sudo -v', 0),
            ('Use pbcopy instead of ! gh auth login.', 0),
            ('! git status', 0),
            ('sudo darwin-rebuild switch (pasted into Terminal)', 0),
        ]
        for text, rc in cases:
            run(['bin/fm-rule-guard.sh', 'scan'], data=text + '\n', expect=rc)
        run(['bin/fm-rule-guard.sh', 'list'])

    def weekly():
        first = rules('weekly-check')
        assert 'weekly report due' in first
        assert rules('weekly-check') == ''
        # Report real events from these CLI operations, not synthetic logs/transcripts.
        report = rules('report', '--transcripts', lab / 'nonexistent-transcripts')
        assert 'short-replies: recorded again 4 time(s)' in report
        assert 'seen 5 in total, no check by decision' in report
        assert 'Rules: 8 total, 9 added, 4 repeated.' in report
        (EVIDENCE / 'weekly-report.md').write_text(report)
        assert rules('weekly-check') == ''
        rules('weekly-arm')
        shim = primary / 'state/captain-rules-weekly.check.sh'
        assert shim.is_file() and (shim.stat().st_mode & 0o777) == 0o700
        run([shim])
        rules('weekly-disarm')
        assert not shim.exists() and not (primary / 'state/captain-rules-weekly.check-trust').exists()
        events = primary / 'state/captain-rules/log.jsonl'
        (EVIDENCE / 'cli-events.jsonl').write_bytes(events.read_bytes())

    def gate_boundary():
        # Preserve the real gate context. Never set FM_ROOT_OVERRIDE or a bypass.
        before = (primary / 'state/captain-rules/log.jsonl').read_bytes()
        assert rules('session', data='{"source":"startup"}\n') == ''
        assert rules('prompt-hook', data='{"prompt":"ab jetzt nie wieder lange Antworten"}\n') == ''
        assert run(['bin/fm-rule-guard.sh', '--claude'], data='{"last_assistant_message":"! sudo -v","session_id":"gate-test"}\n') == ''
        assert (primary / 'state/captain-rules/log.jsonl').read_bytes() == before
        assert not (primary / 'state/captain-rules/candidates').exists()
        record('Real gate hooks stood down without changing rule events or capturing a correction.')

    try:
        scenario('Save and repeat a correction across CLI processes, then link a check or record a reason', persist)
        scenario('Record simultaneous corrections without losing rules or repeat counts', concurrent_writes)
        scenario('Reject an overflowing or invalid rule without partially changing the store', budget)
        scenario('Scaffold ship and scout briefs with the complete central rule set', briefs)
        scenario('Read the inherited rule copy and refuse a secondmate-local overwrite', inheritance)
        scenario('Reject interactive bang commands despite distant or harmless negation, while allowing genuine warnings', scan)
        scenario('Read a weekly recurrence report and arm a reminder that stays quiet after reporting', weekly)
        scenario('Run hooks from the real gate checkout without capturing corrections or intercepting gate replies', gate_boundary)
    finally:
        (EVIDENCE / 'cli-scenarios.json').write_text(json.dumps(results, indent=2) + '\n')
        (EVIDENCE / 'cli-transcript.log').write_text('\n'.join(transcript) + '\n')

record('\nDisposable CLI homes removed; no source changes were made.')
(EVIDENCE / 'cli-transcript.log').write_text('\n'.join(transcript) + '\n')
