#!/usr/bin/env python3
import json, os, pathlib, re, shlex, shutil, signal, subprocess, time
ROOT=pathlib.Path.cwd(); EV=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M52YXRVTHRP8ZG402N2BVNCV')
home=ROOT/'.phase-claude-routine'; state=home/'state'; control=ROOT/'.phase-herdr-control'
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','STATE','PI_CODING_AGENT','PI_CODING_AGENT_DIR','CLAUDECODE')}
env.update(FM_HOME=str(home),FM_SUPERVISION_MODEL='autoarm',FM_HERDR_LAB_STATE_DIR=str(control))
log=(EV/'live-routine-lab.log').open('w'); result=[]; processes=[]; files=[]; session=None

def cmd(args,ok=None,**kw):
    print('$ '+shlex.join(map(str,args)),file=log,flush=True)
    p=subprocess.run(list(map(str,args)),env=env,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=kw.pop('timeout',90),**kw)
    print(p.stdout+'\nEXIT='+str(p.returncode),file=log,flush=True)
    if ok is not None: assert p.returncode==ok,p.stdout
    return p.returncode,p.stdout

def lab(*args): return cmd(['bin/fm-herdr-lab.sh','run',session,*args])
def queue(key): cmd(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append stale "$1" "stale: $1"','_',key],0)
def ack(out):
    line=re.findall(r'^WAKE_ACK_REQUIRED: after handling completes run (.+)$',out,re.M)[-1]
    cmd(shlex.split(line),0)
def start_arm(predecessor=None):
    e=dict(env,FM_POLL='1',FM_SIGNAL_GRACE='1',FM_HEARTBEAT='999999',FM_CHECK_INTERVAL='999999')
    if predecessor: e['FM_WATCH_PREDECESSOR_ARM_PID']=str(predecessor)
    file=(EV/f'routine-arm-{len(processes)}.log').open('w'); files.append(file)
    p=subprocess.Popen(['bin/fm-watch-arm.sh'],cwd=ROOT,env=e,stdout=file,stderr=subprocess.STDOUT,start_new_session=True)
    processes.append(p)
    return p

def wait_started(p):
    deadline=time.monotonic()+20
    while time.monotonic()<deadline:
        if (state/'.last-watcher-beat').exists() and (state/'.watch.lock/pid').exists() and p.poll() is None:
            time.sleep(.2); return
        if p.poll() is not None: raise RuntimeError('real watcher closed before startup')
        time.sleep(.1)
    raise RuntimeError('real watcher did not publish a beacon')

try:
    cmd(['bin/fm-lab-home.sh','create',home],0)
    shutil.copyfile(ROOT/'.tasks.toml',home/'.tasks.toml')
    (home/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    _,session=cmd(['bin/fm-herdr-lab.sh','name','routine']); session=session.strip()
    cmd(['bin/fm-herdr-lab.sh','provision',session],0)
    cmd(['bin/fm-herdr-lab.sh','viewer','start',session],0)
    rc,out=lab('workspace','create','--cwd',str(ROOT),'--label','routine-proof','--no-focus'); assert rc==0
    ws=json.loads(out)['result']; pane=ws['root_pane']['pane_id']
    lab('pane','get',pane)
    # Launch exactly the real harness with its normal login, no test executable or login replacement.
    rc,out=lab('pane','run',pane,'env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='+shlex.quote(str(home))+' claude'); assert rc==0
    ready=False; screen=''
    for _ in range(20):
        time.sleep(1)
        rc,screen=lab('pane','read',pane,'--source','visible')
        if any(x in screen for x in ('Yes, I trust this folder','Select login method','Welcome to Claude Code','Please run /login','Sign in','trust this workspace')):
            raise RuntimeError('Real Claude stopped at setup/trust/login; accepting it could mutate user-level configuration outside the worktree. Provide an already trusted checkout and existing normal login. Captured pane follows in log.')
        rc,agent=lab('agent','get',pane)
        if rc==0:
            data=json.loads(agent).get('result',{}).get('agent',{})
            if data.get('agent_status') in ('idle','done') and ('❯' in screen or '> ' in screen): ready=True; break
    if not ready: raise RuntimeError('Real Claude never exposed a ready composer within the bounded startup window; see captured pane.')
    prompt='Isolated validation task only: use Bash to execute sleep 180, then reply done. Do not run other commands, repository startup, or fleet operations. Do not edit any files.'
    lab('pane','send-text',pane,prompt)
    time.sleep(1)
    lab('pane','send-keys',pane,'enter')
    time.sleep(1)
    # Claude can consume the first Enter settling a paste; a second Enter submits the still-pending composer.
    lab('pane','send-keys',pane,'enter')
    # State is the real running Claude endpoint. No semantic busy records or crew-state stubs are injected.
    (state/'routine.meta').write_text('kind=scout\nharness=claude\nbackend=herdr\nworktree='+str(ROOT)+'\nwindow='+session+':'+pane+'\nherdr_session='+session+'\nherdr_pane_id='+pane+'\n')
    (state/'routine.status').write_text('working: executing isolated validation command\n')
    working=False
    for _ in range(25):
        time.sleep(1)
        rc,out=cmd(['bin/fm-crew-state.sh','routine'])
        if 'state: working · source: pane' in out: working=True; break
        rc,screen=lab('pane','read',pane,'--source','visible')
        if 'sleep 180' in screen and 'Do you want to proceed?' in screen:
            # The default choice allows only this one sleep tool use, not future permissions.
            lab('pane','send-keys',pane,'enter')
    if not working: raise RuntimeError('Actual Claude endpoint never supplied verified working evidence; routine downgrade must remain untested.')
    queue(session+':'+pane)
    first=start_arm()
    first.wait(timeout=30)
    _,out=cmd(['bin/fm-wake-triage.sh']); ack(out)
    successor=start_arm(first.pid); wait_started(successor)
    queue(session+':'+pane)
    rc,out=cmd(['/bin/bash','bin/fm-wake-triage.sh','--absorb'])
    if rc!=0 or 'WAKE_ACKED:' not in out:
        raise RuntimeError('Real-worker routine attempt did not isolate the all-routine path; inspect CLI transcript for confounding watcher state.')
    assert not (state/'.wake-queue').read_text()
    result.append(dict(name='All-routine triage acknowledges a real working Claude endpoint',result='pass',live=True))
    # On a failed presentation the routine rows may already be acknowledged, but pending output must survive.
    queue(session+':'+pane)
    rc,out=cmd(['/bin/bash','bin/fm-wake-triage.sh','--absorb'],preexec_fn=lambda:os.close(1))
    assert rc!=0 and list(state.glob('.wake-triage.pending.*')) and not (state/'.wake-queue').read_text()
    queue(session+':'+pane)
    rc,out=cmd(['/bin/bash','bin/fm-wake-triage.sh','--absorb'])
    assert rc==10 and 'RECOVERED DRAIN OUTPUT' in out and 'WAKE_ACKED:' not in out and (state/'.wake-queue').read_text()
    assert not list(state.glob('.wake-triage.pending.*'))
    result.append(dict(name='Closed all-routine stdout keeps output until non-absorbing replay',result='pass',live=True))
    ack(out)
    queue(session+':'+pane)
    (state/'finished.meta').write_text('kind=ship\n')
    (state/'finished.status').write_text('done: validation result ready for captain\n')
    cmd(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append signal finished.status "signal: finished.status"'],0)
    rc,out=cmd(['bin/fm-wake-triage.sh','--absorb'])
    assert rc==10 and 'ROUTINE ROWS ACKNOWLEDGED BY TRIAGE:' in out
    remaining=(state/'.wake-queue').read_text()
    assert 'finished.status' in remaining and 'stale: '+session+':'+pane not in remaining
    cutoff=int(re.findall(r'--ack-through ([0-9]+)',out)[-1])
    print('Persisted mixed queue before final acknowledgement:\n'+remaining,file=log,flush=True)
    ack(out)
    after=(state/'.wake-queue').read_text()
    print('Persisted queue after acknowledgement (new concurrent rows must remain):\n'+after,file=log,flush=True)
    assert all(int(row.split('\t')[1])>cutoff for row in after.splitlines()), 'acknowledgement retained a presented row'
    result.append(dict(name='Mixed triage retires the real-worker routine row and leaves the captain row for one acknowledgement',result='pass',live=True))
except Exception as e:
    print('BLOCKER: '+repr(e),file=log,flush=True)
    result.append(dict(name='Real-worker routine triage and routine interrupted delivery',result='fail' if isinstance(e,AssertionError) else 'untested',live=isinstance(e,AssertionError),reason=str(e) or repr(e)))
finally:
    if state.exists(): cmd(['bin/fm-watch-arm.sh','--stop'])
    for p in processes:
        if p.poll() is None:
            os.killpg(p.pid,signal.SIGTERM)
            try: p.wait(timeout=10)
            except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait()
    for f in files: f.close()
    if session: cmd(['bin/fm-herdr-lab.sh','teardown',session])
    shutil.rmtree(home,ignore_errors=True); shutil.rmtree(control,ignore_errors=True)
    (EV/'live-routine-results.json').write_text(json.dumps(result,indent=2)+'\n')
    log.close()
print(json.dumps(result,indent=2))
