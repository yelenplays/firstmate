---
name: quiet
description: >-
  Enter quiet supervision mode when the captain invokes /quiet or asks for quiet mode, quiet-while-present, or fewer routine wake turns while they stay in the session.
  Where Pi's supervision branch or an attended supervision host already keeps routine wakes off the conversation, it enters nothing and says so.
  Elsewhere it sets the same durable away/quiet-mode flag as /afk, in `quiet` mode, so the sub-supervisor daemon self-handles routine wakes and escalates captain-relevant events exactly as away mode does, but ordinary captain chat does NOT exit it - only an explicit `/quiet off` does.
user-invocable: true
metadata:
  internal: true
---
