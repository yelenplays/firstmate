import os, json, subprocess, pathlib
import live_checks as lc
R=pathlib.Path.cwd()
session=subprocess.check_output(['bin/fm-herdr-lab.sh','name','jev-delivery'],text=True).strip()
env=lc.env|{'FM_HERDR_LAB_STATE_DIR':str(R/'.validation-tmp/herdr-state')}
helper=['bin/fm-herdr-lab.sh']
transcript=json.loads((lc.E/'herdr-lab-lifecycle.json').read_text())
def call(*args):
    p=subprocess.run(helper+list(args),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
    transcript.append({'command':helper+list(args),'exit':p.returncode,'output':p.stdout})
    if p.returncode: raise RuntimeError(p.stdout)
    return p.stdout
try:
    call('provision',session)
    raw=call('run',session,'workspace','create','--cwd',str(R),'--label','jev-approval-evidence','--no-focus')
    ws=json.loads(raw)['result']['workspace']['workspace_id']
    raw=call('run',session,'tab','create','--workspace',ws,'--cwd',str(R),'--label','fm-t1','--no-focus')
    obj=json.loads(raw)['result']['root_pane']
    lc.env['LAB_ENDPOINT']='|'.join([session,ws,obj['tab_id'],obj['pane_id']])
    lc.results=json.loads((lc.E/'live-cli.json').read_text())
    for name,kwargs in [
      ('quoted-comma-actionable-context',{'shape':'toon','context':'auto-fix','context_file':'"src/a,no-op,b.sh"','context_text':'The parser drops the final field. Correct this bug to preserve every field as required.'})
    ]:
        result=lc.run_case(name,**kwargs)
        if name.endswith('delivery') or name=='date-range-context':
            assert result['exit']==0, result
            assert result['decision_log'][-1]['sent'] is True, result
            assert sum('Jev decided this gate' in record for record in result['inbox_records'])==1, result
            assert 'resolved ' in result['status'], result
        else:
            assert 'Jev decided approve' not in result['output'], result
finally:
    try: call('teardown',session)
    finally: (lc.E/'herdr-lab-lifecycle.json').write_text(json.dumps(transcript,indent=2)+'\n')
