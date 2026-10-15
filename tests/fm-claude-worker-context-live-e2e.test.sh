#!/usr/bin/env bash
# Opt-in native Claude guard for the launch context overlay. Submits six
# no-tool prompts in a temporary repository (not a fleet home or pooled copy).
# Checks transcript instruction paths for supervisor, ship-worker, and secondmate
# launches, preserved global instructions and skill names, listing bytes narrowed
# against a wide-budget control (including the no-mistakes pipeline argv shape),
# and first-request input including cache tokens.
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
PLUGIN="$LAB/plugin"
mkdir -p "$CODE"
git -C "$CODE" init -q
# Copy only the immutable supervisor instructions to a private fixture.
cp "$ROOT/AGENTS.md" "$ROOT/CLAUDE.md" "$CODE/"
git -C "$CODE" add AGENTS.md CLAUDE.md
git -C "$CODE" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
git clone -q "$CODE" "$WT"
git -C "$CODE" remote add origin "$CODE"
# Synthetic skills make budget overflow provable on any operator home: project
# skills reach default-source launches, and a session plugin carries the same
# probes into the pipeline's user-only setting sources.
python3 - "$WT/.claude/skills" "$PLUGIN" <<'PY'
import json, pathlib, sys
project, plugin = map(pathlib.Path, sys.argv[1:])
(plugin / '.claude-plugin').mkdir(parents=True)
(plugin / '.claude-plugin/plugin.json').write_text(json.dumps({'name': 'fmprobe', 'version': '0.0.1', 'description': 'context probe'}))
for root in (project, plugin / 'skills'):
    for i in range(100):
        p = root / f'floor-probe-{i:03d}'
        p.mkdir(parents=True)
        (p / 'SKILL.md').write_text(f'---\nname: floor-probe-{i:03d}\ndescription: ' +
            'A synthetic context probe description for testing the skill listing budget. ' * 8 +
            '\n---\nDo not invoke this test skill.\n')
PY
WIDE='{"env":{"SLASH_COMMAND_TOOL_CHAR_BUDGET":"200000"}}'
BUDGET=$(fm_claude_skill_budget_settings)
# <mode> <settings> [extra claude flags...]; pipeline modes mirror the no-mistakes
# argv: --setting-sources user plus agent_args_override's --settings pair.
probe() {
  local mode=$1 settings=$2
  shift 2
  (
    cd "$WT"
    env -u CLAUDECODE claude -p --permission-mode dontAsk --effort low "$@" \
      --settings "$settings" --max-turns 1 --output-format stream-json --verbose \
      --append-system-prompt 'Context probe only. Do not use tools, write files, or start supervision.' \
      'Reply with exactly FLOOR_PROBE_OK. Do not use any tools.' > "$LAB/$mode.jsonl"
  ) || fail "claude $VERSION: $mode context probe failed"
}
probe supervisor '{}'
probe wide "$WIDE"
probe worker "$(fm_claude_worker_context ship "$WT" "$CODE" "$CODE")"
probe secondmate "$(fm_claude_worker_context secondmate "$WT" "$CODE" "$CODE")"
probe pipeline-wide "$WIDE" --setting-sources user --plugin-dir "$PLUGIN"
probe pipeline "$BUDGET" --setting-sources user --plugin-dir "$PLUGIN"
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
    # Native transcript records are evidence, not an estimate from file sizes.
    records = [json.loads(s) for s in transcript.read_text().splitlines()]
    attachments = [d['attachment'] for d in records if d.get('type') == 'attachment']
    instructions = next((a for a in attachments if a.get('type') == 'instructions'), None)
    listing = next(a for a in attachments if a.get('type') == 'skill_listing')['content']
    u = next(d['message']['usage'] for d in records if d.get('type') == 'assistant')
    tokens = sum(u.get(k, 0) for k in ('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens'))
    return json.dumps(instructions), listing, tokens
def names(listing, prefix=''):
    return all(f'{prefix}floor-probe-{i:03d}' in listing for i in range(100))
try:
    s_ins, s_list, s_tok = read('supervisor')
    _, w_list, _ = read('wide')
    k_ins, k_list, k_tok = read('worker')
    m_ins, m_list, _ = read('secondmate')
    _, pw_list, _ = read('pipeline-wide')
    _, p_list, _ = read('pipeline')
    assert wt + '/AGENTS.md' in s_ins, 'supervisor AGENTS.md not loaded'
    assert wt + '/AGENTS.md' not in k_ins, 'worker supervisor AGENTS.md still loaded'
    assert wt + '/CLAUDE.md' not in k_ins, 'worker root pointer still loaded'
    assert wt + '/AGENTS.md' in m_ins, 'secondmate lost its supervisor AGENTS.md'
    assert m_ins == s_ins, 'secondmate instructions differ from the supervisor default'
    # Every non-fixture instruction loaded before must still load afterwards.
    for file in json.loads(s_ins)['files']:
        if wt not in json.dumps(file):
            assert file in json.loads(k_ins)['files'], 'unrelated instruction changed'
    # The wide controls prove the probes overflow the budget, so a narrowed
    # listing is the budget's effect rather than a listing that already fit.
    assert len(k_list) < len(w_list) and len(m_list) < len(w_list), 'worker or secondmate skill listing was not narrowed'
    assert len(p_list) < len(pw_list), 'pipeline skill listing was not narrowed'
    assert names(w_list) and names(k_list) and names(m_list), 'project skill names lost'
    assert names(pw_list, 'fmprobe:') and names(p_list, 'fmprobe:'), 'pipeline plugin skill names lost'
    assert k_tok < s_tok, 'worker first-request input was not reduced'
    print(f'ok - claude {version}: supervisor and secondmate instructions retained; worker excludes only root files; '
          'worker, secondmate, and user-sources pipeline listings narrowed; skill names retained')
    print(f'# skill listing chars: wide={len(w_list)} supervisor={len(s_list)} worker={len(k_list)} '
          f'secondmate={len(m_list)} pipeline-wide={len(pw_list)} pipeline={len(p_list)}')
    print(f'# first-request transcript input: supervisor={s_tok} worker={k_tok} saved={s_tok-k_tok}')
except Exception as e:
    raise SystemExit(f'not ok - claude {version}: {e}')
PY
