#!/usr/bin/env python3
"""Execute historical and current public scan interfaces on the reported regression."""
import os
from pathlib import Path
import subprocess
import tempfile
ROOT = Path('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5DCW6HK6A3DMX54XM7BNFSH')
OUT = Path('/Users/yelen/.no-mistakes/evidence/01M5DCW6HK6A3DMX54XM7BNFSH/negation-regression.log')
lines = []
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
cases = [
    ('no worries, run ! sudo darwin-rebuild switch', 1),
    ('No worries now run ! sudo darwin-rebuild switch', 1),
    ('Never hand the captain a `! sudo` line.', 0),
    ('Use pbcopy, not ! sudo.', 0),
]
with tempfile.TemporaryDirectory(prefix='.fm-negation-regression-', dir=ROOT) as tmp:
    directory = Path(tmp)
    historical = directory / 'fm-rule-guard.sh'
    historical.write_bytes(subprocess.check_output(['git', 'show', '95cfa17e:bin/fm-rule-guard.sh'], cwd=ROOT))
    for name in ('fm-primary-scope-lib.sh', 'fm-gate-refuse-lib.sh'):
        (directory / name).symlink_to(ROOT / 'bin' / name)
    versions = [('original 95cfa17e', historical), ('target b6754516', ROOT / 'bin/fm-rule-guard.sh')]
    original_misses = 0
    for label, script in versions:
        for text, expected in cases:
            p = subprocess.run(['bash', str(script), 'scan'], cwd=ROOT, env=env, input=text + '\n', text=True, capture_output=True, timeout=10)
            lines.append(f'{label}: bash {script} scan\nstdin: {text}\nexit: {p.returncode}\nstdout: {p.stdout.rstrip()}\nstderr: {p.stderr.rstrip()}\n')
            if label.startswith('target'):
                assert p.returncode == expected
            elif expected == 1 and p.returncode == 0:
                original_misses += 1
    assert original_misses == 2
    lines.append('The original executable missed both handovers; the target rejects both and preserves both genuine rule quotations.\n')
OUT.write_text('\n'.join(lines))
print(OUT.read_text())
