#!/usr/bin/env bash
# Opt-in native Claude guard for the worker context overlay. Submits two
# no-tool prompts in a temporary repository (not a fleet home or pooled copy).
# Checks transcript instruction paths, preserved global instructions and skill
# names, reduced listing bytes, and first-request input including cache tokens.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CLAUDE_WORKER_CONTEXT_LIVE_E2E claude jq python3 git
# shellcheck source=bin/fm-claude-worker-context-lib.sh
. "$ROOT/bin/fm-claude-worker-context-lib.sh"
VERSION=$(claude --version)
LAB=$(fm_test_tmproot fm-claude-worker-context-live)
trap 'rm -rf "$LAB"' EXIT
CODE="$LAB/code"
WT="$LAB/work"
mkdir -p "$CODE"
git -C "$CODE" init -q
# Copy only the immutable supervisor instructions to a private fixture.
cp "$ROOT/AGENTS.md" "$ROOT/CLAUDE.md" "$CODE/"
git -C "$CODE" add AGENTS.md CLAUDE.md
git -C "$CODE" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
git clone -q "$CODE" "$WT"
git -C "$CODE" remote add origin "$CODE"
# Synthetic project skills make budget overflow provable on any operator home.
python3 - "$WT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1]) / '.claude/skills'
for i in range(100):
    p = root / f'floor-probe-{i:03d}'
    p.mkdir(parents=True)
    (p / 'SKILL.md').write_text(f'---\nname: floor-probe-{i:03d}\ndescription: ' +
        'A synthetic context probe description for testing the skill listing budget. ' * 8 +
        '\n---\nDo not invoke this test skill.\n')
PY
for mode in supervisor worker; do
  settings='{}'
  [ "$mode" != worker ] || settings=$(fm_claude_worker_context ship "$WT" "$CODE" "$CODE")
  (
    cd "$WT"
    env -u CLAUDECODE claude -p --permission-mode dontAsk --effort low \
      --settings "$settings" --max-turns 1 --output-format stream-json --verbose \
      --append-system-prompt 'Context probe only. Do not use tools, write files, or start supervision.' \
      'Reply with exactly FLOOR_PROBE_OK. Do not use any tools.' > "$LAB/$mode.jsonl"
  ) || fail "claude $VERSION: $mode context probe failed"
done
python3 - "$LAB" "$WT" "$VERSION" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" <<'PY'
import json, pathlib, re, sys
lab, wt, version, config = sys.argv[1:]
def read(mode):
    stream = [json.loads(s) for s in (pathlib.Path(lab) / (mode + '.jsonl')).read_text().splitlines()]
    result = next(d for d in stream if d.get('type') == 'result')
    assert not result.get('is_error'), result
    assert result.get('num_turns') == 1, result
    sid = result['session_id']
    project = re.sub(r'[^A-Za-z0-9]', '-', wt)
    transcript = pathlib.Path(config) / 'projects' / project / (sid + '.jsonl')
    records = [json.loads(s) for s in transcript.read_text().splitlines()]
    attachments = [d['attachment'] for d in records if d.get('type') == 'attachment']
    instructions = next(a for a in attachments if a.get('type') == 'instructions')
    listing = next(a for a in attachments if a.get('type') == 'skill_listing')
    u = next(d['message']['usage'] for d in records if d.get('type') == 'assistant')
    tokens = sum(u.get(k, 0) for k in ('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens'))
    return instructions, listing, tokens
try:
    before, bs, bt = read('supervisor')
    after, als, at = read('worker')
    # Native transcript records are evidence, not an estimate from file sizes.
    before_text, after_text = json.dumps(before), json.dumps(after)
    assert wt + '/AGENTS.md' in before_text, 'supervisor AGENTS.md not loaded'
    assert wt + '/AGENTS.md' not in after_text, 'worker supervisor AGENTS.md still loaded'
    assert wt + '/CLAUDE.md' not in after_text, 'worker root pointer still loaded'
    assert len(als['content']) < len(bs['content']), 'skill listing was not narrowed'
    assert all(f'floor-probe-{i:03d}' in als['content'] for i in range(100)), 'skill names lost'
    assert at < bt, 'worker first-request input was not reduced'
    # Every non-fixture instruction loaded before must still load afterwards.
    for file in before['files']:
        if wt not in json.dumps(file):
            assert file in after['files'], 'unrelated instruction changed'
    print(f'ok - claude {version}: supervisor instructions retained; worker excludes only root files; skill names retained')
    print(f'# first-request transcript input: before={bt} after={at} saved={bt-at}')
except Exception as e:
    raise SystemExit(f'not ok - claude {version}: {e}')
PY
