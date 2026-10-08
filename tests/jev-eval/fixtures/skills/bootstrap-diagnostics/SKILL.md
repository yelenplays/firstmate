---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap or network-checks section prints an actionable diagnostic line - MISSING, MISSING_MANUAL, PRESENTATION_UNAVAILABLE, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, STARTUP_MEMORY_BUDGET, CREW_DISPATCH invalid, FLEET_SYNC, NETWORK_CHECKS, WIKI_SYNC, HOME_SUMMARY, BACKLOG_RECONCILE, SECONDMATE_SYNC, SECONDMATE_LIVENESS, SECONDMATE_HANDOFF, NUDGE_SECONDMATES, BROWSER_BRIDGES, or FMX - or reports that an interrupted backlog cleanup may have left an endpoint or local copy, or when a standalone bin/fm-bootstrap.sh or bin/fm-startup-network.sh run prints one of those lines.
  A silent bootstrap section, or any other BOOTSTRAP_INFO fact, means no skill load.
user-invocable: false
metadata:
  internal: true
---
