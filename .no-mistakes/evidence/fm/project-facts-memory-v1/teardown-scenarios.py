import os,pathlib,subprocess,shutil,json
root=pathlib.Path.cwd(); ev=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5CCAH0SEX7ZN7PXPC274FMA'); lab=root/'.test-project-facts/cleanup'; lab.mkdir()
base={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND')}; base['TMPDIR']=str(lab)
log=[]
def run(args,env,code=0):
 p=subprocess.run([str(root/args[0]),*args[1:]],env=env,capture_output=True,text=True)
 log.append('$ '+' '.join(args)+'\n'+p.stdout+p.stderr+f'[exit {p.returncode}]\n'); assert p.returncode==code,log[-1]; return p.stdout
try:
 for task,report,force in [('finished-investigation',True,False),('missing-report',False,False),('discard-with-report',True,True),('discard-without-report',False,True),('memory-readonly',True,False)]:
  home=lab/task; home.mkdir(); run(['bin/fm-lab-home.sh','create',str(home)],base)
  env=base|{'FM_HOME':str(home),'FM_SPEND_SESSIONS':str(lab/'absent-sessions'),'FM_SPEND_CLAUDE_SESSIONS':str(lab/'absent-sessions'),'NM_HOME':str(lab/'no-nm')}
  (home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
  run(['bin/fm-tasks-axi.sh','add',task,'Disposable investigation','--kind','scout','--repo','moving-site'],env)
  run(['bin/fm-tasks-axi.sh','start',task],env)
  # Public durable record for a recoverable, windowless legacy scout whose scratch copy is already gone.
  (home/'state'/f'{task}.meta').write_text(f'kind=scout\nproject={home}/projects/moving-site\nworktree={home}/missing-scratch\nharness=claude\n')
  run(['bin/fm-memory.sh','remember','--category','now','--task',task,'Headroom '+task,'Headroom-Vergleichstest laeuft; Ergebnis steht noch aus'],env)
  note=next((home/'data/memories/now').glob('*.md')); before=note.read_bytes()
  if report:
   d=home/'data'/task; d.mkdir(exist_ok=True); (d/'report.md').write_text('# Headroom result\nThe comparison is finished. No outstanding decisions.\n')
  args=['bin/fm-teardown.sh',task]+(['--force'] if force else ['--scout-complete'])
  readonly=task=='memory-readonly'
  if readonly: note.parent.chmod(0o500)
  try:
   out=run(args,env,code=1 if not report and not force else 0)
  finally:
   if readonly: note.parent.chmod(0o700)
  if readonly:
   assert 'could not update the now/ memory note' in log[-1]
   assert note.read_bytes()==before
   assert not (home/'state'/f'{task}.meta').exists()
  elif report and not force:
   assert b'completed:' in note.read_bytes() and b'Ergebnis steht noch aus' not in note.read_bytes()
   assert str(home/'data'/task/'report.md') in note.read_text()
   assert not (home/'state'/f'{task}.meta').exists()
  else:
   assert note.read_bytes()==before
   assert (home/'state'/f'{task}.meta').exists() == (not force)
  run(['bin/fm-memory.sh','recall','Headroom'],env)
  log.append('Persisted memory contract after cleanup:\n'+note.read_text())
  (ev/(task+'-memory.md')).write_bytes(note.read_bytes())
 log.append('All recovered-scout cleanup scenario assertions passed.\n')
finally:
 (ev/'teardown-transcript.log').write_text('\n'.join(log)); shutil.rmtree(lab)
