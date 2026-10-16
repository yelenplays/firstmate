#!/usr/bin/env python3
"""Exact-head public CLI journeys. No dependency stubs or production homes."""
import contextlib, glob, json, os, pathlib, re, shlex, shutil, subprocess, time
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M52YXRVTHRP8ZG402N2BVNCV')
BASE = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('STATE','TMUX')}
RESULTS = []
LOG = (EVIDENCE/'live-cli-transcript.log').open('w')
def log(s):
    print(s, file=LOG, flush=True)
def run(home, argv, expected=None, extra=None, closed=False, timeout=90):
    env = dict(BASE, FM_HOME=str(home), FM_SUPERVISION_MODEL='autoarm')
    env.update(extra or {})
    log('$ FM_HOME=<isolated '+home.name+'> '+shlex.join(map(str,argv))+(' [stdout closed]' if closed else ''))
    def close_stdout(): os.close(1)
    p = subprocess.run(list(map(str,argv)), cwd=ROOT, env=env, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, timeout=timeout,
        preexec_fn=close_stdout if closed else None)
    out=p.stdout+p.stderr
    log(out.rstrip()+'\nEXIT='+str(p.returncode))
    if expected is not None: assert p.returncode==expected, (argv,p.returncode,out)
    return p.returncode,out

def standalone_triage(home):
    # A standalone shell is not a Pi primary. The Pi branch extension owns
    # Pi outcome presentation; the host drain is exercised outside that ancestry.
    output=home/'standalone-output'; done=home/'standalone-exit'; harness=home/'standalone-harness'
    env=dict(BASE, FM_HOME=str(home), FM_SUPERVISION_MODEL='autoarm')
    for key in ('PI_CODING_AGENT','PI_CODING_AGENT_DIR','CLAUDECODE','CURSOR_AGENT','CURSOR_INVOKED_AS','GEMINI_CLI','GROK_AGENT','ROVODEV_CLI','ATLASSIAN_AGENT_TYPE'):
        env.pop(key,None)
    source='''import os, pathlib, subprocess, sys, time
pid=os.fork()
if pid: os._exit(0)
end=time.monotonic()+10
while os.getppid()!=1 and time.monotonic()<end: time.sleep(.01)
base=pathlib.Path(sys.argv[1])
with (base/'standalone-harness').open('w') as f: subprocess.run(['bin/fm-harness.sh'],stdout=f)
with (base/'standalone-output').open('w') as f: p=subprocess.run(['/bin/bash','bin/fm-wake-triage.sh','--absorb'],stdout=f,stderr=subprocess.STDOUT)
(base/'standalone-exit').write_text(str(p.returncode))
'''
    p=subprocess.Popen(['python3','-c',source,str(home)],cwd=ROOT,env=env,start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    p.wait(timeout=10)
    deadline=time.monotonic()+120
    while not done.exists() and time.monotonic()<deadline: time.sleep(.1)
    if not done.exists():
        import signal
        os.killpg(p.pid,signal.SIGTERM)
        raise AssertionError('standalone triage did not finish')
    out=output.read_text(); rc=int(done.read_text())
    log('$ standalone FM_HOME=<isolated '+home.name+'> /bin/bash bin/fm-wake-triage.sh --absorb')
    log('Actual harness detection: '+harness.read_text().strip()+'\n'+out+'\nEXIT='+str(rc))
    return rc,out

def queue(home, kind, key, payload):
    return run(home,['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append "$1" "$2" "$3"','_',kind,key,payload],0)
def queued(home):
    f=home/'state/.wake-queue'
    return f.read_text() if f.exists() else ''
def ack(home, out):
    lines=re.findall(r'^WAKE_ACK_REQUIRED: after handling completes run (.+)$',out,re.M)
    assert lines, out
    run(home,shlex.split(lines[-1]),0)
def status(home, id, text):
    # Status logs are the worker-published input contract, not implementation source.
    (home/f'state/{id}.meta').write_text('kind=ship\n')
    (home/f'state/{id}.status').write_text(text)
    log('worker-published status '+id+': '+repr(text))
@contextlib.contextmanager
def lab(name):
    home=ROOT/('.phase-live-'+name)
    assert not home.exists()
    run(home,['bin/fm-lab-home.sh','create',str(home)],0)
    shutil.copyfile(ROOT/'.tasks.toml',home/'.tasks.toml')
    (home/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    try: yield home
    finally:
        shutil.rmtree(home)
        log('Removed isolated home '+home.name)
def scenario(name,fn):
    log('\n===== '+name+' =====')
    try:
        fn()
        RESULTS.append(dict(name=name,result='pass',live=True))
        log('SCENARIO PASS')
    except Exception as e:
        RESULTS.append(dict(name=name,result='fail',live=True,reason=str(e)))
        log('SCENARIO FAIL: '+repr(e))

def decisions():
    with lab('decisions') as h:
        status(h,'decision','needs-decision [key=lane]: Choose blue or green\n')
        queue(h,'check','manual-review','check: manual-review')
        assert 'decision.status' not in queued(h)
        _,out=run(h,['bin/fm-wake-triage.sh','--absorb'],10)
        assert 'C4 new or changed open decision: decision [key=lane] needs-decision: Choose blue or green' in out
        assert 'WAKE_ACKED:' not in out and queued(h)
        ack(h,out)
        assert not queued(h)
        queue(h,'check','manual-review','check: manual-review')
        _,out=run(h,['bin/fm-wake-triage.sh','--absorb'],10)
        assert 'none new or changed since the last presentation' in out
        assert 'C4 new or changed open decision' not in out
        ack(h,out)
        status(h,'decision','needs-decision [key=lane]: Choose blue or green\nneeds-decision [key=lane]: Choose green by Friday\n')
        queue(h,'check','manual-review','check: manual-review')
        _,out=run(h,['/bin/bash','bin/fm-wake-triage.sh','--absorb'],10)
        assert 'C4 new or changed open decision: decision [key=lane] needs-decision: Choose green by Friday' in out
        ack(h,out)
        run(h,['/bin/bash','bin/fm-wake-triage.sh','--decisions'],0)
        status(h,'decision','needs-decision [key=lane]: Choose green by Friday\nresolved [key=lane]: green\n')
        run(h,['bin/fm-wake-triage.sh'],0)
        with (h/'state/decision.status').open('a') as f: f.write('needs-decision [key=lane]: Choose green by Friday\n')
        _,out=run(h,['bin/fm-wake-triage.sh'],0)
        assert 'C4 new or changed open decision: decision [key=lane] needs-decision: Choose green by Friday' in out
        log('Decision ledger contract: new, changed and reopened decisions were ACT NOW; unchanged decision was count-only; --decisions enumerated the decision.')

def execution():
    with lab('execution') as h:
        run(h,['tasks-axi','add','approved','Implement approved feature','--kind','ship','--file',h/'data/backlog.md'],0)
        run(h,['bin/fm-task-execution.sh','approve','approved','--basis','captain-approved'],0)
        queue(h,'check','manual-review','check: manual-review')
        assert 'execution:approved' not in queued(h)
        _,out=run(h,['bin/fm-wake-triage.sh','--absorb'],10)
        assert 'approved - C8 new execution obligation owned by firstmate: implementation owner missing' in out
        ack(h,out)
        _,out=run(h,['bin/fm-wake-triage.sh','--absorb'],10)
        assert 'UNFINISHED EXECUTION' in out and 'C8 new execution obligation' not in out
        assert 'approved\tfirstmate\timplementation owner missing' in (h/'state/.wake-triage.execution').read_text()
        (h/'state/corrupt.execution').write_text('broken record\n')
        _,out=run(h,['/bin/bash','bin/fm-wake-triage.sh','--absorb'],10)
        assert 'corrupt - C8 new execution obligation owned by firstmate: reconcile-corrupt-execution-record' in out
        log('Delivered execution obligations were recorded; an unnotified approval and a corrupt record each reached ACT NOW with next action.')

def safety():
    with lab('safety') as h:
        for id,txt in [('decision','needs-decision [key=k]: captain must choose\n'),('paused','paused: waiting for captain\n'),('failed','failed: build failed\n'),('blocked','blocked: credentials missing\n'),('finished','done: implementation complete\n')]:
            status(h,id,txt)
            queue(h,'signal',id+'.status','signal: '+id+'.status')
        _,out=run(h,['bin/fm-wake-triage.sh','--absorb'],10)
        for text in ['C4 open decision','C5 paused/captain-held status','C7 latest status is captain-relevant']: assert text in out, text
        assert len(queued(h).splitlines())==5 and 'WAKE_ACKED:' not in out
        ack(h,out)
        assert not queued(h)
        # Branch outcomes are produced by the public append interface and surfaced by a host-enabled drain.
        (h/'config/supervision-host').touch()
        run(h,['bin/fm-branch-outcome.sh','append','--task','finished','--verdict','captain','--summary','Review approved delivery before merging'],0)
        queue(h,'check','manual-review','check: manual-review')
        (h/'config/supervision-host').write_text('claude\n')
        rc,out=standalone_triage(h)
        assert rc==10
        assert 'BRANCH OUTCOMES' in out and 'Review approved delivery before merging' in out
        assert 'WAKE_ACKED:' not in out and queued(h)
        log('Five captain-relevant status rows and a real stored captain branch outcome stayed unacknowledged until manual handling.')

def selective_ack():
    with lab('row-ack') as h:
        queue(h,'check','first','check: first')
        queue(h,'check','second','check: second')
        _,out=run(h,['bin/fm-wake-drain.sh'],0)
        generation=re.findall('--recovery-generation ([A-Za-z0-9._-]+)',out)[-1]
        rows=queued(h).splitlines(); seq1=rows[0].split('\t')[1]; seq2=rows[1].split('\t')[1]
        run(h,['bin/fm-wake-drain.sh','--ack-rows',seq1,'--recovery-generation',generation],0)
        assert 'check: first' not in queued(h) and 'check: second' in queued(h)
        log('Persisted queue after selective acknowledgement:\n'+queued(h))
        ack(h,out)
        assert not queued(h)
        queue(h,'check','third','check: third')
        _,new=run(h,['bin/fm-wake-drain.sh'],0)
        # Earlier generation may return an idempotent no-op but must never consume the new row.
        run(h,['bin/fm-wake-drain.sh','--ack-through',seq2,'--recovery-generation',generation])
        assert 'check: third' in queued(h)
        ack(h,new); assert not queued(h)
        log('Old generation did not consume the later row; the new presentation command did.')

def delivery():
    with lab('delivery') as h:
        status(h,'notice','working: implementing\nnote: one-shot captain answer 548b8aa\n')
        queue(h,'check','manual-review','check: manual-review')
        rc,_=run(h,['/bin/bash','bin/fm-wake-triage.sh','--absorb'],closed=True)
        assert rc!=0
        pending=list((h/'state').glob('.wake-triage.pending.*'))
        assert len(pending)==1 and 'one-shot captain answer 548b8aa' in pending[0].read_text()
        original=pending[0]
        assert queued(h) and not (h/'state/.wake-triage.last').exists()
        # Hold the real product queue lock so the fresh drain returns no acknowledgement command.
        ready=h/'queue-ready'
        holder=subprocess.Popen(['bash','-c','. bin/fm-wake-lib.sh; fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit 1; trap \'fm_lock_release "$FM_WAKE_QUEUE_LOCK"; exit\' TERM INT; printf ready > "$1"; sleep 35 & wait','_',str(ready)],cwd=ROOT,env=dict(BASE,FM_HOME=str(h)),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
        try:
            deadline=time.monotonic()+10
            while not ready.exists() and time.monotonic()<deadline: time.sleep(.05)
            assert ready.exists()
            rc,_=run(h,['/bin/bash','bin/fm-wake-triage.sh','--absorb'],extra={'FM_STATUS_PRESENTATION_LOCK_TIMEOUT':'1'},closed=True)
            assert rc==1 and original.exists()
            pending=list((h/'state').glob('.wake-triage.pending.*')); assert len(pending)==2
            fresh=[p for p in pending if p!=original][0].read_text()
            assert 'WAKE DRAIN SKIPPED: queue lock remains held' in fresh and 'WAKE_ACK_REQUIRED:' not in fresh
            log('Retained pending presentations after closed no-ack replay:\n'+original.read_text()+'\n---second pending---\n'+fresh)
        finally:
            import signal
            os.killpg(holder.pid,signal.SIGTERM)
            holder.wait(timeout=10)
        _,out=run(h,['/bin/bash','bin/fm-wake-triage.sh','--absorb'],10)
        assert 'RECOVERED DRAIN OUTPUT' in out and 'one-shot captain answer 548b8aa' in out
        assert 'WAKE_ACKED:' not in out and queued(h)
        assert not list((h/'state').glob('.wake-triage.pending.*'))
        assert (h/'state/.wake-triage.last').exists()
        ack(h,out); assert not queued(h)
        log('One-shot notice survived both failed stdout deliveries; successful replay committed pending output, refused absorption, and left explicit acknowledgement.')

try:
    log('Candidate '+subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip())
    run(ROOT,['/bin/bash','--version'],0)
    scenario('Unqueued decisions are actionable once, and changes or reopening resurface them',decisions)
    scenario('Execution approval before notification and corrupt records reach firstmate',execution)
    scenario('Captain-relevant statuses and branch outcomes are never auto-acknowledged',safety)
    scenario('Selective acknowledgement retires only presented rows and respects recovery generations',selective_ack)
    scenario('Closed stdout and no-ack replay retain a one-shot notice until delivery',delivery)
finally:
    (EVIDENCE/'live-cli-results.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
    LOG.close()
print(json.dumps(RESULTS,indent=2))
raise SystemExit(any(x['result']=='fail' for x in RESULTS))
