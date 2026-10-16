#!/usr/bin/env python3
"""Supplemental routing behavior with recording backends; NOT live model evidence."""
import os,pathlib,subprocess,tempfile,shutil,json,datetime
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M52YWSZ3NT93VE6AGZ7RJJBZ')
w=pathlib.Path(tempfile.mkdtemp(prefix='routing-',dir=R/'.test-tmp')); cases={}
try:
    jev=w/'jev'; model=w/'model'
    jev.write_text('''#!/usr/bin/env python3
import sys,json,os,pathlib
r=json.load(sys.stdin); pathlib.Path(os.environ['REC']+'/jev.json').write_text(json.dumps(r))
for q in r['questions']: print(q['id']+': none p=0.99 conf=0.99')
'''); jev.chmod(0o755)
    model.write_text('''#!/usr/bin/env python3
import sys,json,os,pathlib
pathlib.Path(os.environ['REC']+'/model.txt').write_text(sys.stdin.read())
print(json.dumps({'structured_output':{'memories':[]},'is_error':False}))
'''); model.chmod(0o755)
    for name,private,body in [('none',False,'The deploy script fixes lint. CI is green.'),('marker',True,'The ORCHID release script is ready.')]:
        h=w/name; (h/'config').mkdir(parents=True); (h/'state').mkdir(); (h/'data').mkdir()
        if private: (h/'config/private-markers').write_text('orchid\n')
        e={k:v for k,v in os.environ.items() if not k.startswith('FM_')}; e.update(FM_HOME=str(h),TMPDIR=str(R/'.test-tmp'),REC=str(h),FM_MEMORY_CAPTURE_JEV_BIN=str(jev),FM_CLAUDE_BIN=str(model),TZ='UTC')
        day=datetime.date.today().isoformat(); tr=h/'authored.jsonl'
        tr.write_text(json.dumps({'type':'user','origin':{'kind':'human'},'uuid':name,'timestamp':day+'T10:00:00Z','message':{'content':body}})+'\n')
        subprocess.run([str(R/'bin/fm-history.sh'),'capture','--transcript',str(tr)],env=e,check=True,capture_output=True)
        p=subprocess.run([str(R/'bin/fm-memory-capture.sh'),'run'],env=e,text=True,capture_output=True,check=True)
        record=json.loads(p.stdout)
        cases[name]={'live':False,'capture':record,'jev_request':json.loads((h/'jev.json').read_text()) if (h/'jev.json').exists() else None,'model_input':(h/'model.txt').read_text() if (h/'model.txt').exists() else None}
        if private:
            assert record['jev_calls']==0 and record['model_calls']==1 and body in cases[name]['model_input']
        else:
            assert record['jev_none']==1 and record['model_calls']==0 and not (h/'model.txt').exists()
        assert json.loads((h/'state/memory-capture/watermark.json').read_text())['id']==name
    (E/'round2-routing.json').write_text(json.dumps(cases,indent=2)+'\n'); print(json.dumps({k:v['capture'] for k,v in cases.items()},indent=2))
finally: shutil.rmtree(w)
