#!/usr/bin/env python3
"""Manual product CLI scenarios against the real installed plugin and an isolated staged deployment."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path.cwd()
EVIDENCE = Path('/Users/yelen/.no-mistakes/evidence/01M4ZTR52N580GZBN507P0FPP9')
LAB = Path(tempfile.mkdtemp(prefix='manual-pointer-', dir=ROOT / '.test-tmp'))
ENV = dict(os.environ, TMPDIR=str(LAB))
LOG = (EVIDENCE / 'round4-live-pointer-cli.log').open('w')
RESULTS = []

def note(text):
    LOG.write(text + '\n')
    LOG.flush()

def run(args, env=ENV, expected=0, full=True):
    note('$ ' + ' '.join(str(x) for x in args))
    result = subprocess.run([str(x) for x in args], cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
    note('exit=' + str(result.returncode))
    if full:
        note('stdout:\n' + result.stdout)
    if result.stderr:
        note('stderr:\n' + result.stderr)
    assert result.returncode == expected, (args, expected, result.returncode, result.stderr)
    return result

def pointer(*args, **kwargs):
    return run(['bin/fm-matt-pointers.sh', *args], **kwargs)

def loader(*args, **kwargs):
    return run(['bin/fm-matt-skill.sh', *args], **kwargs)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def outcome(name):
    RESULTS.append({'name': name, 'result': 'pass'})
    note('SCENARIO PASS: ' + name)

try:
    config = Path(ENV.get('CLAUDE_CONFIG_DIR') or Path.home() / '.claude')
    registry = json.loads((config / 'plugins/installed_plugins.json').read_text())
    registry = {'plugins': {k:v for k,v in registry['plugins'].items() if k.startswith('mattpocock-skills@')}}
    note('Read-only installed plugin identity:\n' + json.dumps(registry, indent=2))
    identity = loader('code-review', '--check').stdout
    assert 'plugin=mattpocock-skills@mattpocock\n' in identity
    assert 'resolved_version=1.3.1\n' in identity
    install = Path(next(x.split('=', 1)[1] for x in identity.splitlines() if x.startswith('skill_file='))).parents[3]
    source_rows = run(['bin/fm-skill-path.sh', 'mattpocock-skills', '--list-skills', '--include-undeclared']).stdout
    offered = dict(line.split('\t', 1) for line in source_rows.splitlines())
    manifest = json.loads((install / '.claude-plugin/plugin.json').read_text())
    source_skills = {p.parent.name for p in (install / 'skills').glob('**/SKILL.md') if 'deprecated' not in p.relative_to(install).parts}
    declared = {Path(p).name for p in manifest['skills']}
    assert len(offered) == 38 and set(offered) == source_skills
    assert len(declared) == 27 and len(set(offered) - declared) == 11
    assert set(loader('--list').stdout.splitlines()) == source_skills
    destination = LAB / 'pointers'
    pointer('--dest', destination)
    assert len(list(destination.glob('matt-*/.firstmate-pointer'))) == 38
    pointer('--check', '--dest', destination)
    shutil.copyfile(destination / 'matt-code-review/SKILL.md', EVIDENCE / 'round4-generated-code-review-pointer.md')
    digest_rows = []
    for name, relative in offered.items():
        generated = (destination / f'matt-{name}/SKILL.md').read_text()
        command = re.search(r'```bash\n(.*?)\n```', generated, re.S).group(1)
        result = run(['bash', '-c', command], full=False)
        assert 'pin=validated\n' in result.stdout
        body = result.stdout.split('=====================================================\n\n', 1)[1].split('\n===== END ORIGINAL SKILL.md =====', 1)[0].encode()
        original = (install / relative / 'SKILL.md').read_bytes()
        assert body == original, name
        digest = sha(original)
        assert f'skill_file_sha256={digest}\n' in result.stdout
        assert '\n## Step 1 - load the original' in generated
        original_procedure = original.decode().split('---', 2)[-1].strip()
        assert original_procedure not in generated, name
        digest_rows.append({'skill': name, 'bucket': Path(relative).parts[1], 'sha256': digest, 'pointer_step1_exit': result.returncode, 'pin': 'validated', 'exact_original_bytes': True})
        note(f'{name}: pin=validated; exact_original_bytes=true; sha256={digest}')
        if name == 'code-review':
            (EVIDENCE / 'round4-loaded-code-review.txt').write_text(result.stdout)
    (EVIDENCE / 'round4-all-38-load-proofs.json').write_text(json.dumps(digest_rows, indent=2) + '\n')
    outcome('Generate 38 pointers and run every generated Step 1 against the enabled 1.3.1 install')

    old = ['--validated-plugin', 'mattpocock-skills@claude-plugins-official', '--validated-version', '1.2.3']
    changed = loader('code-review', *old).stdout
    assert 'PLUGIN CHANGED' in changed and 'pin=changed' in changed
    assert 'plugin=mattpocock-skills@mattpocock\n' in changed
    strict = loader('code-review', *old, '--require-validated-pin', expected=6)
    assert not strict.stdout
    disabled = run(['bin/fm-skill-path.sh', 'mattpocock-skills@claude-plugins-official', 'code-review'], expected=4)
    assert not disabled.stdout and 'disabled' in disabled.stderr
    outcome('A stale official-plugin pin loads the current source with a warning or refuses in strict mode')

    # Real registry and installed package paths, isolated user configuration only.
    isolated_config = LAB / 'config'
    (isolated_config / 'plugins').mkdir(parents=True)
    (isolated_config / 'plugins/installed_plugins.json').write_text(json.dumps(registry))
    isolated_env = dict(ENV, CLAUDE_CONFIG_DIR=str(isolated_config))
    keys = list(registry['plugins'])
    (isolated_config / 'settings.json').write_text(json.dumps({'enabledPlugins': dict.fromkeys(keys, True)}))
    ambiguous = loader('--list', env=isolated_env, expected=6)
    assert not ambiguous.stdout and 'ambiguous' in ambiguous.stderr
    (isolated_config / 'settings.json').write_text(json.dumps({'enabledPlugins': dict.fromkeys(keys, False)}))
    none = pointer('--dest', LAB / 'disabled-destination', env=isolated_env, expected=4)
    assert not (LAB / 'disabled-destination').exists()
    outcome('No enabled source or two enabled marketplaces refuses without creating pointers')

    # Corrupt the actual generated output as an operator might, never the user destination.
    drifted = destination / 'matt-code-review/SKILL.md'
    drifted.write_text(drifted.read_text() + '\nEdited locally\n')
    (destination / 'matt-tdd/SKILL.md').unlink()
    marker = destination / 'matt-code-review/.firstmate-pointer'
    marker.write_text(re.sub(r'^loader=.*$', 'loader=' + str(LAB / 'missing-loader'), marker.read_text(), flags=re.M))
    foreign = destination / 'matt-grilling'
    (foreign / '.firstmate-pointer').unlink()
    (foreign / 'SKILL.md').write_text('Personal skill that must survive installation and cleanup.\n')
    foreign_before = sha((foreign / 'SKILL.md').read_bytes())
    audit = pointer('--check', '--dest', destination, expected=1)
    for expected in ['DRIFTED:', 'MISSING:', 'BROKEN:', 'FOREIGN:']:
        assert expected in audit.stderr, expected
    pointer('--dest', destination, expected=1)
    assert sha((foreign / 'SKILL.md').read_bytes()) == foreign_before
    pointer('--uninstall', '--dest', destination)
    assert foreign.is_dir() and sha((foreign / 'SKILL.md').read_bytes()) == foreign_before
    assert len(list(destination.glob('matt-*/.firstmate-pointer'))) == 0
    outcome('Audit detects edited, missing and dead-loader pointers while install and uninstall preserve a foreign skill')

    # Stage the real upstream package in an isolated deployment, not synthetic skill bodies.
    staged = LAB / 'installed-1.3.1'
    shutil.copytree(install, staged, ignore=shutil.ignore_patterns('.git'))
    for entry in registry['plugins']['mattpocock-skills@mattpocock']:
        entry['installPath'] = str(staged)
    (isolated_config / 'plugins/installed_plugins.json').write_text(json.dumps(registry))
    (isolated_config / 'settings.json').write_text(json.dumps({'enabledPlugins': {k: k == 'mattpocock-skills@mattpocock' for k in keys}}))
    staged_dest = LAB / 'staged-pointers'
    pointer('--dest', staged_dest, env=isolated_env)
    pointer('--check', '--dest', staged_dest, env=isolated_env)
    # Uncurated beta skill is misnamed, another occurs twice, and declared tdd has a support symlink.
    beats = staged / offered['writing-beats'] / 'SKILL.md'
    beats.write_text(re.sub(r'^name:.*$', 'name: wrong-name', beats.read_text(), count=1, flags=re.M))
    shutil.copytree(staged / offered['chief-of-staff'], staged / 'skills/misc/chief-of-staff')
    (staged / offered['tdd'] / 'unsafe-support-link').symlink_to(staged / offered['tdd'] / 'SKILL.md')
    broken_names = {'writing-beats', 'chief-of-staff', 'tdd'}
    listing = loader('--list', env=isolated_env, expected=7)
    assert len(listing.stdout.splitlines()) == 35
    for name in broken_names:
        assert name not in listing.stdout.splitlines() and f'leaves out {name},' in listing.stderr
    for flag in [[], ['--check']]:
        partial = pointer(*flag, '--dest', staged_dest, env=isolated_env, expected=1)
        for name in broken_names:
            assert f'UNRESOLVED: upstream skill {name} is offered' in partial.stderr
        assert 'ok - ' not in partial.stdout
        assert 'RETIRED:' not in partial.stderr
    # A real offered skill disappears from the staged upstream package.
    shutil.rmtree(staged / offered['setup-pre-commit'])
    retired = pointer('--check', '--dest', staged_dest, env=isolated_env, expected=1)
    assert 'RETIRED:' in retired.stderr and 'setup-pre-commit' in retired.stderr
    pruned = pointer('--prune', '--dest', staged_dest, env=isolated_env, expected=1)
    assert not (staged_dest / 'matt-setup-pre-commit').exists()
    for name in broken_names:
        assert (staged_dest / f'matt-{name}/SKILL.md').exists()
        assert f'upstream skill {name} is still offered' in pruned.stderr
    outcome('An incomplete upstream deployment names every unresolved skill, fails health checks, preserves their pointers and prunes only a retired skill')
except Exception as exc:
    note('DRIVER FAILURE: ' + repr(exc))
    RESULTS.append({'name': 'driver', 'result': 'fail', 'error': repr(exc)})
    raise
finally:
    shutil.rmtree(LAB)
    note('Removed isolated generated pointers, staged install and configuration: ' + str(LAB))
    (EVIDENCE / 'round4-live-scenario-results.json').write_text(json.dumps(RESULTS, indent=2) + '\n')
    LOG.close()
