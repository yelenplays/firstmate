import os,pathlib,subprocess,json,shutil
root=pathlib.Path.cwd(); ev=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5CCAH0SEX7ZN7PXPC274FMA'); lab=root/'.test-project-facts/claude'; lab.mkdir()
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('CLAUDECODE','NO_MISTAKES_GATE','TASKS_AXI_FILE','TASKS_AXI_BACKEND')}; env['FM_HOME']=str(lab)
try:
 subprocess.run([str(root/'bin/fm-lab-home.sh'),'create',str(lab)],env=env,check=True,capture_output=True)
 for task in ['ship-facts','scout-facts']:
  prompt=(ev/(task+'-brief.md')).read_text().replace('{TASK}','Prepare a dry-run checklist for the Apple Business signup for Umzugservice Bochum. What legal and tax information is available, and which business registration document should I provide? Do not submit any form.').replace('{FIRSTMATE_SPEC}','Read the recorded project business facts. For this development-only dry-run, produce your checklist as the final text response, without using tools, changing files, starting supervision, or performing lifecycle operations. Do not write a report file.')
  (ev/(task+'-submitted-prompt.md')).write_text(prompt)
  args=['claude','-p','--safe-mode','--tools','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--permission-mode','dontAsk','--no-session-persistence','--effort','low','--max-budget-usd','1','--output-format','json']
  p=subprocess.run(args,input=prompt,cwd=lab,env=env,text=True,capture_output=True,timeout=100)
  (ev/(task+'-claude-response.json')).write_text(p.stdout)
  (ev/(task+'-claude-stderr.log')).write_text(p.stderr)
  assert p.returncode==0,(p.returncode,p.stderr,p.stdout)
  response=json.loads(p.stdout); assert not response.get('is_error'),response
  assert response.get('result'),response
  print(task+': completed normal-login Claude dry-run; response saved')
finally:
 shutil.rmtree(lab)
