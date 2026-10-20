"""Fault injection only: not a live-model or live-crew scenario."""
import json, os, pathlib, shutil, subprocess, tempfile, time
root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5DN3KN9FJ53VCC3H19YD5RQ')
lab = pathlib.Path(tempfile.mkdtemp(prefix='fm-probe-timeout.', dir=root / '.local-test-tmp'))
try:
    home = lab / 'home'
    (home / 'state').mkdir(parents=True)
    # Positive unfinished footprint prevents the retired-task shortcut.
    (home / 'state' / 'hung-task.meta').write_text('kind=scout\nproject=lab\n')
    probe = lab / 'hung-crew-state'
    probe.write_text('#!/usr/bin/env bash\nexec sleep 40\n')
    probe.chmod(0o755)
    env = os.environ.copy()
    for key in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE'):
        env.pop(key, None)
    env.update(FM_HOME=str(home), FM_CREW_STATE_BIN=str(probe))
    cmd = ['bin/fm-branch-outcome.sh', 'append', '--promote-finished', '--task', 'hung-task', '--verdict', 'routine', '--summary', 'Probe unavailable; still record this report']
    start = time.monotonic()
    p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=20)
    elapsed = time.monotonic() - start
    listing = subprocess.run(['bin/fm-branch-outcome.sh','lookup','--seqs','1'], env=env, capture_output=True, text=True, check=True)
    with open(evidence / 'probe-timeout.log', 'w') as log:
        log.write('Fault-injected crew-state executable blocks for 40 seconds (not live evidence).\n')
        log.write('$ ' + ' '.join(cmd) + f'\nexit={p.returncode}; elapsed={elapsed:.2f}s\n' + p.stdout + p.stderr)
        log.write('$ bin/fm-branch-outcome.sh lookup --seqs 1\n' + listing.stdout)
    assert p.returncode == 0 and 9 <= elapsed < 16, (p.returncode, elapsed, p.stderr)
    assert json.loads(listing.stdout)['verdict'] == 'routine'
finally:
    shutil.rmtree(lab)
