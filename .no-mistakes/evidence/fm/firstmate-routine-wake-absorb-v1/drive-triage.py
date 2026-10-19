import os, pathlib, shutil, subprocess, tempfile, json, time
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5A1761RJSQ7EAB7G36QMG05')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_','CLAUDE_CODE_'))}
results=[]

def command(args, home, closed=False):
    e=dict(env, FM_HOME=str(home))
    if closed:
        p=subprocess.run(['bash','-c','exec "$@" >&-', '_']+list(map(str,args)),env=e,text=True,stderr=subprocess.PIPE,timeout=40)
        return p.returncode, p.stderr
    p=subprocess.run(list(map(str,args)),env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
    return p.returncode,p.stdout

def wake(h, kind, key, text):
    rc,out=command(['bash','-c','. "$1"; fm_wake_append "$2" "$3" "$4"','_',root/'bin/fm-wake-lib.sh',kind,key,text],h)
    assert rc==0,out

def seed(h,id,status):
    (h/'state'/f'{id}.meta').write_text(f'kind=scout\nworktree={root}\nwindow=fm-lab-no-endpoint:{id}\n')
    (h/'state'/f'{id}.status').write_text(status+'\n')

def triage(h, log, closed=False):
    rc,out=command([root/'bin/fm-wake-triage.sh','--absorb'],h,closed)
    log.append(f'$ FM_HOME=<disposable-home> bin/fm-wake-triage.sh --absorb'+(' >&-' if closed else '')+f'\nexit={rc}\n{out}')
    log.append('Persisted queue: '+repr((h/'state/.wake-queue').read_text() if (h/'state/.wake-queue').exists() else '<absent>'))
    return rc,out

def run(name, fn):
    h=pathlib.Path(tempfile.mkdtemp(prefix='.gate-live-',dir=root))
    log=[]
    try:
        rc,out=command([root/'bin/fm-lab-home.sh','create',h],h)
        assert rc==0,out
        fn(h,log)
        result='pass'
    except Exception as ex:
        result='fail';log.append('ERROR: '+str(ex))
    finally:
        shutil.rmtree(h)
    path=evidence/(name+'.log');path.write_text('\n'.join(log)+'\n')
    results.append(dict(name=name,result=result,evidence=str(path)))

def empty(h,log):
    rc,out=command(['bash','-c','. "$1"; fm_recovery_marker_publish "$STATE/.watcher-down" handling','_',root/'bin/fm-wake-lib.sh'],h)
    assert rc==0,out
    rc,out=triage(h,log)
    assert rc==0 and 'WAKE_ACKED:' in out,out
    log.append('Recovery record: '+(h/'state/.watcher-down').read_text())
    assert (h/'state/.watcher-down').read_text().startswith('acked:')

def decision(h,log):
    seed(h,'choose','needs-decision [key=lane]: choose a release lane')
    wake(h,'signal','choose.status','signal: choose.status')
    rc,out=triage(h,log)
    assert rc==10 and 'C4' in out and 'choose a release lane' in out and 'WAKE_ACKED:' not in out,out
    assert 'choose.status' in (h/'state/.wake-queue').read_text()
    rc,out=triage(h,log)
    assert rc==10 and 'C4 open decision' in out and 'WAKE_ACKED:' not in out,out

def terminal(h,log):
    seed(h,'finished','done: requested measurement is ready for review')
    wake(h,'signal','finished.status','signal: finished.status')
    rc,out=triage(h,log)
    assert rc==10 and 'ACT NOW:' in out and 'C7' in out and 'WAKE_ACKED:' not in out,out
    assert 'finished.status' in (h/'state/.wake-queue').read_text()

def execution(h,log):
    (h/'state/approved.execution').write_text('not a valid execution record\n')
    wake(h,'check','validation','check: manual reconciliation')
    rc,out=triage(h,log)
    assert rc==10 and 'C8 new execution obligation owned by firstmate' in out and 'reconcile-corrupt-execution-record' in out,out
    assert (h/'state/.wake-queue').stat().st_size>0

def outcome(h,log):
    (h/'config/supervision-host').touch()
    rc,out=command([root/'bin/fm-branch-outcome.sh','append','--task','review','--verdict','captain','--summary','review-ready result needs firstmate'],h)
    assert rc==0,out
    log.append('$ bin/fm-branch-outcome.sh append --task review --verdict captain --summary ...\n'+out)
    wake(h,'check','outcome','check: review-ready result')
    rc,out=triage(h,log)
    assert rc==10 and 'WAKE_ACKED:' not in out,out
    # This gate runs under Pi, whose extension owns outcome presentation.
    # `present` exposes unread as well as delivered-but-unprocessed captain rows.
    rc,pending=command([root/'bin/fm-branch-outcome.sh','present'],h)
    log.append('$ bin/fm-branch-outcome.sh present\n'+pending)
    assert rc==0 and 'review-ready result needs firstmate' in pending

def replay(h,log):
    seed(h,'notice','note: one-shot delivery must survive a broken output')
    wake(h,'check','notice','check: inspect notification')
    rc,out=triage(h,log,True)
    assert rc!=0
    recovered=list((h/'state').glob('.wake-triage.pending.*'))
    assert len(recovered)==1 and 'one-shot delivery' in recovered[0].read_text()
    holder=subprocess.Popen(['bash','-c','. "$1"; fm_lock_acquire_wait "$STATE/.wake-queue.lock" || exit 1; printf ready > "$FM_HOME/ready"; exec sleep 60','_',str(root/'bin/fm-wake-lib.sh')],env=dict(env,FM_HOME=str(h)))
    try:
        deadline=time.monotonic()+10
        while not (h/'ready').exists() and time.monotonic()<deadline: time.sleep(.05)
        assert (h/'ready').exists(),'lock holder failed'
        rc,out=triage(h,log,True)
        assert rc==1
        pending=list((h/'state').glob('.wake-triage.pending.*'))
        assert len(pending)==2 and recovered[0].exists()
        fresh=[p for p in pending if p!=recovered[0]][0].read_text()
        log.append('Retained contended-drain output:\n'+fresh)
        assert 'WAKE DRAIN SKIPPED: queue lock remains held' in fresh and 'WAKE_ACK_REQUIRED:' not in fresh
    finally:
        holder.terminate();holder.wait(timeout=10)
    rc,out=triage(h,log)
    assert rc==10 and 'RECOVERED DRAIN OUTPUT' in out and 'one-shot delivery must survive' in out,out
    assert not list((h/'state').glob('.wake-triage.pending.*'))
    assert (h/'state/.wake-queue').stat().st_size>0

run('live-empty-recovery-absorption',empty)
run('live-decision-remains-actionable',decision)
run('live-terminal-remains-actionable',terminal)
run('live-firstmate-execution-remains-actionable',execution)
run('live-branch-outcome-remains-unprocessed',outcome)
run('live-broken-delivery-and-noack-replay',replay)
(evidence/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
raise SystemExit(any(r['result']=='fail' for r in results))
