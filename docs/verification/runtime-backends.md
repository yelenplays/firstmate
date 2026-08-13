# Runtime backend verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for active runtime guarantees.
The backend guides own current setup, safety boundaries, and limitations.
Exact task chronology, branch names, temporary homes, local paths, process ids, thread ids, and delivery transcripts remain in private reports or PR evidence.

## tmux

Foreground-process behavior was verified on 2026-07-07 with tmux 3.6a on macOS.

```sh
tmux new-session -d -s fmtest -n testwin
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
tmux send-keys -t fmtest:testwin 'sleep 30' Enter
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
tmux send-keys -t fmtest:testwin C-c
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
```

Observed output:

```text
zsh
sleep
zsh
```

A persistent parent shell waiting for a child remained reported as the parent process, while a shell that directly execed a simple command changed identity with the process itself.
Pi and pi-signed 0.82.0 were reverified on 2026-07-27 through real isolated `fm-spawn.sh` launches.

### Agent liveness name sources

The earlier record that every harness is observed under its own `#{pane_current_command}` no longer holds and has been replaced by the per-harness evidence below.
In this macOS run that reading reflected a rewritable process title rather than stable executable identity, so it is now one of two independent name sources rather than the sole basis of a verdict.

The seven primary-capable adapters were relaunched on 2026-08-03 with tmux 3.6a on macOS 26.5.2 arm64, each on a private socket in an isolated lab.

```sh
tmux -L "$socket" new-window -d -t "$session:" -n "$harness" -c "$wt" -- "$bin"
tmux -L "$socket" display-message -p -t "$session:$harness" '#{pane_current_command}'
ps -t "${tty#/dev/}" -o pgid=,tpgid=,comm=      # rows where pgid = tpgid
```

Observed identities, and the resulting verdict:

| Harness | Version | `#{pane_current_command}` | Foreground `comm` | Verdict |
| --- | --- | --- | --- | --- |
| claude | 2.1.220 | `2.1.220` | `claude` | alive |
| codex | codex-cli 0.146.0 | `codex` | `codex` | alive |
| opencode | 1.18.11 | `opencode` | `opencode` | alive |
| pi | 0.82.0 | `pi-launcher` | `pi-signed`, `pi` | alive |
| pi-signed | 0.82.0 | `pi-launcher` | `pi-signed`, `pi` | alive |
| grok | 0.2.118 | `grok-0.2.118-ma` | `grok` | alive |
| kimi | 0.31.1 | `kimi` | `kimi` | alive |

Claude Code is the harness whose title no longer attributes it at all; every other adapter is currently attributed by both sources.
Codex reported `codex-aarch64-a` at 0.145.0 and `codex` at 0.146.0, and Kimi Code reported `kimi-code` as its foreground `comm` at 0.29.1 and `kimi` at 0.31.1, so these identities move between ordinary patch releases in both directions.
That is the evidence for treating any single process name as a surface under vendor control rather than a stable contract.

The crewmate-only Muse Code 0.1.0-R708.1 adapter was verified separately on 2026-08-05 against tmux on macOS arm64.
Its installed `muse-bin-0.1.0-R708.1` foreground identity classified `alive`, while `musescore`, `amuse`, `muse-binary`, and `muse-bind` remained ambiguous in the portable regression.
[`muse.md`](muse.md#process-identity) owns the artifact identity and launcher evidence for that verification.

Bounded observed output:

```text
foreground comms:
  zsh
  .../instbin/muse-bin-0.1.0-R708.1
classify each:
  zsh                            -> shell
  muse-bin-0.1.0-R708.1          -> agent
fm_backend_agent_state tmux museliv:zsh
alive
```

`#{pane_current_command}` and foreground `ps -o comm=` read different name fields, but which one preserves executable identity is platform-dependent.
On macOS the pane command reflected the rewritable title while the full install path could survive in `ps -o comm=`; in the Linux portable regression those roles reversed for the version-named native executable, with the identifying path retained in argv[0].
The classifier therefore accepts a harness basename first, then an exact harness path component in the full executable path, then the same component in argv[0], without depending on which field carries it on a given platform.

The portable regression is CI-enforced, while the real-harness drift guard is opt-in under the policy in `.agents/skills/firstmate-coding-guidelines/SKILL.md`.
Run the live guard after any harness upgrade and before trusting or refreshing the table above:

```sh
FM_HARNESS_LIVENESS_DRIFT=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh
```

Bounded output from the run that produced the table:

```text
ok - harness liveness: claude 2.1.220 (Claude Code) classifies alive
# claude 2.1.220 (Claude Code): title='2.1.220' foreground=[claude ]
# checked 7 installed harness(es)
```

Installed-wrapper checks:

```sh
basename "$(command -v pi-signed)"
pi-signed --version
pi --version
```

Observed bounded output:

```text
pi-signed
0.82.0
0.82.0
```

The isolated process and endpoint checks used:

```sh
tmux display-message -p -t "$target" '#{pane_current_command}'
ps -o comm= -p "$wrapper_pid"
ps -o comm= -p "$engine_pid"
FM_HOME="$fixture_home" bin/fm-crew-state.sh "$task_id"
```

Observed bounded shapes:

```text
pi-launcher
.../pi-signed
.../Pi Launcher.app/Contents/Resources/pi/pi
state: done ...
```

Both launches executed a submitted tool instruction and touched the generated `turn_end` marker.
The pi-signed launch retained `harness=pi-signed`, while the plain comparison retained `harness=pi`.
The exact wrapper ancestry was `pi-signed` parent to Pi engine child, and the plain Pi Launcher path also traversed the signed wrapper on this installation.
That shared plain-Pi path is retained as disconfirming evidence against using ancestry as runtime-selection authority.
Firstmate therefore sets the exact `FM_PI_HARNESS` selection marker on both worker launch paths, while an unmarked Pi-family process remains `pi`.
Both recorded runtime identities now classify the exact `pi-launcher` foreground command as `alive`.

Backend applicability was reviewed across every spawn adapter.
Tmux needs the exact `pi-launcher`, `pi-signed`, `pi`, and `Pi` process identities for recovery-grade liveness.
Herdr uses native registered-agent state and needs no process-name branch.
Zellij has no verified recovery-grade agent process probe, while Orca and cmux do not support secondmate spawns, so those three retain their existing generic ordinary-launch semantics without a new liveness matcher.

The structural multi-row composer reader, Kimi pointer-delivery path, and OpenCode 1.18.4 busy-queue behavior are pinned by:

```sh
tests/fm-composer-ghost.test.sh
tests/fm-kimi-harness.test.sh
tests/fm-tmux-submit-busy.test.sh
```

Expected structural matrix: real text on any content row is pending; all-empty complete boxes are empty; unreadable, incomplete, or unsafe boxes are unknown; and non-bordered panes retain cursor-row compatibility.
Expected submit matrix: proven pending plus busy is accepted as queued; proven pending plus idle remains pending; ambiguous pending is never converted by the busy exception; and only a proven empty composer succeeds directly.

### Cleanup endpoint identity

The cleanup identity boundary was validated on 2026-07-28 with tmux 3.6a and metadata fixtures for every supported backend.

```sh
tests/fm-teardown-endpoint-safety.test.sh
tests/fm-teardown.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-backend-zellij.test.sh
tests/fm-backend-orca.test.sh
tests/fm-backend-cmux.test.sh
```

Bounded output from the incident regression:

```text
ok - fm-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call
ok - cleanup identity: valid tmux, Herdr, Zellij, Orca, and cmux records validate while every empty backend target refuses
ok - tmux backend: direct empty target returns nonzero without invoking tmux
ok - process cleanup: creation-time PID identity removes only the exact child and preserves the control child
ok - fm-teardown: dedicated-socket invalid cleanup preserves target/control and valid cleanup removes only the exact target
```

The dedicated tmux cell removed ambient tmux variables, required a socket-bound wrapper, kept one target and one independent control window, and proved the wrapper was not called for invalid metadata or a direct empty target.
Valid cleanup removed only the exact task-bound target and left the control window live.
The metadata-only validation covers tmux, Herdr, Zellij, Orca, and cmux before backend dispatch.
Claude, Codex, OpenCode, Pi, pi-signed, Grok, Kimi, and Muse share that backend cleanup boundary; their harness-specific hook files, tokens, and session-log sidecars are cleaned only after it, so no harness needs a separate endpoint parser.

## Ordinary worker Megamind preflight routing

The launch-time binding matrix was verified on 2026-08-11 with the repository's current test fixtures and ShellCheck 0.11.0.

```sh
bin/fm-test-run.sh tests/fm-worker-preflight.test.sh tests/fm-brief.test.sh \
  tests/fm-control-relaunch.test.sh tests/fm-spawn-dispatch-profile.test.sh \
  tests/fm-kimi-harness.test.sh tests/fm-muse-harness.test.sh \
  tests/fm-grok-harness.test.sh tests/fm-task-delivery.test.sh \
  tests/fm-tangle-guard.test.sh
bin/fm-test-run.sh tests/fm-backend-autodetect-smoke.test.sh \
  tests/fm-backend-herdr-launcher-workspace-e2e.test.sh \
  tests/fm-backend-herdr-workspace-per-home-e2e.test.sh
```

Observed bounded output:

```text
FM_TEST_SUMMARY total=9 failed=0 skipped_gate=0
FM_TEST_SUMMARY total=3 failed=0 skipped_gate=0
```

The gate is one `fm-spawn.sh` step taken before endpoint creation, worktree provisioning, and task publication, so it is common to claude, codex, opencode, pi, pi-signed, grok, kimi, and muse for both ship and scout tasks, and to tmux, Herdr, Zellij, Orca, and cmux alike - no backend can reach its own endpoint sequence without it.
The backend suites therefore cover endpoint creation and command delivery rather than reimplementing the gate; `tests/fm-worker-preflight.test.sh` owns the binding, routing-request, outcome, refusal, proof-placement, private-result, validate-only, and isolated-copy matrix end to end, `tests/fm-control-relaunch.test.sh` owns the relaunch precondition that refuses before the running worker is touched, and the real-Herdr suites above prove the same step under a live runtime for a primary home and a secondmate-shaped home.
No supported worker-tool or spawn-backend axis is inapplicable to ordinary ship or scout preflight.
Secondmate launch itself is intentionally inapplicable because it starts a firstmate home rather than an ordinary worker; `tests/fm-worker-preflight.test.sh` pins that omission at the launch boundary, and a secondmate's own worker launch applies the same matrix from that home's own binding, as covered by `tests/fm-trace-context-spawn.test.sh` and `tests/fm-backend-herdr-workspace-per-home-e2e.test.sh`.

## Bounded Megamind content admission

The host-owned reader was verified on 2026-08-13 with stock macOS Bash, Python 3, and synthetic wiki roots only.
The portable suite covers no-follow root and component traversal, special files, hardlinks, strict UTF-8, Unicode code-point budgets, binding and root/card changes, concurrent admissions, private output, home isolation, same-day relaunch preservation with UTC-day rollover refusal, age-based pruning on the next admission, and an actual synthetic Megamind 0.6 selection continuation.
The preflight suite also covers the script-owned route relevance contract, which a ranked page must satisfy in both halves before it may replace an authorized declared index: a floor of 0.5 on Megamind's own per-candidate route confidence, and candidate-local evidence that the page's own index entry is what matched.
It covers the unrelated rebalancing-to-tax-page fallback under both card configurations and the same contract during explicit selection continuation, both asserting that the ladder was actually invoked, while retaining a positive above-floor page-ranking control and the fail-closed branches where a served field is left empty.

The contract is calibrated against the real 0.6.0 producer rather than assumed. For the question `Wie oft sollte ich ein Portfolio rebalancieren?` against a synthetic German finance wiki whose index lists two unrelated tax pages and one page that answers it, the producer reports:

| card field carrying `portfolio` | unrelated tax pages | answering page |
| --- | --- | --- |
| `description` (text signal) | 0.3571 | 0.7143 |
| `keywords` (full-strength trigger) | 0.6571 | 0.7143 |

Neither half alone holds the invariant.
A lexical-score cutoff cannot express it: a page candidate exists only when a wiki scored at all and one of its index entries scored at all, so the smallest score the producer can emit for a page is already 2 and no cutoff at that boundary refuses anything.
A confidence floor alone cannot express it either: the producer seeds each page's signal vector from the signals its whole wiki matched on, so a query token sitting in the card's own `keywords` pins every page of that wiki at or above 0.6 however weakly the page itself matched, and the remaining gap is carried entirely by the coverage term, which narrows as the question lengthens.
What separates the controls under both configurations is candidate-local: the answering page's own index entry matched by label and reads `index entry match:`, while each tax page was surfaced only by the spelling of its target path and reads `index path match:`.
Those two strings are produced by the index-entry pass alone, and have been spelled that way in every release long predating the oldest supported line.

The durable form of that half belongs upstream. The smallest producer change that would retire the prose match is a typed per-candidate entry-level field - an entry confidence or entry score derived only from the index-entry signals and never seeded from the wiki-level signal map.
Until a supported release emits one, the compatibility contract is fail-closed in both directions: a build that refuses the `reasons` field exits non-zero and the declared paths stand, and a build that serves it without the marker ranks no eligible page and the declared paths stand.
Neither direction widens privacy, access, path, candidate, character-budget, model-class, or digest-only boundaries, all of which are enforced ahead of this contract and unchanged by it.

```sh
bin/fm-test-run.sh tests/fm-megamind-preflight.test.sh \
  tests/fm-megamind-content.test.sh tests/fm-worker-preflight.test.sh
```

Observed bounded output on 2026-08-13:

```text
FM_TEST_SUMMARY total=3 failed=0 skipped_gate=0 duration_ms=67396
```

The real Megamind 0.6 synthetic-estate selection evidence above remains the upstream command compatibility proof, while `tests/fm-megamind-content.test.sh` proves that a script-issued `fm/megamind-preflight-selection/v1` authorization reaches the same reader boundary without touching a real wiki.
No primary interception or scheduling claim is made by this reader slice.

Every suite above drives a synthetic Megamind stub, which can only confirm the assumption already written into that stub, so `tests/fm-megamind-realshape.test.sh` is the guard that keeps it honest about the fields the reader accepts.
It builds its own synthetic estate, routes it through an installed `megamind-axi`, and requires the resulting authorization to survive the real host path end to end, asserting nothing about implementation source bytes.
It resolves the build in one order - an explicit `FM_MEGAMIND_REAL_EXE` override, then the active home's own `config/megamind-executable`, then `PATH` - so a pilot host that pins its proven build in config is actually guarded instead of skipped because `PATH` carries an older build or none at all; three checks prove that order and need no real binary.
It then asks `bin/fm-megamind-preflight.sh check` whether the resolved build is an accepted release, and skips loudly - naming the real routing-mode vocabulary and ladder descent as what stays unproven - rather than reporting a pass that checked nothing.
`bin/fm-test-run.sh` runs it in the optional-binary `megamind-realshape` family and selects it whenever the bounded reader changes.
The real-producer guard was run on 2026-08-13 with `FM_MEGAMIND_REAL_EXE` pinned to the host's proven Megamind 0.6.0 build:

```sh
FM_MEGAMIND_REAL_EXE=<proven Megamind 0.6.0 path> bin/fm-test-run.sh tests/fm-megamind-realshape.test.sh
```

Observed output was `FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=1089`.

## Primary Megamind prompt interception

The host-owned coordinator and the opt-in Claude and Pi primary adapters were added on 2026-08-12 and their explicit no-wiki disposition was verified on 2026-08-13; the Pi-only `Different existing wiki` path was added and verified on 2026-08-13.
The coordinator is `bin/fm-megamind-primary.sh`, and it is the sole semantic owner for classification, preflight, offer continuation, bounded admission, and context framing.
The Claude transport is `bin/fm-claude-primary-prompt.sh` on `UserPromptSubmit`.
The Pi and pi-signed transport is `.pi/extensions/fm-primary-megamind.ts` on Pi's `input` event with handled and replay semantics.
The implementation remains opt-in through `config/megamind-primary-automatic` or `FM_MEGAMIND_PRIMARY_AUTOMATIC=1` so ordinary sessions retain their prior behavior until the live guard is intentionally enabled.

Portable proof covers bypasses, no-match, privacy-filtered, matched bounded admission, prompt and root privacy, failed bindings, deterministic unsupported decisions, the prompt binding that keeps a reused submission id from replaying another prompt's decision, and the bypass an opted-out home returns even without `jq`.
It also proves one-offer Pi rendering with no initial selection, inert Enter before navigation, Escape cancellation, exact-once no-wiki replay, pending-offer retirement without authorization or admission, replay refusal, future-prompt independence, truthful unavailable proposals, and the governed existing-wiki list, bounded show-more interaction, no-initial-selection requirement, exact returned-name preservation, one-time authorization, bounded admission, and exact-once replay:

```sh
PATH="$(dirname "$(npx -y -p typescript which tsc)"):$PATH" bin/fm-test-run.sh tests/fm-megamind-primary.test.sh tests/fm-megamind-pi-offer.test.sh tests/fm-megamind-existing-selection.test.sh tests/fm-megamind-preflight.test.sh tests/fm-megamind-content.test.sh tests/fm-megamind-claude-control.test.sh tests/fm-pi-primary-types.test.sh
```

The 2026-08-13 portable run completed with `FM_TEST_SUMMARY total=7 failed=0 skipped_gate=0 duration_ms=45938`.
`tests/fm-megamind-existing-selection.test.sh` additionally proves that the list is producer-only, truncated facts control the deliberate full interaction, offered and withheld names are not invented or enumerated, explicit authorization reaches the bounded reader, and replay, catalog drift, malformed output, and producer refusal stop without fallback.
`tests/fm-megamind-claude-control.test.sh` drives the Claude transport over its real hook payload and proves that the offered-wiki and no-wiki controls an ambiguous result advertises are the exact controls the transport accepts, and that no approximation authorizes or declines a selection.
The control carries no leading slash because Claude resolves a leading-slash prompt as one of its own commands and answers `Unknown command` before any `UserPromptSubmit` hook runs; that reachability is not observable without the real CLI, so the live guard below round-trips the advertised control back through it.

The live guard uses only synthetic block prompts and a synthetic coordinator, so it proves the real installed transport reaches the host gate without making a provider call or reading a wiki:

```sh
FM_MEGAMIND_PRIMARY_LIVE=1 tests/fm-megamind-primary-live-e2e.test.sh
```

Observed on 2026-08-13 with Claude Code 2.1.220, Pi 0.84.1, Codex CLI 0.145.0, Grok 1.0.0, and Kimi Code 0.34.0:

```text
live: claude 2.1.220 (Claude Code) blocked before inference with zero provider turns
live: claude 2.1.220 (Claude Code) round-tripped the advertised offer control back through the hook
live: pi 0.84.1 blocked before inference with one governed coordinator submission
unsupported: codex codex-cli 0.145.0 automatic primary interception unproven; ordinary operation retained
absent: opencode
unsupported: grok grok 1.0.0 (3cd0d0cbcebe) [stable] automatic primary interception unproven; ordinary operation retained
unsupported: kimi 0.34.0 automatic primary interception unproven; ordinary operation retained
absent: pi-signed
ok - installed primary interception guards covered every detected harness
```

The live guard deliberately does not claim allow, context reinjection, offered-wiki continuation, existing-wiki continuation, or no-wiki continuation against a real provider until a future synthetic-provider proof can observe those surfaces without exposing credentials or wiki material.
Codex, OpenCode, Grok, and Kimi remain ordinary-operation-only for automatic primary interception because their installed prompt hook surfaces were not proven to stop inference and replay safely in this slice.
Grok is the one of those four that loads `.claude/settings.json` through its Claude-compatible settings support, so the tracked `UserPromptSubmit` entry carries the same `GROK_AGENT`/`GROK_HOOK_EVENT` inertness marker its siblings do; [`../turnend-guard.md`](../turnend-guard.md) owns that marker and `tests/fm-turnend-guard.test.sh` pins the entry inventory.
The Pi adapter is reused by pi-signed only when the exact signed identity marker is present, and the signed executable was absent during this verification.
Primary interception is harness-session behavior and has no tmux, Herdr, Zellij, Orca, or cmux-specific semantic path.
Secondmate Pi launches load the same adapter from the secondmate home, while each home retains its own coordinator state and Megamind binding.

### Megamind version compatibility

`bin/fm-megamind-preflight.sh`'s header owns which `megamind-axi` versions are accepted and why; this record holds the dated evidence and the regression pointers only.

The 0.4.x line was measured against a real Megamind build on 2026-08-11.
The evidence run pinned the upstream Megamind Phase 3 `megamind-axi` 0.4.0 entry point through a throwaway home's `config/megamind-executable` and pointed that home's `config/megamind-estate` at a copy of Megamind's own published example estate, so no private wiki, request, or credential material entered the run:

```sh
megamind-axi --version
megamind-axi preflight --model-class cloud --estate <estate> --format json --no-help-hints -- "pricing"
bin/fm-megamind-preflight.sh check
bin/fm-megamind-preflight.sh run --request "pricing"
bin/fm-worker-preflight.sh <home> <task-id> --config <home>/config --state <home>/state --data <home>/data
```

Observed bounded results:

| Step | Result |
| --- | --- |
| `--version` | Exactly one `megamind-axi` identity line, reporting `0.4.0`. |
| Direct preflight call | `schema_version` `megamind/preflight-result/v2`, status `matched`, a `thresholds` object, one match, no offers, and both optional privacy fields present. |
| `check` | Outcome `available` at version `0.4.0`, exit 0. |
| `run` | One typed `fm/megamind-preflight/v1` document, outcome `matched`, exit 0. |
| Owner-bound `fm-worker-preflight.sh` | Exit 0 with empty stdout, the task's private `state/<task-id>.megamind-preflight.json` filed at mode 0600 with outcome `matched`, and one non-verbatim owner proof line appended to `state/megamind-preflight.jsonl`. |

The launch was therefore authorized from the real 0.4.0 contract before any endpoint, worktree, or task record existed.

The 0.5.0 line was measured against the real Phase 4 release on 2026-08-11 after the initial compatibility refusal.
Phase 4 changes the Megamind version metadata and adds offline evaluation commands, while the `preflight-result/v2` and `route-result/v2` producers and their host-consumed retrieval fields remain unchanged from the accepted 0.4.0 path.
The evidence run used the same throwaway-home binding and published example estate as the 0.4.0 run, with no private wiki, request, or credential material in the evidence:

```sh
megamind-axi --version
megamind-axi preflight --model-class cloud --estate <estate> --format json --no-help-hints -- "pricing"
megamind-axi route --root <estate> --format json --no-help-hints -- "pricing"
bin/fm-megamind-preflight.sh check
bin/fm-megamind-preflight.sh run --request "pricing"
bin/fm-worker-preflight.sh <home> <task-id> --config <home>/config --state <home>/state --data <home>/data
```

Every command ran twice over that one estate and request - once against the accepted 0.4.0 pin, once against 0.5.0 - because the consumed retrieval fields degrade silently rather than loudly: a withheld lexical packet, a dropped context budget, a null freshness, and a discarded allows path all still normalize to `matched` at exit 0.
The comparison therefore runs over the whole consumed surface of the typed `run` document, through one projection that carries no wiki name, root, request, or path:

```sh
bin/fm-megamind-preflight.sh run --request "pricing" | jq -S '
  {outcome, thresholds, notes, read_policy, filtered_count, redacted_count, dropped_allows,
   matches: [.matches[] | {access, routing_mode, freshness, provenance,
                           allows: (.allows | length), context_budget}]}'
```

Observed bounded results:

| Step | Result |
| --- | --- |
| `--version` | Exactly one `megamind-axi` identity line, reporting `0.5.0`, with no second identity line. |
| CLI flags and exit status | The same `--model-class`, `--estate`, `--root`, `--format json`, `--no-help-hints`, and trailing `--` request flags were accepted, none renamed, removed, or newly required, and every listed call exited 0 call for call with the 0.4.0 pin; Phase 4's added evaluation commands are never invoked. |
| Direct preflight call | Schema `megamind/preflight-result/v2`, status `matched`, the same required thresholds and match/offer field types, one match, no offers, and both optional privacy fields present. |
| Direct route call | Schema `megamind/route-result/v2`, the same decision, threshold, candidate, governance, and context-budget field types consumed by the accepted path. |
| Consumed-surface projection | Identical between the two pins. |
| Match evidence | `evidence.signal_counts` carried the same three non-negative `trigger`/`name`/`scope` integers and `evidence.lexical_classes` agreed with those counts on both pins, so the host emitted the full lexical packet rather than the withheld `lexical_classes: []` / `signal_counts: null` shape; `freshness` normalized to the same non-null object rather than the `null` a renamed or retyped field would give. |
| Context budget | The match's `context_budget` normalized to the same authorized-only `max_candidates`/`max_context_chars` pair on both pins, so no renamed or retyped key was dropped into the withheld `{}`. |
| Allows paths | The same entry count on both pins, every entry relative and root-contained, and `dropped_allows` `0` in both, so no listed path was silently discarded. |
| Notes and privacy counters | `notes` held exactly the one fixed host line for `matched` with no upstream note text, and `filtered_count` and `redacted_count` matched the 0.4.0 run with no filtered identity anywhere in the document. |
| `check` | Outcome `available` at version `0.5.0`, exit 0. |
| `run` | One typed `fm/megamind-preflight/v1` document, outcome `matched`, exit 0. |
| Owner-bound `fm-worker-preflight.sh` | Exit 0 with empty stdout, the task's private result filed at mode 0600 with outcome `matched`, and one non-verbatim owner proof line carrying the minimal proof fields only - no request text and no path. |

The 0.5.0 result reached the existing owner-bound worker authorization before launch, so the release is accepted without adding a second policy layer.

The 0.6.0 line was measured on 2026-08-12 against the clean merged Megamind Phase 6 commit `12d3353ac6c18696bd3f6865f195b6c249344ee4`.
The executable reported `megamind-axi 0.6.0`, and its repository had no uncommitted changes.
The evidence used the configured executable and configured pilot estate by reference, without copying either into the fixture or recording their private paths.
The request was a privacy-safe no-match probe, and only bounded typed fields were retained below.

```sh
megamind-axi --version
megamind-axi preflight --model-class cloud --estate <configured pilot estate> --format json --no-help-hints -- <privacy-safe no-match request>
FM_HOME=<temporary evidence home> bin/fm-megamind-preflight.sh check
FM_HOME=<temporary evidence home> bin/fm-megamind-preflight.sh run --request <privacy-safe no-match request>
bin/fm-worker-preflight.sh <temporary evidence home> <task-id>
```

Observed bounded results:

| Step | Result |
| --- | --- |
| `--version` | Exactly one `megamind-axi` identity line, reporting `0.6.0`. |
| Megamind commit | `12d3353ac6c18696bd3f6865f195b6c249344ee4`, clean working tree. |
| Direct preflight call | Exit 0, schema `megamind/preflight-result/v2`, status `no-match`, cloud model class, the three required thresholds, zero matches, zero offers, zero filtered entries, and redacted count `0`. |
| `check` | Exit 0, outcome `available`, version `0.6.0`, and cloud model class. |
| `run` | Exit 0, one typed `fm/megamind-preflight/v1` document with outcome `no-match`, zero matches and offers, zero filtered entries, and no failure. |
| Owner-bound `fm-worker-preflight.sh` | Exit 0 with empty stdout, a private task result with outcome `no-match`, and one proof record carrying only the established minimal fields. |

Unlike the 0.5.0 line above, this evidence carries no matched-path consumed-surface projection, and that omission is deliberate rather than an oversight.
The only estate bound at 0.6.0 was the configured private pilot estate, so a matched probe would have had to put wiki names, request text, or page content into this record, which the privacy boundary forbids.
The projection is not what closes the gap here: the `preflight-result/v2` and `route-result/v2` producers and their command entry points are byte-identical between the measured 0.5.0 pin and this commit, whose additions are a separate rollout command surface, so the fields that degrade silently - lexical packet, freshness, context budget, and allows - have no changed producer path to degrade through.
The portable stub loop below cannot stand in for that argument either, because its fixture is fixed across `FM_TEST_STUB_VERSION` and therefore shows that host normalization is version-independent rather than that a real 0.6.0 still emits those fields.

The governed explicit offer selection was measured separately on 2026-08-12 against Megamind `97d88a3`, the PR 13 commit that publishes `megamind/preflight-selection-result/v1`, reporting `megamind-axi 0.6.0` from a clean tree.
That run used a fully synthetic two-wiki estate built by `megamind-axi init` plus two added routing cards, never the private pilot estate, so the request, wiki names, and paths below are all fixture text.
It exists to settle where `--today` belongs, because the flag is declared on both the top-level parser and the two subparsers, and to prove the selection path end to end rather than only against the stub.

```sh
megamind-axi preflight --model-class cloud --estate <synthetic estate> --today <date> --full --format json --no-help-hints -- "shared topic"
megamind-axi select-offer AlphaWiki --request "shared topic" --preflight-result <packet> --model-class cloud --estate <synthetic estate> --today <date> --format json --no-help-hints
FM_HOME=<synthetic evidence home> bin/fm-megamind-preflight.sh check
FM_HOME=<synthetic evidence home> bin/fm-megamind-preflight.sh run --request "shared topic"
FM_HOME=<synthetic evidence home> bin/fm-megamind-preflight.sh continue --selection-id <id> --offer AlphaWiki
```

Observed bounded results:

| Step | Result |
| --- | --- |
| `--today` placement | Accepted after the subcommand on both `preflight` and `select-offer`, which is the one placement Megamind's own `commands.md` reference spells for each; the host now uses exactly that argv for both calls. |
| Direct preflight call | Exit 0, schema `megamind/preflight-result/v2`, status `ambiguous`, two offers, and no matches. |
| Direct select-offer call | Exit 0, schema `megamind/preflight-selection-result/v1`, status `authorized`, and `selection.basis` `selected-current-offer`. |
| `check` and `run` | Exit 0, outcome `available` at version `0.6.0`, then one typed `ambiguous` document carrying an opaque `selection_id` and no request text. |
| `continue` | Exit 0, outcome `authorized`, the selected wiki's three declared relative `allows`, and `selection.threshold_matched` `false`. |
| Upstream field shapes this settled | `selected.score` is a raw non-negative rank (`8`), not a 0..1 confidence; `selected.confidence.meets_floor` was `true` because the ambiguity was decided inside the band; and the registry `follow_up` ladder embeds the shell-quoted original request, exactly as the already-accepted `run` path forwards it. |

Those last three shapes are why the continuation validator checks the typed shape and the governed refusals rather than restating decisions Megamind already owns.
Requiring a 0..1 `score`, a `false` `meets_floor`, or a request-free `follow_up` refused every real authorized selection while accepting the synthetic fixture, so the stub agreed with the host and both disagreed with the build.

The `continue` row predates the governed `route` ladder descent that `docs/configuration.md` "Megamind preflight" now owns, so it records the declared card paths a full-access selection authorized before any page was ranked; a re-run authorizes the pages `route` ranks whenever at least one of them satisfies that section's local relevance contract, and the declared paths whenever none does.

The `--today` flag the host now sends was measured on 2026-08-12 against every accepted line, because the tables above predate it and prove only the flags they list.
Each line ran from its own release commit - `c59b58b` at 0.3.0, `27d3bf9` at 0.4.0, `44f1b37` at 0.5.0, and `97d88a3` at 0.6.0 - over the same synthetic two-wiki estate, so the comparison isolates the flag rather than the estate.

```sh
megamind-axi preflight --model-class cloud --estate <synthetic estate> --today <date> --format json --no-help-hints -- "shared topic"
megamind-axi select-offer AlphaWiki --request "shared topic" --preflight-result <packet> --model-class cloud --estate <synthetic estate> --today <date> --format json --no-help-hints
FM_HOME=<synthetic evidence home per line> bin/fm-megamind-preflight.sh run --request "shared topic"
```

Observed bounded results:

| Line | `preflight ... --today` | `select-offer` | Host `run` |
| --- | --- | --- | --- |
| 0.3.0 | Exit 0, schema `megamind/preflight-result/v2`, status `ambiguous`, two offers. | Absent: `usage_error`, exit 2, `invalid choice: 'select-offer'`. | Exit 0, one typed `ambiguous` document. |
| 0.4.0 | Exit 0, same schema, status, and two offers. | Absent, same `usage_error` and exit 2. | Exit 0, one typed `ambiguous` document. |
| 0.5.0 | Exit 0, same schema, status, and two offers. | Absent, same `usage_error` and exit 2. | Exit 0, one typed `ambiguous` document. |
| 0.6.0 | Exit 0, same schema, status, and two offers. | Present, and authorized end to end above. | Exit 0, one typed `ambiguous` document carrying an opaque `selection_id`. |

So `--today` after the subcommand is accepted identically on all four accepted lines, and one argv serves every release the version gate admits without narrowing support to 0.6.x.
`select-offer` is the part that is genuinely 0.6-only, so an ambiguous outcome on an older accepted line takes the same uncontinuable path a home without a session lock takes: the result stands, with no `selection_id` and no retained private record, and the command is never sent to a build that would refuse it.

The 0.6.0 result reached the existing owner-bound worker authorization before launch, so the release is accepted without adding a second policy layer.
The same owner still refuses 0.7.x and later, malformed identities, malformed output, and older releases until each future contract is separately established.
A second home pinned to an installed `megamind-axi` 0.1.0 over the published example estate of the 0.4.0 and 0.5.0 runs reported outcome `error` with `failure.code` `version_incompatible`, `failure.detected` `0.1.0`, and exit 1, so the old-release refusal is measured on a real build rather than assumed from the synthetic stub.

The full accept-and-refuse matrix stays portable and runs with no Megamind installed:

```sh
bin/fm-test-run.sh tests/fm-megamind-preflight.test.sh tests/fm-worker-preflight.test.sh
```

Observed bounded output:

```text
ok - run: restrictive defaults, version gate, and invalid config fail closed
ok - run: the version probe is identity-anchored, single-line, and never verbatim
ok - check: availability probe reports configuration honestly
ok - the 0.4.0 owner-bound preflight authorizes a worker before launch
ok - the 0.5.0 owner-bound preflight authorizes a worker before launch
ok - 0.6.0 authorizes before launch while 0.7.0 remains refused
FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0
```

Those cases authorize 0.3.x, 0.4.x, 0.5.x, and 0.6.x, refuse the older `0.2.9`, the malformed `0.4`, `v0.4.0`, `0.4.0.1`, and `0.4.0-rc.1`, and the unproven future `0.7.0` and `1.0.0`, and hold the probe to exactly one `megamind-axi` identity line.
Each proven line is held to the same normalized consumed surface as the 0.3.x baseline - lexical packet, freshness, context budget, allows, and host notes - rather than to its authorized outcome alone, and the 0.6.0 launch case requires the owner proof record that the refused 0.7.0 case, which reaches the same log with its typed refusal, must not carry.
The 0.4.0, 0.5.0, and 0.6.0 lines each keep their own ordinary-worker launch case, so a regression that narrows the gate to only the newest proven line fails on the release it dropped rather than passing on the one it kept.

## Herdr

The compatibility floor is protocol 14.
The whole real-Herdr lane's latest active verification uses both Herdr 0.7.4 protocol 16 and Herdr 0.8.0 protocol 19 on macOS aarch64, while focused Herdr 0.7.5 protocol 17, earlier protocol-16, protocol-14, and 0.7.3 evidence is retained where it defines current behavior or fallbacks.
Protocol 17 keeps every protocol-16 feature gate satisfied; the event and workspace-move floors remain 16.
Default-on presentation projection has its own floor at Herdr 0.8.0, protocol 19, verified below.

Core read-only probes:

```sh
herdr --version
herdr status --json | jq -c '{client:.client.protocol,server:.server.protocol}'
herdr api schema --json | jq -c '.schemas.subscription_event["$defs"].SubscriptionEventKind.enum'
```

Observed protocol-16 compatibility shapes:

```text
herdr 0.7.5
{"client":17,"server":17}
["pane.output_matched","pane.agent_status_changed","pane.scroll_changed"]
```

The CLI matrix was checked directly:

| Guarantee | Command shape | Result |
| --- | --- | --- |
| Explicit session routing | `herdr <verb> ... --session <name>` | Reached the named session even while another server was running. |
| Literal send | `herdr pane send-text <pane> <text> --session <name>` | Left text unsubmitted until Enter. |
| Keys | `herdr pane send-keys <pane> enter|escape|ctrl+c --session <name>` | Enter and Escape worked; Ctrl-C interrupted foreground work. |
| Capture | `herdr pane read <pane> --source recent --lines N` | Small N could return empty below viewport height; a 200-line request plus local trim was stable. |
| Native state | `herdr agent get <pane>` | Working and done transitions were visible; native `busy` remains positive activity evidence, while native `idle` cannot close a turn and the adapter's semantic lifecycle decides worker state. |
| Restart | guarded named-session stop then start | Workspace, tab, pane, and labels persisted; the agent process and registration did not. |
| Close | `herdr pane close <pane> --session <name>` | The exact one-pane task tab closed; closing a final tab could remove the workspace. |

All destructive verification used `bin/fm-herdr-lab.sh` with a non-default `fm-lab-` name and a byte-identical default-session tripwire.
No ambient `herdr server stop` command is a supported test operation.

### Prune and respawn

The real label-collision reproduction is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-prune-safety-e2e.test.sh
```

Observed guarantee: a pre-existing captain-owned workspace with a seed-shaped tab was adopted for routing but its tab was never eligible for prune because the current create call did not return that seed id.

Restart-husk replacement is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-respawn-idem-e2e.test.sh
```

Observed guarantee: a restored no-agent tab was replaced create-before-close, while a registered live agent caused refusal.

### Launcher workspace placement

Herdr exports its pane identity into every process it manages, checked on 2026-07-30 against Herdr 0.7.5 protocol 17 inside a guarded lab pane:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh
"$HERDR_LAB_HELPER" run "$LAB" pane run "$PANE" "sh -c 'env | grep ^HERDR | sort > /tmp/env.txt'"
```

```text
HERDR_ENV=1
HERDR_PANE_ID=w1:p1
HERDR_SESSION=fm-lab-fm-herdr-env-pro-65961-25535
HERDR_SOCKET_PATH=/Users/kunchen/.config/herdr/sessions/fm-lab-fm-herdr-env-pro-65961-25535/herdr.sock
HERDR_TAB_ID=w1:t1
HERDR_WORKSPACE_ID=w1
```

This complete injection shape is verified only for Herdr 0.7.5.
Firstmate requires both `HERDR_PANE_ID` and `HERDR_SOCKET_PATH` before accepting claimed launcher ancestry.

`pane get` reports the pane's current owning tab and workspace, which is what placement resolves from; the injected `HERDR_TAB_ID` and `HERDR_WORKSPACE_ID` are creation-time snapshots and are not read as current identity:

```sh
"$HERDR_LAB_HELPER" run "$LAB" pane get w1:p1 | jq -c '.result.pane | {pane_id,tab_id,workspace_id}'
```

```text
{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}
```

Placement is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-launcher-workspace-e2e.test.sh
```

Observed guarantees on 2026-07-30 against Herdr 0.7.5 protocol 17:

```text
ok - real herdr E2E: with one 'firstmate' workspace and no herdr parent, a crewmate still lands in this home's own workspace without stealing focus
ok - real herdr E2E: the normal unique-label path is unchanged when the launcher's own pane identifies the workspace
ok - real herdr E2E: presentation spaces still create the isolated child workspace and bind it under the launcher's exact parent, without stealing focus
ok - real herdr E2E: with two 'firstmate' workspaces, a worker spawned from inside the second one lands in that exact workspace
ok - real herdr E2E: the duplicate-labeled sibling workspace is left entirely untouched and focus is preserved
ok - real herdr E2E: with a duplicated home label, a projected worker still hangs off the launcher's exact workspace and the sibling stays untouched
ok - real herdr E2E: an ambiguous home label with no launcher identity refuses before any worker endpoint exists
ok - real herdr E2E: a launcher pane that no longer exists refuses before any worker endpoint exists
ok - real herdr E2E: a secondmate launching its own worker gets the same exact-workspace guarantee, and its same-labeled sibling is untouched
ok - real herdr E2E: a --secondmate launch still stands up that secondmate's own workspace instead of inheriting the launcher's
ok - real herdr E2E: teardown closes only the worker's own pane and leaves the launcher, its workspace, and the same-labeled sibling intact
```

That suite's headline case runs `bin/fm-spawn.sh` inside a real Herdr pane, so the parent identity comes from Herdr's own injection rather than a composed environment.
Cross-session and contradictory bindings are covered deterministically in `tests/fm-backend-herdr.test.sh`, which can script a second server's socket without provisioning one.

### Per-home and presentation topology

Per-home behavior is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-workspace-per-home-e2e.test.sh
```

Observed guarantee: the primary and secondmate used distinct home workspaces, a child launched by the secondmate stayed in that secondmate workspace, list-live remained home-scoped, and exact cleanup did not affect sibling homes.

The complete projection suite ran on 2026-07-21 against Herdr 0.7.4 protocol 16:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed guarantees included:

```text
ok - real Herdr lab: primary and two secondmate homes each own a top-level contiguous child block
ok - real Herdr lab: concurrent primary/A/B spawns stay session-locked with zero focus drift
ok - real Herdr lab: session lock contention from a secondmate home falls back flat with no journal
ok - real Herdr lab: legacy projection labels and flat secondmate tabs are left unmigrated
ok - real Herdr lab: multi-home exact-pane teardowns restore captain focus without workspace close authority
ok - real Herdr lab validation completed on Herdr 0.7.4 with the default-session tripwire intact
```

The suite also covers lost or failed move responses, active-tab refusal, restart husks, missing and duplicate tokens, manual renames, concurrent cleanup, and exact focus restoration.

The mandatory projection suite ran again on 2026-07-24 against Herdr 0.7.5 protocol 16:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed restart-reclaim guarantees:

```text
ok - real Herdr lab: Hi Bit and Wheelhouse-style same-identity restarts reclaim one nested space with exact focus and idempotence
ok - real Herdr lab: secondmate restart binding and reclaim stay isolated to the exact child home and parent
ok - real Herdr lab: concurrent cross-home recoveries replace exact husks under one session lock with no focus drift
ok - real Herdr lab: missing, renamed, and duplicate tokens trigger zero destructive or adoptive calls, and live duplicate risk refuses launch
ok - real Herdr lab validation completed on Herdr 0.7.5 with the default-session tripwire intact
```

The projection suite ran again on 2026-08-04 against Herdr 0.8.0 protocol 19 for the default-on flip, where an absent `config/herdr-presentation-spaces` enables the projection and the value `off` opts out; since 2026-08-05 an absent file enables the projection only at or above the 0.8.0 floor recorded under "Presentation version floor" below, and `on` is the explicit opt-in that survives the floor:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed default and opt-out guarantees:

```text
ok - real Herdr lab: an opted-out spawn retains the Stage 1 Herdr command sequence with zero ordering calls
ok - real Herdr lab: a home that configured nothing is projected by default
ok - real Herdr lab: the primary presentation setting inherits into real secondmate homes
ok - real Herdr lab validation completed on Herdr 0.8.0 with the default-session tripwire intact
```

The projected spawn in that run used the historical empty opt-in file, so a home that had already enabled the projection keeps it without any migration step.
One concurrent cross-home recovery case refused under contention on a loaded machine and passed on an immediate rerun; recovery-path presentation lock contention is a deliberate hard refusal rather than a flat fallback, which default-on now makes reachable from any Herdr home.
That run measured the default-on projection on Herdr 0.8.0 only, while the focus-flash regression below was last run on 0.7.5 before the flip, so neither run covered a defective release under default-on projection; the version floor and the focus-flash suite's Part C close that gap.

The restored-shell session-start cleanup ran on 2026-07-24 against Herdr 0.7.5 protocol 17:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-herdr-session-cleanup-e2e.test.sh
```

Observed guarantee: one exact home-local, journal-correlated, one-tab and one-pane childless idle shell was closed after restoration while the exact non-target focus and default fleet session remained unchanged, and a repeat run was a no-op.

### Workspace-removal focus safety

The focus-flash regression ran on 2026-08-05 against both Herdr 0.7.5 protocol 17 and Herdr 0.8.0 protocol 19 on macOS aarch64, with the 0.7.5 run using the pinned upstream release binary first on `PATH`:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-focus-flash-e2e.test.sh
```

Observed output on Herdr 0.7.5:

```text
ok - old path: the explicit last-pane close of a non-focused workspace stole focus (w3	w3:t1 -> w2	w2:t1)
ok - mitigation: every in-operation sample preserved exact focus while the doomed workspace was removed
ok - mitigation: no explicit close and no corrective focus were needed on the defective release
ok - fallback: a doomed pane holding a persistent child exhausts the proof and takes the plain explicit close
ok - fallback on a defective release: a bounded wrong-focus window of 4 samples was fully restored to the anchor
ok - version floor: herdr 0.7.5 protocol 17 remains conservatively below the floor with steal_live=1
ok - version floor: an unconfigured home falls back flat on herdr 0.7.5 and the explicit opt-in still projects
evidence: herdr=0.7.5 protocol=17 steal_live=1 floor_verdict=1 default-session-tripwire=armed
```

Observed output on Herdr 0.8.0:

```text
ok - old path note: this Herdr release preserves focus across the explicit close; continuing with outcome-only assertions
ok - mitigation: every in-operation sample preserved exact focus while the doomed workspace was removed
ok - fallback: a doomed pane holding a persistent child exhausts the proof and takes the plain explicit close
ok - fallback on a focus-preserving release: the plain explicit close preserved exact focus throughout
ok - version floor: herdr 0.8.0 protocol 19 is at or above the floor and preserves focus
ok - version floor: an unconfigured home stays projected on herdr 0.8.0 and the explicit opt-in agrees
evidence: herdr=0.8.0 protocol=19 steal_live=0 floor_verdict=0 default-session-tripwire=armed
```

Part C is the case the suite could not reach before: a doomed pane whose shell holds a persistent background child fails the lone-idle-shell proof on every sample, so the plan takes the plain explicit close, in the geometry where the closing workspace's right neighbour is a spacer rather than the focused anchor.
On 0.7.5 that fallback exposed a bounded four-sample wrong-focus window and restored the anchor exactly; on 0.8.0 the same fallback exposed none, which is why default-on projection is floored at 0.8.0 rather than mitigated further below it.
The suite also cross-checks its own Part A measurement against the floor classifier on whatever release it runs, so a drifted protocol-to-release mapping fails there rather than silently gating on the wrong thing.

### Presentation version floor

Default-on presentation projection is floored at Herdr 0.8.0.
The floor's structural signal is the selected running server's protocol number, falling back to the client protocol only when that selected session positively reports no running server, and the release mapping was measured on 2026-08-05 by running each pinned upstream macOS aarch64 release asset's own `status --json` through the guarded lab helper:

| Release | Reported version | Protocol | Carries both upstream focus fixes | Floor verdict |
|---|---|---|---|---|
| v0.7.3 | 0.7.3 | 16 | no | below |
| v0.7.4 | 0.7.4 | 16 | no | below |
| v0.7.5 | 0.7.5 | 17 | no | below |
| preview-2026-07-21-0f10e1453a7f | 0.7.5-preview.2026-07-21-0f10e1453a7f | 17 | no | below |
| preview-2026-07-29-44b3adb12552 | 0.7.5-preview.2026-07-29-44b3adb12552 | 18 | yes | below |
| preview-2026-08-04-d78e3d3b5126 | 0.8.0-preview.2026-08-04-d78e3d3b5126 | 19 | yes | above |
| v0.8.0 | 0.8.0 | 19 | yes | above |

No build lacking both fixes reaches protocol 19, and every pre-fix build tops out at 17, so protocol 19 is a safe structural expression of the 0.8.0 floor.
The one post-fix build below it is a preview that still reports a 0.7.5 version, so it is conservatively treated as below the floor, which costs a preview build its projection and never lets an unfixed build through.
The 2026-08-05 named-lab cross-version probe started a server from Herdr 0.7.5 and queried it with the installed 0.8.0 client; status reported client version 0.8.0 protocol 19, server version 0.7.5 protocol 17, server running true, and server compatible false.
That ordinary post-upgrade shape proves the running server owns the focus behavior, so the unconfigured default composes client and selected-server verdicts conservatively and rechecks after server ensure before publishing a journal or creating a workspace.

Refresh this table with the opt-in guard, which re-downloads the pinned assets, verifies their digests, and fails naming any release whose reported version, protocol, or verdict has moved:

```sh
FM_HERDR_VERSION_FLOOR_LIVE_E2E=1 tests/fm-herdr-version-floor-live-e2e.test.sh
```

The classifier itself, the config preference it composes with, and the one-warning-per-release behavior are pinned portably with no Herdr installed:

```sh
tests/fm-backend-herdr.test.sh
```

Observed guarantees: every measured release classifies as the table records; either the protocol or the version signal alone carries an at-or-above verdict, and each divergent pair flips once the carrying signal is removed; client and running selected-session server verdicts compose conservatively, an unreadable server-running state and losing both release signals report indeterminate and fall back flat, the default is rechecked after server ensure before projection publication, an unconfigured home is projected only at or above the floor, an explicit `on`, including the historical empty opt-in file, is honored below it, and the below-floor warning is emitted once per home per detected release rather than once per spawn.

The whole real-Herdr lane was run on 2026-08-05 against both the CI-pinned Herdr 0.7.4 protocol 16, which is below the floor, and Herdr 0.8.0 protocol 19, which is at it:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh bin/fm-test-run.sh --lane real-herdr-gated
```

Both runs reported `family=real-herdr-gated count=11 failed=0`.
The projection suite's unconfigured-home case is release-aware rather than pinned to one outcome, so it proves the projected default on 0.8.0 and the flat fallback with its naming warning on 0.7.4:

```text
ok - real Herdr lab: a home that configured nothing is projected by default on herdr 0.8.0
ok - real Herdr lab: a home that configured nothing falls back flat on below-floor herdr 0.7.4 with one naming warning
```

Every other case in that suite uses an explicit opt-in or opt-out, so the floor leaves them unchanged on both releases.

Direct lab probes on 2026-07-28 established the removal rules the emptying-close plan relies on, each verified with `workspace list` focus reads around one mutation in a guarded `fm-lab-` session:

- An explicit `pane close` that emptied a non-focused workspace moved focus off the focused workspace in both before-focus and after-focus geometries.
- Ending a workspace's lone shell preserved the focused workspace exactly when the dying workspace sat behind it or the focused workspace was last, and moved focus to the focused workspace's right neighbor otherwise.
- The production focus-preserving close in the dangerous geometry repositioned the doomed workspace, ended its proved shell, and left every concurrent focus sample on the exact anchor with no corrective `tab focus` issued.

Two real-hardware conditions were required for the pane-death path to engage and are now encoded in the adapter and its unit fixtures: BSD `ps` reports a login shell's `comm` as `-zsh`, and an idle shell transiently hosts a prompt helper (starship) as a second foreground process immediately after a `workspace.move` relayout, which the bounded settle window absorbs.

The rules match the v0.7.5 tag source (`close_selected_workspace` reassigns focus from the closing workspace's index; `handle_pane_died` only clamps the stale focused index), and the upstream default branch resolves both paths by workspace id (PR #1877, commit `165dca45`, for the explicit close; PR #1912, commit `a979916`, for pane death), so the plan degrades to a harmless reorder-then-remove once a release carries them.

The full projection and restored-shell suites were re-run on 2026-07-28 on Herdr 0.7.5 with the updated close path; the presentation suite completed with `real Herdr lab validation completed on Herdr 0.7.5 with the default-session tripwire intact`, and the restored-shell cleanup guarantee above was unchanged.

The teardown-level record-retention gate was verified on 2026-07-28 with metadata fixtures and a live contending lock holder:

```sh
tests/fm-teardown.test.sh
tests/fm-backend-herdr.test.sh
```

Observed guarantees: a contended presentation lock refused the teardown before the isolated copy was returned, with the task branch, every durable record, and the endpoint intact and no pane close attempted; the retry after the contention cleared returned the copy, closed the pane under the lock, and removed the records; an unknown structured-presence result after an attempted projected close retained the journal and every record with a nonzero exit; and every presence-gate mode accepted only a structured not-found as gone.

The same fixtures verified three further boundaries on 2026-07-29: missing or malformed endpoint identity and an unparseable pane presence refused record removal with everything retained; the SIGKILL escalation re-read the exact pane's process information and refused to signal when a different shell pid owned the pane, falling back to the plain close with the original process untouched; and a reposition whose removal then failed on every path restored the exact original workspace order through a second verified move and reported the close as failed.

The teardown fixture was re-run on 2026-07-31 after extending the same fail-closed boundary through forced secondmate cleanup, including recursive cleanup of a nested secondmate whose Herdr grandchild close remains unconfirmed.

Observed output:

```text
ok - forced secondmate teardown preflights every Herdr child before cleanup mutation
ok - forced secondmate teardown retains Herdr child identity until exact pane disappearance
ok - forced teardown retains a nested secondmate home and its grandchild's Herdr identity when the grandchild close is unconfirmed
```

### Composer and operational input

Real captures verified these active distinctions:

- Claude and Codex use bare `❯` and `›` agent composers.
- Pi uses content between complete separator rows and requires exact native Pi identity.
- Dim or faint suggestion text is ghost content, while normally styled text is pending input.
- Grok dark truecolor placeholders are ghost content, while bright truecolor typed input remains pending.
- A bare shell prompt has no safe agent-composer container and is unknown.

`tests/fm-composer-ghost.test.sh`, `tests/fm-composer-lib.test.sh`, and the Herdr composer cases pin the exact captured ANSI bytes.
The U+2063 operational and routed-request separators were exercised through a real Pi-on-Herdr path; the byte-exact active regression is:

```sh
FM_SEND_MARKER_HERDR_E2E=1 \
  tests/fm-send-secondmate-marker-herdr-e2e.test.sh
```

### Native blocked event

The protocol-16 event path was measured on 2026-07-11 with Herdr 0.7.3 and Python 3.13:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-eventwait-smoke.test.sh
```

Observed output:

```text
ok - real herdr: events.subscribe capability gate passes
ok - real herdr: a driven idle->blocked transition returns the blocked record in 0.129s
ok - real herdr: the watcher fast-path enqueues a stale wake naming the task window
```

Polling remained active and is covered as the fallback for capability, connect, subscribe, and repeated reader failure.

### Agent lifecycle control

Herdr is one of the two backends whose recovery-grade agent-state classifier the control plane may trust ([agent-control.md](../agent-control.md)), so its lifecycle gating is measured against the real binary; reverified 2026-08-08 on Herdr 0.8.0, and first measured 2026-08-02 on Herdr 0.7.5 with identical results:

```sh
tests/fm-control-herdr-smoke.test.sh
```

Observed output:

```text
ok - real herdr: exit on a pane with no registered agent is idempotent success
ok - real herdr: interrupt refuses when herdr's own agent registry reports no agent
ok - real herdr: interrupt delivers the harness's key and proves the agent survived it
ok - real herdr: no control verb removed the endpoint or the task's local copy
ok - real herdr: an agent that does not stop fails closed instead of being reported as stopped
```

The registry read through `herdr pane report-agent` is the same source `fm_backend_herdr_agent_state` classifies, so registering and not registering an agent on a plain shell pane exercises exactly the gate every lifecycle verb depends on, with no real agent launched.
That command is the guard that refreshes this record; run it after every Herdr upgrade rather than trusting the version above.

### Away-mode transport

The Pi/Herdr return and injection path was reverified on Herdr 0.7.3 and Pi 0.80.7:

```sh
FM_AFK_PI_HERDR_E2E=1 HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-afk-pi-herdr-return-e2e.test.sh
```

Observed guarantees: pending composer input refused injection and raised one alert; idle Pi accepted one marked escalation; the return gate refused ordinary work while a live blocker remained; resolving the blocker allowed the return flow.
The dedicated Herdr daemon workspace topology is covered by `tests/fm-afk-launch.test.sh` and preserves the captain tab's pane count.

## Zellij

The current compatibility floor and latest verification are Zellij 0.44.0 with `jq` on macOS aarch64.
All real tests use a uniquely named session and `tests/zellij-test-safety.sh`; they never touch a session named `firstmate` or call all-session deletion.

| Guarantee | Command shape | Result |
| --- | --- | --- |
| Headless session | `zellij attach -b <name>` without a TTY | Created a persistent background session and returned. |
| Session list | `zellij list-sessions --short --no-formatting` | Returned one plain name per line without starting a session. |
| Create tab | `zellij action new-tab --cwd <dir> --name <title>` | Returned a numeric tab id and focused the new tab when a client was attached. |
| Pane discovery | `zellij action list-panes --json` | Included terminal pane id, tab id, plugin flag, and top-level `pane_cwd`. |
| Literal send | `zellij action paste --pane-id <id> -- <text>` | Left text unsubmitted. |
| Keys | `send-keys --pane-id <id> Enter`, `Esc`, and one argument `Ctrl c` | All three shared operations worked. |
| Capture | `dump-screen --pane-id <id>` or `--full` | Worked with no attached client; no line-bound flag exists. |
| Close | `close-tab-by-id <id>` | Removed the live task pane and tab together. |
| Failure exit | actions against missing targets | Returned exit 0, requiring structural preflight and output-shape validation. |

`pane_cwd` stayed frozen when a foreground subshell changed directory.
The marker-delimited `pwd` probe returned the live nested cwd and is covered by the real smoke.
The focus mitigation restored the previously active tab after `new-tab`, with the unavoidable narrow race documented in the operator guide.

```sh
tests/fm-backend-zellij.test.sh
tests/fm-backend-zellij-smoke.test.sh
```

The real lifecycle smoke proved spawn, metadata, nested-subshell worktree discovery, send, capture, unlanded-work refusal, approved local landing, exact tab cleanup, and session cleanup without retaining task-specific ids or branch names here.

## Orca

Real readiness was verified against `/usr/local/bin/orca` with `/Applications/Orca.app` bundle version 1.4.116.

```sh
orca status --json
```

Observed fields:

```text
result.runtime.reachable=true
result.runtime.state=ready
```

`orca terminal create --json` returned `result.terminal.handle`.
`orca worktree create` returned `result.worktree.id` and `result.worktree.path`.
Speculative bare ids and nested terminal fields were deliberately rejected.

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```

The fake-Orca suite covers readiness, registration, create response parsing, metadata routing, popup-safe submit, and path-matched release refusal.

## cmux

The current compatibility floor is cmux 0.64, and the active live evidence uses 0.64.17 build 97 on macOS aarch64.
Real tests use only exact `fm-test-` workspaces guarded by `tests/cmux-test-safety.sh` and never quit or relaunch the captain's app.

```sh
cmux version
cmux ping
```

Observed version:

```text
cmux 0.64.17 (97) [9ed29d81a]
```

Source and live checks established the five control modes:

- `off` starts no listener.
- `cmuxOnly` rejects an external Firstmate process by ancestry.
- `automation` uses an owner-only 0600 socket with no handshake.
- `password` uses the same 0600 socket plus `auth <password>`.
- `allowAll` uses a 0666 socket with no authentication.

The live default rejection was `Access denied - only processes started inside cmux can connect`.
The live password challenge was `Authentication required - send auth <password> first`.
The app configuration writer did not retain a hand-added socket password, which is why the operator guide requires Settings and a local Firstmate password source.

Current active CLI findings:

| Guarantee | Command shape | Result |
| --- | --- | --- |
| Create | `new-workspace --name <title> --cwd <dir> --focus false --id-format uuids` | Created one workspace with one surface without focusing it. |
| Fresh readiness | `list-panes --workspace <id> --json --id-format uuids` | Found a brand-new surface before content existed. |
| Fresh read counterexample | `read-screen` before any write | Returned `internal_error: Failed to read terminal text`. |
| Literal send | `send --workspace <id> --surface <id> -- <text>` | Left text unsubmitted. |
| Keys | `send-key ... enter|escape|ctrl-c` | All shared key operations worked. |
| Nested cwd | `current_directory` plus foreground subshell | Structured cwd froze; the marker-delimited `pwd` probe found the live cwd. |
| Last surface | `close-surface` on the only surface | Refused with `invalid_state: Cannot close the last surface`. |
| Last workspace | `close-workspace` on the only workspace in a window | Printed success but left the workspace present. |

The last-workspace workaround was reverified on 2026-07-10 in Automation mode.
After creating one unfocused unnamed sibling in the same window, `close-workspace` removed the exact task workspace and left only cmux's default sibling.
A selected non-last workspace closed directly, proving that window cardinality rather than selection is the trigger.

Source inspection confirmed each workspace constructor creates a new UUID with no restored-id input.
Recovery therefore remains title-based.
The bundled Claude wrapper was observed stripping `CMUX_*` variables on its failed socket-probe path while retaining the app bundle id, supporting the macOS-only bundle-id and ancestry fallbacks.

```sh
tests/fm-backend-cmux.test.sh
tests/fm-backend-cmux-smoke.test.sh
```

The real smoke proves socket access, fresh readiness, current-path probing, send and keys, bounded capture, title identity, and guarded exact cleanup.

### Claude composer confirmation

The borderless Claude composer confirmation was verified on 2026-08-09 with cmux 0.64.22 build 102 and Claude Code 2.1.226 on macOS aarch64.
An isolated real Claude worker rendered a bare `❯` plus U+00A0 row between horizontal rules.
The cmux classifier returned `empty`, and one `fm-send.sh --resolve-key <key> ALBATROSS` command appended the matching `resolved` event before the worker reported completion.
The terminal capture contained exactly one submitted `❯ ALBATROSS` row.
Refresh this harness-dependent proof with an isolated cmux Claude worker before accepting a Claude or cmux upgrade:

```sh
FM_CMUX_CLAUDE_COMPOSER_LIVE=1 bin/fm-test-run.sh tests/fm-cmux-claude-composer-live-e2e.test.sh
```

The portable classifier regression is `tests/fm-backend-cmux.test.sh`.

## Kimi Code effort axis

Kimi Code CLI 0.31.0's effort axis was verified on 2026-07-30 against the current authenticated K3 worker.
`kimi --help` lists `-m, --model` and no reasoning-effort option, so the operational `KIMI_MODEL_THINKING_EFFORT` environment override is the only effort surface.
The override intentionally bypasses Kimi's own `supportEfforts` check, so an unadvertised level reaches the API instead of being rejected locally.

Advertised levels:

```sh
kimi provider list --json
```

Observed bounded output for `kimi-code/k3`:

```text
"supportEfforts": [ "low", "high", "max" ],
"defaultEffort": "high"
```

Per-level acceptance was probed non-interactively with one short prompt each:

```sh
KIMI_MODEL_THINKING_EFFORT="$level" kimi -m kimi-code/k3 -p "Reply with the single word ok."
```

Observed results:

```text
low    -> exit 0, model replied
high   -> exit 0, model replied
max    -> exit 0, model replied
medium -> error: failed to run prompt: provider.api_error: 400 Invalid request Error
xhigh  -> error: failed to run prompt: provider.api_error: 400 Invalid request Error
```

An arbitrary non-effort string produced the same 400, confirming the override reaches the wire unvalidated.
`fm-spawn` therefore emits the override only for `low`, `high`, and `max`, and records an undeliverable level in task metadata without passing it.
`tests/fm-kimi-harness.test.sh` pins the single leading env assignment, the omitted levels, and the refusal of any effort value outside the shared vocabulary.

## Codex App host tools

A reusable Desktop host-tool smoke ran on 2026-07-06 against Codex Desktop bundle version 26.623.101652, build 4674, bundle id `com.openai.codex`.
Local paths and task-specific ids are intentionally not retained here.

The host-tool sequence was:

1. list a saved project;
2. create a Desktop-owned worktree thread;
3. recover and read the thread while active and after completion;
4. verify the thread appended a Firstmate status line and wrote its report;
5. send a follow-up to the same thread;
6. read the completed follow-up;
7. archive the exact thread;
8. read the archived transcript with state `notLoaded`.

Observed guarantee: a Desktop-owned thread can write Firstmate lifecycle files when the prompt provides an authorized absolute path, and create, send, read, and archive work at the Desktop host-tool layer.
The missing guarantee remains a supported shell-callable bridge that lets Firstmate perform those operations against the same visible Desktop endpoint.
App-server partial methods and raw socket experiments do not satisfy that bridge contract.
