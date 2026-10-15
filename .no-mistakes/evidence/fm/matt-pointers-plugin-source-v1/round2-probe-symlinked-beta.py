#!/usr/bin/env python3
"""Probe an undeclared upstream skill with a symlinked SKILL.md in an isolated real-package deployment."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path.cwd()
evidence = Path('/Users/yelen/.no-mistakes/evidence/01M4ZTR52N580GZBN507P0FPP9')
lab = Path(tempfile.mkdtemp(prefix='symlink-probe-', dir=root / '.test-tmp'))
log = (evidence / 'round2-symlinked-beta-probe.log').open('w')
observed = {}

def run(*args):
    result = subprocess.run([str(a) for a in args], cwd=root, env=env, text=True, capture_output=True, timeout=120)
    log.write('$ ' + ' '.join(str(a) for a in args) + '\nexit=' + str(result.returncode) + '\nstdout:\n' + result.stdout + '\nstderr:\n' + result.stderr + '\n')
    log.flush()
    return result

try:
    original_env = os.environ.copy()
    config = Path(original_env.get('CLAUDE_CONFIG_DIR') or Path.home() / '.claude')
    original_registry = json.loads((config / 'plugins/installed_plugins.json').read_text())
    key = 'mattpocock-skills@mattpocock'
    entry = original_registry['plugins'][key][0].copy()
    staged = lab / 'installed-1.3.1'
    shutil.copytree(entry['installPath'], staged, ignore=shutil.ignore_patterns('.git'))
    entry['installPath'] = str(staged)
    isolated_config = lab / 'config'
    (isolated_config / 'plugins').mkdir(parents=True)
    (isolated_config / 'plugins/installed_plugins.json').write_text(json.dumps({'plugins': {key: [entry]}}))
    (isolated_config / 'settings.json').write_text(json.dumps({'enabledPlugins': {key: True}}))
    env = dict(original_env, CLAUDE_CONFIG_DIR=str(isolated_config), TMPDIR=str(lab))
    dest = lab / 'pointers'
    assert run('bin/fm-matt-pointers.sh', '--dest', dest).returncode == 0
    skill = staged / 'skills/in-progress/writing-beats/SKILL.md'
    # Keep the exact live installed bytes, with a symbolic link at the public skill path.
    body = skill.with_name('original-body.md')
    skill.rename(body)
    skill.symlink_to(body.name)
    log.write('Changed only the isolated writing-beats/SKILL.md from regular file to symlink to identical bytes.\n')
    listing = run('bin/fm-matt-skill.sh', '--list')
    observed['list_exit'] = listing.returncode
    observed['writing_beats_listed'] = 'writing-beats' in listing.stdout.splitlines()
    observed['listed_count'] = len(listing.stdout.splitlines())
    direct = run('bin/fm-matt-skill.sh', 'writing-beats', '--check')
    observed['single_skill_exit'] = direct.returncode
    install = run('bin/fm-matt-pointers.sh', '--dest', lab / 'fresh-pointers')
    observed['fresh_install_exit'] = install.returncode
    audit = run('bin/fm-matt-pointers.sh', '--check', '--dest', dest)
    observed['check_classified_retired'] = 'RETIRED:' in audit.stderr
    pruned = run('bin/fm-matt-pointers.sh', '--prune', '--dest', dest)
    observed['prune_exit'] = pruned.returncode
    observed['pointer_survives_prune'] = (dest / 'matt-writing-beats/SKILL.md').exists()
    fresh_check = run('bin/fm-matt-pointers.sh', '--check', '--dest', lab / 'fresh-pointers')
    observed['fresh_check_exit'] = fresh_check.returncode
    observed['fresh_check_says_ok'] = 'ok - 37 pointers' in fresh_check.stdout
    assert observed == {'list_exit': 7, 'writing_beats_listed': False, 'listed_count': 37, 'single_skill_exit': 6, 'fresh_install_exit': 1, 'check_classified_retired': False, 'prune_exit': 1, 'pointer_survives_prune': True, 'fresh_check_exit': 1, 'fresh_check_says_ok': False}, observed
    log.write('OBSERVED:\n' + json.dumps(observed, indent=2) + '\n')
finally:
    shutil.rmtree(lab)
    log.write('Removed isolated staged package and generated pointers.\n')
    log.close()
    (evidence / 'round2-symlinked-beta-result.json').write_text(json.dumps(observed, indent=2) + '\n')
print(json.dumps(observed, indent=2))
