---
name: updatefirstmate
description: >-
  Self-update a running firstmate and its secondmates to the latest from origin.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  Updates this firstmate repo's default branch and every local or remote secondmate through its guarded convergence path (never forced, never disruptive), then re-reads AGENTS.md and restarts every live second mate through the persist-gated restart, with a fallback re-read nudge only where a restart cannot be proven.
user-invocable: true
metadata:
  internal: true
---
