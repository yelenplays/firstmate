import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess

ROOT = Path.cwd()
EVIDENCE = Path('/Users/yelen/.no-mistakes/evidence/01M52ZH81AHJBVPJCFBT00P44Y')
LAB = ROOT / '.test-local-tmp/live-routes'
LAB.mkdir(parents=True, exist_ok=True)
ENV = os.environ.copy()
ENV['TMPDIR'] = str(ROOT / '.test-local-tmp')
LOADER = ROOT / 'bin/fm-matt-skill.sh'
POINTERS = ROOT / 'bin/fm-matt-pointers.sh'
results = []

def run(label, args, expected=0, env=None):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=env or ENV,
                       text=True, capture_output=True, timeout=300)
    record = {'label': label, 'command': shlex.join([str(a) for a in args]),
              'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr}
    results.append(record)
    (EVIDENCE / 'live-skill-routes.json').write_text(json.dumps(results, indent=2) + '\n')
    print(f'{label}: exit={p.returncode}', flush=True)
    assert p.returncode == expected, record
    return p

# Baseline is run with the same real installed plugin, without changing the checkout.
base = LAB / 'baseline/bin'
base.mkdir(parents=True, exist_ok=True)
for name in ['fm-matt-skill.sh', 'fm-skill-path.sh']:
    data = subprocess.check_output(['git', 'show', f'3a9eb4b325abfaa313c291d30a62a8f7425400c6:bin/{name}'])
    (base / name).write_bytes(data)
    (base / name).chmod(0o755)
p = run('Before fix: real installed plugin blocks the conflict skill',
        [base / 'fm-matt-skill.sh', 'resolving-merge-conflicts'], 5)
assert not p.stdout

original_pointer = Path('/Users/yelen/.agents/skills/matt-resolving-merge-conflicts/SKILL.md').read_text()
original_marker = Path('/Users/yelen/.agents/skills/matt-resolving-merge-conflicts/.firstmate-pointer').read_text()
original_command = original_pointer.split('```bash\n', 1)[1].split('\n```', 1)[0]
argv = shlex.split(original_command)
assert argv[1:] == ['resolving-merge-conflicts'], argv
# Replay the discovered installed command against the gate's code, never another checkout.
argv[0] = str(LOADER)
(EVIDENCE / 'caller-route.txt').write_text(
    'Installed discovery pointer: /Users/yelen/.agents/skills/matt-resolving-merge-conflicts/SKILL.md\n'
    f'Installed Step 1: {original_command}\n'
    f'Replayed Step 1 (only executable relocated to this change): {shlex.join(argv)}\n'
    'No global pointer, plugin cache, credentials, or pipeline state was changed.\n')
p = run('Installed pointer Step 1 replay returns the bundled procedure', argv)
assert 'pin=bundled\n' in p.stdout and 'plugin=none\n' in p.stdout
assert '===== END BUNDLED SKILL.md =====' in p.stdout
assert 'ORIGINAL SKILL LOADED' not in p.stdout
(EVIDENCE / 'loaded-conflict-skill.txt').write_text(p.stdout)

path = run('Conflict skill path is loadable', [LOADER, 'resolving-merge-conflicts', '--path']).stdout.strip()
assert Path(path).read_bytes() == (ROOT / '.agents/skills/resolving-merge-conflicts/SKILL.md').read_bytes()
identity = run('Conflict skill identity matches its actual bytes', [LOADER, 'resolving-merge-conflicts', '--check']).stdout
assert 'skill_file_sha256=' + hashlib.sha256(Path(path).read_bytes()).hexdigest() in identity
files = run('Bundled license is reachable', [LOADER, 'resolving-merge-conflicts', '--files']).stdout.splitlines()
assert str(Path(path).with_name('LICENSE')) in files

pins = ['--validated-plugin', 'mattpocock-skills@claude-plugins-official',
        '--validated-version', '1.2.3', '--validated-commit', '2ab958093e83e0ec752e6c1c5932da465bf23e0c']
p = run('Old generated pointer pins still load with honest bundled provenance',
        [LOADER, 'resolving-merge-conflicts', *pins])
assert 'pin=bundled\n' in p.stdout
p = run('Strict plugin provenance refuses bundled content without printing a body',
        [LOADER, 'resolving-merge-conflicts', *pins, '--require-validated-pin'], 6)
assert not p.stdout
p = run('Unknown skill cannot activate the compatibility fallback', [LOADER, 'not-a-real-skill'], 5)
assert not p.stdout
p = run('Generic resolver still refuses false plugin provenance',
        [ROOT / 'bin/fm-skill-path.sh', 'mattpocock-skills', 'resolving-merge-conflicts', '--include-undeclared'], 5)
assert not p.stdout
p = run('An ordinary plugin skill still loads its original', [LOADER, 'tdd'])
assert 'ORIGINAL SKILL LOADED' in p.stdout and 'BUNDLED COMPATIBILITY' not in p.stdout

# Produce genuine pointers from the real plugin, transplant the installed legacy pointer
# into this isolated destination, and run the end-user maintenance commands on it.
dest = LAB / 'skills'
run('Generate pointers from the actual installed plugin into an isolated destination',
    [POINTERS, '--dest', dest, '--date', '2026-10-16'])
conflict = dest / 'matt-resolving-merge-conflicts'
conflict.mkdir()
pointer = conflict / 'SKILL.md'
marker = conflict / '.firstmate-pointer'
pointer.write_text(original_pointer.replace(shlex.split(original_command)[0], str(LOADER)))
marker.write_text('\n'.join('loader=' + str(LOADER) if s.startswith('loader=') else s
                           for s in original_marker.splitlines()) + '\n')
before = {f.name: f.read_bytes() for f in [pointer, marker]}
for label, flags in [('Audit keeps the legacy conflict pointer', ['--check']),
                     ('Dry prune keeps the legacy conflict pointer', ['--prune', '--dry-run']),
                     ('Real prune keeps the legacy conflict pointer', ['--prune'])]:
    p = run(label, [POINTERS, *flags, '--dest', dest])
    assert 'BUNDLED:' in p.stdout
    assert {f.name: f.read_bytes() for f in [pointer, marker]} == before
cmd = shlex.split(pointer.read_text().split('```bash\n', 1)[1].split('\n```', 1)[0])
p = run('Execute the preserved pointer after prune', cmd)
assert 'pin=bundled\n' in p.stdout

pointer.unlink()
p = run('Audit actively detects a missing bundled pointer body', [POINTERS, '--check', '--dest', dest], 1)
assert f'MISSING: {pointer}' in p.stderr
pointer.write_bytes(before['SKILL.md'])
marker.write_text(marker.read_text().replace('loader=' + str(LOADER), 'loader=' + str(LAB / 'missing-loader')))
p = run('Audit actively detects a broken recorded loader', [POINTERS, '--check', '--dest', dest], 1)
assert f'BROKEN: {pointer}' in p.stderr
marker.write_bytes(before['.firstmate-pointer'])
print('All live CLI scenarios passed; isolated runtime data will be removed by the test phase.', flush=True)
