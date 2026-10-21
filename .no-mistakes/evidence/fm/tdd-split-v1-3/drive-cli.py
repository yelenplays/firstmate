#!/usr/bin/env python3
"""Manual product CLI checks, no mocked executable or agent. Fixtures stay in the worktree."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5G9280W309SJ4NPFZERASXA')
EVIDENCE = Path('/Users/yelen/.no-mistakes/evidence/01M5G9280W309SJ4NPFZERASXA')
WORK = ROOT / '.local-validation' / 'manual'
WORK.mkdir(parents=True, exist_ok=False)
ENV = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'GIT_'))}
ENV.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='Lab', GIT_AUTHOR_EMAIL='lab@example.invalid',
           GIT_COMMITTER_NAME='Lab', GIT_COMMITTER_EMAIL='lab@example.invalid',
           TMPDIR=str(ROOT / '.local-validation' / 'tmp'))
TRANSCRIPT = []
RESULTS = []

def call(args, env=None, expected=0, show=True):
    result = subprocess.run([str(a) for a in args], cwd=ROOT,
                            env=env or ENV, capture_output=True, text=True, timeout=30)
    if show:
        TRANSCRIPT.append('$ ' + ' '.join(str(a) for a in args))
        TRANSCRIPT.append(result.stdout + result.stderr + f'[exit {result.returncode}]\n')
    if expected is not None:
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result

def git(wt, *args):
    return call(['git', '-C', wt, *args], show=False).stdout.strip()

def commit(wt, path, body, message='lab change'):
    dest = wt / path
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(body)
    git(wt, 'add', '--', path)
    git(wt, 'commit', '-q', '-m', message)
    return git(wt, 'rev-parse', 'HEAD')

def new_case(name, command='for t; do bash "$t" || exit 1; done'):
    home = WORK / name
    call(['bash', ROOT / 'bin/fm-lab-home.sh', 'create', home], show=False)
    wt = home / 'projects' / 'sample'
    wt.mkdir()
    git(wt, 'init', '-q', '--initial-branch=main')
    base = commit(wt, 'feature.sh', 'printf "old\\n"\n', 'base')
    git(wt, 'update-ref', 'refs/remotes/origin/main', base)
    git(wt, 'checkout', '-qb', 'fm/trial')
    data = home / 'data' / 'trial'
    data.mkdir()
    (data / 'brief.md').write_text('# Trial\n\nFail-to-pass command: `' + command + '`\n')
    env = ENV | {'FM_HOME':str(home), 'NM_HOME':str(home / 'nm')}
    meta = home / 'state' / 'trial.meta'
    fields = {'kind':'ship', 'mode':'no-mistakes', 'project':str(wt), 'worktree':str(wt),
              'base_branch':'main', 'branch':'fm/trial', 'harness':'claude',
              'model':'claude-opus-5-5', 'effort':'medium', 'tdd_split':'tests',
              'tdd_split_impl_harness':'claude', 'tdd_split_impl_model':'claude-sonnet-5-5',
              'tdd_split_impl_effort':'medium', 'spawn_gen':'s1.1.lab'}
    def update(**changes):
        fields.update(changes)
        meta.write_text(''.join(k+'='+v+'\n' for k,v in fields.items()))
    update()
    def report(line):
        (home / 'state' / 'trial.status').write_text(line+'\n')
    def tdd(subcommand, expected=1, binary=None, *extra):
        return call(['bash', binary or ROOT / 'bin/fm-tdd-split.sh', subcommand, 'trial', *extra], env, expected)
    return home, wt, data, env, fields, update, report, tdd

def scenario(name):
    TRANSCRIPT.append('\n=== ' + name + ' ===\n')
    RESULTS.append({'name':name, 'result':'pass'})

try:
    scenario('Reject a handoff whose tests are already green, cannot execute, or time out')
    for name, command, body, expected_message, extra in [
        ('green', 'for t; do bash "$t" || exit 1; done', 'bash feature.sh | grep -qx old\n', 'pass on the base', []),
        ('missing-tool', 'fm-definitely-missing-red-command "$@"', 'exit 1\n', 'could not run (exit 127)', []),
        ('timeout', 'sleep 4', 'exit 1\n', 'hit its 1s bound', ['--timeout','1']),
    ]:
        home, wt, data, env, fields, update, report, tdd = new_case(name, command)
        commit(wt, 'tests/feature.test.sh', body)
        report('done: tests-ready ' + git(wt, 'rev-parse', 'HEAD'))
        out = tdd('handoff', 1, None, *extra)
        assert expected_message in out.stderr
        assert 'tdd_split=tests\n' in (home/'state/trial.meta').read_text()
        log = data / 'tdd-split-red.log'
        TRANSCRIPT.append(log.read_text())

    scenario('Reject a test seat that changes production code or leaves tests uncommitted')
    home, wt, data, env, fields, update, report, tdd = new_case('seat-production')
    commit(wt, 'tests/feature.test.sh', 'bash feature.sh | grep -qx new\n')
    commit(wt, 'feature.sh', 'printf "new\\n"\n')
    report('done: tests-ready')
    assert 'not tests: feature.sh' in tdd('handoff').stderr
    home, wt, data, env, fields, update, report, tdd = new_case('seat-dirty')
    commit(wt, 'tests/feature.test.sh', 'exit 1\n')
    (wt/'tests/feature.test.sh').write_text('exit 2\n')
    report('done: tests-ready')
    assert 'uncommitted changes' in tdd('handoff').stderr

    scenario('Run mutation on implemented HEAD with locked tests as exact arguments in a private clone')
    home, wt, data, env, fields, update, report, tdd = new_case('mutation-pass')
    seat = commit(wt, 'tests/feature with spaces.test.sh', 'bash feature.sh | grep -qx new\n')
    commit(wt, 'feature.sh', 'printf "new\\n"\n')
    update(tdd_split='implement', model='claude-sonnet-5-5', test_ban_model='claude-sonnet-5-5', test_ban_since=seat)
    report('done: implementation ready')
    with (data/'brief.md').open('a') as f:
        f.write('Mutation command: `printf "argc=%s test=%s\\n" "$#" "$1"; [ "$#" = 1 ] && [ "$1" = "tests/feature with spaces.test.sh" ] && bash "$1" && touch clone-only-side-effect`\n')
    tdd('mutation', 0)
    TRANSCRIPT.append((data/'tdd-split-mutation.log').read_text())
    assert not (wt/'clone-only-side-effect').exists()
    assert not git(wt, 'status', '--porcelain')
    TRANSCRIPT.append('Observed worker copy unchanged; mutation side effect stayed in the disposable clone.\n')

    scenario('Refuse mutation on an unreadable base, unrelated history, or zero remaining tests; reproduce before fix')
    oldbin = WORK / 'before-fix' / 'bin'
    oldbin.mkdir(parents=True)
    for source in (ROOT/'bin').iterdir():
        if source.name != 'fm-tdd-split.sh':
            (oldbin/source.name).symlink_to(source)
    prior = call(['git','show','ca9ec295^:bin/fm-tdd-split.sh'], show=False).stdout
    (oldbin/'fm-tdd-split.sh').write_text(prior)
    for name in ['missing-base','unrelated-base','empty-tests','deleted-tests']:
        home, wt, data, env, fields, update, report, tdd = new_case(name)
        if name != 'empty-tests':
            commit(wt, 'tests/feature.test.sh', 'bash feature.sh | grep -qx new\n')
        if name == 'deleted-tests':
            git(wt, 'rm', '-q', 'tests/feature.test.sh')
            git(wt, 'commit', '-qm', 'remove the only test')
        if name == 'missing-base':
            update(base_branch='unavailable')
        if name == 'unrelated-base':
            tree = git(wt, 'rev-parse', 'HEAD^{tree}')
            detached = git(wt, 'commit-tree', tree, '-m', 'unrelated root')
            git(wt, 'update-ref', 'refs/remotes/origin/main', detached)
        update(tdd_split='implement')
        report('done: implementation ready')
        marker = home / 'mutation-was-executed'
        with (data/'brief.md').open('a') as f:
            f.write('Mutation command: `printf "mutation executed with argc=%s\\n" "$#"; touch "'+str(marker)+'"`\n')
        TRANSCRIPT.append('BEFORE FIX: '+name+'\n')
        tdd('mutation', 0, oldbin/'fm-tdd-split.sh')
        assert marker.exists()
        TRANSCRIPT.append((data/'tdd-split-mutation.log').read_text())
        marker.unlink()
        (data/'tdd-split-mutation.log').unlink()
        TRANSCRIPT.append('TARGET: '+name+'\n')
        out = tdd('mutation', 1)
        expected = ('cannot resolve the base branch' if name == 'missing-base' else
                    'no merge-base' if name == 'unrelated-base' else 'leave no test file')
        assert expected in out.stderr
        assert not marker.exists()
        assert not (data/'tdd-split-mutation.log').exists()
        assert 'tdd_split=implement\n' in (home/'state/trial.meta').read_text()
        TRANSCRIPT.append('Observed command not executed; phase unchanged.\n')
        if name in ['missing-base','unrelated-base']:
            update(tdd_split='tests')
            report('done: tests-ready')
            assert ('base branch' if name == 'missing-base' else 'merge-base') in tdd('handoff').stderr

    scenario('DeepSeek, GLM, and Sonnet cannot change or delete handed-over tests or add their own tests')
    for model in ['opencode-go/deepseek-v4.1-flash','zhipu/glm-5.2','claude-sonnet-5-5']:
        for change in ['edit','delete','add','e2e-edit']:
            name = 'lock-' + model.split('/')[-1] + '-' + change
            home, wt, data, env, fields, update, report, tdd = new_case(name)
            path = 'tests/feature.e2e.sh' if change == 'e2e-edit' else 'tests/feature.test.sh'
            seat = commit(wt, path, 'bash feature.sh | grep -qx new\n')
            commit(wt, 'feature.sh', 'printf "new\\n"\n')
            if change == 'delete':
                git(wt, 'rm', '-q', path)
                git(wt, 'commit', '-qm', 'delete handed-over test')
            else:
                commit(wt, 'tests/self-authored.test.sh' if change == 'add' else path, 'exit 0\n')
            update(tdd_split='implement', model=model, test_ban_model=model, test_ban_since=seat)
            report('blocked [key=test-dispute]: '+path+': too strict')
            out = tdd('dispute')
            assert 'no test authoring on '+model in out.stderr
            assert ('tests/self-authored.test.sh' if change == 'add' else path) in out.stderr
            assert 'tdd_split=implement\n' in (home/'state/trial.meta').read_text()

    scenario('Count distinct failed Sonnet rounds, request Opus at round two, never escalate an unknown strong model down')
    for model in ['claude-sonnet-5-5', 'gemini-3.5-pro']:
        home, wt, data, env, fields, update, report, tdd = new_case('rounds-'+model)
        update(tdd_split='implement', model=model)
        commit(wt, 'work.txt', 'first attempt\n')
        def escalate(sub, *args, expected=0):
            return call(['bash',ROOT/'bin/fm-escalate.sh',sub,'trial',*args], env, expected)
        out = escalate('record-failure', '--reason', 'review rejected first attempt')
        assert 'failed_rounds=1\n' in out.stdout and 'action=none\n' in out.stdout
        out = escalate('record-failure', '--reason', 'same failed head again')
        assert 'failed_rounds=1\n' in out.stdout
        commit(wt, 'work.txt', 'second attempt\n')
        out = escalate('record-failure', '--reason', 'review rejected second attempt')
        assert 'failed_rounds=2\n' in out.stdout and 'next_model=claude-opus-5-5\n' in out.stdout
        update(model='claude-opus-5-5')
        out = escalate('run', expected=3)
        assert 'action=captain\n' in out.stdout

except Exception:
    if RESULTS:
        RESULTS[-1]['result'] = 'fail'
    raise
finally:
    (EVIDENCE/'cli-transcript.txt').write_text('\n'.join(TRANSCRIPT))
    (EVIDENCE/'cli-results.json').write_text(json.dumps(RESULTS, indent=2)+'\n')
    shutil.rmtree(WORK)
    print('\n'.join(TRANSCRIPT))
