import json, os, pathlib, shlex, subprocess

root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M52N7HE3KYQD9KR1W9HF5Y1N')
scratch = root / '.test-tmp-skill-loader' / 'live'
scratch.mkdir(parents=True, exist_ok=True)
loader = root / 'bin/fm-matt-skill.sh'
log = []

def run(label, argv, expected=0, env=None):
    p = subprocess.run([str(a) for a in argv], cwd=root, env=env, text=True, capture_output=True, timeout=90)
    log.extend([f'## {label}', '$ ' + shlex.join([str(a) for a in argv]), f'exit={p.returncode}', 'stdout:', p.stdout, 'stderr:', p.stderr])
    (evidence / 'live-loader-transcript.txt').write_text('\n'.join(log))
    assert p.returncode == expected, (label, p.returncode, expected)
    return p

# Read the actual installed caller instruction, never execute its other-checkout path.
pointer = pathlib.Path('/Users/yelen/.agents/skills/matt-resolving-merge-conflicts/SKILL.md')
command = pointer.read_text().split('```bash\n', 1)[1].split('```', 1)[0].strip()
argv = shlex.split(command)
assert argv[1:] == ['resolving-merge-conflicts'], argv
log.extend(['Actual installed pointer Step 1:', command, 'Only the executable prefix is retargeted to the gate branch; no global pointer or other checkout is changed or executed.'])

# Reproduce the failure with the base executables inside this worktree.
basebin = scratch / 'base/bin'
basebin.mkdir(parents=True, exist_ok=True)
for name in ['fm-matt-skill.sh', 'fm-skill-path.sh']:
    p = subprocess.run(['git', 'show', '8045dac2e15053eff300e75778019a5656601cb0:bin/' + name], check=True, capture_output=True)
    path = basebin / name
    path.write_bytes(p.stdout)
    path.chmod(0o755)
p = run('Base: installed pointer invocation cannot load retired skill', [basebin / 'fm-matt-skill.sh'] + argv[1:], 5)
assert not p.stdout
p = run('Branch: installed pointer invocation emits full bundled procedure', [loader] + argv[1:])
assert 'FIRSTMATE: BUNDLED COMPATIBILITY SKILL' in p.stdout
assert 'name: resolving-merge-conflicts' in p.stdout
assert 'END BUNDLED SKILL.md' in p.stdout
assert 'ORIGINAL SKILL LOADED' not in p.stdout

p = run('Plugin resolver remains honest: retired skill is not installed', [root/'bin/fm-skill-path.sh', 'mattpocock-skills', 'resolving-merge-conflicts', '--include-undeclared'], 5)
assert not p.stdout
p = run('Path mode returns readable bundled skill', [loader, 'resolving-merge-conflicts', '--path'])
path = pathlib.Path(p.stdout.strip())
assert path.is_file() and path.is_relative_to(root)
p = run('Check mode labels bundled identity without procedure', [loader, 'resolving-merge-conflicts', '--check'])
assert 'pin=bundled' in p.stdout and 'name: resolving-merge-conflicts' not in p.stdout
p = run('Support file mode exposes attributed license', [loader, 'resolving-merge-conflicts', '--files'])
assert any(pathlib.Path(s).name == 'LICENSE' and pathlib.Path(s).is_file() for s in p.stdout.splitlines())
p = run('Stale pointer pins cannot falsely validate bundled content', [loader, 'resolving-merge-conflicts', '--validated-plugin', 'mattpocock-skills@claude-plugins-official', '--validated-version', '1.2.3', '--validated-commit', '2ab958093e83e0ec752e6c1c5932da465bf23e0c'])
assert 'pin=bundled' in p.stdout and 'ORIGINAL SKILL LOADED' not in p.stdout
p = run('Strict plugin pin refuses bundled procedure', [loader, 'resolving-merge-conflicts', '--validated-version', '1.3.1', '--require-validated-pin'], 6)
assert not p.stdout
p = run('Unrelated unknown name does not trigger fallback', [loader, 'no-such-conflict-skill'], 5)
assert not p.stdout
p = run('Existing TDD skill still loads installed original', [loader, 'tdd', '--check'])
assert 'ORIGINAL SKILL LOADED' in p.stdout and 'resolved_version=1.3.1' in p.stdout

# Production CLI + actual plugin bytes, with only enablement isolated locally.
config = pathlib.Path(os.environ.get('CLAUDE_CONFIG_DIR', str(pathlib.Path.home()/'.claude')))
registry = json.loads((config/'plugins/installed_plugins.json').read_text())
keys = [k for k in registry['plugins'] if k.split('@')[0] == 'mattpocock-skills']
assert keys
isolated = scratch/'disabled-config'
(isolated/'plugins').mkdir(parents=True, exist_ok=True)
(isolated/'plugins/installed_plugins.json').write_text(json.dumps(registry))
(isolated/'settings.json').write_text(json.dumps({'enabledPlugins': dict.fromkeys(keys, False)}))
env = dict(os.environ, CLAUDE_CONFIG_DIR=str(isolated))
p = run('Disabled actual installed plugin cannot activate fallback', [loader, 'resolving-merge-conflicts'], 4, env)
assert not p.stdout
absent = scratch/'absent-config'
absent.mkdir(exist_ok=True)
p = run('Absent registry cannot activate fallback', [loader, 'resolving-merge-conflicts'], 3, dict(os.environ, CLAUDE_CONFIG_DIR=str(absent)))
assert not p.stdout
log.append('All live loader assertions passed. No pipeline, harness lifecycle, global pointer, login, or plugin cache was changed.')
(evidence/'live-loader-transcript.txt').write_text('\n'.join(log))
print('Live loader assertions passed; full CLI output captured in live-loader-transcript.txt')
