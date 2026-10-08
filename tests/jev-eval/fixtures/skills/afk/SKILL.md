---
name: afk
description: >-
  Enter the away posture when the captain invokes /afk, says they are going afk, `state/.afk-contract` or `state/.afk` exists, an incoming message starts with `FM_INJECT_MARK`, or any `state/.subsuper-*` marker is involved.
  It writes the durable away-posture record with the captain's away words verbatim as the whole mandate in the same turn as /afk, before any other work and without waiting for a further go, reads the words back in plain sentences after entry, announces hold-for-return only at entry, keeps the one supervision session running in the away posture (on Pi the supervision branch acts on the words by its own judgment and takes every safe actionable wake with main parked, as the supervision host does on a non-Pi home that runs it; the daemon still delivers batched digests elsewhere for now), and on the first unmarked message renders the return brief from durable records before ordinary work resumes.
user-invocable: true
metadata:
  internal: true
---
