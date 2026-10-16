"""Drive real Firstmate CLI interfaces; no dependency stubs or LLM calls."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path.cwd()
assert str(root) == '/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M52HMW2AFHNV6F4XCFK7W19G'
base = Path(tempfile.mkdtemp(prefix='cli-proof-', dir=root / '.test-tmp'))
env = dict(os.environ)
for key in tuple(env):
    if key.startswith('FM_') or key in ('NM_HOME', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
        env.pop(key)
env.update(TMPDIR=str(root / '.test-tmp'), NM_HOME=str(base / 'no-nm'))

def run(*argv):
    print('$', ' '.join(map(str, argv)), flush=True)
    completed = subprocess.run(list(map(str, argv)), env=env, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, timeout=60)
    print(completed.stdout, end='', flush=True)
    print('exit:', completed.returncode, flush=True)
    completed.check_returncode()
    return completed.stdout

try:
    home = base / 'home'
    run(root / 'bin/fm-lab-home.sh', 'create', home)
    env['FM_HOME'] = str(home)
    project = base / 'project'
    project.mkdir()
    run('git', '-C', project, 'init', '-q', '-b', 'main')
    (project / 'change.txt').write_text('base\n')
    run('git', '-C', project, 'add', 'change.txt')
    run('git', '-C', project, '-c', 'user.name=CLI validation', '-c', 'user.email=test@example.invalid',
        'commit', '-qm', 'base')
    run('git', '-C', project, 'checkout', '-qb', 'fm/cli-task')
    (project / 'change.txt').write_text('changed\n')
    run('git', '-C', project, '-c', 'user.name=CLI validation', '-c', 'user.email=test@example.invalid',
        'commit', '-qam', 'change')
    head = run('git', '-C', project, 'rev-parse', 'HEAD').strip()
    (home / 'data/cli-task').mkdir()
    meta = home / 'state/cli-task.meta'
    meta.write_text('kind=ship\nharness=codex\nmodel=gpt-6.1-sol\neffort=high\n'
                    'ai_family=openai\nai_family_source=Codex native model\nmode=local-only\n'
                    'branch=fm/cli-task\nspawn_gen=cli-proof-g1\nredispatches=2\n'
                    'account=ordinary\naccount_provider=codex\n'
                    f'project={project}\nworktree={project}\n')
    plan = run(root / 'bin/fm-cross-review.sh', 'plan', 'cli-task', '--head', head)
    fields = dict(line.split('=', 1) for line in plan.splitlines() if '=' in line)
    assert fields['action'] == 'spawn-reviewer', fields
    assert fields['reviewer_harness'] == 'claude', fields
    assert fields['reviewer_model'] == 'claude-opus-5-5', fields
    assert fields['reviewer_effort'] == 'medium', fields
    print('Persisted review profile:', (home / 'data/cli-task/cross-review-model.json').read_text())
    (home / 'state/cli-task.status').write_text(
        'needs-decision [at=1]: PRIVATE-DECISION\nblocked [at=2]: PRIVATE-BLOCKER\n'
        'resolved [at=3]: PRIVATE-ANSWER\ndone [at=4]: PRIVATE-OUTCOME\n')
    ledger = home / 'data/model-ledger.jsonl'
    history = b'{"task":"historical","spawn_gen":"old"}\n[1]\n\xffbad\n{"partial":'
    ledger.write_bytes(history)
    for attempt in (1, 2):
        run('python3', root / 'bin/fm-model-ledger.py', '--state', home / 'state',
            '--data', home / 'data', 'cli-task')
    valid = []
    for line in ledger.read_bytes().splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            valid.append(row)
    assert [row['task'] for row in valid] == ['historical', 'cli-task'], valid
    row = valid[-1]
    assert row['final_state'] == 'done' and row['needs_decision_count'] == row['blocked_count'] == 1, row
    assert row['redispatches'] == 2 and row['pool'] == 'ordinary', row
    assert row['claude_eq_tokens'] is None and row['pipeline_review_rounds'] is None, row
    text = json.dumps(row)
    assert 'PRIVATE-' not in text and str(base) not in text, row
    assert ledger.read_bytes().startswith(history + b'\n')
    print('Persisted outcome after two append attempts:', json.dumps(row, sort_keys=True))
    print('Historical row retained; malformed lines ignored; unterminated tail separated; one new row; no private text.')
finally:
    shutil.rmtree(base)
    print('Disposable CLI home and project removed.')
