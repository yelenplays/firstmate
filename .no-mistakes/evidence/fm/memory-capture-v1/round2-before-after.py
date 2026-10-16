#!/usr/bin/env python3
import os,pathlib,subprocess,tempfile,shutil,json
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M52YWSZ3NT93VE6AGZ7RJJBZ')
w=pathlib.Path(tempfile.mkdtemp(prefix='regression-',dir=R/'.test-tmp')); results={}
try:
    for name in ['fm-memory.sh','fm-memory-capture.mjs']:
        (w/name).write_bytes(subprocess.check_output(['git','show','66ff658e:bin/'+name])); (w/name).chmod(0o755)
    shutil.copyfile(R/'bin/fm-memory-bm25.mjs',w/'fm-memory-bm25.mjs')
    for version,module in [('before',w/'fm-memory-capture.mjs'),('after',R/'bin/fm-memory-capture.mjs')]:
        js=f"import {{buildUnits}} from {json.dumps(module.as_uri())}; console.log(JSON.stringify(buildUnits([{{captain:\"I'm vegan.\",reply:'Noted.'}}],new Set())));"
        results[version]={'short_fact':json.loads(subprocess.check_output(['node','--input-type=module','-e',js],text=True))}
    e={k:v for k,v in os.environ.items() if not k.startswith('FM_')}; e.update(FM_HOME=str(w/'home'),FM_MEMORY_DIR=str(w/'store'))
    for i in range(1,12):
        subprocess.run([str(R/'bin/fm-memory.sh'),'remember','--category','now',f'Entry {i}','x'*585],env=e,check=True,capture_output=True)
    for version,script in [('before',w/'fm-memory.sh'),('after',R/'bin/fm-memory.sh')]:
        text=subprocess.check_output([str(script),'now'],env=e,text=True)
        results[version]['NOW']={'chars':len(text),'omission_notice_present':'more now/ entries omitted by the size cap' in text}
    assert results['before']['short_fact']['dropped']==1 and results['after']['short_fact']['dropped']==0
    assert results['before']['NOW']['chars']>6000 and results['after']['NOW']['chars']<=6000
    (E/'round2-before-after.json').write_text(json.dumps(results,indent=2)+'\n'); print(json.dumps(results,indent=2))
finally: shutil.rmtree(w)
