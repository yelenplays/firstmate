---
name: process-event-sources
description: >-
  Agent-only procedure for registered process-to-event sources and their wakes.
  Use before arming a long-polling source firstmate owns, before registering a
  deterministic condition->action watch, on any
  `procevent <adapter> <source-id> <sequence>` check wake, and on any
  `process-event source stranded` or `process-event source failed to start`
  check wake.
  Owns the arming commands, the condition->action eligibility boundary, the
  durable result read, which wakes must be routed to their adapter instead of
  acknowledged generically, the handled acknowledgement contract, the one-owner
  rule, and the precise durability boundary.
user-invocable: false
metadata:
  internal: true
---
