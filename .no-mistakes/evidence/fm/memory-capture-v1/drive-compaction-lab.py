#!/usr/bin/env python3
import html,json,os,pathlib,shlex,shutil,subprocess,time
R=pathlib.Path('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M59XY24CQN6E6XS9CMW0DM5S')
E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M59XY24CQN6E6XS9CMW0DM5S')
H=R/'.test-compaction-home'; S=R/'.test-compaction-herdr-state'
env=dict(os.environ,FM_HERDR_LAB_STATE_DIR=str(S))
helper=str(R/'bin/fm-herdr-lab.sh'); logs=[]; active=False; name=''
def cmd(args,timeout=80):
 p=subprocess.run(args,cwd=R,env=env,text=True,capture_output=True,timeout=timeout)
 logs.append({'command':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
 if p.returncode: raise RuntimeError(p.stderr or p.stdout)
 return p.stdout

def lab(*args): return cmd([helper,'run',name,*args])
try:
 assert not H.exists() and not S.exists()
 cmd([str(R/'bin/fm-lab-home.sh'),'create',str(H)])
 (H/'config/supervision-host-off').touch()
 name=cmd([helper,'name','memory-window']).strip()
 # Provision owns prepare, including its default-session tripwire.
 cmd([helper,'provision',name]); active=True
 cmd([helper,'viewer','start',name]) # fixed 40x120 pty before the harness starts
 for label,config,caller,expected in [
  ('home-100k','100000',[], '100k'),
  ('caller-settings-200k','100000',['--settings','{"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"200000"}}'],'200k'),
  ('caller-autocompact','100000',['--autocompact','180000'],None),
  ('home-auto','auto',[],None)]:
  (H/'config/claude-autocompact').write_text(config+'\n')
  ws=json.loads(lab('workspace','create','--cwd',str(R),'--label','fm-memory-'+label,'--no-focus'))
  pane=ws['result']['root_pane']['pane_id']
  launch=['env','-u','NO_MISTAKES_GATE','-u','FM_GATE_REFUSE_BYPASS','-u','FM_ROOT_OVERRIDE','-u','FM_STATE_OVERRIDE','-u','FM_DATA_OVERRIDE','-u','FM_CONFIG_OVERRIDE','-u','FM_PROJECTS_OVERRIDE','-u','FM_TASK_ID','-u','FM_SUPERVISION_ACTOR','-u','FM_MEMORY_CAPTURE_CHILD', 'FM_HOME='+str(H),'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false',str(R/'bin/fm-claude-primary.sh'),*caller]
  lab('pane','run',pane,shlex.join(launch))
  trusted=False; ready=False
  for _ in range(70):
   text=lab('pane','read',pane,'--source','visible')
   if 'Yes, I trust this folder' in text and not trusted:
    lab('pane','send-keys',pane,'down','enter'); trusted=True
   if ('❯' in text and ('auto mode on' in text or 'Try ' in text or 'for shortcuts' in text or 'bypass permissions' in text)) and 'trust this folder' not in text:
    ready=True; break
   time.sleep(.4)
  if not ready: raise RuntimeError('Claude never rendered its composer: '+text)
  lab('pane','send-text',pane,'/context'); time.sleep(.5); lab('pane','send-keys',pane,'enter')
  window=''
  for _ in range(50):
   text=lab('pane','read',pane,'--source','visible')
   if 'Auto-compact window:' in text:
    window=text; break
   time.sleep(.3)
  (E/(label+'.txt')).write_text(window or text)
  if not window: raise RuntimeError('No /context auto-compact report for '+label)
  if expected and ('Auto-compact window: '+expected) not in window: raise RuntimeError('Window mismatch: '+window)
  logs.append({'scenario':label,'config':config,'caller':caller,'context':window,'expected':expected})
  lab('pane','send-keys',pane,'esc'); time.sleep(.2)
  lab('pane','send-text',pane,'/exit'); time.sleep(.4); lab('pane','send-keys',pane,'enter'); time.sleep(.5)
 # An HTML rendering of the exact terminal view, not a reconstructed or summarized UI.
 sections=''.join('<section><h2>'+html.escape(p.stem)+'</h2><pre>'+html.escape(p.read_text())+'</pre></section>' for p in [E/'home-100k.txt',E/'caller-settings-200k.txt',E/'caller-autocompact.txt',E/'home-auto.txt'] if p.exists())
 (E/'compaction-terminal.html').write_text('<!doctype html><meta charset="utf-8"><title>Live Claude /context views</title><style>body{background:#171717;color:#eee;font:14px monospace;margin:24px}h1{font-size:20px}h2{font-size:16px;color:#fac98b}section{margin-bottom:40px}pre{white-space:pre;line-height:1.3}</style><h1>Live Claude Code /context — isolated Herdr lab</h1><p>Exact terminal viewport text captured at 40×120; not a native screenshot.</p>'+sections)
finally:
 if active:
  try: cmd([helper,'teardown',name])
  except Exception as exc: logs.append({'teardown_error':str(exc)}); raise
 (E/'compaction-lab.json').write_text(json.dumps(logs,indent=2)+'\n')
 for p in (H,S):
  if p.exists(): shutil.rmtree(p)
print(json.dumps([entry for entry in logs if 'scenario' in entry],indent=2))
