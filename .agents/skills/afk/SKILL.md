---
name: afk
description: >-
  Enter away mode on /afk, an away announcement, state/.afk-contract or state/.afk, FM_INJECT_MARK input, or state/.subsuper-* markers.
  Record exact words first in the same turn, read back without confirmation, keep one supervision session, render the durable return brief on genuine return.
user-invocable: true
metadata:
  internal: true
---

# afk

Away changes the one supervision session's posture, never approval authority.
Only `fm-afk-contract.sh` writes it; never infer from chat.
Quiet records belong to `quiet`, without return holds.
The only reach profile is hold-for-return, no phone channel.

## Enter

1. Before other work in this same turn, run `bin/fm-afk-launch.sh enter` with the exact away words; consult its help for word-file, expected-return and spend flags.
   `/afk`, even empty, is the go: never gate entry on confirmation/read-back.
   Words are the whole verbatim mandate, no clause fields/merge-grant lists or parser/tokenizer/classifier/grammar.
   An empty refresh preserves the record; new words replace it immediately, preserving original entry and archiving superseded words.
2. Load `away-quiet-supervision` and use the current harness's single supervision path.
   Pi/pi-signed keeps its branch, a host home its host, main parked in both, never an away daemon.
   If entry reports no host engine, say every away notification reaches this conversation instead.
   Read [daemon reference](references/daemon.md) before daemon launch/operation/diagnosis; consult launch help.
   Use `start-native` plus `FM_AFK_STATE_PREPARED=1 bin/fm-afk-start.sh` through a native tracked-background tool when available; roll back a failed native launch with `stop`.
   Otherwise use `start`, which owns the non-visible tracked terminal and supervisor target; never substitute `nohup ... &`.
   Both require the entry record; daemon injection is presence-gated by `state/.afk`.
   Where the daemon runs it owns its watcher child: arm no separate cycle; Pi keeps its own cycle.
3. Announce hold-for-return and no phone channel, then restate the recorded words sentence by sentence in plain outcome language, with expected return and spend cap.
   Uncertain or captain-owned calls wait for return.
   Name any sentence that cannot be acted on away, including red merges, discards and local-only landing.
   Read-back is informational; changed readings require new `/afk` words.

## Authority and operation

- Read the words at every notification's tail and judge this event against exactly what they say, never by analogy; doubt holds with verdict captain.
  Use guarded scripts under standing authority and begin every outcome taken under the words with "per your away instructions:".
  Destructive, irreversible and security-sensitive actions are never pre-authorizable, whatever the words say.
  Ask-user findings keep `ask-user-authority` unless the words pre-answer that exact decision; all other captain calls wait.
- A PR may merge only when green at its live head and called for by the words, synchronously through the merge guard; no red/missing-check waiver, auto-merge or unproven queue state while away.
  Away authority never releases a captain hold, expires at archive, and never permits local-only landing.
  These gates and the recorded dispatch spend cap bind main, Pi's branch and host engine equally.
  Queued work may dispatch when blockers clear, including work filed by the branch only because the words explicitly requested it.
- Items held for the captain are never rechecked while the record exists; external waits retain their condition-aware hours-long cadence.
  Pi's branch takes every safe actionable notification; only declined work (including broken branch or unsafe scan) or watcher failure wakes main.
  A host hand-back is automatic supervision, not the captain's return; handle it away through the emitted harness protocol.
  Restart recovers the posture from the digest's durable AFK record.
- Daemon safety remains mandatory: inject only into an idle pane with an affirmatively empty composer, otherwise preserve the buffer for retry and raise the bounded wedge alarm on prolonged deferral.
  Type once, retry only Enter, and clear the buffer only after verified submit; never lose queued events before routing and acknowledgement.
  Preserve the singleton lock, crash backoff, pane-gone guard, shutdown flush, dedupe without advancing unreadable status, bounded wedge detection and catch-all scan.
  Honor declared waits over wedge cadence; escalate checks, unknown events and captain-relevant status spans in order, including unread steering instructions, without consuming that worker status.
  Delivery artifacts are session-local: fresh entry clears old, refresh preserves buffers, stop keeps presence through shutdown flush then archives.
  The reference owns signals, classification branches and timers; `FM_INJECT_SKIP` overrides routing, use sparingly.

## Return

The first genuine message other than `/afk` means return: run `bin/fm-afk-return.sh` before acting on it.
Relay every emitted return section in order, in outcome language.
Internal forms stay away: the current U+2063 operational prefix, legacy `FM_INJECT_MARK`, Stop/host feedback and the arm's Grok completion notification.
An operational doorbell counts only after `fm-operational-input.sh open '<path>'` verifies its record; failed open/ASCII lookalikes are genuine input.
Bias ambiguity toward exit; `/afk` refresh never exits and ordinary chat must not exit `/quiet`.
Remediate every open blocker or durably reclassify it with a reason and resolve its exact key, then run `fm-afk-return.sh check`; captain-verdict outcomes do not exempt blockers.
After archive restore primary responsiveness during catch-up; allow Bearings, not dispatch, steering, merges or ordinary work until check succeeds.
Then clean up every "Landed, cleanup due" task through ordinary non-forced teardown; investigate refusals and report the closed workers.
