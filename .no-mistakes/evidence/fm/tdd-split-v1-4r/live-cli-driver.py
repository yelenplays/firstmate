#!/usr/bin/env python3
"""Real fm-tdd-split CLI against disposable, explicitly seeded author histories.
No harness/backend/forge stand-ins; successful commands print their received tests.
All mutable runtime data is created below the supplied worktree and removed.
"""
import json, os, pathlib, shutil, sqlite3, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1])
cli_root = pathlib.Path(os.environ.get('LIVE_CLI_ROOT', str(root)))
selected = set(filter(None, os.environ.get('LIVE_CASE_FILTER', '').split('|')))
evidence = pathlib.Path(sys.argv[2])
scratch = root / '.validation' / 'tmp'
base_env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'GIT_')) and k not in ('NM_HOME','TMUX','CLAUDE_CONFIG_DIR')}
base_env.update(TMPDIR=str(scratch), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_TERMINAL_PROMPT='0', GIT_AUTHOR_NAME='Live validation', GIT_AUTHOR_EMAIL='live@example.invalid', GIT_COMMITTER_NAME='Live validation', GIT_COMMITTER_EMAIL='live@example.invalid')
results=[]
opus='claude-opus-5-5'
sonnet='claude-sonnet-5-5'
def cmd(args, env=base_env, cwd=None):
    return subprocess.run([str(a) for a in args], cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
def checked(args, cwd=None):
    p=cmd(args,cwd=cwd)
    if p.returncode: raise RuntimeError(str(args)+'\n'+p.stdout+p.stderr)
    return p.stdout.strip()
def run(name, subject, yaml=None, source='global', authors=None, expected='refuse', reason='no test authoring', unreadable=False, worker=False, schema_less=False, absent_db=False, restore=False, allowed=False, reverted=False):
    if selected and name not in selected:
        return
    lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=scratch))
    try:
        checked([root/'bin/fm-lab-home.sh','create',lab])
        wt=lab/'projects/demo'; wt.mkdir()
        checked(['git','init','-q',wt]); checked(['git','-C',wt,'symbolic-ref','HEAD','refs/heads/fm/live'])
        tests=wt/'tests'; tests.mkdir(); (tests/'contract.test.sh').write_text('printf "ASSERTION_EXECUTED:%s\\n" "$@"\n')
        checked(['git','-C',wt,'add','.']); checked(['git','-C',wt,'commit','-qm','base'])
        base=checked(['git','-C',wt,'rev-parse','HEAD'])
        checked(['git','-C',wt,'update-ref','refs/remotes/origin/main',base])
        nm=lab/'nm'; nm.mkdir()
        if yaml is not None:
            if source=='global': (nm/'config.yaml').write_text(yaml+'\n')
            elif source=='repo': (wt/'.no-mistakes.yaml').write_text(yaml+'\n')
        (tests/'contract.test.sh').write_text('printf "ASSERTION_EXECUTED:%s\\n" "$@"\n# new required behavior\n')
        checked(['git','-C',wt,'add','.']); checked(['git','-C',wt,'commit','-qm',subject])
        repair_head=checked(['git','-C',wt,'rev-parse','HEAD'])
        if reverted:
            checked(['git','-C',wt,'checkout',base,'--','tests/contract.test.sh'])
            checked(['git','-C',wt,'commit','-qm','restore test contract'])
        head=checked(['git','-C',wt,'rev-parse','HEAD'])
        if not absent_db:
            db=sqlite3.connect(nm/'state.sqlite')
            if schema_less: db.execute('create table legacy (id text)')
            else:
                db.executescript('create table repos(id text,working_path text); create table runs(id text,repo_id text,branch text); create table agent_invocations(run_id text,step_name text,purpose text,model text,exit_status text); create table step_results(id text,run_id text); create table step_rounds(step_result_id text,global_config_yaml text,repo_config_yaml text);')
                db.execute('insert into repos values(?,?)',('repo',str(wt)))
                db.execute('insert into runs values(?,?,?)',('run','repo','fm/live'))
                for a in authors or []:
                    step,purpose,model,*status=a
                    db.execute('insert into agent_invocations values(?,?,?,?,?)',('run',step,purpose,model,status[0] if status else 'ok'))
                if source in ('round-global','round-repo') and yaml is not None:
                    db.execute('insert into step_results values(?,?)',('step','run'))
                    db.execute('insert into step_rounds values(?,?,?)',('step',yaml if source=='round-global' else None,yaml if source=='round-repo' else None))
            db.commit(); db.close()
        task=lab/'data/live'; task.mkdir()
        mutation='printf "ASSERTION_EXECUTED:%s\\n" "$@"; '+('exit 1' if restore else 'exit 0')
        (task/'brief.md').write_text('# Live test contract\nFail-to-pass command: `bash "$1"`\nMutation command: `'+mutation+'`\n')
        meta=lab/'state/live.meta'
        lines=['kind=ship','mode=no-mistakes','worktree='+str(wt),'project='+str(wt),'branch=fm/live','base_branch=main','model='+ (sonnet if worker else opus),'tdd_split=implement','tdd_split_impl_harness=claude','tdd_split_impl_model='+sonnet,'tdd_split_impl_effort=medium']
        if worker: lines+=['test_ban_model='+sonnet,'test_ban_since='+base]
        if allowed: lines+=['test_ban_allowed=tests/contract.test.sh']
        if restore: lines+=['harness=claude','backend=tmux','window=fm-lab:missing','endpoint_task_id=live','tdd_split_dispute_head='+base]
        meta.write_text('\n'.join(lines)+'\n')
        before=meta.read_text()
        (lab/'state/live.status').write_text('done: implementation ready\n')
        if unreadable: (nm/'config.yaml').chmod(0)
        env=base_env|{'FM_HOME':str(lab),'NM_HOME':str(nm)}
        args=[cli_root/'bin/fm-tdd-split.sh','mutation','live','--timeout','10']
        p=cmd(args,env)
        if unreadable: (nm/'config.yaml').chmod(0o600)
        log=task/'tdd-split-mutation.log'
        log_text=log.read_text() if log.exists() else ''
        after=meta.read_text()
        if expected=='allow': passed=p.returncode==0 and 'ASSERTION_EXECUTED:tests/contract.test.sh' in log_text
        elif expected=='rollback': passed=p.returncode==1 and 'relaunch onto the test seat failed' in p.stderr and sorted(after.splitlines())==sorted(before.splitlines()) and 'ASSERTION_EXECUTED:' in log_text
        else: passed=p.returncode==1 and reason in p.stderr and not log.exists()
        results.append(dict(name=name,result='pass' if passed else 'fail',live=True,source=source,subject=subject,configuration=yaml,authors=authors,command='FM_HOME=<disposable marked lab> NM_HOME=<lab>/nm bin/fm-tdd-split.sh mutation live --timeout 10',exit_code=p.returncode,stdout=p.stdout,stderr=p.stderr,mutation_log=log_text,head=head,repair_head=repair_head,metadata_before=before,metadata_after=after))
        print(name+': '+results[-1]['result'],flush=True)
    finally:
        shutil.rmtree(lab)

review=[('review','review-fix',sonnet)]
for source in ('global','repo','round-global','round-repo'):
    plain='commit:\n  fix_message: "repair[{{.Step}}] {{.Branch}}: {{.Summary}}"'
    run('custom Sonnet '+source,'repair[review] fm/live: add test',plain,source,review)
    run('custom Opus '+source,'repair[review] fm/live: add test',plain,source,[('review','review-fix',opus)],'allow')
    bound='commit:\n  fix_message: "{{.Branch}}/{{.Step}}: {{.Summary}}"'
    run('summary impersonation '+source,'fm/live/review: repair/test: add test',bound,source,review+[('test','test',opus)])
    run('summary harmless Opus '+source,'fm/live/test: repair/review: add test',bound,source,review+[('test','test',opus)],'allow')
    for form, val in [('plain','repair-{{.Step}}\n    {{.Summary}}'),('single',"'repair-{{.Step}}\n    {{.Summary}}'"),('double','"repair-{{.Step}}\n    {{.Summary}}"'),('block','>\n    repair-{{.Step}} {{.Summary}}')]:
        folded='commit:\n  fix_message: '+val
        run('multiline '+form+' '+source,'repair-review add test',folded,source,review,reason='commit.fix_message')
        run('unreadable worker '+form+' '+source,'worker adds test',folded,source,review,reason='commit.fix_message')
    run('normalized multiline '+source,'repair-review add test','commit:\n  fix_message: "repair-{{.Step}} {{.Summary}}"',source,review)
    for merge in ('*style','[*style]'):
        indirect='repair_style: &style\n  fix_message: "repair[{{.Step}}] {{.Branch}}: {{.Summary}}"\ncommit:\n  <<: '+merge
        run('YAML merge '+merge+' '+source,'repair[review] fm/live: add test',indirect,source,review,reason='commit.fix_message')
    run('unsupported placeholder '+source,'repair-review add test','commit:\n  fix_message: "repair-{{.Unknown}} {{.Summary}}"',source,review,reason='commit.fix_message')
run('default Sonnet','no-mistakes(review): add test',authors=review)
run('default Opus','no-mistakes(review): add test',authors=[('review','review-fix',opus)],expected='allow')
run('dotted unknown author','no-mistakes(gate.test.mutation-budget): add test')
run('dotted Sonnet','no-mistakes(gate.test.mutation-budget): add test',authors=[('gate.test.mutation-budget','gate.test.mutation-budget-fix',sonnet)])
run('dotted Opus','no-mistakes(gate.test.mutation-budget): add test',authors=[('gate.test.mutation-budget','gate.test.mutation-budget-fix',opus)],expected='allow')
run('housekeeping Sonnet','no-mistakes(document): add test',authors=[('document','housekeeping',sonnet)])
run('housekeeping Opus','no-mistakes(document): add test',authors=[('document','housekeeping',opus)],expected='allow')
run('read-only review ignored','no-mistakes(review): add test',authors=[('review','review',sonnet),('review','review-fix',opus)],expected='allow')
run('failed invocation ignored','no-mistakes(test): add test',authors=[('test','test',sonnet,'failed'),('test','test',opus)],expected='allow')
run('every successful writer counts','no-mistakes(test): add test',authors=[('test','test',opus),('test','other-writing-purpose',sonnet)])
run('stepless all writers','fm/live: add test','commit:\n  fix_message: "{{.Branch}}: {{.Summary}}"',authors=[('test','test',opus),('lint','lint-fix',sonnet)])
run('overlapping templates','no-mistakes(test): add test','commit:\n  fix_message: "{{.Summary}}"',authors=review+[('test','test',opus)])
run('ambiguous steps','review-test-add test','commit:\n  fix_message: "{{.Step}}-{{.Summary}}"',authors=review+[('review-test','test',opus)])
run('summary before step','repair/test/review: fm/live','commit:\n  fix_message: "{{.Summary}}/{{.Step}}: {{.Branch}}"',authors=review+[('test','test',opus)])
run('other branch not pipeline','fm/other/review: add test','commit:\n  fix_message: "{{.Branch}}/{{.Step}}: {{.Summary}}"',authors=review,expected='allow')
run('Opus own test ordinary config','worker adds test','agent_config: &other\n  claude:\n    model: claude-opus-5-5',authors=review,expected='allow')
for subject in ('repair[review] fm/live: add test','worker adds test'):
    run('unreadable global '+subject,subject,'commit:\n  fix_message: "repair[{{.Step}}] {{.Branch}}: {{.Summary}}"',authors=review,unreadable=True,reason='commit.fix_message')
run('absent database worker','worker adds test',absent_db=True,expected='allow')
run('old schema worker','worker adds test',schema_less=True,expected='allow')
run('old schema repair refuses','no-mistakes(test): add test',schema_less=True)
run('locked Sonnet worker','worker adds test',worker=True)
run('captain allowed test','no-mistakes(review): add test',authors=review,allowed=True,expected='allow')
# The mutation command needs a changed test, so reverted tests are exercised by registration regressions instead.
run('failed real relaunch restores metadata','worker adds test',restore=True,expected='rollback')
(evidence/'live-cli-results.json').write_text(json.dumps(results,indent=2)+'\n')
(evidence/'live-cli-transcript.txt').write_text('\n\n'.join('\n'.join([r['name']+' => '+r['result'],r['command'],'exit='+str(r['exit_code']),r['stdout'],r['stderr'],r['mutation_log']]) for r in results)+'\n')
print(json.dumps({'cases':len(results),'failures':[r['name'] for r in results if r['result']=='fail']}))
sys.exit(any(r['result']=='fail' for r in results))
