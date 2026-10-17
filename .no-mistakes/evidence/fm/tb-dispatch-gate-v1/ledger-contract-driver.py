import json, os, shutil, subprocess
from pathlib import Path
root = Path.cwd()
base = root / '.local-test' / 'ledger-proof'
state = base / 'state'
data = base / 'data'
evidence = Path('/Users/yelen/.no-mistakes/evidence/01M54YCVS0RQYVBAHB4CQ8TGKR/ledger-generated-contract.log')
state.mkdir(parents=True)
data.mkdir()
env = os.environ.copy()
env['NM_HOME'] = str(base / 'no-nm')
task = 'ledger-proof'
argv = ['python3', 'bin/fm-model-ledger.py', '--state', str(state), '--data', str(data), task]
def call():
    return subprocess.run(argv, env=env, text=True, capture_output=True, timeout=20)
try:
    (state / f'{task}.meta').write_text('kind=ship\nharness=claude\nmodel=claude-opus-5-5\neffort=medium\naccount=ordinary\nspawn_gen=s100.1.proof\nredispatches=2\npr_head=abc\nreport=PRIVATE-REPORT-PATH\n')
    (state / f'{task}.status').write_text('needs-decision [key=test]: PRIVATE-QUESTION\nblocked: PRIVATE-BLOCKER\ndone: PRIVATE-OUTCOME\n')
    (state / f'{task}.spend').write_text(json.dumps({'task':task,'status':'ok','totals':{'claudeEqTokens':150}}))
    (data / task).mkdir()
    (data / task / 'cross-review.jsonl').write_text('{"kind":"review","accepted":true,"head":"old","verdict":"failure"}\n{"kind":"review","accepted":true,"head":"abc","verdict":"success","report":"PRIVATE-REPORT-PATH"}\n')
    ledger = data / 'model-ledger.jsonl'
    ledger.mkdir()
    p = call()
    assert p.returncode == 1 and (state / f'{task}.meta').exists() and (state / f'{task}.status').exists()
    log = ['Synthetic persisted-input behavioral proof, not a real worker cleanup.', '$ ' + repr(argv), f'Write failure exit={p.returncode}', p.stderr, 'Metadata and status remain present.']
    ledger.rmdir()
    prefix = b'{"task":"previous","spawn_gen":"g1"}\n[1]\n\xffbad\n{"task":"unfinished"'
    ledger.write_bytes(prefix)
    p = call()
    assert p.returncode == 0, p.stderr
    content = ledger.read_bytes()
    assert content.startswith(prefix + b'\n')
    rows = []
    for line in content.splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict):
            rows.append(r)
    assert [r['task'] for r in rows] == ['previous', task], rows
    row = rows[-1]
    assert row['model'] == 'claude-opus-5-5' and row['effort'] == 'medium'
    assert row['final_state'] == 'done' and row['needs_decision_count'] == row['blocked_count'] == 1
    assert row['redispatches'] == 2 and row['claude_eq_tokens'] == 150 and row['cross_review_verdict'] == 'success'
    assert row['pipeline_review_rounds'] is None
    assert b'PRIVATE' not in content
    p = call()
    assert p.returncode == 0 and ledger.read_bytes() == content
    log += ['After fixing the output path and seeding a valid row, malformed/non-object rows, and an unterminated malformed tail:', 'Valid historical row retained, malformed bytes retained, next record separated by newline.', 'Generated minimal outcome:', json.dumps(row, indent=2), 'Second call exit=0; ledger bytes unchanged (idempotent).', 'Private status text and report metadata absent from the ledger.']
    evidence.write_text('\n'.join(log) + '\n')
    print('Minimal ledger generated output, malformed-tail recovery, write failure, and retry evidence saved (synthetic input; not live-worker evidence).')
finally:
    shutil.rmtree(base)
