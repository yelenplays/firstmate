lab home: /var/folders/9d/8w50jhgd79x63rgbq_5cyyvm0000gn/T//fm-lab.VhSwYi
.
..
.fm-lab-home
bin
config
data
projects
state
tmux

### S1 --absorb, actionable wake with a one-shot unread note, handoff into a dead reader
triage rc=1 (handoff failed)
- pending files: 1
- .wake-triage.last: absent
- queued wake rows: 1
- retained pending holds the one-shot note: 1

### S1 retry: next triage replays it and does not absorb
triage rc=10
  | WAKE TRIAGE: 1 row(s), 1 task(s): 1 act now, 0 routine
  | RECOVERED DRAIN OUTPUT (an earlier triage was interrupted; act on all of it):
  | WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 58870.1792082426.ov6CUU
  | beta note: captain answer for beta - use option B
  | ACT NOW:
  | WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 58870.1792082426.ov6CUU
- pending files: 0
- .wake-triage.last: present
- queued wake rows: 1

### S2 manual triage (no --absorb), closed stdout
triage rc=1
- pending files: 1
- .wake-triage.last: absent
- queued wake rows: 1
retry rc=0
  | WAKE TRIAGE: 1 row(s), 1 task(s): 1 act now, 0 routine
  | RECOVERED DRAIN OUTPUT (an earlier triage was interrupted; act on all of it):
  | WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 7169.1792082464.0EZp4i
  | WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 7169.1792082464.0EZp4i
- pending files: 0
- .wake-triage.last: present
- queued wake rows: 1

### S3 adversarial: recovered output + queue lock held (no WAKE_ACK_REQUIRED) + closed stdout
first triage rc=1
- pending files: 1
- .wake-triage.last: absent
- queued wake rows: 1
queue lock holder ready: ready
contended replay rc=1 (stock /bin/bash)
- pending files: 2
- .wake-triage.last: absent
- queued wake rows: 1
- original recovered file still present: yes
- it still carries the one-shot note: 1
- new pending: 1 skipped-drain line, 0 ack lines
uncontended retry rc=10
  | RECOVERED DRAIN OUTPUT (an earlier triage was interrupted; act on all of it):
  | WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 58368.1792082497.INuZax
  | eps note: one-shot answer for eps
  | WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 58368.1792082497.INuZax
- pending files: 0
- .wake-triage.last: present
- queued wake rows: 1

### S4 --absorb all-routine wake (crew probe reports working), handoff into a dead reader
triage rc=1
- pending files: 1
- .wake-triage.last: absent
- queued wake rows: 0
next wake rc=10
  | WAKE TRIAGE: 1 row(s), 1 task(s): 0 act now, 1 routine
  | RECOVERED DRAIN OUTPUT (an earlier triage was interrupted; act on all of it):
  | WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 13109.1792082536.RYvRCz
  | ROUTINE (worker verifiably working, no open decision, no hold):
  | WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 2 --recovery-generation 30226.1792082552.XYrZO6
- pending files: 0
- .wake-triage.last: present
- queued wake rows: 1

### S5 --absorb all-routine wake delivered normally (happy path)
triage rc=0
  | WAKE TRIAGE: 2 row(s), 1 task(s): 0 act now, 1 routine
  | WAKE_ACKED: triage acknowledged every row through 3; nothing needs firstmate
- pending files: 0
- .wake-triage.last: present
- queued wake rows: 0

teardown: removing /var/folders/9d/8w50jhgd79x63rgbq_5cyyvm0000gn/T//fm-lab.VhSwYi
