"""Drive the real terminal-outcome publisher; no CLI, Git, or backend mocks.
Run from the gate worktree. All disposable product homes/repos stay under .test-phase.
"""
import json
import os
from pathlib import Path
import subprocess

root = Path.cwd()
world = root / '.test-phase' / 'live'
world.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'GIT_')) or key in ('NM_HOME', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
        env.pop(key, None)
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='Validation', GIT_AUTHOR_EMAIL='validation@example.invalid',
           GIT_COMMITTER_NAME='Validation', GIT_COMMITTER_EMAIL='validation@example.invalid',
           TMPDIR=str(root / '.test-phase' / 'tmp'))

def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], env=kwargs.pop('env', env),
                          text=True, capture_output=True, check=True, **kwargs).stdout.strip()

parent = world / 'parent'
mate = world / 'mate'
for home in (parent, mate):
    print('$ bin/fm-lab-home.sh create', home)
    print(run([root / 'bin/fm-lab-home.sh', 'create', home]))
(mate / '.fm-secondmate-home').write_text('validation-mate\n')
(mate / '.fm-secondmate-parent').write_text(
    f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={parent}\n')
channel = parent / 'state/validation-mate.status'
product_env = dict(env, FM_HOME=str(mate))

def repo_for(task):
    repo = mate / 'projects' / task
    repo.mkdir()
    run(['git', '-C', repo, 'init', '-q', '-b', 'main'])
    (repo / 'impl.py').write_text('value = 0\n')
    run(['git', '-C', repo, 'add', '.'])
    run(['git', '-C', repo, 'commit', '-qm', 'base'])
    base = run(['git', '-C', repo, 'rev-parse', 'HEAD'])
    run(['git', '-C', repo, 'update-ref', 'refs/remotes/origin/main', base])
    return repo

def commit(repo, message):
    run(['git', '-C', repo, 'add', '-A'])
    run(['git', '-C', repo, 'commit', '-qm', message])
    return run(['git', '-C', repo, 'rev-parse', 'HEAD'])

def meta(task, repo, model, since='', allowed=''):
    fields = [f'worktree={repo}', f'project={repo}', 'kind=ship', 'mode=no-mistakes',
              'yolo=off', f'model={model}', f'spawn_gen={task}']
    if model != 'claude-opus-5-5':
        fields.append(f'test_ban_model={model}')
    if since:
        fields.append(f'test_ban_since={since}')
    if allowed:
        fields.append(f'test_ban_allowed={allowed}')
    (mate / f'state/{task}.meta').write_text('\n'.join(fields) + '\n')

def publish(task, repo, attempt, expected):
    declaration = f'done: {task} {attempt}'
    (mate / f'state/{task}.status').write_text(declaration + '\n')
    before = channel.read_text() if channel.exists() else ''
    head = run(['git', '-C', repo, 'rev-parse', 'HEAD'])
    print(f'\n$ FM_HOME=<isolated-mate> bin/fm-inactive-reconcile.sh report {task}')
    print(f'head={head}; declaration={declaration}')
    print('branch changes: ' + run(['git', '-C', repo, 'diff', '--name-status', 'origin/main', 'HEAD']))
    out = run([root / 'bin/fm-inactive-reconcile.sh', 'report', task], env=product_env)
    if out:
        print(out)
    after = channel.read_text() if channel.exists() else ''
    delivered = after != before
    print('Parent channel append: ' + (after[len(before):].strip() if delivered else '<none>'))
    assert delivered == expected, (task, attempt, delivered, expected)
    if delivered:
        assert declaration.split(': ', 1)[1] in after[len(before):]
    print('Observed: ' + ('completion delivered' if delivered else 'completion withheld'))

results = []
for label, model in [('deepseek', 'opencode/deepseek-v4.1-flash-free'), ('glm', 'zai/glm-5.3-flash')]:
    repo = repo_for(label)
    (repo / 'tests').mkdir()
    test = repo / 'tests/unit.test.py'
    test.write_text('assert True\n')
    commit(repo, 'implementer authors a unit test')
    meta(label, repo, model)
    publish(label, repo, 'unit-test', False)
    run(['git', '-C', repo, 'revert', '--no-edit', 'HEAD'])
    (repo / 'impl.py').write_text('value = 1\n')
    (repo / 'e2e').mkdir()
    (repo / 'e2e/smoke.spec.py').write_text('assert True\n')
    commit(repo, 'implementer changes code and an allowed e2e test')
    publish(label, repo, 'code-and-e2e', True)
    results.append({'scenario': label + '-unit-ban-and-e2e-exemption', 'result': 'pass'})

repo = repo_for('handoff')
(repo / 'tests').mkdir()
test = repo / 'tests/locked.test.py'
test.write_text('assert value == 1\n')
since = commit(repo, 'Opus writes a failing test first')
meta('handoff', repo, 'claude-sonnet-5-5', since=since)
(repo / 'impl.py').write_text('value = 1\n')
commit(repo, 'Sonnet implements without changing inherited tests')
publish('handoff', repo, 'implementation-only', True)
for action in ('modify', 'delete', 'rename'):
    if action == 'modify':
        test.write_text('assert True\n')
    elif action == 'delete':
        test.unlink()
    else:
        test.rename(repo / 'impl-test-disguised.py')
    commit(repo, 'implementer tries to ' + action + ' a locked test')
    publish('handoff', repo, action, False)
    run(['git', '-C', repo, 'revert', '--no-edit', 'HEAD'])
publish('handoff', repo, 'restored', True)
results.append({'scenario': 'inherited-test-lock-modify-delete-rename-and-restore', 'result': 'pass'})

repo = repo_for('captain-exception')
(repo / 'tests').mkdir()
(repo / 'tests/approved.test.py').write_text('assert True\n')
commit(repo, 'author exactly the authorized test')
meta('captain-exception', repo, 'claude-sonnet-5-5', allowed='tests/approved.test.py')
publish('captain-exception', repo, 'authorized', True)
(repo / 'tests/other.test.py').write_text('assert True\n')
commit(repo, 'try to widen permission to an adjacent path')
publish('captain-exception', repo, 'unauthorized-sibling', False)
results.append({'scenario': 'exact-path-exception-does-not-authorize-sibling', 'result': 'pass'})

repo = repo_for('opus')
(repo / 'tests').mkdir()
(repo / 'tests/opus.test.py').write_text('assert True\n')
commit(repo, 'Opus authors tests')
meta('opus', repo, 'claude-opus-5-5')
publish('opus', repo, 'own-tests', True)
results.append({'scenario': 'opus-test-authorship-accepted', 'result': 'pass'})
print('\nRESULTS ' + json.dumps(results))
print('\nPersisted parent channel:\n' + channel.read_text())
