exec(open('.test-runtime/live.py').read().split("for task in ['task-x1'")[0])
import signal
records=[]
for sig in ['status','turn-ended']:
 h=home_for('staleness-retry-'+sig);s=h/'state';e=env_for(h);e['FM_SIGNAL_GRACE']='0';e['FM_HEARTBEAT']='1'
 (s/'locked.meta').write_text(f'window=firstmate:fm-locked\nendpoint_task_id=locked\nbackend=tmux\nworktree={h}/gone\nproject={h}/gone-project\nkind=ship\nmode=local-only\nspawn_gen=live-locked\n');(s/'.last-watcher-beat').touch()
 t=subprocess.Popen([str(root/'bin/fm-teardown.sh'),'locked'],env=e,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 lock=s/'.meta-locked.lock'
 try:
  for _ in range(20000):
   if (lock/'pid').exists():
    os.kill(t.pid,signal.SIGSTOP);break
   if t.poll() is not None:raise Exception('teardown completed before pause')
   time.sleep(.001)
  assert lock.exists()
  (s/('locked.'+sig)).write_text('done: cleanup in progress\n')
  (s/'other.status').write_text('done: unrelated review required\n')
  rc,txt=run(['bash','-c','. "$1"; fm_wake_status_reported_commit "$STATE" "$STATE/other.status" "$(fm_wake_signal_sig "$STATE/other.status")"','_',str(root/'bin/fm-wake-lib.sh')],e);assert rc==0,txt
  os.utime(s/'.last-heartbeat',(1,1)) if (s/'.last-heartbeat').exists() else (s/'.last-heartbeat').touch()
  os.utime(s/'.last-heartbeat',(1,1))
  outputs=[]
  for _ in range(2):
   rc,txt=run([str(root/'bin/fm-watch.sh')],e);outputs.append(txt);assert rc==0,txt
   rc,drain=run([str(root/'bin/fm-wake-drain.sh')],e)
   import re
   ack=re.search(r'--ack-through (\d+) --recovery-generation (\S+)',drain)
   if ack:
    rc,aout=run([str(root/'bin/fm-wake-drain.sh'),'--ack-through',ack[1],'--recovery-generation',ack[2]],e);assert rc==0,aout
   if 'heartbeat' in txt:break
  assert any(x.strip()=='heartbeat' for x in outputs),outputs
  assert lock.exists() and (s/'.hb-surfaced-other').exists()
  if sig=='status': assert any('locked.status' in x for x in outputs),outputs
  if sig=='turn-ended': assert not (s/'.seen-locked_turn-ended').exists()
  (s/'other.meta').write_text(f'window=firstmate:fm-other\nendpoint_task_id=other\nbackend=tmux\nkind=ship\nspawn_gen=live-other\n')
  rc,txt=run(['tmux','new-session','-d','-s','firstmate','-n','fm-other','-x','120','-y','40','sleep 300'],e);assert rc==0,txt
  try:
   e['FM_HEARTBEAT']='999999'
   rc,stale=run([str(root/'bin/fm-watch.sh')],e);assert rc==0 and 'stale:' in stale and 'fm-other' in stale,stale
   assert lock.exists()
  finally:run(['tmux','kill-server'],e)
  records.append(dict(signal=sig,watch_outputs=outputs,staleness_output=stale,teardown_lock_still_held=True,other_heartbeat_surfaced=True))
 finally:
  os.kill(t.pid,signal.SIGCONT);out=t.communicate(timeout=40)[0];(evidence/('staleness-'+sig+'-teardown.log')).write_text(out)
(evidence/'staleness-results.json').write_text(json.dumps(records,indent=2));print(json.dumps(records,indent=2))
