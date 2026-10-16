# Rearm/resurface validation

Candidate: 16e94d508dfea59a8086de04f68313a6d8b601dc. Runtime scripts were unchanged during testing. One test-only fixture correction remains in tests/fm-supervision-host.test.sh.

## Focused behavioral checks (not live Claude evidence)

A transient copy of tests/fm-supervision-host.test.sh retained only these queue_case entries and used its existing runner/cleanup:
- test_hook_rearms_after_group_teardown_without_empty_recovery
- test_at_turn_successor_survives_group_teardown_and_real_outage_recovers
- test_confirmed_takeover_does_not_resurface_acknowledged_interleaved_work
- test_confirmed_takeover_still_resurfaces_unread_interleaved_work

Command: TMPDIR="$PWD/.local-test-tmp" FM_LOCAL_EVIDENCE=/Users/yelen/.no-mistakes/evidence/01M52K8W2DD20AFAN2G8JXM7A5 bash tests/.local-rearm-selected.sh

The first two passed. Both handover tests initially timed out waiting for their setup's empty recovery. A sequential retry reproduced both timeouts. The marker showed acked downtime, consistent with the existing intentional quiet retirement of empty clean downtime. The tracked test fixture was corrected to enqueue actual initial unread work. Both handover checks then passed sequentially. Runtime code was not changed.

A transient copy of tests/fm-wake-queue.test.sh retained only test_handover_restore_undoes_only_its_own_stop and test_stale_recovery_generation_cannot_touch_a_newer_episode. Command: TMPDIR="$PWD/.local-test-tmp" bash tests/.local-wake-selected.sh. Both passed, including unread work, unsafe symlink queue, acknowledged arrivals, and stale-generation rejection.

The fixtures use a simulated Claude session/engine and deterministic handover interposition; they are NOT live primary evidence. Host event histories and actual drain output are preserved in fixture-behavior.log.

## Real-primary attempt

Tool checks: Claude Code 2.1.301; Herdr 0.9.0; tmux not found on PATH. No package installation or tool hunting occurred.

Used bin/fm-herdr-lab.sh exclusively, named fm-lab-* sessions, marked disposable homes inside .local-test-tmp, and a 40x120 attached viewer provided by the helper. Provision invokes prepare internally. Initial setup mistakes (separate prepare before provision, response-field parsing, and incorrect pane command names) were corrected and re-driven; every lab was torn down in its creating command's EXIT trap and its default-session tripwire verified.

The real CLI launched under the normal login. A prompt restricted it to the lab and requested wake drain/ack handling with Stop-hook-owned continuity. The primary ran session startup and acquired its lab lock, then finished its turn. No automatic watcher or auto-arm ledger appeared. Repeating with explicit --settings pointing to this checkout's .claude/settings.json had the same result. No live notification was injected because the necessary automatic lifecycle had not armed. The cause of absent hook execution was not established; this is a setup limitation, not a demonstrated failure of the changed runtime code. A hook-enabled real primary is needed to finish the live scenarios. The approved live-coverage exception remains unchanged.

No screenshot was captured: the change concerns lifecycle scheduling rather than visual rendering; actual TUI text captures are in the live attempt logs. No suite, linter, formatter, push, PR, or CI phase was run. Transient runners and lab files were removed after evidence collection.
