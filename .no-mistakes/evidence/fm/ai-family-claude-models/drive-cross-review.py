#!/usr/bin/env python3
"""Drive the real collection/status CLI with disposable review input records.
No agent, catalog, network, or product executables are mocked. Reports are
synthetic collector inputs, not claims that a model actually reviewed code.
"""
import json, os, pathlib, shutil, subprocess, tempfile
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/Users/marcocadornini/.no-mistakes/evidence/01M43MVJN49FK05RPFGR073HCV')
BASE = 'f0bf94d9791e13ec6aa9bb8b49d474536f95ec91'
HEAD = 'f1646332e6b26f6a043866ac095f1a6da8c8f3ff'
logs, results = [], []
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'NM_', 'NO_MISTAKES', 'TASKS_AXI'))}

def run(args, home):
    e = dict(env, FM_HOME=str(home))
    p = subprocess.run(args, cwd=ROOT, env=e, text=True, capture_output=True, timeout=30)
    logs.append('$ ' + ' '.join(map(str,args)) + '\n' + p.stdout + p.stderr)
    if p.returncode: raise RuntimeError(f'{args}: exit {p.returncode}')
    return p.stdout

try:
    with tempfile.TemporaryDirectory(prefix='.cross-review-live-', dir=ROOT) as temp:
        tmp = pathlib.Path(temp)
        basebin = tmp/'baseline-bin'
        shutil.copytree(ROOT/'bin', basebin)
        (basebin/'fm-ai-family-lib.sh').write_bytes(subprocess.check_output(['git','show',f'{BASE}:bin/fm-ai-family-lib.sh']))
        def case(name, model, expected_family, accepted, builder='openai', harness='claude', wrong_head=False, baseline=False):
            home=tmp/name
            for d in ['state', 'config', 'data/task', 'data/reviewer']:
                (home/d).mkdir(parents=True, exist_ok=True)
            (home/'state/task.meta').write_text(f'harness=codex\nmodel=gpt-6-luna\nmode=direct-PR\nai_family={builder}\nai_family_source=disposable builder input\n')
            # Omit ai_family to exercise the collector's actual resolver boundary.
            (home/'state/reviewer.meta').write_text(f'harness={harness}\nmodel={model}\n')
            (home/'data/reviewer/cross-review-request').write_text(f'task=task\nhead={HEAD}\nkind=review\n')
            declared=BASE if wrong_head else HEAD
            (home/'data/reviewer/report.md').write_text(f'# Disposable collector input\n\nreviewed head {declared}\n\nVerdict: PASS\n')
            script=(basebin if baseline else ROOT/'bin')/'fm-cross-review.sh'
            logs.append(f'\n=== {name}: harness={harness}, model={model}, builder={builder} ===\n')
            run(['bash',str(script),'collect','task','reviewer'],home)
            record=json.loads((home/'data/task/cross-review.jsonl').read_text())
            logs.append('Persisted cross-review.jsonl:\n'+json.dumps(record,indent=2)+'\n')
            assert record['family']==expected_family, record
            assert record['accepted']==accepted, record
            state=json.loads(run(['bash',str(script),'status','task','--head',HEAD,'--json'],home))
            if accepted:
                assert state['independent_review']['family']==expected_family, state
                assert state['independent_review']['head']==HEAD, state
                assert state['independent_review']['verdict']=='success', state
            else:
                assert isinstance(state['independent_review'],str) and state['independent_review'].startswith('MISSING:'), state
            results.append(dict(name=name,model=model,harness=harness,baseline=baseline,record=record,status=state))
        for m in ['claude-opus-5-5','claude-sonnet-5-5']:
            case('baseline-'+m,m,'unknown',False,baseline=True)
            case('accept-'+m,m,'anthropic',True)
        for m in ['claude-haiku-4-5-20251001','claude-fable-5-1','opus','sonnet','haiku','fable','default']:
            case('accept-'+m,m,'anthropic',True)
        for i,m in enumerate(['gpt-6-luna','anthropic/claude-opus-5-5','claude-not-a-model','claude-opus-','claude-opus-5-other','']):
            case('unknown-'+str(i),m,'unknown',False)
        case('wrong-harness','claude-opus-5-5','unknown',False,harness='cursor')
        case('same-family','claude-opus-5-5','anthropic',False,builder='anthropic')
        case('overlapping-builder-set','claude-sonnet-5-5','anthropic',False,builder='anthropic,openai')
        case('unknown-builder','claude-opus-5-5','anthropic',False,builder='unknown')
        case('wrong-head','claude-opus-5-5','anthropic',False,wrong_head=True)
finally:
    (EVIDENCE/'cross-review-cli-transcript.txt').write_text('Real Firstmate CLI; disposable input records only. No real worker launch or historical record migration.\n'+ '\n'.join(logs))
    (EVIDENCE/'cross-review-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(f'Completed {len(results)} CLI cases; disposable homes and baseline copy removed.')
