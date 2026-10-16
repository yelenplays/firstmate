import json, os, pathlib, shutil, subprocess

root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M52RTBTG0QNV993T00MH13XY')
lab = root / '.test-tmp' / 'family-cli-home'
env = os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'PI_CODING_AGENT_DIR', 'NM_HOME'):
        env.pop(k, None)
env.update(FM_HOME=str(lab), TMPDIR=str(root / '.test-tmp'), PI_CODING_AGENT_DIR=str(lab / 'pi'), NM_HOME=str(lab / 'nm'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', FM_AI_FAMILY_CATALOG_TIMEOUT='10')
transcript = []
checks = []
def run(args, expected=0):
    p = subprocess.run(args, cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=40)
    transcript.append({'command': args, 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr})
    if p.returncode != expected:
        raise AssertionError(transcript[-1])
    return p.stdout

def xr(*args):
    return run(['bash', 'bin/fm-cross-review.sh', *args])

def task(tid, harness, model, family=None):
    (lab / 'data' / tid).mkdir(parents=True, exist_ok=True)
    data = f'harness={harness}\nmodel={model}\nmode=local-only\nbranch=main\nworktree={project}\nproject={project}\n'
    if family is not None:
        data += f'ai_family={family}\nai_family_source=operator-supplied lab history\n'
    (lab / 'state' / f'{tid}.meta').write_text(data)

def status(tid):
    return json.loads(xr('status', tid, '--json'))

def plan(tid):
    out = xr('plan', tid)
    return dict(line.split('=', 1) for line in out.splitlines() if '=' in line)

def submitted_report(tid, rid, harness, model, family=None):
    task(rid, harness, model, family)
    (lab / 'data' / rid / 'cross-review-request').write_text(f'task={tid}\nhead={head}\nkind=review\n')
    (lab / 'data' / rid / 'report.md').write_text(f'reviewed head {head}\nVerdict: PASS\nOperator-authored lab protocol input, not an AI review.\n')
    return xr('collect', tid, rid)

try:
    run(['bash', 'bin/fm-lab-home.sh', 'create', str(lab)])
    project = lab / 'projects' / 'example'
    project.mkdir()
    run(['git', '-C', str(project), 'init', '-q', '-b', 'main'])
    (project / 'example.txt').write_text('Isolated family-resolution CLI validation.\n')
    run(['git', '-C', str(project), 'add', 'example.txt'])
    run(['git', '-C', str(project), '-c', 'user.name=Lab', '-c', 'user.email=lab@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Lab input'])
    head = run(['git', '-C', str(project), 'rev-parse', 'HEAD']).strip()
    for harness in ('opencode', 'pi', 'pi-signed'):
        for model, expected in (('deepseek-v4.1-flash', 'deepseek'), ('glm-5', 'zhipu')):
            tid = f'{harness}-{model}'.replace('.', '-')
            task(tid, harness, f'opencode-go/{model}')
            assert status(tid)['builder']['family'] == expected
            p = plan(tid)
            assert p['action'] == 'spawn-reviewer' and p['reviewer_family'] not in (expected, 'unknown')
            profile = json.loads((lab / 'data' / tid / 'cross-review-model.json').read_text())
            assert profile['head'] == head and profile['profile']['harness'] == p['reviewer_harness']
            checks.append({'scenario': 'known-gateway-maker', 'task': tid, 'family': expected, 'plan': p, 'persisted_profile': profile})
    for gateway in ('openrouter', 'another-gateway'):
        for model, expected in (('deepseek-v4.1-flash', 'deepseek'), ('glm-5', 'zhipu')):
            tid = f'{gateway}-{model}'.replace('.', '-')
            task(tid, 'opencode', f'{gateway}/{model}')
            assert status(tid)['builder']['family'] == expected
            assert plan(tid)['action'] == 'spawn-reviewer'
            checks.append({'scenario': 'other-gateway-maker', 'task': tid, 'family': expected})
    for i, model in enumerate(('opencode-go/not-a-known-model', 'opencode-go/deepseek-', 'opencode-go/glm-', 'opencode-go/x-glm-5', 'opencode-go/glm-5/other', 'deepseek-v4.1-flash')):
        tid = f'unknown-model-{i}'
        task(tid, 'opencode', model)
        assert status(tid)['builder']['family'] == 'unknown'
        p = plan(tid)
        assert p['action'] == 'escalate'
        assert not (lab / 'data' / tid / 'cross-review-model.json').exists()
        checks.append({'scenario': 'reject-unproven-maker', 'model': model, 'plan': p})
    for i, family in enumerate(('unknown', 'openai,unknown', 'unknown,zhipu')):
        tid = f'preserve-history-{i}'
        task(tid, 'opencode', 'opencode-go/glm-5', family)
        assert status(tid)['builder']['family'] == family
        assert plan(tid)['action'] == 'escalate'
        out = submitted_report(tid, f'{tid}-reviewer', 'opencode', 'opencode-go/deepseek-v4.1-flash')
        assert 'accepted=no' in out
        assert isinstance(status(tid)['independent_review'], str)
        checks.append({'scenario': 'preserve-unknown-history', 'family': family, 'collection': out})
    task('recorded-maker', 'opencode', 'opencode-go/glm-5', 'deepseek')
    assert status('recorded-maker')['builder']['family'] == 'deepseek'
    checks.append({'scenario': 'preserve-known-history', 'recorded': 'deepseek', 'current_model': 'opencode-go/glm-5'})
    for builder, reviewer, family in (('zai', 'opencode-go/glm-5', None), ('zhipu', 'opencode-go/glm-5', 'zai'), ('deepseek,zhipu', 'opencode-go/glm-5', 'zai')):
        tid = f'alias-{len(checks)}'
        task(tid, 'opencode', 'opencode-go/glm-5', builder)
        out = submitted_report(tid, f'{tid}-reviewer', 'opencode', reviewer, family)
        assert 'accepted=no' in out
        assert isinstance(status(tid)['independent_review'], str)
        checks.append({'scenario': 'same-maker-alias-refused', 'builder': builder, 'reviewer_model': reviewer, 'reviewer_family': family, 'collection': out})
    task('cross-gateway-review', 'opencode', 'opencode-go/deepseek-v4.1-flash', 'deepseek')
    out = submitted_report('cross-gateway-review', 'cross-gateway-reviewer', 'pi', 'opencode-go/glm-5')
    assert 'accepted=yes' in out
    s = status('cross-gateway-review')
    assert s['independent_review']['family'] == 'zhipu' and s['independent_review']['head'] == head
    assert plan('cross-gateway-review')['action'] == 'none'
    checks.append({'scenario': 'distinct-gateway-reviewer', 'collection': out, 'status': s})
    (evidence / 'live-cli-results.json').write_text(json.dumps({'scope': 'Real unmodified cross-review CLI; isolated operator-supplied task records and report protocol inputs; real Pi catalog CLI; no worker launches or AI reviews claimed.', 'checks': checks}, indent=2) + '\n')
    print(f'CLI validation passed; {len(checks)} cases; no fake vendor or pipeline executables.')
finally:
    transcript.append({'cleanup': 'Remove disposable lab home inside worktree', 'path': str(lab)})
    shutil.rmtree(lab, ignore_errors=True)
    (evidence / 'live-cli-transcript.json').write_text(json.dumps(transcript, indent=2) + '\n')
