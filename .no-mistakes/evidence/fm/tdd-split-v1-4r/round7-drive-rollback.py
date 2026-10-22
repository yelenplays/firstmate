#!/usr/bin/env python3
"""Drive failed seat returns through actual fm-control, without a fake backend/agent."""
import json, os, pathlib, shutil, subprocess
ROOT=pathlib.Path('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5GS3M4W07Q0D4MM3H04RCEJ')
E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5GS3M4W07Q0D4MM3H04RCEJ')
env=dict(os.environ)
for k in list(env):
    if k.startswith(('FM_','GIT_')) or k in ('NM_HOME','TASKS_AXI_FILE','TASKS_AXI_BACKEND'): env.pop(k,None)
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='1',GIT_CONFIG_KEY_0='core.hooksPath',GIT_CONFIG_VALUE_0='/dev/null',GIT_AUTHOR_NAME='Validation',GIT_AUTHOR_EMAIL='validation@example.invalid',GIT_COMMITTER_NAME='Validation',GIT_COMMITTER_EMAIL='validation@example.invalid',TMPDIR=str(ROOT/'.test-phase-tmp'))
results=[]
for cmd in ('dispute','mutation'):
    for previous in ('absent','present'):
        name=cmd+'-'+previous
        d=ROOT/'.test-phase-tmp'/('rollback-'+name)
        d.mkdir()
        home=d/'home'; wt=d/'repo'; nm=d/'nm'
        subprocess.run(['bash',str(ROOT/'bin/fm-lab-home.sh'),'create',str(home)],env=env,check=True,capture_output=True)
        wt.mkdir(); nm.mkdir(); (home/'data/live').mkdir()
        def git(*args):
            return subprocess.run(['git','-C',str(wt),*args],env=env,text=True,capture_output=True,check=True).stdout.strip()
        git('init','-q','-b','main'); git('commit','-qm','base','--allow-empty')
        base=git('rev-parse','HEAD'); git('update-ref','refs/remotes/origin/main',base); git('checkout','-qb','fm/live')
        (wt/'tests').mkdir(); (wt/'tests/feature.test.sh').write_text('exit 0\n'); git('add','.'); git('commit','-qm','worker tests')
        head=git('rev-parse','HEAD')
        meta='\n'.join(['kind=ship','mode=no-mistakes','harness=claude','model=claude-opus-5-5','tdd_split=implement','branch=fm/live','base_branch=main','worktree='+str(wt),'project='+str(wt)])+'\n'
        if previous=='present': meta+='tdd_split_dispute_head='+base+'\n'
        mp=home/'state/live.meta'; mp.write_text(meta)
        status='blocked [key=test-dispute]: tests/feature.test.sh: wrong expectation\n' if cmd=='dispute' else 'done: implementation ready\n'
        sp=home/'state/live.status'; sp.write_text(status)
        (home/'data/live/brief.md').write_text('# Return failure validation\nFail-to-pass command: `for t; do bash "$t" || exit 1; done`\nMutation command: `echo SURVIVING_MUTANT; exit 1`\n')
        cp=subprocess.run(['bash',str(ROOT/'bin/fm-tdd-split.sh'),cmd,'live'],env=dict(env,FM_HOME=str(home),NM_HOME=str(nm)),text=True,capture_output=True,timeout=30)
        after=mp.read_text(); after_status=sp.read_text()
        # Ordering of unrelated record fields is not a public contract.
        preserved=sorted(after.splitlines())==sorted(meta.splitlines())
        refused=cp.returncode!=0 and 'relaunch onto the test seat failed' in cp.stderr
        result=dict(name=name,result='pass' if preserved and refused and after_status==status else 'fail',live=True,command='FM_HOME=<marked-lab-home> NM_HOME=<isolated-nm> bash bin/fm-tdd-split.sh '+cmd+' live',exit=cp.returncode,stdout=cp.stdout,stderr=cp.stderr,meta_before=meta,meta_after=after,status_before=status,status_after=after_status,head=head)
        results.append(result)
        print(name,result['result'],cp.returncode,cp.stderr.strip(),flush=True)
        shutil.rmtree(d)
(E/'round7-rollback-results.json').write_text(json.dumps(results,indent=2)+'\n')
