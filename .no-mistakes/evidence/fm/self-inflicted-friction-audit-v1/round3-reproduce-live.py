import os, pathlib, subprocess, json, shutil, time
ROOT=pathlib.Path.cwd(); LAB=ROOT/'.validation-round3-home'
EV=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5CSAEF80R6DCD8ED5DJSSM3')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE')) and k!='FM_GATE_REFUSE_BYPASS'}
def run(args, **kw): return subprocess.run(args,env=env,text=True,capture_output=True,**kw)
try:
 p=run(['bin/fm-lab-home.sh','create',str(LAB)]); assert p.returncode==0,p.stderr
 env['FM_HOME']=str(LAB)
 p=run(['bin/fm-session-start.sh','--source','startup'],timeout=150)
 (EV/'round3-live-startup.txt').write_text(p.stdout)
 print('startup:',p.returncode)
 state=LAB/'state'
 for i in range(1,14):
  (state/f'probe-{i}.meta').write_text(f'window=missing-lab:probe-{i}\nbackend=tmux\nkind=scout\nharness=claude\nworktree={ROOT}\n')
  (state/f'probe-{i}.status').write_text('working: '+'implementing reliable state '*120+'\n')
  if i<=11:
   with (state/f'probe-{i}.status').open('a') as f: f.write(f'needs-decision [key=call-{i}]: '+'choose a recovery option '*200+'\n')
 (LAB/'config/theme').write_text('ny-trenches\n')
 p=run(['bin/fm-session-start.sh','--reemit','--source','compact'],timeout=150)
 (EV/'round3-live-compact.txt').write_text(p.stdout); (EV/'round3-live-compact-stderr.txt').write_text(p.stderr)
 print('compact:',p.returncode,len(p.stdout.encode()),'bytes'); assert p.returncode == 0 and len(p.stdout.encode()) < 9000
 if (state/'.session-start-reemit.detail').exists(): shutil.copyfile(state/'.session-start-reemit.detail',EV/'round3-live-compact-detail.txt')
 # Exercise the same public generated-output contract with non-ASCII user data.
 for i in range(1,14):
  (state/f'probe-{i}.status').write_text('working: '+'測試修復狀態'*120+'\n')
  if i<=11:
   with (state/f'probe-{i}.status').open('a') as f: f.write(f'needs-decision [key=call-{i}]: '+'請選擇方案'*200+'\n')
 p=run(['bin/fm-session-start.sh','--reemit','--source','compact'],timeout=150)
 (EV/'round3-live-compact-unicode.txt').write_text(p.stdout)
 print('unicode compact:',p.returncode,len(p.stdout.encode()),'bytes'); assert p.returncode == 0 and len(p.stdout.encode()) < 9000
 baseline=state/'.session-start-agents-baseline'
 if baseline.exists(): baseline.unlink()
 p=run(['bin/fm-session-start.sh','--reemit','--source','compact'],timeout=150)
 (EV/'round3-live-compact-missing-baseline.txt').write_text(p.stdout)
 print('missing baseline compact:',p.returncode,len(p.stdout.encode()),'bytes'); assert p.returncode == 0 and len(p.stdout.encode()) < 9000; assert p.stdout.index('SUPERVISION OPERATING INSTRUCTIONS') < p.stdout.index('CURRENT AGENTS.md - INSTRUCTION REFRESH')
 # Execute the commands in the generated recovery protocol, not source-text checks.
 refresh=next(line.split(': ',1)[1] for line in p.stdout.splitlines() if line.startswith('INSTRUCTION_REFRESH_REQUIRED:'))
 recovered=run(['bash','-c',refresh]); assert recovered.returncode==0 and recovered.stdout==(ROOT/'AGENTS.md').read_text()
 whole=next(line.split('): ',1)[1] for line in p.stdout.splitlines() if line.startswith('- Whole block ('))
 full=run(['bash','-c',whole]); assert full.returncode==0
 (EV/'round3-recovered-supervision.txt').write_text(full.stdout)
 print('On-demand current instructions recovered:',len(recovered.stdout.encode()),'bytes; whole supervision:',len(full.stdout.encode()),'bytes')
 # Feed the real triage command eligible stale rows and real unavailable endpoints.
 for i in range(1,13): (state/f'probe-{i}.status').write_text('working: implementing\n')
 # Remove earlier decision presentation inputs; use the queue writer interface.
 for i in range(1,13):
  p=run(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append stale "$1" "stale: $1"','_',f'missing-lab:probe-{i}'])
  assert p.returncode==0,p.stderr
 compact_queue=run(['bin/fm-session-start.sh','--reemit','--source','compact'],timeout=150)
 (EV/'round3-live-compact-queued.txt').write_text(compact_queue.stdout)
 assert compact_queue.returncode==0 and len(compact_queue.stdout.encode())<9000
 assert sum(line.startswith('WAKE_ACK_REQUIRED:') for line in compact_queue.stdout.splitlines())==1
 assert compact_queue.stdout.index('Condensed operating rules')<compact_queue.stdout.index('WAKE QUEUE')
 detail=(state/'.session-start-reemit.detail').read_text()
 assert 'stale: missing-lab:probe-12' in detail
 (EV/'round3-live-compact-detail.txt').write_text(detail)
 print('Compact with queued wakes:',len(compact_queue.stdout.encode()),'bytes; exact acknowledgement and uncut detail preserved')
 p=subprocess.Popen(['bin/fm-wake-triage.sh'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 peak=0; sample=[]
 while p.poll() is None:
  rows=subprocess.check_output(['ps','-axo','pid,ppid,command'],text=True).splitlines()
  probes=[r for r in rows if '/fm-crew-state.sh probe-' in r and 'ps -' not in r]
  if len(probes)>peak: peak=len(probes); sample=probes
  time.sleep(.05)
 out,err=p.communicate()
 (EV/'round3-live-triage.txt').write_text(out+'\nSTDERR:\n'+err)
 (EV/'round3-live-triage-concurrency.txt').write_text('Peak simultaneous real crew-state processes: '+str(peak)+'\n'+'\n'.join(sample)+'\n')
 print('triage:',p.returncode,'peak real crew-state processes',peak)
 print(out[-2000:])
 p=run(['bin/fm-wake-triage.sh','--absorb'],timeout=60)
 (EV/'round3-live-triage-absorb.txt').write_text(p.stdout+'\nSTDERR:\n'+p.stderr)
 assert p.returncode==10, p.stdout
 queue=(state/'.wake-queue').read_text()
 (EV/'round3-live-triage-retained-queue.txt').write_text(queue)
 assert len(queue.splitlines())==12,queue
 print('absorb:',p.returncode,'retained all 12 unverified task rows')
finally:
 shutil.rmtree(LAB,ignore_errors=True)
