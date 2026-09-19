# Worker-launch integration evidence

Real fm-spawn.sh and selector executed with fixture Git repositories, simulated terminal/harness tools, and fixed Jev HTTP responses. No live model was contacted.


## codex-default

Published skill instructions:

```text
# Jev-selected skills
This launch selected the following installed skills.
Load them now, before doing the assigned work, using this runtime's skill form when it has one, otherwise by reading the installed skill file.
Do not search for extra skills this session.
- $codex-only: read `/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/codex-default/home/user-home/.codex/skills/codex-only/SKILL.md`

```

Captured Jev request:

```json
{
  "model": "jev-latest",
  "state": "harness: codex\ntask_id: t-codex-default\nsummary: Find pager skills\ninstalled_skills: codex-only, pager, review",
  "questions": {
    "skill": {
      "type": "choice",
      "instructions": "Once for this worker session, pick the single most useful installed skill to load. Prefer none when the brief is enough. Prefer search_external only when a missing skill would materially help.",
      "criteria": {
        "codex-only": "Installed skill codex-only",
        "pager": "Installed skill pager",
        "review": "Installed skill review",
        "none": "Load no extra skill this session.",
        "search_external": "A useful skill is missing from the installed list."
      }
    }
  }
}
```

Persisted selector record:

```json
{
  "version": 1,
  "task_id": "t-codex-default",
  "harness": "codex",
  "summary": "Find pager skills",
  "mode": "live",
  "status": "clear",
  "primary": "codex-only",
  "skills": [
    "codex-only"
  ],
  "confidence": 0.95,
  "probabilities": {
    "codex-only": 0.95,
    "none": 0.05
  },
  "floor": 0.7,
  "max": 3,
  "catalog_truncated": false,
  "live_loaded": true,
  "once": true,
  "reused": false,
  "reason": ""
}

```

Terminal launch payload:

```text
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI codex --dangerously-bypass-approvals-and-sandbox --disable hooks -c "notify=[\"bash\",\"-c\",\"touch '/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/codex-default/home/state/t-codex-default.turn-ended'\"]" "$('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/bin/fm-operational-input.sh' encode launch-brief < '/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/codex-default/home/data/t-codex-default/launch-brief.md')"

```


## codex-other-harness

Published skill instructions:

```text
No Jev-selected skill section.
```

Captured Jev request:

```json
{
  "model": "jev-latest",
  "state": "harness: grok\ntask_id: t-codex-other-harness\nsummary: Find pager skills\ninstalled_skills: pager, review",
  "questions": {
    "skill": {
      "type": "choice",
      "instructions": "Once for this worker session, pick the single most useful installed skill to load. Prefer none when the brief is enough. Prefer search_external only when a missing skill would materially help.",
      "criteria": {
        "pager": "Installed skill pager",
        "review": "Installed skill review",
        "none": "Load no extra skill this session.",
        "search_external": "A useful skill is missing from the installed list."
      }
    }
  }
}
```

Persisted selector record:

```json
{
  "version": 1,
  "task_id": "t-codex-other-harness",
  "harness": "grok",
  "summary": "Find pager skills",
  "mode": "live",
  "status": "clear",
  "primary": "none",
  "skills": [],
  "confidence": 0.91,
  "probabilities": {
    "pager": 0.05,
    "none": 0.9,
    "search_external": 0.05
  },
  "floor": 0.7,
  "max": 3,
  "catalog_truncated": false,
  "live_loaded": false,
  "once": true,
  "reused": false,
  "reason": ""
}

```

Terminal launch payload:

```text
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI grok --always-approve "$('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/bin/fm-operational-input.sh' encode launch-brief < '/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/codex-other-harness/home/data/t-codex-other-harness/launch-brief.md')"

```


## codex-override

Published skill instructions:

```text
# Jev-selected skills
This launch selected the following installed skills.
Load them now, before doing the assigned work, using this runtime's skill form when it has one, otherwise by reading the installed skill file.
Do not search for extra skills this session.
- $codex-only: read `/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/codex-override/home/custom-codex/skills/codex-only/SKILL.md`

```

Captured Jev request:

```json
{
  "model": "jev-latest",
  "state": "harness: codex\ntask_id: t-codex-override\nsummary: Find pager skills\ninstalled_skills: codex-only, pager, review",
  "questions": {
    "skill": {
      "type": "choice",
      "instructions": "Once for this worker session, pick the single most useful installed skill to load. Prefer none when the brief is enough. Prefer search_external only when a missing skill would materially help.",
      "criteria": {
        "codex-only": "Installed skill codex-only",
        "pager": "Installed skill pager",
        "review": "Installed skill review",
        "none": "Load no extra skill this session.",
        "search_external": "A useful skill is missing from the installed list."
      }
    }
  }
}
```

Persisted selector record:

```json
{
  "version": 1,
  "task_id": "t-codex-override",
  "harness": "codex",
  "summary": "Find pager skills",
  "mode": "live",
  "status": "clear",
  "primary": "codex-only",
  "skills": [
    "codex-only"
  ],
  "confidence": 0.95,
  "probabilities": {
    "codex-only": 0.95,
    "none": 0.05
  },
  "floor": 0.7,
  "max": 3,
  "catalog_truncated": false,
  "live_loaded": true,
  "once": true,
  "reused": false,
  "reason": ""
}

```

Terminal launch payload:

```text
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI codex --dangerously-bypass-approvals-and-sandbox --disable hooks -c "notify=[\"bash\",\"-c\",\"touch '/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/codex-override/home/state/t-codex-override.turn-ended'\"]" "$('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/bin/fm-operational-input.sh' encode launch-brief < '/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/codex-override/home/data/t-codex-override/launch-brief.md')"

```


## disabled

Published skill instructions:

```text
No Jev-selected skill section.
```

Captured Jev request:

```json
No HTTP request was made.
```

Terminal launch payload:

```text
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI grok --always-approve "$('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/bin/fm-operational-input.sh' encode launch-brief < '/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/disabled/home/data/t-disabled/launch-brief.md')"

```


## jev-fail

Published skill instructions:

```text
No Jev-selected skill section.
```

Captured Jev request:

```json
{
  "model": "jev-latest",
  "state": "harness: grok\ntask_id: t-jev-fail\nsummary: Find pager skills\ninstalled_skills: pager, review",
  "questions": {
    "skill": {
      "type": "choice",
      "instructions": "Once for this worker session, pick the single most useful installed skill to load. Prefer none when the brief is enough. Prefer search_external only when a missing skill would materially help.",
      "criteria": {
        "pager": "Installed skill pager",
        "review": "Installed skill review",
        "none": "Load no extra skill this session.",
        "search_external": "A useful skill is missing from the installed list."
      }
    }
  }
}
```

Persisted selector record:

```json
{
  "version": 1,
  "task_id": "t-jev-fail",
  "harness": "grok",
  "summary": "Find pager skills",
  "mode": "live",
  "status": "error",
  "primary": null,
  "skills": [],
  "confidence": 0,
  "probabilities": {},
  "floor": 0.7,
  "max": 3,
  "catalog_truncated": false,
  "live_loaded": false,
  "once": true,
  "reused": false,
  "reason": "jev: http 000 after 175 ms:"
}

```

Terminal launch payload:

```text
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI grok --always-approve "$('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/bin/fm-operational-input.sh' encode launch-brief < '/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/jev-fail/home/data/t-jev-fail/launch-brief.md')"

```


## live-load

Published skill instructions:

```text
# Jev-selected skills
This launch selected the following installed skills.
Load them now, before doing the assigned work, using this runtime's skill form when it has one, otherwise by reading the installed skill file.
Do not search for extra skills this session.
- /pager: read `/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/live-load/wt/.agents/skills/pager/SKILL.md`
- /review: read `/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/live-load/wt/.agents/skills/review/SKILL.md`

```

Captured Jev request:

```json
{
  "model": "jev-latest",
  "state": "harness: grok\ntask_id: t-live-load\nsummary: Find pager skills\ninstalled_skills: pager, review",
  "questions": {
    "skill": {
      "type": "choice",
      "instructions": "Once for this worker session, pick the single most useful installed skill to load. Prefer none when the brief is enough. Prefer search_external only when a missing skill would materially help.",
      "criteria": {
        "pager": "Installed skill pager",
        "review": "Installed skill review",
        "none": "Load no extra skill this session.",
        "search_external": "A useful skill is missing from the installed list."
      }
    }
  }
}
```

Persisted selector record:

```json
{
  "version": 1,
  "task_id": "t-live-load",
  "harness": "grok",
  "summary": "Find pager skills",
  "mode": "live",
  "status": "clear",
  "primary": "pager",
  "skills": [
    "pager",
    "review"
  ],
  "confidence": 0.82,
  "probabilities": {
    "pager": 0.8,
    "review": 0.1,
    "none": 0.05,
    "search_external": 0.05
  },
  "floor": 0.7,
  "max": 3,
  "catalog_truncated": false,
  "live_loaded": true,
  "once": true,
  "reused": false,
  "reason": ""
}

```

Terminal launch payload:

```text
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI grok --always-approve "$('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/bin/fm-operational-input.sh' encode launch-brief < '/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/live-load/home/data/t-live-load/launch-brief.md')"

```


## none

Published skill instructions:

```text
No Jev-selected skill section.
```

Captured Jev request:

```json
{
  "model": "jev-latest",
  "state": "harness: grok\ntask_id: t-none\nsummary: Find pager skills\ninstalled_skills: pager, review",
  "questions": {
    "skill": {
      "type": "choice",
      "instructions": "Once for this worker session, pick the single most useful installed skill to load. Prefer none when the brief is enough. Prefer search_external only when a missing skill would materially help.",
      "criteria": {
        "pager": "Installed skill pager",
        "review": "Installed skill review",
        "none": "Load no extra skill this session.",
        "search_external": "A useful skill is missing from the installed list."
      }
    }
  }
}
```

Persisted selector record:

```json
{
  "version": 1,
  "task_id": "t-none",
  "harness": "grok",
  "summary": "Find pager skills",
  "mode": "live",
  "status": "clear",
  "primary": "none",
  "skills": [],
  "confidence": 0.91,
  "probabilities": {
    "pager": 0.05,
    "none": 0.9,
    "search_external": 0.05
  },
  "floor": 0.7,
  "max": 3,
  "catalog_truncated": false,
  "live_loaded": false,
  "once": true,
  "reused": false,
  "reason": ""
}

```

Terminal launch payload:

```text
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI grok --always-approve "$('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/bin/fm-operational-input.sh' encode launch-brief < '/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/none/home/data/t-none/launch-brief.md')"

```


## query-blank

Published skill instructions:

```text
No Jev-selected skill section.
```

Captured Jev request:

```json
No HTTP request was made.
```

Terminal launch payload:

```text
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI grok --always-approve "$('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/bin/fm-operational-input.sh' encode launch-brief < '/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/query-blank/home/data/t-query-blank/launch-brief.md')"

```


## query-legacy

Published skill instructions:

```text
No Jev-selected skill section.
```

Captured Jev request:

```json
No HTTP request was made.
```

Terminal launch payload:

```text
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI grok --always-approve "$('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/bin/fm-operational-input.sh' encode launch-brief < '/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/query-legacy/home/data/t-query-legacy/launch-brief.md')"

```


## query-legacy-direct

Published skill instructions:

```text
No Jev-selected skill section.
```

Captured Jev request:

```json
No HTTP request was made.
```

Terminal launch payload:

```text
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI grok --always-approve "$('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/bin/fm-operational-input.sh' encode launch-brief < '/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/query-legacy-direct/home/data/t-query-legacy-direct/launch-brief.md')"

```


## query-legacy-scout

Published skill instructions:

```text
No Jev-selected skill section.
```

Captured Jev request:

```json
No HTTP request was made.
```

Terminal launch payload:

```text
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI grok --always-approve "$('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/bin/fm-operational-input.sh' encode launch-brief < '/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/query-legacy-scout/home/data/t-query-legacy-scout/launch-brief.md')"

```


## query-modern

Published skill instructions:

```text
No Jev-selected skill section.
```

Captured Jev request:

```json
No HTTP request was made.
```

Terminal launch payload:

```text
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI grok --always-approve "$('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/bin/fm-operational-input.sh' encode launch-brief < '/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2X0PDAH0885228RX64SA7ZA/.test-jev-tmp/fm-spawn-jev-skill-live.9RtRhm/query-modern/home/data/t-query-modern/launch-brief.md')"

```
