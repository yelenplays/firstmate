#!/usr/bin/env python3
"""Exercise pruning when an undeclared skills bucket becomes a directory link."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path.cwd()
evidence = Path('/Users/yelen/.no-mistakes/evidence/01M4ZTR52N580GZBN507P0FPP9')
lab = Path(tempfile.mkdtemp(prefix='symlink-bucket-', dir=root / '.test-tmp'))
log = (evidence / 'round4-symlinked-bucket-probe.log').open('w')
observed = {}

def run(*args):
    result = subprocess.run([str(a) for a in args], cwd=root, env=env, text=True, capture_output=True, timeout=120)
    log.write('$ ' + ' '.join(str(a) for a in args) + '\nexit=' + str(result.returncode) + '\nstdout:\n' + result.stdout + '\nstderr:\n' + result.stderr + '\n')
    log.flush()
    return result

try:
    config = Path(os.environ.get('CLAUDE_CONFIG_DIR') or Path.home() / '.claude')
    registry = json.loads((config / 'plugins/installed_plugins.json').read_text())
    key = 'mattpocock-skills@mattpocock'
    entry = registry['plugins'][key][0].copy()
    staged = lab / 'installed-1.3.1'
    shutil.copytree(entry['installPath'], staged, ignore=shutil.ignore_patterns('.git'))
    entry['installPath'] = str(staged)
    isolated = lab / 'config'
    (isolated / 'plugins').mkdir(parents=True)
    (isolated / 'plugins/installed_plugins.json').write_text(json.dumps({'plugins': {key: [entry]}}))
    (isolated / 'settings.json').write_text(json.dumps({'enabledPlugins': {key: True}}))
    env = dict(os.environ, CLAUDE_CONFIG_DIR=str(isolated), TMPDIR=str(lab))
    dest = lab / 'pointers'
    assert run('bin/fm-matt-pointers.sh', '--dest', dest).returncode == 0
    bucket = staged / 'skills/in-progress'
    names = sorted(p.parent.name for p in bucket.glob('*/SKILL.md'))
    before = {name: (dest / f'matt-{name}/SKILL.md').read_bytes() for name in names}
    body = staged / 'original-in-progress-bucket'
    bucket.rename(body)
    bucket.symlink_to(body, target_is_directory=True)
    log.write('Replaced only isolated skills/in-progress with a symlink to its identical original bucket. All seven SKILL.md files remain intact.\n')
    listing = run('bin/fm-matt-skill.sh', '--list')
    observed['list_exit'] = listing.returncode
    observed['listed_count'] = len(listing.stdout.splitlines())
    direct = run('bin/fm-matt-skill.sh', 'writing-beats', '--check')
    observed['single_skill_exit'] = direct.returncode
    observed['single_skill_stdout_empty'] = not direct.stdout
    install = run('bin/fm-matt-pointers.sh', '--dest', lab / 'fresh-pointers')
    observed['fresh_install_exit'] = install.returncode
    audit = run('bin/fm-matt-pointers.sh', '--check', '--dest', dest)
    observed['check_classified_retired'] = 'RETIRED:' in audit.stderr
    observed['unresolved_summary_names_writing_beats'] = 'UNRESOLVED: upstream skill writing-beats is offered' in install.stderr
    pruned = run('bin/fm-matt-pointers.sh', '--prune', '--dest', dest)
    observed['prune_exit'] = pruned.returncode
    observed['removed_pointers'] = [name for name in names if not (dest / f'matt-{name}/SKILL.md').exists()]
    observed['preserved_unchanged_pointers'] = [name for name in names if (dest / f'matt-{name}/SKILL.md').exists() and (dest / f'matt-{name}/SKILL.md').read_bytes() == before[name]]
    fresh_check = run('bin/fm-matt-pointers.sh', '--check', '--dest', lab / 'fresh-pointers')
    observed['fresh_check_exit'] = fresh_check.returncode
    observed['fresh_check_says_ok'] = 'ok - ' in fresh_check.stdout
    log.write('OBSERVED:\n' + json.dumps(observed, indent=2) + '\n')
    assert direct.returncode == 6 and not observed['check_classified_retired'] and observed['preserved_unchanged_pointers'] == names and pruned.returncode != 0, 'Bucket symlink must be unresolved, never retired, and pruning must preserve every affected pointer'
except Exception as exc:
    log.write('SCENARIO FAILURE: ' + str(exc) + '\n')
    raise
finally:
    shutil.rmtree(lab)
    log.write('Removed isolated staged package, configuration and generated pointers.\n')
    log.close()
    (evidence / 'round4-symlinked-bucket-result.json').write_text(json.dumps(observed, indent=2) + '\n')
