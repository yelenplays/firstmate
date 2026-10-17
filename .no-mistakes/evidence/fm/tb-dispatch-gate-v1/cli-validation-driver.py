import json, os, shutil, subprocess
from pathlib import Path

root = Path.cwd()
base = root / '.local-test'
lab = base / 'manual-home'
project = base / 'manual-project'
evidence = Path('/Users/yelen/.no-mistakes/evidence/01M54YCVS0RQYVBAHB4CQ8TGKR')
env = os.environ.copy()
for key in ['FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_GATE_REFUSE_BYPASS', 'FM_TEST_SEAM', 'FM_AI_FAMILY_PI_CATALOG', 'FM_BACKEND', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND']:
    env.pop(key, None)
env['TMPDIR'] = str(base / 'tmp')
env['FM_HOME'] = str(lab)
env['NM_HOME'] = str(base / 'absent-nm')
env['GIT_CONFIG_GLOBAL'] = '/dev/null'
env['GIT_CONFIG_NOSYSTEM'] = '1'
env['GIT_AUTHOR_NAME'] = env['GIT_COMMITTER_NAME'] = 'CLI validation'
env['GIT_AUTHOR_EMAIL'] = env['GIT_COMMITTER_EMAIL'] = 'test@example.invalid'

def run(*args, check=True, cwd=root):
    p = subprocess.run(args, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
    if check and p.returncode:
        raise RuntimeError((args, p.returncode, p.stdout, p.stderr))
    return p

try:
    run('bin/fm-lab-home.sh', 'create', str(lab))
    project.mkdir()
    run('git', 'init', '-q', '-b', 'main', str(project))
    (project / 'example.txt').write_text('base\n')
    run('git', 'add', 'example.txt', cwd=project)
    run('git', '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'base', cwd=project)
    run('git', 'checkout', '-qb', 'fm/cli-review', cwd=project)
    (project / 'example.txt').write_text('base\nchange\n')
    run('git', '-c', 'core.hooksPath=/dev/null', 'commit', '-qam', 'example change', cwd=project)
    head = run('git', 'rev-parse', 'HEAD', cwd=project).stdout.strip()

    commands = [
        'claude --model claude-opus-5-5 --effort high',
        'claude --model="claude-opus-5-5[1m]" --effort=xhigh',
        'pi --provider anthropic --model claude-opus-5-5 --thinking high',
        'env WORKER=1 claude --model anthropic/claude-opus-5-5 --effort max',
        'echo starting && claude --model claude-opus-5-5 --effort high',
        'claude --model claude-opus-5-5 --effort medium',
        'claude --model claude-opus-5-5',
    ]
    logs = ['Real fm-spawn.sh CLI; marked disposable home; real PATH; no backend, harness, quota or transport mocks.']
    for i, command in enumerate(commands + [commands[0]]):
        task = f'raw-check-{i}'
        argv = ['bin/fm-spawn.sh', task, str(project), command, '--mode', 'local-only', '--yolo', 'off']
        if i == len(commands):
            argv += ['--captain-override', 'claude-opus-5-5 high explicitly approved']
        p = run(*argv, check=False)
        logs += ['\n$ ' + repr(argv), f'exit={p.returncode}', p.stdout, p.stderr]
        assert p.returncode == 1 and 'raw launch commands naming claude-opus-5-5 are unsupported' in p.stderr, logs[-4:]
        assert not (lab / 'state' / f'{task}.meta').exists()
        logs.append('Task metadata absent after refusal; no worker launched.')
    (evidence / 'raw-opus-live-cli.log').write_text('\n'.join(logs))

    # A new isolated task record is the plan command's public persisted input.
    # This tests planning only, not an actual builder or reviewer launch.
    task = 'cli-review'
    (lab / 'state' / f'{task}.meta').write_text(
        f'harness=codex\nmodel=gpt-6.1-sol\nai_family=openai\nai_family_source=cli-validation\n'
        f'mode=direct-PR\nbranch=fm/cli-review\nworktree={project}\nproject={project}\n')
    d = lab / 'data' / task
    d.mkdir()
    (d / 'brief.md').write_text("# Task\n\n## Captain's intent\n\nReview this isolated example change.\n\n## Firstmate spec\n\nDo not launch a worker.\n")
    argv = ['bin/fm-cross-review.sh', 'plan', task, '--head', head]
    p = run(*argv)
    fields = dict(line.split('=', 1) for line in p.stdout.splitlines() if '=' in line)
    assert fields['action'] == 'spawn-reviewer', fields
    assert fields['reviewer_harness'] == 'claude' and fields['reviewer_effort'] == 'medium', fields
    assert fields['reviewer_model'] == 'claude-opus-5-5' and fields['reviewer_family'] == 'anthropic', fields
    plan = json.loads((d / 'cross-review-model.json').read_text())
    assert plan['head'] == head and plan['profile']['effort'] == 'medium', plan
    (evidence / 'cross-review-live-plan.log').write_text(
        'Real CLI planning against a newly seeded disposable lab task; no dependency mocks.\n'
        'Scope: plan output and persisted profile only; no real builder/reviewer worker.\n'
        '$ ' + repr(argv) + '\n' + p.stdout + p.stderr + '\nPersisted cross-review-model.json:\n' + json.dumps(plan, indent=2) + '\n')
    print('Raw Opus refusal and cross-family medium-effort planning verified through real CLI; evidence saved.')
finally:
    shutil.rmtree(lab, ignore_errors=True)
    shutil.rmtree(project, ignore_errors=True)
