"""Drive the real cross-review CLI using disposable, freshly authored local records.
No fake executables, captured catalog, pipeline-control calls, or agent launches.
Report collection probes the CLI's input validation; reports are test inputs,
not claims of an actual AI review.
"""
import json, os, pathlib, subprocess

root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M52HZK4E4RZF8MGVM5BH9A8S')
lab = root / '.test-gateway-tmp' / 'manual'
home = lab / 'home'
project = lab / 'project'
for p in [home / 'state', home / 'data', home / 'config', project]:
    p.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
for key in list(env):
    if key in ['FM_HOME', 'NM_HOME', 'FM_WIKIS_ROOT', 'FM_AI_FAMILY_PI_CATALOG', 'FM_GATE_REFUSE_BYPASS', 'FM_TEST_SEAM'] or key.startswith(('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'GIT_CONFIG_', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE')):
        env.pop(key, None)
env.update(FM_HOME=str(home), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', TMPDIR=str(root / '.test-gateway-tmp'))
transcript = []
checks = []

def run(args, *, cwd=root):
    p = subprocess.run(args, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90)
    transcript.append({'command': args, 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr})
    if p.returncode:
        raise RuntimeError(transcript[-1])
    return p.stdout

def check(name, observed, expected):
    checks.append({'check': name, 'observed': observed, 'expected': expected, 'pass': observed == expected})

def xr(*args):
    return run(['bash', 'bin/fm-cross-review.sh', *args])

def task(name, harness, model, family=None):
    data = home / 'data' / name
    data.mkdir(exist_ok=True)
    meta = f'harness={harness}\nmodel={model}\nmode=direct-PR\nbranch=main\nworktree={project}\nproject={project}\n'
    if family is not None:
        meta += f'ai_family={family}\nai_family_source=previous spawn\n'
    (home / 'state' / (name + '.meta')).write_text(meta)
    return name

def status(name):
    return json.loads(xr('status', name, '--head', head, '--json'))

def fields(output):
    return dict(line.split('=', 1) for line in output.splitlines() if '=' in line)

run(['git', 'init', '-q', '-b', 'main'], cwd=project)
run(['git', '-c', 'user.name=Local validation', '-c', 'user.email=validation@example.invalid', 'commit', '--allow-empty', '-qm', 'Disposable review candidate'], cwd=project)
head = run(['git', 'rev-parse', 'HEAD'], cwd=project).strip()

# Public status and plan commands, with real candidate catalog lookup.
for name, harness, model, expected in [
    ('deepseek-go', 'opencode', 'opencode-go/deepseek-v4.1-flash', 'deepseek'),
    ('glm-go', 'opencode', 'opencode-go/glm-5', 'zhipu'),
    ('deepseek-pi', 'pi', 'opencode-go/deepseek-v4.1-flash', 'deepseek'),
    ('glm-pi-signed', 'pi-signed', 'openrouter/glm-5', 'zhipu'),
    ('unknown-go', 'opencode', 'opencode-go/mystery-model', 'unknown'),
    ('substring-go', 'opencode', 'opencode-go/x-deepseek-v4.1-flash', 'unknown'),
    ('empty-suffix', 'opencode', 'opencode-go/glm-', 'unknown'),
    ('nested-id', 'opencode', 'opencode-go/glm-5/other', 'unknown'),
]:
    task(name, harness, model)
    s = status(name)
    check(name + ': maker', s['builder']['family'], expected)
    plan = fields(xr('plan', name, '--head', head))
    check(name + ': plan', plan['action'], 'escalate' if expected == 'unknown' else 'spawn-reviewer')
    if expected != 'unknown':
        check(name + ': independent candidate', plan['reviewer_family'] not in [expected, 'unknown'], True)
        saved = json.loads((home / 'data' / name / 'cross-review-model.json').read_text())
        check(name + ': persisted head binding', saved['head'], head)

# Existing spawn records already contain unknown, rather than having no family field.
for name, model, expected in [
    ('existing-deepseek', 'opencode-go/deepseek-v4.1-flash', 'deepseek'),
    ('existing-glm', 'opencode-go/glm-5', 'zhipu'),
]:
    task(name, 'opencode', model, 'unknown')
    s = status(name)
    check(name + ': maker after upgrade', s['builder']['family'], expected)
    plan = fields(xr('plan', name, '--head', head))
    check(name + ': no unknown-builder escalation', plan['action'], 'spawn-reviewer')

# Fresh test-input reports deliberately try to bypass independence by changing
# gateway or using the old zai spelling. They do not claim a real AI review.
def collect_probe(name, builder_family, reviewer_model, expected_accept):
    task(name, 'opencode', 'opencode-go/glm-5', builder_family)
    rid = name + '-reviewer'
    task(rid, 'opencode', reviewer_model)
    data = home / 'data' / rid
    (data / 'cross-review-request').write_text(f'task={name}\nhead={head}\nkind=review\n')
    (data / 'report.md').write_text(f'head: {head}\nVerdict: PASS\n')
    out = xr('collect', name, rid)
    record = json.loads((home / 'data' / name / 'cross-review.jsonl').read_text().splitlines()[-1])
    transcript.append({'persisted_review_record': record})
    check(name + ': accepted', record['accepted'], expected_accept)
    return status(name)

collect_probe('same-maker-other-gateway', None, 'openrouter/glm-5', False)
collect_probe('legacy-zai-overlap', 'zai', 'opencode-go/glm-5', False)
collect_probe('legacy-union-overlap', 'deepseek,zai', 'openrouter/glm-5', False)
independent = collect_probe('different-maker', None, 'openrouter/deepseek-v4.1-flash', True)
check('different-maker: status exposes accepted independent maker', independent['independent_review']['family'], 'deepseek')

(evidence / 'gateway-cli-transcript.json').write_text(json.dumps({'head': head, 'commands': transcript}, indent=2) + '\n')
(evidence / 'gateway-cli-checks.json').write_text(json.dumps(checks, indent=2) + '\n')
for c in checks:
    print(('PASS' if c['pass'] else 'FAIL') + ' ' + c['check'] + ': ' + str(c['observed']))
print('Evidence: gateway-cli-transcript.json; gateway-cli-checks.json')
