import pathlib,subprocess,os,shutil,time,json,signal
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5CSAEF80R6DCD8ED5DJSSM3'); H=R/'.validation-round3-send'
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_')) and k not in ('TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND')}
env['FM_HERDR_LAB_STATE_DIR']=str(H/'lab-state'); log=[]; name=None; prepared=False

def run(args, timeout=30):
 p=subprocess.run(args,env=env,text=True,capture_output=True,timeout=timeout)
 log.append('$ '+str(args)+'\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
 return p

def lab(*args): return run(['bin/fm-herdr-lab.sh','run',name,*args])
try:
 p=run(['bin/fm-lab-home.sh','create',str(H)]); assert p.returncode==0,p.stderr
 env['FM_HOME']=str(H)
 name=run(['bin/fm-herdr-lab.sh','name','send-proof']).stdout.strip()
 # Provision owns prepare for a new session; do not prepare twice.
 prepared=True
 p=run(['bin/fm-herdr-lab.sh','provision',name],90); assert p.returncode==0,p.stderr
 p=run(['bin/fm-herdr-lab.sh','viewer','start',name]); assert p.returncode==0,p.stderr
 p=lab('workspace','create','--cwd',str(R),'--label','send-proof','--no-focus'); assert p.returncode==0,p.stderr
 j=json.loads(p.stdout)['result']; pane=j['root_pane']['pane_id']; ws=j['workspace']['workspace_id']; tab=j['root_tab']['tab_id'] if 'root_tab' in j else None
 if tab is None:
  g=lab('pane','get',pane); tab=json.loads(g.stdout)['result']['pane']['tab_id']
 cmd='env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='+str(H)+' pi --no-session --no-extensions --no-skills --no-context-files'
 p=lab('pane','run',pane,cmd); assert p.returncode==0,p.stderr
 live=False
 for _ in range(30):
  g=lab('agent','get',pane)
  if g.returncode==0 and json.loads(g.stdout).get('result',{}).get('agent',{}).get('agent')=='pi': live=True;break
  time.sleep(1)
 read=lab('pane','read',pane,'--lines','200'); (E/'round3-send-live-pane.txt').write_text(read.stdout)
 assert live,'Real Pi did not register: see pane transcript'
 # Stop only the exact real Pi foreground PID reported by this owned lab pane.
 info=lab('pane','process-info','--pane',pane)
 procs=json.loads(info.stdout)['result']['process_info']['foreground_processes']
 pid=next(x['pid'] for x in procs if x.get('argv0')=='pi')
 os.kill(pid,signal.SIGTERM); log.append('SIGTERM exact lab Pi pid '+str(pid))
 gone=False
 for _ in range(30):
  info=lab('pane','process-info','--pane',pane)
  procs=json.loads(info.stdout)['result']['process_info']['foreground_processes']
  if not any(x.get('argv0')=='pi' for x in procs): gone=True;break
  time.sleep(.5)
 assert gone,'Pi did not exit to the lab shell'
 time.sleep(2)
 # Persist exact real endpoint identity as the public send interface requires.
 (H/'state/exited.meta').write_text(f'backend=herdr\nwindow={name}:{pane}\nherdr_session={name}\nherdr_workspace_id={ws}\nherdr_tab_id={tab}\nherdr_pane_id={pane}\nharness=pi\nkind=scout\nworktree={R}\n')
 p=run(['bin/fm-send.sh','exited','Keep this steering message for recovery.'])
 assert p.returncode==0 and p.stdout.startswith('recorded-not-delivered:'),p.stdout+p.stderr
 records=list((H/'state').glob('**/*'))
 for f in records:
  if f.is_file() and 'Keep this steering message for recovery.' in f.read_text(errors='ignore'):
   log.append('Persisted durable message: '+str(f.relative_to(H))+'\n'+f.read_text(errors='ignore'))
 print('PASS: real Pi exited; fm-send returned visible recorded-not-delivered on stdout with a durable recovery message.')
finally:
 if prepared:
  p=run(['bin/fm-herdr-lab.sh','teardown',name],90)
  if p.returncode!=0: print('CLEANUP FAILED:',p.stderr)
 (E/'round3-live-send-transcript.txt').write_text('\n'.join(log))
 shutil.rmtree(H,ignore_errors=True)
