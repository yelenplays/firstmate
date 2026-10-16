"""Exercise real spawn refusals; all Herdr operations delegate to guarded lab helper."""
import json, os, pathlib, shutil, subprocess, tempfile
root = pathlib.Path.cwd()
base = pathlib.Path(tempfile.mkdtemp(prefix='.test-live-', dir=root))
env = dict(os.environ)
for k in list(env):
    if k.startswith(('FM_', 'HERDR_')) or k in ('TMUX', 'TMUX_PANE', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
        env.pop(k)
env['FM_HERDR_LAB_STATE_DIR'] = str(base / 'lab-state')
helper = str(root / 'bin/fm-herdr-lab.sh')
def run(args, check=True):
    print('$', ' '.join(map(str,args)), flush=True)
    p = subprocess.run(list(map(str,args)), env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90)
    print(p.stdout, end='', flush=True)
    print('exit:', p.returncode, flush=True)
    if check: p.check_returncode()
    return p
session = run([helper, 'name', 'raw-opus']).stdout.strip()
provisioned=False
try:
    run([helper, 'provision', session]); provisioned=True
    home=base/'home'
    run([root/'bin/fm-lab-home.sh','create',home])
    env['FM_HOME']=str(home)
    env['HERDR_SESSION']=session
    (home/'config/supervision-host').touch()
    project=base/'project'; project.mkdir()
    run(['git','-C',project,'init','-q','-b','main'])
    run(['git','-C',project,'-c','user.name=CLI validation','-c','user.email=test@example.invalid','commit','--allow-empty','-qm','initial'])
    # Scoped transport wrapper, not a stub: delegates to the real Herdr binary through the lab helper.
    bindir=base/'bin'; bindir.mkdir()
    wrapper=bindir/'herdr'
    original=env['PATH']
    wrapper.write_text('#!/usr/bin/env python3\nimport os,sys\na=sys.argv[1:]\n'
      +f'session={session!r}\nhelper={helper!r}\n'
      +'if "--session" in a:\n i=a.index("--session"); assert a[i+1]==session; del a[i:i+2]\n'
      +f'os.environ["PATH"]={original!r}\n'
      +'os.execv(helper,[helper,"run",session]+a)\n')
    wrapper.chmod(0o755)
    env['PATH']=str(bindir)+os.pathsep+original
    commands=['claude --model claude-opus-5-5 --effort high', 'claude --model="claude-opus-5-5[1m]" --effort=xhigh', 'env WORKER=1 claude --model anthropic/claude-opus-5-5 --effort max']
    for i, command in enumerate(commands):
        task=f'raw-live-{i}'
        p=run([root/'bin/fm-spawn.sh',task,project,command,'--scout','--backend','herdr'],check=False)
        assert p.returncode==1 and 'raw launch commands naming claude-opus-5-5 are unsupported' in p.stdout,p.stdout
        assert not (home/'state'/f'{task}.meta').exists()
        print('Verified: refused before publishing task metadata.',flush=True)
finally:
    env['PATH']=original if 'original' in locals() else env['PATH']
    if provisioned:
        run([helper,'teardown',session])
    shutil.rmtree(base)
    print('Lab session and disposable local files removed.',flush=True)
