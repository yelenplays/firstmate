#!/usr/bin/env python3
"""Exercise production mutation/dispute CLIs with isolated Git and SQLite inputs.
No harness, forge, control command, or pipeline executable is replaced.
"""
import json, os, pathlib, shutil, sqlite3, subprocess
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5GKBK7PVAYVBDDQ69A2EV0M')
SCRATCH = ROOT / '.phase-test'
SCRATCH.mkdir(exist_ok=True)
(SCRATCH / 'tmp').mkdir(exist_ok=True)
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('NM_HOME', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_COUNT'):
        env.pop(key, None)
env.update(TMPDIR=str(SCRATCH / 'tmp'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Local CLI QA', GIT_AUTHOR_EMAIL='qa@example.invalid', GIT_COMMITTER_NAME='Local CLI QA', GIT_COMMITTER_EMAIL='qa@example.invalid')

def run(args, cwd=ROOT, e=None):
    p = subprocess.run([str(x) for x in args], cwd=cwd, env=e or env, capture_output=True, text=True, timeout=40)
    return p

def must(args, cwd=ROOT, e=None):
    p = run(args,cwd,e)
    if p.returncode: raise RuntimeError(f'{args}: {p.stderr}')
    return p.stdout.strip()

T = 'repair[{{.Step}}] {{.Branch}}: {{.Summary}}'
Y = 'commit:\n  fix_message: "' + T + '"\n'
OPUS = ('review','review-fix','claude-opus-5-5')
SONNET = ('review','review-fix','claude-sonnet-5-5')
CASES=[]
def case(name, subject='repair[review] fm/local: adjust assertion', configs=None, invocations=None, expected=1, action='mutation', prior=False, mutation=None):
    CASES.append(dict(name=name, subject=subject, configs=configs or {}, invocations=invocations or [SONNET], expected=expected, action=action, prior=prior, mutation=mutation))
for source in ['global','repo','round-global','round-repo']:
    case(source+'-sonnet',configs={source:Y})
case('recorded-opus', configs={'round-global':Y},invocations=[OPUS],expected=0)
case('worker-own',subject='worker: adjust assertion', configs={'global':Y},expected=0)
case('stepless-all-authors',subject='repair fm/local: adjust assertion',configs={'global':'commit:\n  fix_message: "repair {{.Branch}}: {{.Summary}}"\n'},invocations=[('test','test','claude-opus-5-5'),('lint','lint-fix','claude-sonnet-5-5')])
case('unsupported-block-scalar', subject='worker: adjust assertion',configs={'global':'commit:\n  fix_message: |\n    repair {{.Summary}}\n'},invocations=[OPUS])
case('unsupported-placeholder',subject='worker: adjust assertion',configs={'global':'commit:\n  fix_message: "repair {{.Unknown}}"\n'},invocations=[OPUS])
case('dotted-default',subject='no-mistakes(gate.test.mutation-budget): adjust assertion', invocations=[('gate.test.mutation-budget','gate.test.mutation-budget-fix','claude-sonnet-5-5')])
for model,expect in [('claude-opus-5-5',0),('claude-sonnet-5-5',1)]:
    case('housekeeping-'+model, subject='no-mistakes(document): adjust assertion',invocations=[('document','housekeeping',model)], expected=expect)
case('readonly-review-excluded', configs={'global':Y},invocations=[OPUS,('review','review','claude-sonnet-5-5')],expected=0)
case('failed-invocation-excluded', configs={'global':Y},invocations=[OPUS,('review','review-fix','claude-sonnet-5-5','failed')],expected=0)
for source in ['global','repo','round-global','round-repo']:
    case('quoted-'+source, configs={source:'"commit":\n  "fix_message": "'+T+'"\n'})
    case('flow-root-'+source, configs={source:'{commit: {fix_message: "'+T+'"}}\n'})
    case('indented-root-'+source, configs={source:'  commit:\n    fix_message: "'+T+'"\n'})
case('single-quoted',configs={'global':"'commit':\n  'fix_message': '"+T+"'\n"})
# Adversarial attribution: multiple supported/historical templates can match
# one subject. A step-less matching template must include all step authors.
case('overlap-global-stepless',configs={'global':'commit:\n  fix_message: "{{.Summary}}"\n','repo':Y},invocations=[OPUS,('lint','lint-fix','claude-sonnet-5-5')])
case('overlap-recorded-stepless',configs={'round-global':'commit:\n  fix_message: "{{.Summary}}"\n','repo':Y},invocations=[OPUS,('lint','lint-fix','claude-sonnet-5-5')])
case('default-versus-stepless',subject='no-mistakes(review): adjust assertion',configs={'global':'commit:\n  fix_message: "{{.Summary}}"\n'},invocations=[OPUS,('lint','lint-fix','claude-sonnet-5-5')])
for action in ['dispute','mutation']:
    for prior in [False,True]:
        case(f'{action}-rollback-{prior}',subject='worker: adjust assertion',invocations=[OPUS],expected=1,action=action,prior=prior,mutation='echo MUTANT_SURVIVED; exit 1' if action=='mutation' else None)

results=[]
try:
    for c in CASES:
        d=SCRATCH/c['name']; d.mkdir()
        wt=d/'wt'; wt.mkdir()
        home=d/'home'; nm=d/'nm'; nm.mkdir()
        must([ROOT/'bin/fm-lab-home.sh','create',home])
        must(['git','init','-q','-b','main'],wt)
        (wt/'README.md').write_text('Local validation input\n')
        must(['git','add','.'],wt); must(['git','commit','-qm','base'],wt)
        base=must(['git','rev-parse','HEAD'],wt)
        must(['git','update-ref','refs/remotes/origin/main',base],wt)
        must(['git','checkout','-qb','fm/local'],wt)
        (wt/'tests').mkdir()
        (wt/'tests/feature.test.sh').write_text('[ -f feature.sh ] && echo ASSERTION_EXECUTED\n')
        must(['git','add','.'],wt); must(['git','commit','-qm','worker: red tests'],wt)
        seat=must(['git','rev-parse','HEAD'],wt)
        # Keep the pre-existing tests at the base; only the repair changes
        # tests in the inspected range, isolating its attribution.
        must(['git','update-ref','refs/remotes/origin/main',seat],wt)
        (wt/'feature.sh').write_text('echo implemented\n')
        must(['git','add','.'],wt); must(['git','commit','-qm','worker: implement feature'],wt)
        db=sqlite3.connect(nm/'state.sqlite')
        db.executescript('CREATE TABLE repos(id TEXT, working_path TEXT); CREATE TABLE runs(id TEXT, repo_id TEXT, branch TEXT); CREATE TABLE agent_invocations(run_id TEXT, step_name TEXT, purpose TEXT, model TEXT, exit_status TEXT); CREATE TABLE step_results(id TEXT, run_id TEXT, step_name TEXT); CREATE TABLE step_rounds(step_result_id TEXT,global_config_yaml BLOB,repo_config_yaml BLOB);')
        db.execute('INSERT INTO repos VALUES (?,?)',('repo',str(wt)))
        db.execute('INSERT INTO runs VALUES (?,?,?)',('run','repo','fm/local'))
        for v in c['invocations']:
            db.execute('INSERT INTO agent_invocations VALUES (?,?,?,?,?)',('run',*v[:3],v[3] if len(v)>3 else 'ok'))
        db.execute('INSERT INTO step_results VALUES (?,?,?)',('step','run','review'))
        configs=c['configs']
        db.execute('INSERT INTO step_rounds VALUES (?,?,?)',('step',configs.get('round-global','').encode(),configs.get('round-repo','').encode()))
        db.commit(); db.close()
        if 'global' in configs: (nm/'config.yaml').write_text(configs['global'])
        if 'repo' in configs: (wt/'.no-mistakes.yaml').write_text(configs['repo'])
        (wt/'tests/feature.test.sh').write_text('[ -f feature.sh ] && echo ASSERTION_EXECUTED\n# repair authored by recorded pipeline invocation\n')
        must(['git','add','.'],wt); must(['git','commit','-qm',c['subject']],wt)
        head=must(['git','rev-parse','HEAD'],wt)
        data=home/'data/local'; data.mkdir()
        mutation=c['mutation'] or 'for t; do bash "$t" || exit 1; done'
        (data/'brief.md').write_text('# Local QA\n\nFail-to-pass command: `for t; do bash "$t" || exit 1; done`\nMutation command: `'+mutation+'`\n')
        meta=home/'state/local.meta'
        text=f'kind=ship\nmode=no-mistakes\nworktree={wt}\nproject={wt}\nbranch=fm/local\nbase_branch=main\nharness=claude\nmodel=claude-opus-5-5\ntdd_split=implement\ntdd_split_tests={seat}\n'
        if c['prior']: text+=f'tdd_split_dispute_head={seat}\n'
        meta.write_text(text)
        status='blocked [key=test-dispute]: tests/feature.test.sh: it checks the wrong file' if c['action']=='dispute' else 'done: local implementation ready'
        (home/'state/local.status').write_text(status+'\n')
        e=env|{'FM_HOME':str(home),'NM_HOME':str(nm)}
        args=[ROOT/'bin/fm-tdd-split.sh',c['action'],'local']
        if c['action']=='mutation': args+=['--timeout','10']
        p=run(args,e=e)
        log=data/'tdd-split-mutation.log'
        restored=sorted(meta.read_text().splitlines())==sorted(text.splitlines()) if 'rollback' in c['name'] else None
        ok=p.returncode==c['expected'] and (restored is not False)
        results.append(c|dict(candidate=must(['git','rev-parse','HEAD']),command='bin/fm-tdd-split.sh '+c['action']+' local'+(' --timeout 10' if c['action']=='mutation' else ''),exit=p.returncode,stdout=p.stdout,stderr=p.stderr,mutation_output=log.read_text() if log.exists() else '',record_restored=restored,passed=ok))
        print(c['name'],p.returncode,'PASS' if ok else 'FAIL',flush=True)
finally:
    (EVIDENCE/'round3-cli-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(SCRATCH)
