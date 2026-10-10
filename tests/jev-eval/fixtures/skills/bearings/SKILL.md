---
name: bearings
description: >-
  Generate a "pick up where I left off" fleet digest from firstmate's live fleet state.
  Use when the captain invokes /bearings or asks for a bearings report, morning brief, status report, catch-up, "where did I leave off", or "what's in the works".
  Plain /bearings is chat-only by default, /bearings file explicitly writes the dated data/status-report-<YYYY-MM-DD>.md artifact, and /bearings lavish additionally builds and arms the interactive fleet board; live PR enrichment remains opt-in and composes with the other modes.
  Also use on a contributions check wake or when filing work linked to an upstream issue.
  Also load this skill's board-wake handling when a procevent lavish wake's source id matches the canonical source id of the stable bearings board path.
user-invocable: true
metadata:
  internal: true
---
