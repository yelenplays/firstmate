import os,sys,json,pathlib,subprocess,time,signal,shutil,resource
root=pathlib.Path.cwd(); e=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M4FX8WGTCAVF0NABDEZP63VV')
w=root/'.test-validation/live-runner'; repo=w/'repo'; slots=w/'slots'
paths=['tests/'+n+'.test.sh' for n in ['fm-cd-pretool-check','fm-pr-merge','fm-supervision-instructions','fm-brief']]
for path in paths: (repo/path).write_text('#!/usr/bin/env bash\nexec '+shutil.which('python3')+' "'+str(w/'probe.py')+'"\n')
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k.startswith('HERDR_') or k in ['TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND']: env.pop(k,None)
env.update(HOME=str(root/'.test-validation/home'),TMPDIR=str(root/'.test-validation/tmp'),FM_TEST_SLOT_DIR=str(slots))
cpus=int(subprocess.check_output(['getconf','_NPROCESSORS_ONLN'],text=True)); cap=max(1,cpus//3)
held=e/'occupied-slot-events.jsonl'; admitted=e/'waiting-admission-events.jsonl'
for f in [held,admitted]:
    if f.exists(): f.unlink()
log1=open(e/'occupied-slot-holder.log','w'); log2=open(e/'waiting-admission.log','w')
holder=subprocess.Popen(['bin/fm-test-run.sh','--jobs','8',*paths],cwd=repo,env=dict(env,EVENTS=str(held),PROBE_SLEEP='7'),stdout=log1,stderr=subprocess.STDOUT,start_new_session=True)
waiter=None
try:
    end=time.monotonic()+15
    while time.monotonic()<end:
        if held.exists() and len(held.read_text().splitlines())==cap: break
        time.sleep(.05)
    assert held.exists() and len(held.read_text().splitlines())==cap,'holder scripts did not start'
    waiter=subprocess.Popen(['bin/fm-test-run.sh',paths[0]],cwd=repo,env=dict(env,EVENTS=str(admitted),PROBE_SLEEP='.1'),stdout=log2,stderr=subprocess.STDOUT,start_new_session=True)
    before=time.monotonic(); pid,status,usage=os.wait4(waiter.pid,0); waiter.returncode=os.waitstatus_to_exitcode(status)
    elapsed=time.monotonic()-before
    assert waiter.returncode==0,waiter.returncode
    cpu=usage.ru_utime+usage.ru_stime
    assert holder.wait(timeout=15)==0
    starts=[json.loads(l) for l in held.read_text().splitlines() if json.loads(l)['kind']=='start']
    ends=[json.loads(l) for l in held.read_text().splitlines() if json.loads(l)['kind']=='end']
    waitstart=json.loads(admitted.read_text().splitlines()[0])
    last_end=max(x['time'] for x in ends)
    assert waitstart['time']>=last_end,(waitstart,last_end)
    assert elapsed>=5,elapsed
    assert cpu<1.5,(cpu,elapsed)
    assert not list(slots.iterdir())
    record=dict(core_count=cpus,held_slots=cap,waiter_wall_seconds=round(elapsed,3),waiter_cpu_seconds_including_children=round(cpu,3),admission_delay_after_release_seconds=round(waitstart['time']-last_end,3),slots_released=True)
    (e/'live-slot-wait-results.json').write_text(json.dumps(record,indent=2)+'\n'); print(json.dumps(record,indent=2))
finally:
    for p in [holder,waiter]:
        if p is not None and p.poll() is None:
            p.send_signal(signal.SIGTERM); p.wait(timeout=15)
    log1.close(); log2.close()
