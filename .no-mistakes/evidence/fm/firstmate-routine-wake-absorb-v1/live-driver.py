import os, subprocess, json, pathlib, time, shlex, shutil
root=pathlib.Path.cwd(); ev=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M527NFPCVT0E1ABBY0407R58')
env=os.environ.copy()
for k in list(env):
    if k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_CREW_STATE_BIN','FM_CAPTAIN_HOLD_BIN') or (k.startswith('FM_') and k.endswith('_OVERRIDE')) or k.startswith('HERDR_'):
        env.pop(k,None)
env['FM_HERDR_LAB_STATE_DIR']=str(root/'.gate-test/herdr')
home=root/'.gate-test/scenario-home'; state=home/'state'
subprocess.run(['bin/fm-lab-home.sh','create',str(home)],env=env,check=True)
env['FM_HOME']=str(home); env.update(FM_POLL='1',FM_SIGNAL_GRACE='1',FM_HEARTBEAT='999999',FM_SUPERVISION_MODEL='autoarm')
log=(ev/'live-triage.log').open('w'); results=[]; arm=None; holder=None

def run(args,timeout=35,closed=False):
    log.write('$ '+' '.join(shlex.quote(str(a)) for a in args)+(' [stdout closed]' if closed else '')+'\n'); log.flush()
    if closed:
        p=subprocess.run(args,env=env,text=True,stderr=subprocess.PIPE,preexec_fn=lambda:os.close(1),timeout=timeout)
        p.stdout=''
    else:
        p=subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    log.write((p.stdout or '')+(p.stderr or '')+f'\nexit={p.returncode}\n'); log.flush(); return p

def lab(*args,timeout=40,check=True):
    p=run(['bin/fm-herdr-lab.sh',*args],timeout)
    if check and p.returncode: raise RuntimeError(p.stdout+p.stderr)
    return p

def append(kind,key,payload):
    p=run(['bash','-c','. "$1"; fm_wake_append "$2" "$3" "$4"','_',str(root/'bin/fm-wake-lib.sh'),kind,key,payload]); assert p.returncode==0

def triage(expected=10,closed=False,manual=False):
    p=run(['bin/fm-wake-triage.sh']+([] if manual else ['--absorb']),closed=closed)
    assert p.returncode==expected, (p.returncode,p.stdout,p.stderr)
    return p.stdout

def ack(out):
    cmd=next(l.split('run ',1)[1] for l in out.splitlines() if l.startswith('WAKE_ACK_REQUIRED:'))
    p=run(shlex.split(cmd)); assert p.returncode==0

def queued():
    q=state/'.wake-queue'; return q.read_text() if q.exists() else ''

def check(name,fn):
    log.write('\n=== '+name+' ===\n');log.flush()
    try:
        fn(); results.append({'name':name,'result':'pass','live':True})
    except Exception as e:
        results.append({'name':name,'result':'fail','live':True,'error':repr(e)})
        raise
name=lab('name','routine-live').stdout.strip()
try:
    lab('provision',name,timeout=85)
    ws=json.loads(lab('run',name,'workspace','create','--cwd',str(root),'--label','routine-live','--env','FM_HOME='+str(home),'--no-focus').stdout)
    pane=ws['result']['root_pane']['pane_id']; endpoint=name+':'+pane
    lab('run',name,'agent','start','routine-worker','--kind','claude','--pane',pane,'--timeout','30000',timeout=45)
    lab('run',name,'agent','prompt',pane,'Captain-approved test-only action: run /bin/sleep 300 directly using the Bash tool, in the foreground, then reply DONE. Do not edit files, inspect projects, start workers, or do any other work. This is a disposable test session.','--wait','--until','working','--timeout','20000',timeout=30)
    (state/'routine.meta').write_text(f'kind=scout\nharness=claude\nbackend=herdr\nwindow={endpoint}\nherdr_session={name}\nherdr_pane_id={pane}\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nworktree={root}\n')
    (state/'routine.status').write_text('working: bounded live verification\n')
    crew=run(['bin/fm-crew-state.sh','routine']); assert 'state: working' in crew.stdout and 'source: pane' in crew.stdout, crew.stdout
    lab('run',name,'agent','read',pane,'--source','visible')
    armout=(ev/'live-watcher.log').open('w')
    arm=subprocess.Popen(['bin/fm-watch-arm.sh'],env=env,stdout=armout,stderr=subprocess.STDOUT,start_new_session=True)
    for _ in range(100):
        if (state/'.last-watcher-beat').exists(): break
        if arm.poll() is not None: raise RuntimeError('watcher ended before beacon')
        time.sleep(.1)
    assert (state/'.last-watcher-beat').exists()
    def routine():
        append('stale',endpoint,'stale: '+endpoint)
        out=triage(0); assert 'WAKE_ACKED:' in out and not queued()
    check('A working real Claude worker has a routine wake acknowledged by triage',routine)
    # End the real watcher cycle before controlled status-write/notification races.
    # Autoarm's fresh between-turn beacon is the production continuity model here.
    p=run(['bin/fm-watch-arm.sh','--stop']); assert p.returncode==0
    arm.wait(timeout=10)
    def mixed():
        (state/'finished.meta').write_text('kind=scout\nwindow=unavailable:finished\n')
        (state/'finished.status').write_text('done: bounded work complete\n')
        append('stale',endpoint,'stale: '+endpoint); append('signal','finished.status','signal: finished.status')
        out=triage(); assert 'ROUTINE ROWS ACKNOWLEDGED BY TRIAGE:' in out
        assert 'finished.status' in queued() and endpoint not in queued(); ack(out); assert not queued()
    check('Mixed wake retires routine rows but preserves a completed outcome for firstmate',mixed)
    def decisions():
        (state/'other.meta').write_text('kind=scout\n')
        (state/'other.status').write_text('needs-decision [key=route]: choose live lane\n')
        append('stale',endpoint,'stale: '+endpoint)
        out=triage(); assert 'C4 new open decision: other [key=route] needs-decision: choose live lane' in out and queued(); ack(out)
        append('stale',endpoint,'stale: '+endpoint); out=triage(0); assert not queued()
        with (state/'other.status').open('a') as f:f.write('needs-decision [key=route]: choose changed live lane\n')
        append('stale',endpoint,'stale: '+endpoint)
        out=triage(); assert 'C4 new open decision: other [key=route] needs-decision: choose changed live lane' in out; ack(out)
    check('An unqueued new or changed decision stays actionable; only a delivered unchanged decision is absorbable',decisions)
    def execution():
        shutil.copyfile(root/'.tasks.toml',home/'.tasks.toml')
        (home/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
        p=run(['tasks-axi','add','accepted','Implement accepted feature','--kind','ship','--file',str(home/'data/backlog.md')]); assert p.returncode==0
        p=run(['bin/fm-task-execution.sh','approve','accepted','--basis','captain-approved']); assert p.returncode==0
        append('stale',endpoint,'stale: '+endpoint)
        out=triage(); assert 'accepted - C8 new execution obligation owned by firstmate: implementation owner missing' in out and queued(); ack(out)
        append('stale',endpoint,'stale: '+endpoint); triage(0); assert not queued()
    check('Approval before notification exposes a firstmate-owned execution obligation once and remembers successful delivery',execution)
    def corrupt_execution():
        (state/'broken.execution').write_text('not a record\n')
        append('stale',endpoint,'stale: '+endpoint)
        out=triage(); assert 'broken - C8 new execution obligation owned by firstmate: reconcile-corrupt-execution-record' in out; ack(out)
        append('stale',endpoint,'stale: '+endpoint); triage(0); assert not queued()
    check('A corrupt execution record requires firstmate once, then only a successfully delivered unchanged obligation is absorbable',corrupt_execution)
    def manual_decision():
        (state/'manual.meta').write_text('kind=scout\n')
        (state/'manual.status').write_text('needs-decision [key=manual]: manual presentation provenance\n')
        append('stale',endpoint,'stale: '+endpoint)
        out=triage(0,manual=True); assert 'C4 new open decision: manual [key=manual]' in out; ack(out)
        append('stale',endpoint,'stale: '+endpoint); out=triage(0);assert 'C4 new open decision: manual' not in out and not queued()
    check('Manual triage presents a previously unseen decision once and records successful delivery for later absorption',manual_decision)
    def capped_decisions():
        for i in range(30):
            (state/f'cap{i}.meta').write_text('kind=scout\n')
            (state/f'cap{i}.status').write_text('needs-decision [key=cap]: '+('x'*1700)+'\n')
        for _ in range(2):
            append('stale',endpoint,'stale: '+endpoint)
            out=triage(); assert 'C4 open decisions omitted by the byte cap' in out and queued(); ack(out)
        for i in range(30):
            (state/f'cap{i}.meta').unlink(); (state/f'cap{i}.status').unlink()
    check('A byte-capped decision list refuses whole-batch absorption even after its visible entries were presented',capped_decisions)
    def failed_delivery():
        (state/'notice.meta').write_text('kind=scout\n')
        (state/'notice.status').write_text('note: one-shot live answer must survive\n')
        append('stale',endpoint,'stale: '+endpoint)
        triage(1,closed=True); pending=list(state.glob('.wake-triage.pending.*')); assert len(pending)==1 and 'one-shot live answer' in pending[0].read_text()
        global holder
        holder=subprocess.Popen(['bash','-c','. "$1"; fm_lock_acquire_wait "$2" || exit 1; echo ready > "$3"; exec sleep 60','_',str(root/'bin/fm-wake-lib.sh'),str(state/'.wake-queue.lock'),str(home/'ready')],env=env)
        for _ in range(100):
            if (home/'ready').exists():break
            time.sleep(.05)
        assert (home/'ready').exists()
        env['FM_STATUS_PRESENTATION_LOCK_TIMEOUT']='1'
        try: triage(1,closed=True)
        finally: holder.terminate(); holder.wait(); holder=None;env.pop('FM_STATUS_PRESENTATION_LOCK_TIMEOUT')
        assert len(list(state.glob('.wake-triage.pending.*')))==2
        assert 'one-shot live answer' in pending[0].read_text()
        out=triage(); assert 'RECOVERED DRAIN OUTPUT' in out and 'one-shot live answer' in out and 'WAKE_ACKED:' not in out
        assert not list(state.glob('.wake-triage.pending.*')); ack(out)
    check('Closed stdout preserves a one-shot notice, including a no-ack lock-contended replay, until successful delivery',failed_delivery)
    def routine_failure():
        append('stale',endpoint,'stale: '+endpoint)
        triage(1,closed=True); assert not queued() and list(state.glob('.wake-triage.pending.*'))
        append('stale',endpoint,'stale: '+endpoint)
        out=triage();assert 'RECOVERED DRAIN OUTPUT' in out and 'WAKE_ACKED:' not in out and queued();ack(out)
    check('Even an acknowledged all-routine presentation survives failed delivery and prevents absorption on replay',routine_failure)
    def away():
        (state/'.afk').touch();append('stale',endpoint,'stale: '+endpoint)
        out=triage(); assert 'WAKE_ACKED:' not in out and queued(); (state/'.afk').unlink();ack(out)
    check('Away-mode ownership prevents triage from acknowledging a routine wake',away)
finally:
    if holder is not None:holder.terminate();holder.wait()
    if arm is not None:
        run(['bin/fm-watch-arm.sh','--stop'])
        try:arm.wait(timeout=10)
        except subprocess.TimeoutExpired:
            import signal
            os.killpg(arm.pid,signal.SIGTERM);arm.wait(timeout=10)
        armout.close()
    lab('run',name,'agent','read','w1:p1','--source','visible',check=False)
    lab('teardown',name,timeout=45,check=False)
    (ev/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(home)
    log.close()
