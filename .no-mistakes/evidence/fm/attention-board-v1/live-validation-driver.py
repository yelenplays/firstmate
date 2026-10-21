import os, subprocess, json, pathlib, shutil, html, time, traceback
ROOT = pathlib.Path.cwd()
WORK = ROOT / '.validation-tmp' / 'live'
EVID = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5G90CKM6QB4XMMX9E8JHPP3')
WORK.mkdir()
ENV = os.environ.copy()
for key in list(ENV):
    if key.startswith(('FM_', 'GIT_', 'TASKS_AXI_', 'GH_')) or key in ('TMUX', 'HERDR_ENV'):
        ENV.pop(key, None)
# Use a declared isolated installation root, distinct from its homes. All scripts
# still execute the actual tracked bin; no external executable is stubbed.
INSTALL = WORK / 'installation-root'
INSTALL.mkdir()
(INSTALL / 'bin').symlink_to(ROOT / 'bin', target_is_directory=True)
ENV.update(FM_ROOT_OVERRIDE=str(INSTALL), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Live validation', GIT_AUTHOR_EMAIL='validation@example.invalid', GIT_COMMITTER_NAME='Live validation', GIT_COMMITTER_EMAIL='validation@example.invalid', TMPDIR=str(WORK), GH_CONFIG_DIR=str(WORK / 'gh-config'))
LOG = open(EVID / 'live-cli-transcript.txt', 'w')
BOARDS = []
RESULTS = []
def run(args, home=None, check=True, quiet=False):
    env = ENV.copy()
    if home: env['FM_HOME'] = str(home)
    p = subprocess.run([str(a) for a in args], env=env, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=50)
    if not quiet:
        LOG.write('$ ' + ('FM_HOME=' + str(home) + ' ' if home else '') + ' '.join(str(a) for a in args) + '\n' + p.stdout + '\n'); LOG.flush()
    if check and p.returncode: raise AssertionError(f'{args}: exit {p.returncode}: {p.stdout}')
    return p.stdout if check else p

def git(repo, *args, **kw): return run(['git', '-C', repo, *args], **kw).strip()
def write(path, text): path.parent.mkdir(parents=True, exist_ok=True); path.write_text(text)
def record(path, **fields): write(path, ''.join(f'{k}={v}\n' for k,v in fields.items()))
def read_record(path): return dict(line.split('=',1) for line in path.read_text().splitlines() if '=' in line)
def home(name):
    p = WORK / name
    for d in ('state','data','config','projects','bin'): (p/d).mkdir(parents=True)
    write(p/'AGENTS.md','# Isolated validation home\n')
    write(p/'.tasks.toml','backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
    write(p/'data/backlog.md','## In flight\n\n## Queued\n\n## Done\n')
    return p
H = home('main-home'); P = H/'projects/demo'
run(['git','init','-q','-b','main',P])
write(P/'common.txt','base\n'); write(P/'base.txt','base\n')
git(P,'add','.'); git(P,'commit','-qm','Initial local project')
# A local bare remote lets us prove no remote ref was pushed.
REMOTE=WORK/'remote.git'; run(['git','init','-q','--bare',REMOTE]); git(P,'remote','add','origin',str(REMOTE)); git(P,'push','-q','origin','main')
REMOTE0=git(REMOTE,'show-ref')
TASKS={}
def task(id, file, value, with_wt=True):
    wt=WORK/('ready-'+id)
    if with_wt:
        git(P,'worktree','add','-q','-b','fm/'+id,wt,'main'); repo=wt
    else:
        git(P,'checkout','-q','-b','fm/'+id,'main'); repo=P
    write(repo/file,value); git(repo,'add',file); git(repo,'commit','-qm',id+' work')
    old=git(repo,'rev-parse','HEAD')
    if not with_wt: git(P,'checkout','-q','main')
    record(H/'state'/f'{id}.meta',worktree=repo,project=P,branch='fm/'+id,harness='claude',kind='ship',mode='local-only',spawn_gen='live.'+id)
    write(H/'state'/f'{id}.status',f'done: ready branch fm/{id}\n')
    TASKS[id]=(repo,old)

def sync(*ids): return run([ROOT/'bin/fm-main-sync.sh',*ids],H)
def board(label, target=H, **opts):
    args=[ROOT/'bin/fm-board.sh','--json']
    if opts.get('home_only',True): args+=['--home-only']
    data=json.loads(run(args,target))
    text=run([ROOT/'bin/fm-board.sh','--all']+(['--home-only'] if opts.get('home_only',True) else []),target)
    BOARDS.append((label,text))
    write(EVID/(label+'.json'),json.dumps(data,indent=2)+'\n')
    return data

def item(data,id): return next(dict(row,group=group) for group,rows in data['groups'].items() for row in rows if row['id']==id)
def save_result(name,fn):
    try: fn(); RESULTS.append({'name':name,'result':'pass'})
    except Exception as e: RESULTS.append({'name':name,'result':'fail','error':str(e)}); LOG.write(traceback.format_exc()); LOG.flush()

for args in [('clean','clean.txt','ready clean\n',True),('bare','bare.txt','ready unchecked out\n',False),('dirty','dirty.txt','ready dirty\n',True),('conflict','common.txt','branch side\n',True),('locked','locked.txt','ready locked\n',False)]: task(*args)
D=TASKS['dirty'][0]; write(D/'dirty.txt','ready dirty\nunsaved\n')
write(P/'common.txt','main side\n'); write(P/'advance.txt','main advance\n'); git(P,'add','.'); git(P,'commit','-qm','Independent main advance')
MAIN=git(P,'rev-parse','main'); write(P/'uncommitted-main.txt','must not touch\n'); MAIN_STATUS=git(P,'status','--porcelain')

def invariant():
    assert git(P,'rev-parse','main')==MAIN
    assert git(P,'symbolic-ref','--short','HEAD')=='main'
    assert git(P,'status','--porcelain')==MAIN_STATUS
    assert git(REMOTE,'show-ref')==REMOTE0

def clean_sync():
    sync('clean')
    new=git(P,'rev-parse','fm/clean'); assert new!=TASKS['clean'][1]
    assert git(P,'show','-s','--format=%P',new).split()==[TASKS['clean'][1],MAIN]
    assert git(TASKS['clean'][0],'rev-parse','HEAD')==new
    assert git(TASKS['clean'][0],'status','--porcelain')==''
    assert (TASKS['clean'][0]/'advance.txt').read_text()=='main advance\n'
    git(P,'merge-base','--is-ancestor','main','fm/clean')
    assert read_record(H/'state/clean.main-sync')['result']=='synced'
    invariant(); sync('clean'); assert read_record(H/'state/clean.main-sync')['result']=='current'; invariant()
save_result('Sync a clean checked-out ready branch and keep main and the remote untouched',clean_sync)

def bare_sync():
    sync('bare'); new=git(P,'rev-parse','fm/bare')
    assert git(P,'show','-s','--format=%P',new).split()==[TASKS['bare'][1],MAIN]
    git(P,'merge-base','--is-ancestor','main','fm/bare'); invariant()
save_result('Sync a ready branch checked out nowhere using a fast-forward ref update',bare_sync)

def dirty_sync():
    sync('dirty'); assert read_record(H/'state/dirty.main-sync')['result']=='blocked'
    assert git(P,'rev-parse','fm/dirty')==TASKS['dirty'][1]
    assert (D/'dirty.txt').read_text().endswith('unsaved\n')
    b=board('01-blocked-board'); assert item(b,'dirty')['group']=='needs_you'; assert item(b,'dirty')['reason']=='sync-blocked'
    invariant(); git(D,'add','dirty.txt'); git(D,'commit','-qm','Save pending edit')
    sync('dirty'); assert read_record(H/'state/dirty.main-sync')['result']=='synced'
    assert item(board('02-dirty-recovered'),'dirty')['group']=='ready'; invariant()
save_result('Refuse a dirty ready copy, show sync-blocked, and retry after its changes are saved',dirty_sync)

def conflict_sync():
    sync('conflict'); assert read_record(H/'state/conflict.main-sync')['result']=='conflict'
    C=TASKS['conflict'][0]; assert git(C,'rev-parse','HEAD')==TASKS['conflict'][1]; assert git(C,'status','--porcelain')==''
    b=board('03-conflict-board'); assert item(b,'conflict')['group']=='needs_you'; assert item(b,'conflict')['reason']=='conflict'
    invariant()
    # Restore a saved incarnation with the same task id: old sync records cannot hold the new task.
    meta=H/'state/conflict.meta'; old=meta.read_text(); write(meta,old.replace('spawn_gen=live.conflict','spawn_gen=live.reused'))
    assert item(board('04-reused-incarnation'),'conflict')['group']=='ready'
    write(meta,old)
    write(C/'common.txt','main side\n'); git(C,'add','common.txt'); git(C,'commit','-qm','Resolve conflicting change')
    sync('conflict'); assert read_record(H/'state/conflict.main-sync')['result']=='synced'
    assert item(board('05-conflict-recovered'),'conflict')['group']=='ready'; invariant()
save_result('Keep a conflicting branch untouched, ignore old-incarnation blockers, and re-evaluate after resolution',conflict_sync)

def locked_sync():
    for lock,expected in [(H/'state/.control-locked.lock','a lifecycle action holds the task'),(H/'state/.main-sync.lock','another run holds')]:
        holder=subprocess.Popen(['bash','-c','. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" || exit 2; echo HELD; read -r release; fm_lock_release "$2"','_',str(ROOT),str(lock)],env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            assert holder.stdout.readline().strip()=='HELD'
            assert expected in sync('locked'); assert git(P,'rev-parse','fm/locked')==TASKS['locked'][1]
            assert not (H/'state/locked.main-sync').exists(); invariant()
        finally: holder.communicate('release\n',timeout=10)
    sync('locked'); assert read_record(H/'state/locked.main-sync')['result']=='synced'; invariant()
save_result('Skip held task and home locks without moving the branch, then sync after release',locked_sync)

def durable_ready():
    # No PR recording, relay, or backend is required to recover an unrelayed URL.
    record(H/'state/missed.meta',kind='ship',mode='no-mistakes',spawn_gen='live.missed')
    status=H/'state/missed.status'
    write(status,'needs-decision [key=old]: old question\ndone: PR https://github.com/example/disposable/pull/1 checks green\nnote: evidence collected\nresolved [key=old]: answered\n')
    b=board('06-durable-ready'); assert item(b,'missed')['group']=='ready'
    b2=board('07-ready-reread'); assert item(b2,'missed')==item(b,'missed')
    write(status,status.read_text()+'working: addressing review\nnote: additional context\n')
    assert item(board('08-resumed-work'),'missed')['group']=='working'
    invariant()
save_result('Recover unrelayed readiness from stored events across notes and resolutions, but not resumed work',durable_ready)

def postmerge_columns():
    backlog=H/'data/backlog.md'; write(backlog,backlog.read_text()+'- [x] deployed - Stored merged delivery (repo: demo) (kind: ship) (merged 2026-10-20)\n')
    pm=H/'state/deployed.post-merge'
    record(pm,version='fm-post-merge-v1',task='deployed',spawn_gen='live.deployed',kind='pr',phase='witness',pr='https://github.com/example/disposable/pull/2',witness='https://example.invalid')
    assert item(board('09-merged-not-live'),'deployed')['group']=='merged'
    record(pm,version='fm-post-merge-v1',task='deployed',spawn_gen='live.deployed',kind='pr',phase='clear',pr='https://github.com/example/disposable/pull/2',witness='https://example.invalid',witness_verdict='pass')
    assert item(board('10-stored-live-verdict'),'deployed')['group']=='live'
    # This validates the board's durable input contract, not an actual deployment or witness.
save_result('Render merged versus live columns from durable post-merge records even without task metadata',postmerge_columns)

def secondmate():
    M=home('child-home'); write(M/'.fm-secondmate-home','child\n')
    suffix='i'*110
    write(M/'data/backlog.md','## In flight\n'+''.join(f'- [ ] orphan-{i}-{suffix} - Missing metadata (repo: demo) (kind: ship)\n' for i in range(1,601))+'\n## Queued\n\n## Done\n')
    run([ROOT/'bin/fm-home-summary-refresh.sh'],M)
    summary=json.loads((M/'state/home-summary.json').read_text())
    write(EVID/'child-home-summary.json',json.dumps(summary,indent=2)+'\n')
    assert summary['board']['omitted']['working']>0
    write(H/'data/secondmates.md',f'- child - validation domain (home: {M}; scope: validation; projects: demo; added 2026-10-20)\n')
    record(H/'state/child.meta',window='unused:fm-child',endpoint_task_id='child',worktree=M,project=M,harness='claude',kind='secondmate',mode='secondmate',home=M,projects='demo')
    parent=board('11-parent-board',home_only=False)
    assert parent['counts']['working']>=600
    assert any(x['home']=='child' and x['group']=='working' and x['count']==summary['board']['omitted']['working'] for x in parent['partial'])
    assert not parent['unavailable'], parent['unavailable']
save_result('Publish a bounded child-home board and expose omitted counts on the parent board',secondmate)

invariant()
write(EVID/'live-results.json',json.dumps(RESULTS,indent=2)+'\n')
write(EVID/'board-output.html','<!doctype html><html lang="en"><meta charset="utf-8"><title>Actual Firstmate CLI board output</title><style>body{margin:32px;background:#111;color:#eee;font:14px/1.6 monospace}pre{white-space:pre-wrap;border:1px solid #555;padding:20px}h1{font-size:22px}h2{font-size:17px}</style><h1>Actual Firstmate CLI board output</h1><p>Rendered stdout from isolated real CLI invocations. Stored post-merge verdicts are input-contract checks, not deployment proof.</p>'+''.join('<h2>'+html.escape(label)+'</h2><pre>'+html.escape(text)+'</pre>' for label,text in BOARDS))
LOG.close()
print(json.dumps(RESULTS,indent=2))
