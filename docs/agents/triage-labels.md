# Triage labels for Matt engineering skills

Matt engineering skills use five canonical triage roles on `yelenplays/firstmate`.
The tracker label string is identical to each role name.

| Role | Tracker label | Meaning |
| --- | --- | --- |
| `needs-triage` | `needs-triage` | A maintainer needs to evaluate the issue. |
| `needs-info` | `needs-info` | The issue is waiting for more information from the reporter. |
| `ready-for-agent` | `ready-for-agent` | The issue is fully specified and ready for an autonomous agent. |
| `ready-for-human` | `ready-for-human` | The issue requires human implementation. |
| `wontfix` | `wontfix` | The issue will not be actioned. |

When a skill names a role descriptively, apply the corresponding exact label above.
Create a missing label only when the captain has explicitly authorized that GitHub mutation, and use the `gh-axi` workflow in [`issue-tracker.md`](issue-tracker.md).
