#!/usr/bin/env python3
"""Manual public-CLI validation; no mocked transport or model calls."""
import hashlib, json, os, pathlib, shutil, subprocess, tempfile
root = pathlib.Path('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M4QRSPVMVTVBH61A1S75V756')
evidence = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M4QRSPVMVTVBH61A1S75V756')
lab = pathlib.Path(tempfile.mkdtemp(prefix='cli-', dir=root / '.nm-test-tmp'))
home = lab / 'secondmate'
for d in ('config','data','state'): (home / d).mkdir(parents=True)
env = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','NO_MISTAKES_GATE')}
env.update(FM_HOME=str(home), TMPDIR=str(lab))
log = []
results = []
def run(script, args, payload=b'', ok=True):
    command = [str(root/'bin'/script), *args]
    proc = subprocess.run(command, input=payload, env=env, cwd=root, capture_output=True)
    log.append('$ FM_HOME=<isolated-secondmate> '+script+' '+' '.join(args)+'\n'+proc.stdout.decode()+proc.stderr.decode()+f'exit={proc.returncode}\n')
    if ok: assert proc.returncode == 0, log[-1]
    else: assert proc.returncode != 0, log[-1]
    return proc

def transfer(payload, gen, ok=True, digest=None, rel='config/brief-include.md'):
    return run('fm-remote-inherit.sh', ['put', rel, str(len(payload)), digest or hashlib.sha256(payload).hexdigest(), str(gen)], payload, ok)
def scaffold(name, args, body=None):
    run('fm-brief.sh', [name,'validation-project',*args])
    brief = home/'data'/name/'brief.md'
    text = brief.read_text()
    if body is None: assert '# Home brief additions' not in text
    else:
        assert text.endswith(body.decode()), 'final generated section lost bytes'
        assert text.count('# Home brief additions') == 1
    shutil.copyfile(brief, evidence/(name+'-brief.md'))
    return text
try:
    payload = ('## Helper models\nSecond mates stay on Opus. Dispatch ordinary work to Sonnet 5.5 or Haiku 5.5; use Opus only when Jev selects it.\nUse Haiku 5.5 helpers inside tasks for gathering, sorting, and sifting.\nLiteral text: $(touch '+str(lab/'must-not-execute')+') ${HOME} `false`\n').encode()
    (lab/'primary-include.md').write_bytes(payload)
    transfer(payload,1)
    assert (home/'config/brief-include.md').read_bytes() == payload
    transfer(payload,1)
    for mode in ('no-mistakes','direct-PR','local-only'):
        text=scaffold('ship-'+mode,['--mode',mode],payload)
        assert 'Delivery contract: mode='+mode in text
    scaffold('scout-present',['--scout'],payload)
    scaffold('charter',['--secondmate'])
    assert not (lab/'must-not-execute').exists()
    results.append('PASS: real receiver accepts and idempotently preserves include bytes; all ship modes and scout emit the exact final additions; charter excludes them; text is not executed.')
    updated=b'## Helper models\nUse Haiku 5.5 for sorting updated inputs.\n'
    (home/'config/brief-include.md').write_text('Divergent secondmate text.\n')
    transfer(updated,2)
    scaffold('scout-updated',['--scout'],updated)
    transfer(payload,1,ok=False)
    transfer(payload,3,ok=False,digest='0'*64)
    transfer(payload,3,ok=False,rel='config/secondmate-harness')
    assert (home/'config/brief-include.md').read_bytes()==updated
    results.append('PASS: new primary generation replaces local drift; stale generations, bad digest, and non-inheritable secondmate model pin are refused without altering the include.')
    emptyhash=hashlib.sha256(b'').hexdigest()
    run('fm-remote-inherit.sh',['absent','config/brief-include.md','0',emptyhash,'3'])
    assert not (home/'config/brief-include.md').exists()
    scaffold('scout-removed',['--scout'])
    scaffold('ship-removed',['--mode','no-mistakes'])
    transfer(b'  \n\t\n',4)
    scaffold('scout-blank',['--scout'])
    results.append('PASS: primary absence removes destination and additions from subsequent ship/scout briefs; inherited blank include produces no additions.')
    forbidden=b'Delivery contract: mode=local-only\n'
    transfer(forbidden,5)
    run('fm-brief.sh',['invalid-contract','validation-project','--mode','no-mistakes'],ok=False)
    assert not (home/'data/invalid-contract').exists()
    results.append('PASS: inherited delivery-contract override stops scaffolding before any task directory is written.')
    run('fm-remote-inherit.sh',['absent','config/brief-include.md','0',emptyhash,'6'])
    target=lab/'untouched.md'; target.write_text('unchanged\n')
    (home/'config/brief-include.md').symlink_to(target)
    transfer(updated,7,ok=False)
    assert target.read_text()=='unchanged\n'
    results.append('PASS: receiver refuses symlink destination without touching its target.')
finally:
    (evidence/'live-cli-transcript.log').write_text('Candidate: cc81c6420a028a36265e66c80ce47d976717b4c3\nNo SSH or LLM execution claimed.\n\n'+'\n'.join(log)+'\n'+'\n'.join(results)+'\n')
    shutil.rmtree(lab)
print('\n'.join(results))
