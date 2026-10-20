import os, pathlib, subprocess, json, shutil
root = pathlib.Path.cwd()
base = root / '.phase-test-tmp' / 'pr-cli'
evidence = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5D4JM8YEQBE4H1ZWVM390Q6')
base.mkdir(parents=True)
home = base / 'home'
for d in ['state','data','config','projects']:
    (home/d).mkdir(parents=True)
repo = base/'repo'
repo.mkdir()
env = dict(os.environ)
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM']:
    env.pop(k,None)
env.update(FM_HOME=str(home), FM_GUARD_READ_ONLY='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Local validation', GIT_AUTHOR_EMAIL='validation@example.invalid', GIT_COMMITTER_NAME='Local validation', GIT_COMMITTER_EMAIL='validation@example.invalid')
# Exercise local refusal without touching a real forge or the outer pipeline.
# These are real OS tools, not executable shims. gh is deliberately absent.
env['PATH']='/usr/bin:/bin:/usr/sbin:/sbin'

def run(args,cwd=None):
    return subprocess.run([str(x) for x in args],cwd=cwd or root,env=env,text=True,capture_output=True,timeout=25)
def git(*args):
    p=run(['git','-C',repo,*args]); assert p.returncode == 0,p.stderr
    return p.stdout.strip()
def commit(msg):
    git('add','-A');git('commit','-q','-m',msg);return git('rev-parse','HEAD')
git('init','-q','-b','main')
(repo/'impl.sh').write_text('echo initial\n')
base_sha=commit('initial')
git('update-ref','refs/remotes/origin/main',base_sha)
git('checkout','-q','-b','fm/probe')
(repo/'tests').mkdir()
(repo/'tests'/'feature.test.sh').write_text('test "$(sh impl.sh)" = implemented\n')
handoff=commit('tests first')
(repo/'impl.sh').write_text('echo implemented\n')
impl=commit('implementation')
url='https://github.com/fm-validation-nonexistent/local-probe/pull/82'
meta=home/'state'/'probe.meta'
transcript=[]
results=[]

def model_banned(model):
    p=run(['bash','-c','. "$1"; if fm_test_ban_model_applies "$2"; then printf banned; else printf allowed; fi','_',root/'bin/fm-dod-lib.sh',model])
    assert p.returncode==0,p.stderr
    return p.stdout=='banned'

def check(name,model,expected,allowed=None,since=None):
    banned=model_banned(model)
    lines=['kind=ship','mode=no-mistakes',f'worktree={repo}',f'project={repo}',f'model={model}']
    if banned: lines.append(f'test_ban_model={model}')
    if allowed: lines.append(f'test_ban_allowed={allowed}')
    if since: lines.append(f'test_ban_since={since}')
    meta.write_text('\n'.join(lines)+'\n')
    before=meta.read_bytes()
    p=run([root/'bin/fm-pr-check.sh','probe',url])
    errors='\n'.join(l for l in p.stderr.splitlines() if l.startswith('error:'))
    transcript.append(f'## {name}\nmodel: {model}\npolicy: {"banned" if banned else "allowed"}\n$ FM_HOME=<isolated home> bin/fm-pr-check.sh probe {url}\nexit: {p.returncode}\n{errors}\nmetadata unchanged: {meta.read_bytes()==before}\n')
    assert p.returncode==1,(name,p.stdout,p.stderr)
    assert expected in errors,(name,p.stdout,p.stderr)
    assert before==meta.read_bytes(),name
    if expected=='named head': assert 'no test authoring' not in errors,errors
    results.append({'name':name,'model':model,'exit':p.returncode,'error':errors,'metadata_unchanged':True})

try:
    for model in ['sonnet','haiku','opencode/deepseek-v4.1-flash-free','zai/glm-5.3-flash','some-future-cheap-model']:
        check('Banned model cannot register a branch adding tests',model,'no test authoring')
    for model in ['opus','fable','openai-codex/gpt-6.1-sol','default']:
        check('Allowed/default lane reaches ordinary named-head check',model,'named head')
    check('Code-only implementation preserves the handed-over tests','sonnet','named head',since=handoff)
    (repo/'tests'/'feature.test.sh').write_text('true\n');commit('weaken handed-over test')
    check('Sonnet cannot weaken handed-over tests','sonnet','no test authoring',since=handoff)
    (repo/'tests'/'feature.test.sh').unlink();commit('delete handed-over test')
    check('GLM cannot delete handed-over tests','zai/glm-5.3-flash','tests/feature.test.sh',since=handoff)
    # Reset only this disposable local probe repository, never the project.
    git('reset','--hard',impl)
    (repo/'tests'/'extra.test.sh').write_text('true\n');commit('sibling test')
    check('Captain-authorized path does not authorize its sibling','opencode/deepseek-v4.1-flash-free','tests/extra.test.sh',allowed='tests/feature.test.sh')
    assert 'tests/feature.test.sh' not in results[-1]['error'],results[-1]
finally:
    (evidence/'pr-cli-transcript.txt').write_text('\n'.join(transcript))
    (evidence/'pr-cli-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(base)
print(f'Completed {len(results)} real CLI refusal checks; transcript: {evidence}/pr-cli-transcript.txt')
