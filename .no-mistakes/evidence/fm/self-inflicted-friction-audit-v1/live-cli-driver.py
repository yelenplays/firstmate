import os, json, subprocess, time, pathlib, shutil, threading, signal
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5DHR1T6KYVV9PN7CDD65ME0')
env=os.environ.copy()
for k in ['FM_HOME','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_CREW_STATE_BIN','FM_CAPTAIN_HOLD_BIN']:
    env.pop(k,None)
env.update(TMPDIR=str(ROOT/'.test-tmp'), FM_HERDR_LAB_STATE_DIR=str(ROOT/'.test-tmp/herdr-lab'))
session=(ROOT/'.test-tmp/session').read_text().strip()
log=(E/'live-cli-transcript.log').open('w',buffering=1)
def call(args, extra=None, check=True, timeout=60):
    e=env.copy(); e.update(extra or {})
    log.write('$ '+ ' '.join(map(str,args))+'\n')
    p=subprocess.Popen(list(map(str,args)),env=e,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
    try: out,_=p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid,signal.SIGTERM); out,_=p.communicate(timeout=10)
        log.write(out+'\nTIMEOUT\n'); raise
    log.write(out+f'\nexit={p.returncode}\n')
    if check and p.returncode: raise RuntimeError(f'{args[0]} exited {p.returncode}')
    return out

def h(*args):
    return call(['bin/fm-herdr-lab.sh','run',session,*args])
lab=ROOT/'.test-tmp/live-home'
try:
    call(['bin/fm-lab-home.sh','create',lab])
    (lab/'config/supervision-host').touch()
    (lab/'config/task-backend').write_text('manual\n')
    (lab/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    call(['bin/fm-herdr-lab.sh','provision',session])
    created=json.loads(h('workspace','create','--label','friction-lab','--cwd',str(ROOT),'--no-focus'))
    (E/'lab-workspace.json').write_text(json.dumps(created,indent=2))
    log.write('Workspace response saved; extracting the exact created pane.\n')
    # Traverse only this creation response, never discover another workspace.
    def vals(obj,key):
        if isinstance(obj,dict):
            for k,v in obj.items():
                if k==key and isinstance(v,str): yield v
                yield from vals(v,key)
        elif isinstance(obj,list):
            for v in obj: yield from vals(v,key)
    panes=list(vals(created,'pane_id'))
    if not panes: raise RuntimeError('creation response contains no exact pane_id')
    pane=panes[0]
    state=lab/'state'
    worker=lab/'projects/worker'
    worker.mkdir()
    for i in range(1,5):
        task=f'exited-{i}'
        (state/f'{task}.meta').write_text(f'kind=ship\nharness=claude\nworktree={worker}\nbackend=herdr\nwindow={session}:{pane}\nherdr_session={session}\nherdr_pane_id={pane}\n')
        (state/f'{task}.status').write_text('working: implementation had started before agent exit\n')
    e={'FM_HOME':str(lab),'FM_BACKEND':'herdr','FM_HERDR_SESSION':session}
    # Exercise the actual local inbox against a real empty shell, with stderr suppressed.
    out=call(['bash','-c','bin/fm-send.sh exited-1 "retain this steer for recovery" 2>/dev/null'],e)
    assert out.startswith('recorded-not-delivered: exited-1 '),out
    assert len(out.splitlines())==1,out
    records=list((state/'exited-1.inbox').glob('*.msg'))
    assert len(records)==1, records
    (E/'dead-target-inbox-record.txt').write_text(records[0].read_text())
    h('pane','read',pane,'--source','visible','--format','text')
    # Queue four stale notifications using the real durable queue writer.
    for i in range(1,5):
        task=f'exited-{i}'
        call(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append stale "$1" "stale: $1"','_',f'{session}:{pane}'],e)
    # Duplicate endpoint rows intentionally coalesce; use status signals to retain each task identity.
    for i in range(1,5):
        call(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append signal "$1.status" "signal: $1.status changed"','_',f'exited-{i}'],e)
    # Sample actual live probe processes while triage runs; no substituted probe binaries.
    stopped=threading.Event(); peak=[0]; sample=['']
    def monitor():
        while not stopped.is_set():
            p=subprocess.run(['ps','-axo','pid=,ppid=,command='],capture_output=True,text=True)
            rows=[r for r in p.stdout.splitlines() if str(ROOT/'bin/fm-crew-state.sh') in r and 'ps -' not in r]
            if len(rows)>peak[0]: peak[0]=len(rows); sample[0]='\n'.join(rows)
            stopped.wait(.05)
    t=threading.Thread(target=monitor); t.start()
    try:
        out=call(['bin/fm-wake-triage.sh'],e,timeout=120)
    finally:
        stopped.set(); t.join()
    (E/'live-triage-output.txt').write_text(out)
    (E/'live-probe-concurrency.txt').write_text(f'Peak simultaneously observed real crew-state processes: {peak[0]}\n'+sample[0]+'\n')
    assert 'ACT NOW:' in out,out
    for i in range(1,5): assert f'exited-{i} - C3 crew not working' in out,out
    assert (state/'.wake-queue').stat().st_size>0
    assert peak[0]>=2,peak
    # Render real compact output without impersonating a harness; lock-refused is explicit.
    out=call(['bin/fm-session-start.sh','--reemit','--source','compact'],e,timeout=120)
    (E/'live-compact-output.txt').write_text(out)
    assert len(out.encode())<9000,len(out.encode())
    assert out.index('Condensed operating rules')<out.index('WAKE QUEUE')
    # Stress the actual compact interface with bulky state and on-demand recovery.
    long='OVERSIZED_LIVE_PAYLOAD '+('請選擇方案，確認實作狀態。'*160)
    for i in range(1,14):
        task=f'busy-{i}'
        (state/f'{task}.meta').write_text(f'kind=ship\nharness=claude\nbackend=herdr\nwindow={session}:{pane}\nherdr_session={session}\nherdr_pane_id={pane}\n')
        (state/f'{task}.status').write_text(f'working: {long}\n')
    for i in range(1,12):
        with (state/f'busy-{i%3+1}.status').open('a') as f:
            f.write(f'needs-decision [key=live-decision-{i}]: {long}\n')
    for i in range(1,4):
        call(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append signal "$1.status" "$2"','_',f'busy-{i}',long],e)
    out=call(['bin/fm-session-start.sh','--reemit','--source','compact'],e,timeout=120)
    (E/'busy-compact-output.txt').write_text(out)
    assert len(out.encode())<9000,len(out.encode())
    out.encode().decode('utf-8',errors='strict')
    assert out.index('Condensed operating rules')<out.index('WAKE QUEUE')
    detail_line=next(l for l in out.splitlines() if l.startswith('Uncut wake queue and bootstrap text: '))
    detail=pathlib.Path(detail_line.split(': ',1)[1])
    body=call(['cat',detail],e)
    (E/'busy-compact-on-demand-detail.txt').write_text(body)
    assert 'live-decision-11' in body and long in body
    # Execute the exact acknowledgement delivered by the compact interface.
    ack=next(l.split('after handling completes run ',1)[1] for l in out.splitlines() if l.startswith('WAKE_ACK_REQUIRED: '))
    call(['bash','-c',ack],e)
    assert not (state/'.wake-queue').read_text().strip()
    for harness in ['claude','pi','omp','codex']:
        rules=call(['bin/fm-supervision-instructions.sh','--harness',harness,'--state-only'],e)
        (E/f'condensed-{harness}.txt').write_text(rules)
    log.write(f'Live script checks passed. Busy multilingual compact output: {len(out.encode())} bytes; full detail recovered and printed acknowledgement cleared queue.\n')
finally:
    try: call(['bin/fm-herdr-lab.sh','teardown',session],timeout=30)
    finally:
        shutil.rmtree(lab,ignore_errors=True)
        log.close()
