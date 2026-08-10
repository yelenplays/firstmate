# Domain documentation for engineering skills

Matt engineering skills use this repository's domain documentation when they explore the codebase.

## Sources

Read root `CONTEXT.md` before exploration when it exists.
Read applicable records under `docs/adr/` before working in an area when that directory exists.
If either source is absent, continue silently rather than proposing it up front.
The domain-modeling skill creates these sources lazily when accepted terminology or decisions need a durable owner.
Classify every newly tracked `CONTEXT.md` or `docs/adr/` Markdown surface in [`docs/documentation-audiences.json`](../documentation-audiences.json) as `agent-runtime` or `maintainer-architecture` in the same change that adds it.

## Vocabulary and decisions

Use the terms defined in `CONTEXT.md` rather than synonyms it explicitly rejects.
Surface a conflict with an existing architecture decision record instead of silently overriding it.
