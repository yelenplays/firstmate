import os, sys, pathlib, shutil, subprocess, json, time, signal
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M4FX8WGTCAVF0NABDEZP63VV')
work=root/'.test-validation/live-runner'; repo=work/'repo'; slots=work/'slots'
(repo/'bin').mkdir(parents=True,exist_ok=True); (repo/'tests').mkdir(exist_ok=True)
for f in ['fm-test-run.sh','fm-qos-lib.sh','fm-timeout-lib.sh']: shutil.copy2(root/'bin'/f,repo/'bin'/f)
for f in ['environment.sh','git-config-helpers.sh']: shutil.copy2(root/'tests'/f,repo/'tests'/f)
cpus=int(subprocess.check_output(['getconf','_NPROCESSORS_ONLN'],text=True)); cap=max(1,cpus//3)
names=['fm-cd-pretool-check','fm-pr-merge','fm-supervision-instructions','fm-brief']
paths=['tests/'+n+'.test.sh' for n in names]
probe=work/'probe.py'
probe.write_text('''import os,time,ctypes,json,sys
qos=ctypes.CDLL(None).qos_class_self()
pid=os.getpid(); file=os.environ['EVENTS']
fd=os.open(file,os.O_WRONLY|os.O_CREAT|os.O_APPEND,0o600)
def emit(kind): os.write(fd,(json.dumps(dict(kind=kind,pid=pid,time=time.monotonic(),qos=hex(qos)))+'\\n').encode())
emit('start'); print('script pid=%s qos=%s'%(pid,hex(qos)),flush=True)
time.sleep(float(os.environ.get('PROBE_SLEEP','1')))
emit('end'); os.close(fd)
''')
python=sys.executable
for path in paths:
    (repo/path).write_text('#!/usr/bin/env bash\nif [ "${NESTED:-0}" = 1 ]; then\n  NESTED=0 bin/fm-test-run.sh --jobs 8 tests/fm-cd-pretool-check.test.sh tests/fm-pr-merge.test.sh\nelse\n  exec '+shutil.which('python3')+' "'+str(probe)+'"\nfi\n')
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k.startswith('HERDR_') or k in ['TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND']: env.pop(k,None)
env.update(HOME=str(root/'.test-validation/home'),TMPDIR=str(root/'.test-validation/tmp'),FM_TEST_SLOT_DIR=str(slots))
results=[]
for old in evidence.glob('*events.jsonl'): old.unlink()
def run(label,args,extra=None):
    ee=env.copy(); ee.update(extra or {})
    log=open(evidence/(label+'.log'),'w')
    p=subprocess.Popen(['bin/fm-test-run.sh',*args],cwd=repo,env=ee,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    return p,log

def finish(p,log,expected=0):
    try: code=p.wait(timeout=65)
    except subprocess.TimeoutExpired:
        p.send_signal(signal.SIGTERM); p.wait(timeout=10); log.close(); raise
    log.close(); assert code==expected,(p.pid,code,expected)

def analyze(file,expected):
    events=[json.loads(l) for l in file.read_text().splitlines()]; live=set(); maximum=0; starts=0
    for e in sorted(events,key=lambda e:e['time']):
        assert e['qos']=='0x11',e
        if e['kind']=='start': live.add(e['pid']); starts+=1; maximum=max(maximum,len(live))
        else: live.remove(e['pid'])
    assert not live and starts==expected,(live,starts,expected)
    assert maximum<=cap,(maximum,cap)
    assert not list(slots.iterdir()),list(slots.iterdir())
    return dict(starts=starts,maximum=maximum,cap=cap,qos='0x11')
# Distinct independent runners use real core discovery and the same slot directory.
events=evidence/'concurrent-events.jsonl'
if events.exists(): events.unlink()
runs=[run('concurrent-'+str(i),(['--jobs','8'] if i<2 else [])+paths+['--json',str(evidence/('concurrent-'+str(i)+'.json'))],{'EVENTS':str(events),'PROBE_SLEEP':'2'}) for i in range(3)]
for p,log in runs: finish(p,log)
r=analyze(events,12); assert r['maximum']==cap,r
results.append(dict(name='three concurrent suites',**r))
# A dead holder and a directory without a published holder are reclaimed.
for kind in ['dead','unpublished']:
    slots.mkdir(exist_ok=True)
    dead=subprocess.Popen(['sleep','0.01']); dead.wait()
    for n in range(1,cap+1):
        d=slots/str(n); d.mkdir()
        if kind=='dead': (d/'pid').write_text(str(dead.pid)+'\n')
    event=evidence/(kind+'-events.jsonl')
    p,log=run('reclaim-'+kind,[paths[0]],{'EVENTS':str(event)}); finish(p,log)
    results.append(dict(name='reclaim '+kind,**analyze(event,1)))
# Each occupied parent launches a nested runner asking for eight jobs.
event=evidence/'nested-events.jsonl'
p,log=run('nested',['--jobs','8',*paths,'--per-script-timeout-secs','15'],{'EVENTS':str(event),'NESTED':'1'})
finish(p,log); results.append(dict(name='nested runners',**analyze(event,8)))
# Both signal paths stop a running child before releasing its slot.
for sig,code in [(signal.SIGINT,130),(signal.SIGTERM,143)]:
    event=evidence/('cancel-'+sig.name+'-events.jsonl')
    p,log=run('cancel-'+sig.name,['--jobs','8',*paths,'--per-script-timeout-secs','45'],{'EVENTS':str(event),'PROBE_SLEEP':'40'})
    deadline=time.monotonic()+15
    while time.monotonic()<deadline:
        if event.exists() and len(event.read_text().splitlines())==cap: break
        time.sleep(.1)
    assert event.exists() and len(event.read_text().splitlines())==cap,'scripts never all started'
    p.send_signal(sig); finish(p,log,code)
    deadline=time.monotonic()+10
    while list(slots.iterdir()) and time.monotonic()<deadline: time.sleep(.1)
    assert not list(slots.iterdir()),list(slots.iterdir())
    pids=[e['pid'] for e in map(json.loads,event.read_text().splitlines()) if e['kind']=='start']
    for pid in pids:
        row=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True).stdout.strip()
        assert not row or row.startswith('Z'),(pid,row)
    results.append(dict(name='cancel '+sig.name,exit=code,children_stopped=pids,slots_released=True))
# Native Perl and actual Bash fallback keep the slot until TERM-resistant scripts die.
(repo/paths[0]).write_text('#!/usr/bin/env bash\ntrap "" TERM\nprintf "%s\\n" "$$" >"$STARTED"\nwhile :; do\n  [ -f "$FM_TEST_SLOT_HELD/1/pid" ] || touch "$EARLY_RELEASE"\n  sleep .1\ndone\n')
for mechanism in ['native','bash']:
    started=work/('started-'+mechanism); early=work/('early-'+mechanism)
    result=evidence/('timeout-'+mechanism+'.json')
    p,log=run('timeout-'+mechanism,[paths[0],'--per-script-timeout-secs','2','--json',str(result)],{'FM_TIMEOUT_MECHANISM_OVERRIDE':mechanism,'STARTED':str(started),'EARLY_RELEASE':str(early)})
    finish(p,log,1)
    data=json.loads(result.read_text()); assert data['scripts'][0]['exit']==124,data
    assert started.exists() and not early.exists()
    assert 'exceeded the per-script bound of 2s' in (evidence/('timeout-'+mechanism+'.log')).read_text()
    row=subprocess.run(['ps','-p',started.read_text().strip(),'-o','stat='],capture_output=True,text=True).stdout.strip()
    assert not row or row.startswith('Z'),row
    assert not list(slots.iterdir())
    results.append(dict(name='timeout '+mechanism,script_exit=124,slot_held_until_termination=True,slots_released=True))
(evidence/'live-runner-results.json').write_text(json.dumps(dict(cpus=cpus,results=results),indent=2)+'\n')
print(json.dumps(dict(cpus=cpus,results=results),indent=2))
