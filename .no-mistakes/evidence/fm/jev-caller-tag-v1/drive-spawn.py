import os, subprocess, pathlib, tempfile, json, time, shlex
root=pathlib.Path.cwd()
ev=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5D9Q6N38KC8WMSXQ8Q0RC89')
entries=[]
with tempfile.TemporaryDirectory(prefix='fm-lab-spawn-',dir=root/'.test-tmp') as scratch:
    s=pathlib.Path(scratch); home=s/'home'; proj=s/'project'; wrapper=s/'guarded-bin'
    wrapper.mkdir(); proj.mkdir()
    env=os.environ.copy()
    for k in list(env):
        if k.startswith(('FM_','HERDR_','GIT_CONFIG')) or k in ('NO_MISTAKES_GATE','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
            env.pop(k,None)
    original_path=env['PATH']
    env.update(FM_HOME=str(home),GROK_HOME=str(s/'grok-home'),FM_HERDR_LAB_STATE_DIR=str(s/'lab-state'),TMPDIR=str(root/'.test-tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Live Test',GIT_AUTHOR_EMAIL='live-test@example.invalid',GIT_COMMITTER_NAME='Live Test',GIT_COMMITTER_EMAIL='live-test@example.invalid')
    helper=str(root/'bin/fm-herdr-lab.sh'); session=None
    def run(args,timeout=30,check=True):
        try:
            p=subprocess.run(args,env=env,text=True,capture_output=True,timeout=timeout)
        except subprocess.TimeoutExpired:
            entries.append(dict(command=args,timeout_seconds=timeout)); raise
        entry=dict(command=args,exit=p.returncode,stdout=p.stdout,stderr=p.stderr)
        entries.append(entry); print(json.dumps(entry),flush=True)
        if check and p.returncode: raise RuntimeError(f'command failed: {args}')
        return p
    try:
        run(['bin/fm-lab-home.sh','create',str(home)])
        session=run([helper,'name','no-skill-jev']).stdout.strip(); env['HERDR_SESSION']=session
        # Every backend command delegates to the real helper on the ORIGINAL PATH,
        # avoiding wrapper recursion while retaining its named-session guards.
        script='''#!/usr/bin/env bash
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ] && [ "${args[$((n-1))]}" = "$HERDR_SESSION" ]; then
  unset 'args[$((n-1))]' 'args[$((n-2))]'
fi
exec env PATH='''+shlex.quote(original_path)+' '+shlex.quote(helper)+''' run "$HERDR_SESSION" "${args[@]}"
'''
        (wrapper/'herdr').write_text(script); (wrapper/'herdr').chmod(0o755)
        run([helper,'provision',session],timeout=80)
        run(['git','init','--quiet','--initial-branch=main',str(proj)])
        (proj/'treehouse.toml').write_text('max_trees = 1\nroot = '+json.dumps(str(s/'pool'))+'\n')
        (proj/'README.md').write_text('# Isolated live spawn validation\n')
        run(['git','-C',str(proj),'add','.'])
        run(['git','-C',str(proj),'commit','--quiet','-m','Initialize disposable live project'])
        run(['git','clone','--quiet','--bare',str(proj),str(s/'origin.git')])
        run(['git','-C',str(proj),'remote','add','origin',str(s/'origin.git')])
        (home/'config/backlog-backend').write_text('manual\n')
        (home/'config/jev-skill-select-live').touch()
        (home/'config/herdr-presentation-spaces').write_text('off\n')
        (home/'data/backlog.md').write_text('# Tasks\n')
        task='no-skill-live'
        run(['bin/fm-brief.sh',task,'project','--scout','--herdr-lab'])
        brief=home/'data'/task/'brief.md'
        brief.write_text(brief.read_text().replace('{TASK}','Confirm the greeting in README.md, then write a short local report. Do not invoke any pipeline or publish anything.').replace('{FIRSTMATE_SPEC}','Read only README.md. No source changes, external calls, lifecycle commands, or additional tasks.'))
        (brief.parent/'jev-skill-query.txt').write_text('Find documentation skills\n')
        env.update(PATH=str(wrapper)+':'+original_path,FM_JEV_SKILL_SELECT='live',FM_JEV_BRIEF_PREFLIGHT='off',FM_BACKEND='herdr')
        p=run(['bin/fm-spawn.sh',task,str(proj),'--scout','--harness','grok','--backend','herdr'],timeout=100,check=False)
        env['PATH']=original_path
        if p.returncode==0:
            meta=home/'state'/f'{task}.meta'
            fields=dict(line.split('=',1) for line in meta.read_text().splitlines() if '=' in line)
            pane=fields['herdr_pane_id']
            run([helper,'run',session,'pane','get',pane])
            time.sleep(2)
            run([helper,'run',session,'pane','read',pane,'--lines','200'])
            overlay=brief.parent/'launch-brief.md'
            if overlay.exists(): (ev/'spawn-live-launch-brief.md').write_text(overlay.read_text())
            entries.append(dict(observation='post-spawn state',jev_call_log_exists=(home/'state/jev-calls.jsonl').exists(),skill_record_exists=(home/'state'/f'{task}.jev-skills.json').exists(),skill_shadow_exists=(home/'state/jev-skill-shadow').exists(),metadata=fields))
            assert not (home/'state/jev-calls.jsonl').exists()
        else:
            entries.append(dict(observation='spawn stopped before native worker launch; not a live success'))
    except Exception as exc:
        entries.append(dict(driver_error=str(exc))); raise
    finally:
        env['PATH']=original_path
        if session: run([helper,'teardown',session],timeout=40,check=False)
        (ev/'spawn-live-transcript.json').write_text(json.dumps(entries,indent=2)+'\n')
