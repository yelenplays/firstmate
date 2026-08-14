# Megamind estate wave 1 - adoption notes

Task: `megamind-estate-wave1-v1`. Adopt exactly five knowledge vaults into
Megamind, dry-run first, approval-gated apply, most restrictive access that
still lets routing work. Binary used:
`/Users/yelen/github/firstmate/data/megamind-readonly-pilot/runtime/megamind-axi`.
All work happened in the clones under `/Users/yelen/github/firstmate/projects/`;
nothing was written to `~/Documents/Wikis/` or to the pilot estate.

## Preflight binding

`fm-megamind-content.sh admit --task-id megamind-estate-wave1-v1` returned
`authorization_not_matched` - a benign non-authorizing result per the brief.
No wiki content was loaded through the reader; all digest and card content was
written from each vault's own `index.md`, `AGENTS.md`/`CLAUDE.md`, and
directory structure, read directly in the clones.

## What was adopted vs verified

| Wiki | Action | plan_id |
|---|---|---|
| OutreachWiki | verified, not re-adopted (existing registry) | - |
| VentureWiki | verified, not re-adopted (existing registry) | - |
| LinkedInWiki | adopted | `db6233c038fc` |
| FitnessBrain | adopted | `30c395197c79` |
| ClashRoyaleWiki | adopted | `14be68b6385b` |

`adopt` on OutreachWiki and VentureWiki refuses with `adopt_invalid: target
already has a Megamind registry; it is a registry vault, not a canonical wiki
root`. That refusal is the verification that both already carry their card
(the `_meta/routing/` spine + `.megamind/registry.json` schema). Both were
left exactly as they were; `git status` in both is empty.

## Dry-run plans (all reviewed before any apply)

All three plans stated: "adoption adds sidecar and scaffold files only;
existing pages are never moved, renamed, or rewritten." None proposed touching
an existing page, so no stop condition triggered.

- **LinkedInWiki** - files: `AGENTS.md`, `wiki/log.md`,
  `.megamind/wiki-card.json`, `.megamind/gaps.jsonl`; dirs: `wiki/`,
  `.megamind/proposals/`, `.megamind/audit/`. Note: "existing index/hub page
  adopted as the index: INDEX.md".
- **FitnessBrain** - files: `wiki/log.md`, `.megamind/wiki-card.json`,
  `.megamind/gaps.jsonl`; dirs: `.megamind/proposals/`, `.megamind/audit/`.
  Note: "AGENTS.md exists: kept as is (adoption never overwrites)".
- **ClashRoyaleWiki** - files: `wiki/index.md`, `wiki/log.md`,
  `.megamind/wiki-card.json`, `.megamind/gaps.jsonl`; dirs:
  `.megamind/proposals/`, `.megamind/audit/`. Note: "AGENTS.md exists: kept
  as is".

Applied with `--apply --plan-id` only after all three dry runs were recorded.
Apply results matched the plans exactly (plus one
`.megamind/audit/adoption-<plan_id>.json` record each).

## Access level chosen, per wiki

Every wiki in this wave is set to the **PictureWiki reference posture**:
`model_access: {local: full, cloud: digest-only}`, `routing_mode: full`,
`catalog_visibility: redacted`.

- This is the most restrictive setting that still lets routing work: local
  models route against the full page index, cloud models receive exactly the
  one approved digest (`wiki/digest.md`) and nothing else. The next step down
  (`cloud: none`, `routing_mode: pointer`) would break cloud-side routing
  entirely, which is what the estate exists to provide.
- `catalog_visibility: redacted` (not `full`) because all three contain
  personal or single-user material; the estate catalog still routes, it just
  projects less.
- No wiki got cloud full-page access, and none looked like it needed it.

Per-wiki privacy classification:

- **LinkedInWiki**: `company-private`. The clone's repo is shared with a
  colleague; its own schema keeps client PII in gitignored paths only.
- **FitnessBrain**: `personal-local`. Single-user health-adjacent evidence
  base (no body metrics or health records in the vault).
- **ClashRoyaleWiki**: `personal-local`. Single-user gaming profile and
  coaching data.

OutreachWiki and VentureWiki already classify every routing slice
`company-private` **without an explicit cloud access policy, so cloud access
defaults to `none`** - stricter than this wave's posture. Left unchanged
(verify-only), recorded here because `doctor` surfaces it as warnings (see
below).

## Digests and routing indexes

Each card's `digest` points at a new `wiki/digest.md`, written from the
vault's own index and structure, each with an explicit "what this wiki does
not answer" section. The card's `does_not_answer` and `negative_triggers`
mirror that, because overselling digests are what produced the wrong matches
this wave exists to fix.

Finding during probing: the router resolves the card's `index` entries as
Markdown path links, relative to the index file's own directory. Obsidian
`[[wikilink]]` catalogs (LinkedInWiki and FitnessBrain root `index.md`) do not
resolve - route returned "no index entry matched" and fell back to the digest
only. Fix, without touching any existing page: wrote a new
`wiki/index.md` in both vaults with path links derived 1:1 from the root
index (LinkedInWiki links use `../pages/...` so they resolve to the vault
root), and pointed the card's `index` there. ClashRoyaleWiki's adopt-created
`wiki/index.md` scaffold was filled the same way from `_meta/index.md`.
After the fix, match probes surface the correct pages.

Also edited the adopt-generated `LinkedInWiki/AGENTS.md` (a new file) to note
that this vault's knowledge layer lives in `pages/` and its operating schema
is `CLAUDE.md` - the generated text describes the canonical `wiki/` layout,
which is wrong for this vault.

## Verification

### doctor (recorded after all edits)

| Wiki | Result |
|---|---|
| LinkedInWiki | healthy, 0 errors, 0 warnings |
| FitnessBrain | healthy, 0 errors, 0 warnings |
| ClashRoyaleWiki | healthy, 0 errors, 0 warnings |
| OutreachWiki | 0 errors, 17 warnings (pre-existing) |
| VentureWiki | 0 errors, 18 warnings (pre-existing) |

The registry-vault warnings are all the same pre-existing posture fact, one
per routing slice: "wiki \<slice\> is company-private without an explicit
cloud access policy; cloud access defaults to none". They predate this wave
(I changed nothing in those vaults) and describe a stricter-than-required
default, not a defect. Whether to set an explicit cloud policy on those 19
slices is a captain decision; their own schemas own those registries.

### Routing probes (match + non-match per wiki)

| Wiki | Should-answer query | Result | Should-NOT-answer query | Result |
|---|---|---|---|---|
| LinkedInWiki | "Welches LinkedIn-Format bringt 2025 die meiste Reichweite?" | offer: `pages/algorithm/format-multipliers-oct-2025.md` (+2 related) | "Wie viel Protein pro Tag fuer Muskelaufbau?" | no-match |
| FitnessBrain | "How much protein per day supports hypertrophy?" | offer: `wiki/nutrition/protein-intake-for-hypertrophy.md` | "Which LinkedIn post format gets the most reach?" | no-match |
| ClashRoyaleWiki | "How do I defend Goblin Barrel with Battle Ram Control?" | offer: `wiki/decks/Battle Ram Control (mine).md`, `wiki/cards/Battle Ram.md` | "Wie optimiere ich mein LinkedIn-Profil fuer die Recruiter-Suche?" | no-match |
| OutreachWiki | "How do I improve local SEO for a small business?" | offer: `wiki/concepts/entity-disambiguation-local-ai.md`, `wiki/concepts/service-area-business.md` | "How much protein per day for hypertrophy?" | offer (weak) |
| VentureWiki | "Was ist der naechste Schritt im Fahrplan unseres Ventures?" | offer: `betrieb/fahrplan.md` | "What is the best Clash Royale deck for ladder?" | offer (weak) |

The three newly adopted wikis discriminate cleanly: right pages on the match
probe, `no-match` on the foreign query.

Finding on the two registry vaults: junk queries still produce weak `offer`
results (confidence 0.68 and 0.38, both below the 0.75 reliance floor, so
nothing auto-loads) driven by stop-word-like token matches - "per" from
"protein per day" matched `ppc-keyword-cost.md`, and "best" matched the
Angebot digest. Routing within a single registry vault has no wiki-level
keyword gate, so anything scores something. Not a wave-1 regression and not
in scope to fix, but it is exactly the "matches everything" failure mode in
embryo; worth a stop-word/keyword-gate look in Megamind itself.

### No existing page changed

`git status` in all five clones after everything:

- OutreachWiki, VentureWiki: completely clean (verify-only).
- LinkedInWiki: `?? .megamind/`, `?? AGENTS.md`, `?? wiki/`
- FitnessBrain: `?? .megamind/`, `?? wiki/digest.md`, `?? wiki/index.md`, `?? wiki/log.md`
- ClashRoyaleWiki: `?? .megamind/`, `?? wiki/digest.md`, `?? wiki/index.md`, `?? wiki/log.md`

Only new untracked sidecar/scaffold files; zero modified or deleted existing
files. The new files are left **uncommitted** in the clones for firstmate's
review and vault-side merge handling.

## Refusals and boundaries kept

- No `--apply` before all dry runs were recorded and reviewed.
- Nothing written to `~/Documents/Wikis/`.
- No edits under `data/megamind-readonly-pilot/` - the estate directory still
  holds only the original four wikis; syncing the five adopted wikis into the
  estate is firstmate's side after the merge.
- No `evolve`, `capture`, `research`, or `provision-wiki` - adoption only.
- No out-of-scope vault touched. `AiWiki` stays excluded for the recorded
  second reason (its committed rules forbid agent commits entirely); nothing
  in this wave suggested a different vault belongs here.
- No cloud full-page access granted anywhere.
- The two registry vaults' schemas (warning-producing access defaults, and
  the junk-query weak offers) were left unchanged - both are owned by those
  vaults' own `AGENTS.md` contracts and by the Megamind router respectively,
  and are flagged above instead of silently patched.

## Follow-ups for firstmate / the captain

1. Estate sync: copy or link the five adopted/verified clones into
   `data/megamind-readonly-pilot/estate/` so `catalog --estate` sees nine
   wikis (firstmate side; the pilot estate is read-only to me).
2. Decide whether OutreachWiki/VentureWiki slices get an explicit cloud
   access policy (currently default `none`, which silences the 35 doctor
   warnings either way).
3. Consider a stop-word list or keyword gate for registry-vault routing
   (the "per"/"best" weak-offer finding above).
4. Commit the new sidecar/scaffold files in the three adopted clones through
   the vault-side delivery path.
