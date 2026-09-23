---
name: browser-steps
description: Agent-only guidance for compact, act-and-verify browser steps. Load before driving a multi-step browser flow with chrome-devtools-axi.
user-invocable: false
metadata:
  internal: true
---

# browser-steps

Use `bin/fm-browser.sh step` to combine one browser action with a bounded expectation check.
Include an expectation whenever the action's effect must be confirmed; without one, the result is explicitly unverified. An expectation already satisfied before the action is also unverified, even if it remains satisfied afterward.
Read `bin/fm-browser.sh --help` for the current command grammar and output contract.
Choose a task-unique named session and never use the default session, auto-connect, a remote browser URL, or a persistent profile with this wrapper.
The wrapper returns only compact, redacted interactive labels and never returns a snapshot or field value.
Prefer the step result for verification and take a screenshot only when an expectation fails and visual evidence is needed.
