lab home: /var/folders/9d/8w50jhgd79x63rgbq_5cyyvm0000gn/T//fm-lab.pqDlF2
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
- pending files: 0
- .wake-triage.last: present
- queued wake rows: 1
- retained pending holds the one-shot note: 

### S1 retry: next triage replays it and does not absorb
triage rc=10
  | WAKE TRIAGE: 1 row(s), 1 task(s): 1 act now, 0 routine
  | ACT NOW:
  | WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 74081.1792082592.hTCIzQ
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
  | WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 4493.1792082615.HBnRe3
  | WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 4493.1792082615.HBnRe3
- pending files: 0
- .wake-triage.last: present
- queued wake rows: 1

### S3 adversarial: recovered output + queue lock held (no WAKE_ACK_REQUIRED) + closed stdout
first triage rc=1
- pending files: 0
- .wake-triage.last: present
- queued wake rows: 1
ls: .wake-triage.pending.*: No such file or directory
queue lock holder ready: ready
contended replay rc=1 (stock /bin/bash)
- pending files: 0
- .wake-triage.last: present
- queued wake rows: 1
- original recovered file still present: no
grep: /var/folders/9d/8w50jhgd79x63rgbq_5cyyvm0000gn/T//fm-lab.pqDlF2/state/: Is a directory
- it still carries the one-shot note: 
grep: /var/folders/9d/8w50jhgd79x63rgbq_5cyyvm0000gn/T//fm-lab.pqDlF2/state/.wake-triage.pending.*: No such file or directory
grep: /var/folders/9d/8w50jhgd79x63rgbq_5cyyvm0000gn/T//fm-lab.pqDlF2/state/.wake-triage.pending.*: No such file or directory
- new pending:  skipped-drain line,  ack lines
uncontended retry rc=10
  | WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 29338.1792082632.vaUnq7
- pending files: 0
- .wake-triage.last: present
- queued wake rows: 1

### S4 --absorb all-routine wake (crew probe reports working), handoff into a dead reader
triage rc=0
- pending files: 0
- .wake-triage.last: present
- queued wake rows: 0
next wake rc=0
  | WAKE TRIAGE: 1 row(s), 1 task(s): 0 act now, 1 routine
  | ROUTINE (worker verifiably working, no open decision, no hold):
  | WAKE_ACKED: triage acknowledged every row through 2; nothing needs firstmate
- pending files: 0
- .wake-triage.last: present
- queued wake rows: 0

### S5 --absorb all-routine wake delivered normally (happy path)
triage rc=0
  | WAKE TRIAGE: 1 row(s), 1 task(s): 0 act now, 1 routine
  | WAKE_ACKED: triage acknowledged every row through 3; nothing needs firstmate
- pending files: 0
- .wake-triage.last: present
- queued wake rows: 0

teardown: removing /var/folders/9d/8w50jhgd79x63rgbq_5cyyvm0000gn/T//fm-lab.pqDlF2
