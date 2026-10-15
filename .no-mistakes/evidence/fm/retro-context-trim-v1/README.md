# Live context-trim evidence (claude 2.1.300, operator's normal login)

All sessions are real `claude -p` sessions; numbers come from Claude's own transcript
attachments (`skill_listing`, `instructions`) and the first assistant usage record.

## home-and-pipeline-probes.txt
Disposable clones of this repo at base e2704dba (`base`) and target a0149d7e (`home`).
- base-home: AGENTS.md 53,375 chars, instructions 62,560, skill listing 29,976, 52,957 first-request tokens.
- new-home-default (no launch settings, i.e. the main home): AGENTS.md 36,448, instructions 45,463, listing 29,996, 47,661 tokens.
- new-home-secondmate (exact settings fm_claude_worker_context secondmate emits): AGENTS.md still loaded,
  listing 8,603, 40,260 tokens; task-intake skill listed.
- pipeline-default (`--setting-sources user`, the no-mistakes shape): listing 29,974, 34,850 tokens.
- pipeline-budget (same plus the documented `--settings '{"env":{"SLASH_COMMAND_TOOL_CHAR_BUDGET":"8000"}}'`): listing 7,994, 27,314 tokens.

## task-intake-skill-invocation.txt
Real session in the target home under the 8000 budget invokes `Skill(task-intake)` and returns the body heading `# Task intake`,
so the intake rules moved out of AGENTS.md section 7 load on demand.

## claude-context-live-e2e.txt
`FM_CLAUDE_WORKER_CONTEXT_LIVE_E2E=1 bash tests/fm-claude-worker-context-live-e2e.test.sh` - six real probes
(supervisor, wide control, ship worker, secondmate, pipeline-wide, pipeline) all passed.
