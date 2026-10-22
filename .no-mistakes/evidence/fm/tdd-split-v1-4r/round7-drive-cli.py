#!/usr/bin/env python3
"""Exercise the real mutation CLI against isolated git repositories and invocation records."""
import json, os, pathlib, shutil, sqlite3, subprocess
ROOT = pathlib.Path('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5GS3M4W07Q0D4MM3H04RCEJ')
EVIDENCE = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5GS3M4W07Q0D4MM3H04RCEJ')
FIXTURES = ROOT / '.test-phase-tmp/live-cli'
FIXTURES.mkdir(parents=True, exist_ok=True)
base_env = dict(os.environ)
for k in list(base_env):
    if k.startswith(('FM_', 'GIT_')) or k in ('NM_HOME', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
        base_env.pop(k, None)
base_env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='core.hooksPath', GIT_CONFIG_VALUE_0='/dev/null', GIT_AUTHOR_NAME='CLI Validation', GIT_AUTHOR_EMAIL='validation@example.invalid', GIT_COMMITTER_NAME='CLI Validation', GIT_COMMITTER_EMAIL='validation@example.invalid', TMPDIR=str(ROOT / '.test-phase-tmp'))
results = []

def case(name, subject, expected, invocations=(), template=None, source='global', unreadable=False, raw_yaml=None, extra_yaml='', allow_path=False, restore=False, foreign=False, schema=True):
    d = FIXTURES / name
    if d.exists(): shutil.rmtree(d)
    d.mkdir()
    wt, home, nm = d/'repo', d/'home', d/'nm'
    for p in (wt, home/'state', home/'data/live', home/'config', nm): p.mkdir(parents=True, exist_ok=True)
    env = dict(base_env, FM_HOME=str(home), NM_HOME=str(nm))
    def git(*args):
        return subprocess.run(['git', '-C', str(wt), *args], env=env, text=True, capture_output=True, check=True).stdout.strip()
    git('init', '-q', '-b', 'main')
    git('commit', '-qm', 'base', '--allow-empty')
    base = git('rev-parse', 'HEAD')
    git('update-ref', 'refs/remotes/origin/main', base)
    git('checkout', '-qb', 'fm/live')
    (wt/'tests').mkdir()
    (wt/'tests/feature.test.sh').write_text('printf "FEATURE_TEST_EXECUTED\\n"\nexit 0\n')
    yaml = raw_yaml if raw_yaml is not None else (('commit:\n  fix_message: \''+template.replace("'", "''")+"'\n") if template is not None else '')
    yaml += extra_yaml
    if source == 'repo' and yaml: (wt/'.no-mistakes.yaml').write_text(yaml)
    if source == 'global' and yaml: (nm/'config.yaml').write_text(yaml)
    git('add', '.')
    git('commit', '-qm', subject)
    changed = git('rev-parse', 'HEAD')
    if restore:
        git('rm', '-q', 'tests/feature.test.sh')
        git('commit', '-qm', 'revert unauthorized test')
        # Keep a legitimate test to give the mutation command a real input.
        (wt/'tests').mkdir(exist_ok=True)
        (wt/'tests/allowed.test.sh').write_text('exit 0\n')
        git('add', 'tests/allowed.test.sh')
        git('commit', '-qm', 'worker test')
    head = git('rev-parse', 'HEAD')
    meta = '\n'.join(['kind=ship', 'mode=no-mistakes', 'tdd_split=implement', 'harness=claude', 'model=claude-opus-5-5', 'branch=fm/live', 'base_branch=main', 'worktree='+str(wt), 'project='+str(wt)])+'\n'
    if allow_path: meta += 'test_authoring_allow=tests/feature.test.sh\n'
    (home/'state/live.meta').write_text(meta)
    (home/'state/live.status').write_text('done: implementation ready\n')
    (home/'data/live/brief.md').write_text('# CLI validation\nFail-to-pass command: `for t; do bash "$t" || exit 1; done`\nMutation command: `printf "ASSERTION_EXECUTED tests=%s\\n" "$*"; for t; do bash "$t" || exit 1; done`\n')
    if schema:
        db = sqlite3.connect(nm/'state.sqlite')
        db.executescript('CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT); CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT, branch TEXT); CREATE TABLE agent_invocations (id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT, purpose TEXT, model TEXT, exit_status TEXT, started_at INTEGER);')
        db.execute('INSERT INTO repos VALUES (?,?)', ('p', str(wt) if not foreign else str(d/'other-project')))
        db.execute('INSERT INTO runs VALUES (?,?,?)', ('r', 'p', 'fm/live'))
        for i, inv in enumerate(invocations):
            step, purpose, model, *status = inv
            db.execute('INSERT INTO agent_invocations VALUES (?,?,?,?,?,?,?)', (str(i), 'r', step, purpose, model, status[0] if status else 'ok', i))
        if source in ('round-global', 'round-repo'):
            db.executescript('CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT); CREATE TABLE step_rounds (id TEXT PRIMARY KEY, step_result_id TEXT, global_config_yaml BLOB, repo_config_yaml BLOB);')
            db.execute('INSERT INTO step_results VALUES (?,?,?)', ('s','r','review'))
            db.execute('INSERT INTO step_rounds VALUES (?,?,?,?)', ('o','s',yaml.encode() if source=='round-global' else b'',yaml.encode() if source=='round-repo' else b''))
        db.commit(); db.close()
    if unreadable: (nm/'config.yaml').chmod(0)
    command = ['bash', str(ROOT/'bin/fm-tdd-split.sh'), 'mutation', 'live', '--timeout', '10']
    try:
        cp = subprocess.run(command, env=env, text=True, capture_output=True, timeout=40)
    finally:
        if unreadable: (nm/'config.yaml').chmod(0o600)
    log_path = home/'data/live/tdd-split-mutation.log'
    log = log_path.read_text() if log_path.exists() else ''
    executed = 'ASSERTION_EXECUTED' in log
    passed = (cp.returncode==0 and executed) if expected=='allow' else (cp.returncode!=0 and not executed and 'no test authoring' in cp.stderr)
    result = dict(name=name, expected=expected, result='pass' if passed else 'fail', live=True, command='FM_HOME=<isolated-home> NM_HOME=<isolated-nm> bash bin/fm-tdd-split.sh mutation live --timeout 10', subject=subject, template=yaml, source=source, invocations=invocations, head=head, changed_head=changed, exit=cp.returncode, assertion_executed=executed, stdout=cp.stdout, stderr=cp.stderr, mutation_log=log)
    results.append(result)
    (EVIDENCE/'round7-cli-results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(name, result['result'], 'exit='+str(cp.returncode), 'executed='+str(executed), flush=True)
    shutil.rmtree(d)

SONNET=('review','review-fix','claude-sonnet-5-5')
OPUS=('review','review-fix','claude-opus-5-5')
TEST=('test','test','claude-opus-5-5')
CUSTOM='repair[{{.Step}}] {{.Branch}}: {{.Summary}}'
case('default-sonnet-review', 'no-mistakes(review): add test', 'refuse', [SONNET])
for source in ('global','repo','round-global','round-repo'):
    case('template-'+source+'-sonnet', 'repair[review] fm/live: add test', 'refuse', [SONNET], CUSTOM, source)
    case('template-'+source+'-opus', 'repair[review] fm/live: add test', 'allow', [OPUS], CUSTOM, source)
case('worker-own-test', 'write feature tests', 'allow', [SONNET], CUSTOM)
case('branch-summary-without-step', 'fm/live: add test', 'refuse', [TEST, SONNET], '{{.Branch}}: {{.Summary}}')
case('unsupported-template', 'fix add test', 'refuse', [TEST], '{{printf "%s" .Summary}}')
case('overlapping-default-template', 'no-mistakes(test): add test', 'refuse', [TEST, SONNET], '{{.Summary}}')
case('dotted-gate-unrecorded', 'no-mistakes(gate.test.mutation-budget): add test', 'refuse')
case('dotted-gate-sonnet', 'no-mistakes(gate.test.mutation-budget): add test', 'refuse', [('gate.test.mutation-budget','custom','claude-sonnet-5-5')])
case('document-housekeeping-sonnet', 'no-mistakes(document): lint tests', 'refuse', [('document','housekeeping','claude-sonnet-5-5')])
case('document-housekeeping-opus', 'no-mistakes(document): lint tests', 'allow', [('document','housekeeping','claude-opus-5-5')])
case('review-readonly-sonnet-opus-fix', 'no-mistakes(review): add test', 'allow', [('review','review','claude-sonnet-5-5'),OPUS])
case('multiple-successful-authors', 'repair[review] fm/live: add test', 'refuse', [OPUS, SONNET], CUSTOM)
case('failed-sonnet-not-author', 'repair[review] fm/live: add test', 'allow', [OPUS,('review','review-fix','claude-sonnet-5-5','error')], CUSTOM)
case('foreign-opus-not-author', 'repair[review] fm/live: add test', 'refuse', [OPUS], CUSTOM, foreign=True)
for source in ('global','repo','round-global','round-repo'):
    for form in ('scalar','sequence'):
        yaml='repair_style: &repair_style\n  fix_message: "'+CUSTOM+'"\ncommit:\n  <<: '+ ('*repair_style' if form=='scalar' else '[*repair_style]')+'\n'
        case('inherited-'+source+'-'+form, 'repair[review] fm/live: add test', 'refuse', [SONNET], source=source, raw_yaml=yaml)
case('unrelated-anchor-own-test', 'write feature tests', 'allow', [SONNET], raw_yaml='agent_config: &agent_config\n  claude:\n    model: claude-opus-5-5\n')
for subject, name in [('repair[review] fm/live: add test','sonnet-repair'),('write feature tests','opus-own')]:
    case('unreadable-global-'+name, subject, 'refuse', [SONNET], CUSTOM, unreadable=True)
case('absent-config-old-schema-worker', 'write feature tests', 'allow', [SONNET])
case('absent-config-no-database-worker', 'write feature tests', 'allow', schema=False)
case('reverted-sonnet-test', 'repair[review] fm/live: add test', 'allow', [SONNET], CUSTOM, restore=True)
for source in ('global','repo','round-global','round-repo'):
    case('summary-resembles-another-step-'+source, 'fm/live/review: repair/test: add test', 'refuse', [SONNET, TEST], '{{.Branch}}/{{.Step}}: {{.Summary}}', source)
case('ambiguous-template-without-opus-decoy', 'fm/live/review: repair/test: add test', 'refuse', [SONNET], '{{.Branch}}/{{.Step}}: {{.Summary}}')
case('ambiguous-template-ordinary-summary', 'fm/live/review: add test', 'refuse', [SONNET, TEST], '{{.Branch}}/{{.Step}}: {{.Summary}}')
case('summary-before-step-delimiter', 'repair/test/review: fm/live', 'refuse', [SONNET, TEST], '{{.Summary}}/{{.Step}}: {{.Branch}}')
print('Results:',len(results),'failures:',sum(r['result']=='fail' for r in results))
