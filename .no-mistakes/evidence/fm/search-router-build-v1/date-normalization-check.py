#!/usr/bin/env python3
"""Live public-interface date contract check; no mock or implementation reads."""
import datetime, json, os, pathlib, re, shutil, subprocess, tempfile
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5CZS0W61XMJMT1EW98XF3BY')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.router-date-',dir=root))
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_'): env.pop(k)
env.update(FM_HOME=str(lab),HOME=str(lab/'user'), XDG_CACHE_HOME=str(lab/'cache'),XDG_CONFIG_HOME=str(lab/'config-user'), FM_SEARCH_KEY_DIR=str(pathlib.Path.home()/'.config'))
for p in ('user','cache','config-user','config'): (lab/p).mkdir()
(lab/'config/fm-search.json').write_text('{"exa":{"monthly_usd_cap":0}}')
records=[]
try:
    for args in [ ['--urls','--json','--limit','2','Python contextlib ExitStack official documentation'], ['--urls','--limit','2','Python contextlib ExitStack official documentation'] ]:
        p=subprocess.run([str(root/'bin/fm-search.sh')]+args, env=env,text=True,capture_output=True,timeout=60)
        records.append({'command':'bin/fm-search.sh '+ ' '.join(repr(x) for x in args),'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    data=json.loads(records[0]['stdout'])
    errors=[]
    for item in data['results']:
        date=item['date']
        if date and not re.fullmatch(r'\d{4}-\d{2}-\d{2}',date):
            errors.append({'url':item['url'],'date':date,'expected':'YYYY-MM-DD or empty'})
        elif date:
            try: datetime.date.fromisoformat(date)
            except ValueError: errors.append({'url':item['url'],'date':date,'expected':'valid calendar date'})
    output={'records':records,'contract_violations':errors,'result':'fail' if errors else 'pass'}
    (evidence/'live-date-normalization.json').write_text(json.dumps(output,indent=2,ensure_ascii=False)+'\n')
    print(json.dumps(output,indent=2,ensure_ascii=False))
    raise SystemExit(1 if errors else 0)
finally:
    shutil.rmtree(lab)
