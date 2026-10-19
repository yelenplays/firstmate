import json, os, pathlib, shlex, shutil, subprocess
ROOT=pathlib.Path.cwd(); LAB=ROOT/'.primary-window-lab'; LAB.mkdir()
E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M59XY24CQN6E6XS9CMW0DM5S')
env=dict(os.environ); env['FM_HERDR_LAB_STATE_DIR']=str(LAB/'lab-state')
helper=str(ROOT/'bin/fm-herdr-lab.sh'); transcript=[]; prepared=False

def call(args, check=True, timeout=45):
 p=subprocess.run(args,env=env,capture_output=True,text=True,timeout=timeout)
 transcript.append('$ '+shlex.join(args)+'\n'+p.stdout+p.stderr+f'\nexit={p.returncode}\n')
 if check: assert p.returncode==0,transcript[-1]
 return p

session=call([helper,'name','memory-window']).stdout.strip()
try:
 # provision performs prepare internally for a fresh session.
 prepared=True
 call([helper,'provision',session])
 call([helper,'viewer','start',session])
 home=LAB/'home'; home.mkdir()
 call([str(ROOT/'bin/fm-lab-home.sh'),'create',str(home)])
 (home/'config/claude-autocompact').write_text('100000\n')
 out=call([helper,'run',session,'tab','create','--cwd',str(ROOT),'--label','memory-window','--no-focus'])
 pane=json.loads(out.stdout)['result']['root_pane']['pane_id']
 unset=['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TASK_ID']
 command=shlex.join(['env',*[s for key in unset for s in ['-u',key]],'FM_HOME='+str(home),'CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000',str(ROOT/'bin/fm-claude-primary.sh')])
 call([helper,'run',session,'pane','run',pane,command])
 call([helper,'run',session,'pane','wait-output',pane,'--regex','trust|Claude Code|login|sign in','--timeout','20000'],False)
 read=call([helper,'run',session,'pane','read',pane,'--source','visible','--lines','120'])
 (E/'primary-window-startup.json').write_text(read.stdout)
 if 'trust' in read.stdout.lower():
  print('UNTESTED: Claude requires repository trust confirmation; did not change user-level trust configuration outside the worktree.')
 else:
  call([helper,'run',session,'pane','run',pane,'/context'])
  call([helper,'run',session,'pane','wait-output',pane,'--match','Auto-compact window','--timeout','15000'],False)
  read=call([helper,'run',session,'pane','read',pane,'--source','recent-unwrapped','--lines','200'])
  (E/'primary-window-context.json').write_text(read.stdout)
  assert 'Auto-compact window: 100k tokens' in read.stdout
  # A second genuine primary launch confirms explicit caller settings win.
  out=call([helper,'run',session,'tab','create','--cwd',str(ROOT),'--label','memory-window-caller','--no-focus'])
  pane=json.loads(out.stdout)['result']['root_pane']['pane_id']
  caller=command+' --settings '+shlex.quote('{"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"180000"}}')
  call([helper,'run',session,'pane','run',pane,caller])
  call([helper,'run',session,'pane','wait-output',pane,'--match','Opus','--timeout','20000'],False)
  call([helper,'run',session,'pane','run',pane,'/context'])
  call([helper,'run',session,'pane','wait-output',pane,'--match','Auto-compact window: 180k','--timeout','15000'],False)
  read=call([helper,'run',session,'pane','read',pane,'--source','recent-unwrapped','--lines','200'])
  (E/'primary-window-caller-context.json').write_text(read.stdout)
  assert 'Auto-compact window: 180k tokens' in read.stdout
  print('PASS: real Claude /context reports configured 100k despite process 300k; explicit caller settings report 180k despite home 100k.')
finally:
 if prepared: call([helper,'teardown',session])
 (E/'primary-window-transcript.txt').write_text('\n'.join(transcript))
 shutil.rmtree(LAB)
