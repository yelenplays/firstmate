#!/usr/bin/env python3
"""Drive real Firstmate CLI commands in a disposable worktree-local home; no shims."""
import html
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile

root = Path.cwd()
evidence = Path('/Users/yelen/.no-mistakes/evidence/01M5F6QX9TE6QXV066J3EK4DEC')
lab = Path(tempfile.mkdtemp(prefix='.board-live-', dir=root))
env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'HERDR_')) and k not in ('TMUX', 'TMUX_PANE')}
env['FM_HOME'] = str(lab)
transcript = []
lock = None

def run(*args, extra=None, timeout=100):
    command = [str(root / args[0]), *args[1:]]
    transcript.append('$ ' + ' '.join(args))
    result = subprocess.run(command, cwd=root, env=env | (extra or {}), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    transcript.append(result.stdout)
    transcript.append(f'exit: {result.returncode}\n')
    if result.returncode:
        raise RuntimeError(f'{args[0]} returned {result.returncode}: {result.stdout}')
    return result.stdout

try:
    run('bin/fm-lab-home.sh', 'create', str(lab))
    run('bin/fm-tasks-axi.sh', 'add', 'board-work', 'Review export behavior', '--kind', 'ship', '--repo', 'sample')
    run('bin/fm-captain-hold.sh', 'hold', 'board-choice', '--title', 'Choose export format', '--reason', 'Choose JSON or CSV')
    run('bin/fm-tasks-axi.sh', 'add', 'board-finished', 'Completed lab preparation', '--kind', 'docs', '--repo', 'sample')
    run('bin/fm-tasks-axi.sh', 'done', 'board-finished')
    first = run('bin/fm-board.sh', '--all', '--home-only')
    (evidence / 'board-before.txt').write_text(first)
    one = json.loads(run('bin/fm-board.sh', '--json', '--home-only'))
    two = json.loads(run('bin/fm-board.sh', '--json', '--home-only'))
    assert one['groups'] == two['groups'], 'Board changed between reads with no input'
    assert one['groups']['needs_you'][0]['id'] == 'board-choice'
    assert one['groups']['queued'][0]['id'] == 'board-work'
    assert one['counts']['done'] == 1
    decision = lab / 'decision.txt'
    decision.write_text('Use JSON for the export.\n')
    run('bin/fm-captain-hold.sh', 'answer', 'board-choice', '--decision-file', str(decision))
    final = run('bin/fm-board.sh', '--all', '--home-only')
    (evidence / 'board-after.txt').write_text(final)
    final_json = json.loads(run('bin/fm-board.sh', '--json', '--home-only'))
    assert final_json['counts']['needs_you'] == 0
    assert final_json['counts']['done'] == 2
    digest = run('bin/fm-session-start.sh', '--reemit', '--full', timeout=150)
    (evidence / 'session-digest.txt').write_text(digest)
    assert 'Board (bin/fm-board.sh' in digest
    assert digest.index('Board (bin/fm-board.sh') < digest.index('Work under way')
    board_block = digest[digest.index('Board (bin/fm-board.sh'):digest.index('Work under way')]
    assert 'board-work' in board_block
    assert '2 done' in board_block
    assert 'board-finished' not in board_block
    assert 'board-choice' not in board_block
    assert '●  STARTUP TRUNCATED' not in digest

    # Hold the real publication lock in an owned process, provoking real writer
    # deadlines rather than seeding an artificial error log.
    lock = subprocess.Popen(['bash', '-c', '. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"; printf "held\\n"; sleep 120', '_', str(root), str(lab)], cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    assert lock.stdout.readline().strip() == 'held'
    for _ in range(2):
        run('bin/fm-home-summary-refresh.sh', '--best-effort', extra={'FM_HOME_SUMMARY_TIMEOUT': '2'})
    before = run('bin/fm-bootstrap.sh', extra={'FM_BOOTSTRAP_DETECT_ONLY': '1', 'FM_BOOTSTRAP_NETWORK': 'skip'})
    assert 'HOME_SUMMARY:' in before and '2 failed attempt(s)' in before
    os.killpg(lock.pid, signal.SIGKILL)
    lock.wait()
    lock = None
    run('bin/fm-home-summary-refresh.sh', '--best-effort', extra={'FM_HOME_SUMMARY_IF_IDLE': '1'})
    ledger = json.loads((lab / 'state/home-summary.json').read_text())
    assert ledger['schema'] == 'fm-secondmate-home-summary.v1'
    assert ledger['home'] == str(lab)
    after = run('bin/fm-bootstrap.sh', extra={'FM_BOOTSTRAP_DETECT_ONLY': '1', 'FM_BOOTSTRAP_NETWORK': 'skip'})
    assert 'HOME_SUMMARY:' not in after
    (evidence / 'published-summary.json').write_text(json.dumps(ledger, indent=2) + '\n')
    (evidence / 'publication-recovery.txt').write_text('Before recovery:\n' + '\n'.join(x for x in before.splitlines() if 'HOME_SUMMARY:' in x) + '\n\nAfter terminating the exact lock owner and calling fm-home-summary-refresh.sh --best-effort with FM_HOME_SUMMARY_IF_IDLE=1:\n' + json.dumps({'schema': ledger['schema'], 'counts': ledger['counts'], 'board': ledger['board']}, indent=2) + '\nBootstrap no longer emits HOME_SUMMARY diagnostics.\n')
    page = '<!doctype html><meta charset="utf-8"><title>Firstmate live CLI board</title><style>body{background:#16191e;color:#e7ecf1;font:16px/1.65 monospace;padding:32px}pre{white-space:pre-wrap}h1,h2{font:inherit;color:#adc4dd}</style><h1>Actual Firstmate CLI output</h1><h2>Before answering</h2><pre>' + html.escape(first) + '</pre><h2>After answering through fm-captain-hold.sh</h2><pre>' + html.escape(final) + '</pre><h2>Startup digest board (DONE rows omitted)</h2><pre>' + html.escape(board_block) + '</pre>'
    (evidence / 'board-output.html').write_text(page)
    print('Live public-command checks passed: persistent queued/decision board, answer transition, startup digest ordering and DONE omission, real stalled-publication recovery.')
finally:
    if lock is not None and lock.poll() is None:
        os.killpg(lock.pid, signal.SIGKILL)
        lock.wait()
    (evidence / 'live-cli-transcript.txt').write_text('\n'.join(transcript))
    import shutil
    shutil.rmtree(lab)
