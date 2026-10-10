---
name: fmx-respond
description: >-
  Agent-only playbook for handling Relay mentions and follow-ups.
  Use on an "x-mention <request_id>" check wake to read the stashed mention, classify it, act autonomously on eligible requests, reply or dismiss, and link spawned work.
  Also use on an "x-mode-error ..." check wake to report the Relay configuration blocker instead of answering a mention.
  Also use on milestone and terminal wakes for a Relay-linked task before posting completion follow-ups, using typed promised-final reconciliation when registered and --final otherwise.
  Also use on a "public-followup ..." check wake, and whenever a promised final public reply must be created, reconciled, or delivered.
  Loaded only when Relay is enabled.
user-invocable: false
metadata:
  internal: true
---
