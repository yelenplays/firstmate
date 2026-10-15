---
name: matt-code-review
description: "Review the changes since a fixed point (commit, branch, tag, or merge-base) along two axes: Standards (does the code follow this repo's documented coding standards?) and Spec (does the code match what the originating issue/spec asked for?). Runs both reviews in parallel sub-agents and reports them side by side. Use when the user wants to review a branch, a PR, work-in-progress changes, or asks to \\\"review since X\\\"."
user-invocable: true
disable-model-invocation: false
license: MIT
metadata:
  firstmate-pointer: "true"
  generated: "2026-10-15"
  author: "Matt Pocock"
  upstream-skill: "code-review"
  upstream-repo: "https://github.com/mattpocock/skills"
  upstream-plugin: "mattpocock-skills@mattpocock"
  validated-version: "1.3.1"
  validated-commit: "49dd158d1076134a641b33efb035946536778336"
---

# matt-code-review

This file is a pointer, not a skill. It contains no part of the procedure.

The real skill is **`code-review`** by **Matt Pocock**, MIT licensed, from
<https://github.com/mattpocock/skills>, installed here as the plugin `mattpocock-skills@mattpocock`.
This pointer was validated against version 1.3.1 (49dd158d1076134a641b33efb035946536778336).
Firstmate generated it on 2026-10-15 so runtimes that read `.agents/skills` can
reach the installed original. Nothing was copied, so nothing here can be out of
date with the original.

## Step 1 - load the original, before doing anything else

Run exactly this:

```bash
/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M4ZTR52N580GZBN507P0FPP9/bin/fm-matt-skill.sh code-review \
  --validated-plugin mattpocock-skills@mattpocock \
  --validated-version 1.3.1 \
  --validated-commit 49dd158d1076134a641b33efb035946536778336
```

It prints the original `SKILL.md` bytes, preceded by an identity header naming
the resolved version, commit and SHA-256 of the file it read, and followed by
the absolute paths of the skill's support files.

## Step 2 - follow what it printed

Treat the printed instructions as the body of this skill and follow them as
written. Read any support file they refer to, at the absolute path listed. Do
not summarise the printed procedure and then work from your summary.

If the header says **PLUGIN CHANGED**, the enabled plugin is no longer the
plugin, version, or commit this pointer was validated against. The printed bytes
are still the installed original and are authoritative, so follow them - and
tell the user the pointers need regenerating with `bin/fm-matt-pointers.sh`.

## If the command fails

It exits nonzero, prints a diagnostic on stderr, and prints nothing on stdout.
There is no second source for this procedure. So:

- Stop. Do not carry out the task this skill was meant to govern.
- Do not reconstruct, paraphrase, or improvise the procedure from memory, from
  this file, or from any copy found elsewhere on disk.
- Tell the user plainly that `code-review` could not be loaded, and quote the exact
  diagnostic.
- Never report this skill as used, followed, or applied.
