# Live evidence: execution-receipt false alarm (fm/exec-receipt-false-alarm-v1)

All runs used a disposable lab home (`bin/fm-lab-home.sh create`), an isolated Herdr lab session
(`bin/fm-herdr-lab.sh` session `fm-lab-exec-receipt-8349-11269`, torn down afterwards with the default-session
tripwire intact), a scratch git project with a local bare origin, real `bin/fm-spawn.sh --backend herdr`, and
real `omp` workers (oh-my-pi, the machine's existing login). Every task was approved first with
`fm-task-execution.sh approve`.

| File | What it shows |
| --- | --- |
| `base-skip-started-transcript.txt` | Base commit 22fdb5a6. A busy worker that posted `working:` and `paused:` but did not run `started` stays `implementation owner unconfirmed` (the reported bug, reproduced live). |
| `base-delivered-execution-brief.md` | The base launch prompt, with a plain `echo >> status` recipe and a separate `started` appendix. |
| `base-skip-started-pane.txt` | That worker's Herdr pane during its simulated build: visibly busy. |
| `fixed-skip-started-transcript.txt` | Target commit 2de8ff2c. The same scenario reaches `phase=processing`, `state: working`, and `worker continue-implementation`. |
| `fixed-delivered-execution-brief.md` | The target launch prompt. Rules item 4 is now the receipt-bearing `fm-task-execution.sh status <id> <token> ...` command. |
| `fixed-skip-started-pane.txt` | The target worker's pane, busy during the simulated build. |
| `worker-executed-commands.txt` | The shell commands each worker actually ran, from omp's own transcript. Neither ran `started`. |
| `fixed-notify-transcript.txt` | Watcher `notify` pass: the fixed worker queues no `check: execution` wake. The base-launched worker and the genuinely failed Codex handoff still do. |
| `codex-delivered-execution-brief.md` | Recipe delivered to a codex spawn. That worker stopped at Codex's own folder-trust dialog and was quit, so its handoff was never processed and correctly stays unconfirmed. |
| `adversarial-recipe-transcript.txt` | The delivered recipe run against real spawned state. Primary checkout and subdirectory: the status line is kept, no receipt is recorded. Multi-line: refused. Worker root: confirms. Stale token after a new attempt: refused and nothing appended. |
| `promoted-ship-instructions.md`, `promoted-skip-started-transcript.txt`, `promoted-worker-executed-commands.txt` | An omp scout promoted in place via `fm-promote.sh` and steered via `fm-send.sh`. It reported only through the new status command, reached `processing`, `worker continue-implementation`, and queued no wake. |

## Earlier round's files

The `s1-*` through `s5-*` and `t-*` files come from the earlier test round of this run and were left untouched.
This round's README replaced that round's README.md. `worker-executed-commands.txt` was written by this round and
may have replaced a same-named file from the earlier round.
