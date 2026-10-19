# Memory store

Durable agent memory is plain markdown under a per-home store directory, searched by a light length-normalized BM25 index.
This page owns the operator contract: store layout, automatic capture, the migration out of OpenViking, the retirement of the old server, and rollback.
Each script's header and `--help` own exact flags and exit codes; this page states the shape and the invariants.

The arrangement exists because the captain chose it on 2026-09-20 after the `data/memory-store-reliable-cheap` investigation: the OpenViking server burned about 9.5% of a core in a non-converging retry loop against a dead Ollama, while the memory payload itself was about 119 markdown files.
The memory store deliberately excludes vector recall and vikingbot; it remains plain files plus keyword search, with no daemon or GPU.
[Automatic capture](#automatic-capture) retains new captain facts across sessions, with lower total usage as its acceptance condition rather than an assumption that capture alone saves tokens.

## Layout

The store defaults to `$FM_HOME/data/memories`; [`configuration.md`](configuration.md#memory-store-configmemory-dir) owns the `FM_MEMORY_DIR` and gitignored `config/memory-dir` overrides and their precedence.
Every home has its own store; `config/memory-dir` is home-local and is not part of secondmate inherited configuration.
A memory is one markdown file with frontmatter and a topic title; [`bin/fm-memory.sh`](../bin/fm-memory.sh)'s header owns the record format and write options.
The OpenViking categories carry over: `preferences`, `entities`, `events`; `remember` normalizes the singular names.
A fourth category, `now`, holds short-lived current captain context, such as an open personal or project situation a follow-up may refer to implicitly.
Automatically captured `now` entries carry an `expires` date; manually written entries may omit it and remain current indefinitely.
An expired entry stays on disk but is no longer printed by `now`.
`sensitivity: private` marks an entry that a non-Claude primary harness must not see in its session-start digest.
Neither expiry nor sensitivity filters `recall`; these metadata control startup presentation, not access to the store.
The BM25 index is `<store>/.index.json`, a disposable cache owned by [`bin/fm-memory-bm25.mjs`](../bin/fm-memory-bm25.mjs) that self-rebuilds whenever the tree drifts from its recorded manifest, so recall never answers from stale bytes.
Recall scores the title and body only: the frontmatter block stays structured metadata and is never indexed, so a metadata word or a date is not a ranking signal.
During OpenViking migration, legacy session history and other non-memory Markdown files are copied to `$FM_HOME/data/memory-archive/`, not to the searchable memory store.

## Commands

See `bin/fm-memory.sh --help` for exact syntax.

- `remember` writes or updates a memory from arguments or stdin.
- `recall` ranks memories by BM25, with a JSON envelope available for recall-injection consumers.
- `now` prints current entries newest first under a size cap; [automatic capture](#automatic-capture) describes startup delivery.
- `merge-from` copies memories missing from this store without overwriting; differing files at the same relative path are conflicts for an operator to settle.
- `list`, `stats`, `dir`, and `reindex` inspect the store and manage the index.

## Automatic capture

[`bin/fm-memory-capture.sh`](../bin/fm-memory-capture.sh) captures durable facts from the captain's own words at each compaction and session end of the primary home's main Claude session.
The project `.claude/settings.json` chains it after `bin/fm-history.sh capture` on PreCompact and SessionEnd, and it detaches at once so neither waits on a model.
The automatic hook stands down outside the primary main session; its header owns the scope guards and manual-run caveat, and [configuration](configuration.md#automatic-capture-configmemory-capture) owns the disable and model settings.

A separate Claude SessionStart hook calls `bin/fm-memory-capture.sh now` on every source, including compact.
It prints only a header and bounded current entries (about 1.5K tokens by default), keeping NOW inline even when Claude saves the larger startup digest and shows only a preview.
The [`fm-memory.sh` header](../bin/fm-memory.sh) owns the size controls.
It uses the capture hook's primary-session scope guards, but disabling capture does not suppress already-captured context; an empty store prints nothing.
The Claude digest omits NOW to avoid duplicate tokens.
Other harnesses keep the digest block with private entries excluded.

Each run reads journaled captain turns after its watermark, starting with all available journaled turns when no watermark exists.
It drops recognized wake prompts and acknowledgements, strips pasted blocks and configured no-op replies, and keeps each captain message whole with its paired reply clipped as context; tool output is excluded by journal capture.
After filtering, a very long captain message is split losslessly into consecutive labeled parts rather than clipped.
Short factual messages remain eligible.
Every retained turn goes to the configured Claude Haiku or Sonnet model and to no other service: Jev accepts task facts only, and no word filter can prove a chat turn is free of personal data.
All automatically captured memories and NOW summaries are marked private, including work-related derivations: a model's sensitivity label cannot prove they contain no personal context.
They remain available to Claude but are excluded from other harnesses' startup digests; publishing public context requires an explicit `remember` write.
If no turns remain after filtering, the extractor skips the model.
Each memory is written through `remember`, read back, and recalled by topic before it counts, and the watermark advances only when every write verified.
A boundary that fires while an earlier run is still extracting leaves a pending marker.
After a successful pass, the lock holder drains pending boundaries with fresh passes over newer turns and rechecks after releasing the lock.
A failed pass leaves newer pending boundaries for a later run; unverified turns remain behind the watermark for retry.
Capture is detached, so a new session can start before extraction finishes; its NOW hook reads only memories already written.
Two failed runs in a row append one `failed` line to `state/memory-capture.status`, which wakes firstmate, and the next good run appends `resolved`.
The script header owns flags, state files, and per-run usage records; `bin/fm-memory-capture.sh status` summarizes them.
These records account for extraction, not total main-session savings; compare total usage with the opt-in [auto-compaction window](configuration.md#auto-compaction-window-configclaude-autocompact) before claiming a net reduction.
The recall-injection hook is unchanged.
[`tests/fm-memory-capture.test.sh`](../tests/fm-memory-capture.test.sh) covers capture routing, long messages, overlapping boundaries, writes, watermarking, and recovery with recording stand-ins; [`tests/fm-memory-filter-budget.test.sh`](../tests/fm-memory-filter-budget.test.sh) covers short facts and the complete NOW output cap.

## Migrating from OpenViking

Run [`bin/fm-memory-migrate.sh`](../bin/fm-memory-migrate.sh) on the machine that holds the OpenViking workspace:

```sh
bin/fm-memory-migrate.sh migrate                # copies, verifies, reindexes
bin/fm-memory-migrate.sh migrate --dry-run      # prints the plan only
bin/fm-memory-migrate.sh verify                 # re-checks every destination hash
```

The memories tree is located under `--source` (default `$FM_OV_HOME/data`, `FM_OV_HOME` defaulting to `~/.openviking`) by the probe order in the script header, or pinned directly with `--memories-dir`.
All remaining markdown under the source - sessions, wiki-layer, resources, skills - lands in the archive directory, while `_system/`, `vectordb/`, and `logs/` are deliberately skipped.
Each run writes a manifest under `<store>/.migration/` pairing every exported source file with its sha256, and verifies destination hashes before reporting success; the script never writes to the source and never deletes from the destination. A re-run restores a missing copy and refreshes a destination the last migration wrote that still matches its recorded hash; any other destination that already exists - including one the migration never wrote, or one the newest manifest carries no row for - is left untouched and reported as skipped-and-kept, so operator edits are never overwritten.

## Retiring the server

Run [`bin/fm-openviking-retire.sh`](../bin/fm-openviking-retire.sh) on the OpenViking host after a verified migration.
It boots out and disables every launchd label containing "viking", SIGTERMs a residual `openviking-server`, rotates the unrotated logs under `~/.openviking/logs/` to timestamped names, and verifies nothing answers on the API port.
`--dry-run` narrates the sequence without touching anything.
The `~/.openviking/data` tree is never deleted; rollback is the printed `launchctl enable` + `bootstrap` pair per label, and the store keeps working because nothing in the new path depends on the server.
A nix or home-manager rebuild can reinstall the plist - remove the `openviking` module there for permanence.

Standing check carried over from the investigation: after any backend change, confirm the OpenViking queue is empty (`ov status`) before trusting that the retry burn is gone.

## Operator steps outside this repo

The repo ships the store and its commands; three pieces of the old path live outside it and are repointed by hand:

- `~/.local/bin/ov-remember`: `exec <repo>/bin/fm-memory.sh remember "$@"` is not a drop-in for the old argument order; translate each old form by hand:
  - `ov-remember <topic> "<fact>"` -> `fm-memory.sh remember <topic> "<fact>"`
  - `ov-remember <topic> "<fact>" --category entity` -> `fm-memory.sh remember --category entity <topic> "<fact>"`; `--category` must come before the topic.
  - `ov-remember <topic> --from-file <path>` -> `fm-memory.sh remember <topic> < <path>`; there is no `--from-file`, the body comes from arguments or stdin.
  - `ov-remember --list` -> `fm-memory.sh list`
  An option left after the body (`--category ...`, `--from-file ...`) now exits non-zero instead of being stored as the fact.
- The `~/.claude/CLAUDE.md` durable-memory section: point recall at `bin/fm-memory.sh recall` and writes at `bin/fm-memory.sh remember` in place of `ov find` and `ov-remember`.
- The Pi extension's recall injection: call `bin/fm-memory.sh recall --json <query>` where it previously called `viking_search`; session-commit shipping is gone by design.

Secondmates resolve the same commands against their own `$FM_HOME`; nothing is shared or synced between stores unless the operator makes it so.

## What is intentionally absent

No vector embeddings, no semantic similarity beyond keyword BM25, no bulk session-archive ingestion, no vikingbot, and no resident model backend.
The only model-backed memory extraction path is [automatic capture](#automatic-capture).
Adding any of the rest back is a new decision, not a repair.
