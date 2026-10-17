import json, os, pathlib, shutil, subprocess, tempfile
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M553SQ300X5SAG5FSK2P04PP')
lab = pathlib.Path(tempfile.mkdtemp(prefix='fm-lab-token-', dir=ROOT / '.test-tmp'))
env = os.environ.copy()
for key in list(env):
    if (key.startswith('FM_') or key in ('TYPESAFE_API_KEY','OPENROUTER_API_KEY','CLAUDE_CONFIG_DIR','QUOTA_AXI_FIXTURE','TMUX','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_TAB_ID','HERDR_WORKSPACE_ID')):
        env.pop(key, None)
env.update(FM_HOME=str(lab), TMPDIR=str(ROOT / '.test-tmp'), FM_SPEND_SESSIONS=str(lab / 'no-sessions'), FM_SPEND_CLAUDE_SESSIONS=str(lab / 'no-sessions'), NM_HOME=str(lab / 'no-nm'))
log = []
def run(args, timeout=70):
    result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    log.extend(['$ ' + ' '.join(map(str, args)), 'exit=' + str(result.returncode), result.stdout, result.stderr])
    return result
try:
    assert run(['bin/fm-lab-home.sh','create',str(lab)]).returncode == 0
    (lab / 'config/supervision-host').touch()
    (lab / 'no-sessions').mkdir()
    (lab / 'no-nm').mkdir()
    (lab / 'config/crew-dispatch.json').write_text(json.dumps({'rules':[], 'default':{'harness':'claude','model':'claude-opus-5-5','effort':'medium'}}))
    (lab / 'custom-account').mkdir()
    (lab / 'config/claude-account').write_text(str(lab / 'custom-account') + '\n')
    (lab / 'brief.md').write_text('# Task\n\n## Captain\'s intent\nReport the configured launch profile without launching a worker.\n')
    result = run(['bin/fm-dispatch-resolve.sh',str(lab / 'brief.md')])
    assert result.returncode == 0, result.stderr
    assert 'quota and runway unknown' in result.stdout, result.stdout
    assert "--effort 'medium'" in result.stdout, result.stdout
    (lab / 'config/claude-account').unlink()
    task = 'token-review'
    (lab / 'data' / task).mkdir()
    (lab / 'state' / (task + '.meta')).write_text('kind=ship\nmode=direct-PR\nharness=codex\nmodel=gpt-6-astra\nbranch=fm/tb-dispatch-gate-v1\nproject=' + str(ROOT) + '\nworktree=' + str(ROOT) + '\n')
    result = run(['bin/fm-cross-review.sh','plan',task,'--head','bafe7598a9413e6a704d536674ed11e6ad7a970f'])
    assert result.returncode == 0, result.stderr
    assert 'reviewer_harness=claude' in result.stdout, result.stdout
    assert 'reviewer_effort=medium' in result.stdout, result.stdout
    plan = json.loads((lab / 'data' / task / 'cross-review-model.json').read_text())
    log.extend(['Persisted public reviewer plan:', json.dumps(plan, indent=2)])
    # No Herdr/session lifecycle or worker launch is attempted: this raw-command
    # refusal is evaluated before provisioning and requires no running backend.
    result = run(['bin/fm-spawn.sh','raw-opus-check',str(ROOT),'claude --model claude-opus-5-5 --effort high','--backend','tmux','--mode','local-only','--yolo','off'])
    assert result.returncode == 1, result.stdout + result.stderr
    assert 'raw launch commands naming claude-opus-5-5 are unsupported' in result.stderr, result.stdout + result.stderr
    assert not (lab / 'state/raw-opus-check.meta').exists()
    log.append('No raw-opus-check metadata was published.')
finally:
    shutil.rmtree(lab)
    log.append('Disposable CLI lab removed; no worker or session was created.')
    (EVIDENCE / 'live-cli-transcript.log').write_text('\n'.join(log))
