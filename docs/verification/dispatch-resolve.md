# Typed dispatch resolution verification

Audience: maintainer verification.

This record supports the live `bin/fm-dispatch-resolve.sh` contract owned by [`../configuration.md`](../configuration.md) ("Typed dispatch resolution") and the declared rule and profile fields owned there under "Crew dispatch profiles".
It records only facts that must be re-established when the typesafe.ai model, its API, or firstmate's dispatch rules change.
Task chronology, the captain's rules, and the briefs themselves stay in the private scout report.

## The API the tool depends on

Verified 2026-09-16 against `https://api.typesafe.ai`.
`GET /v1/models` listed `jev-latest` and `jev-preview`, both released 2026-09-10; a `jev-latest` request answered as `jev-1.13.0`.
`POST /v1/systemone` takes `{model, state, questions}`; a `choice` question returns `{choice, probabilities, confidence}` with the probabilities summing to 1.
Observed error shapes: 401 `authentication_error` for a bad key, 403 when the header is missing, 422 with a `detail[].loc` naming the offending field, 400 `api_usage_error` for an unknown model, 405 on GET.
No rate-limit headers were present on any response; every response carried `x-typesafe-request-id`.
Observed end-to-end latency from a Mac was 123 to 348 ms per request, with the server's own upstream time at 4 to 60 ms.

## Live rule match against real briefs

Run 2026-09-16 with the key injected for the one command through the vault (`av inject +TYPESAFE_API_KEY -- ...`), model `jev-latest`, confidence floor 0.6, timeout 5 s, one `quota-axi --json` snapshot for the whole run.
Rules: the captain's five-rule file with a captain-authored none option, one `approval: captain` rule, two rule floors on `model:fable`, and declared `provider` on the Pi profiles.
Briefs: 15 real briefs from this home's recent work plus 10 synthetic ones written to hit each rule.

| Measure | Result |
| --- | --- |
| Rule matched the hand label | 20 of 25 |
| Resolved to the hand-labeled profile | 20 of 25 |
| Outcomes: clear / ambiguous / escalate / error | 18 / 1 / 6 / 0 |
| Clear results with a wrong profile | 0 |
| API latency (min / median / max) | 152 / 214 / 348 ms |
| Wall time per call including jq (min / median / max) | 198 / 261 / 396 ms |
| Input tokens per brief (min / median / max) | 1,279 / 3,114 / 4,538 |
| Output tokens | 150 to 152 |
| API errors | 0 |

Of the five disagreements, one was a wrong hand label (the brief quoted the bug-fix rule's wording verbatim), three were real briefs the model read as the approval-gated design rule at 0.66 to 0.86 confidence and escalated by design, each of which the captain had in fact dispatched at the strongest-reasoning class, and one was a synthetic tweak that came back ambiguous at 0.41 confidence and was handed back to firstmate.
A lean request that asked only the rule Choice matched the full request (rule, profile, and status) on all 25 briefs, so rule matching remains one question with every gate in code.
The shipped tool now also asks the effort Choice in that same request.
That table records the 2026-09-16 run with the captain-authored none option.
A second live run on 2026-09-17 used the same 25 briefs, held one quota snapshot constant through a fake `quota-axi`, and exercised a copy of this branch with the shipped neutral `No listed rule applies to this task.` option and option-free interface.

| Measure | Result |
| --- | --- |
| Rule matched the hand label | 20 of 25 |
| Resolved to the hand-labeled profile | 18 of 25 |
| Outcomes: clear / ambiguous / escalate / error | 17 / 2 / 6 / 0 |
| Clear results with a profile other than the hand label | 1 |
| API latency (min / median / max) | 137 / 220 / 1,795 ms |
| Input tokens per brief (min / median / max) | 754 / 2,589 / 4,013 |
| Output tokens | 60 to 62 |
| API errors | 0 |

The maximum latency was one outlier; the next slowest request was 309 ms.
The differing clear result was a synthetic small tweak that matched the simple-bug-fix rule at 0.90 and selected `cursor-grok-4.6-medium` instead of the hand-labeled `cursor-grok-4.6-high`: the tweak exemption removed from the none-option text belongs in that rule's own `when` text.
Two default-labeled briefs became ambiguous.

## Margin gate and rule precedence calibration

Run 2026-09-22 on the TypeSafe route, model `jev-latest`, compact intent state, with the home's 13-rule file (14 options with the neutral none option), 56 live requests in total.
The labeled set is 14 real briefs from the firstmate home, screened for private personal data, each labeled with the rule or rules a supervisor would accept; 6 predate the captain's-intent brief section and are sent as the first 800 characters of the whole brief.
Every live row came from `bin/fm-dispatch-replay.sh run --cases <cases> --out <jsonl> --max-calls 14 --rules <candidate>`, once with the home's rules unchanged and three times with candidate `beats`, and every table below from `bin/fm-dispatch-replay.sh score --margin <list> <jsonl>...`.

Home rules unchanged, 14 rows:

```console
  gate: confidence>=0.6 ambiguous=9 pass=5 wrong=0
  gate: margin>=0.25 ambiguous=4 pass=10 wrong=1
  gate: margin>=0.3 ambiguous=4 pass=10 wrong=1
  gate: margin>=0.4 ambiguous=6 pass=8 wrong=0
```

The one wrong pick at every margin below 0.4 is a short build brief answered with the none option at margin 0.35 and derived confidence 0.59.

The three `beats` variants pooled, 42 rows:

```console
  gate: confidence>=0.6 ambiguous=15 pass=27 wrong=0
  gate: margin>=0.15 ambiguous=5 pass=37 wrong=2
  gate: margin>=0.2 ambiguous=8 pass=34 wrong=1
  gate: margin>=0.25 ambiguous=9 pass=33 wrong=0
  gate: margin>=0.3 ambiguous=12 pass=30 wrong=0
```

0.4 is the lowest tested threshold with no wrong pick under unchanged rules, which is why it is the default.
0.25 is the lowest threshold with no wrong pick across the pooled precedence rows, so it becomes valid only once `beats` are applied and a replay re-verifies it at `wrong=0`.
The best variant, the conditional `beats` proposed for rules 8 through 13, measured 2 of 14 ambiguous at 0.25 with no wrong pick; both remaining rows are short German briefs split between a rule and the none option.
Margins moved by up to 0.17 between variants on a brief whose contested pair neither variant's `beats` named, so one run per brief cannot certify a threshold finer than that.

The 41-row shadow history recorded under the home rules, scored without a network call:

```console
$ bin/fm-dispatch-replay.sh score --margin 0.25,0.3,0.45 state/jev-dispatch-shadow.jsonl
replay-score: rows=41 labeled=0 skipped=0
  gate: confidence>=0.6 ambiguous=18 pass=23 wrong=0
  gate: margin>=0.25 ambiguous=11 pass=30 wrong=0
  gate: margin>=0.3 ambiguous=12 pass=29 wrong=0
  gate: margin>=0.45 ambiguous=15 pass=26 wrong=0
```

The history carries no brief identity, so it measures the ambiguous rate only; the gate changes no pick, since the clear rule is always the most probable option.

## Task sections and per-rule confidence floors

Run 2026-09-23 against `jev-latest` (answering as `jev-1.13.0`), comparing the resolver before this change (whole brief as state) with the resolver after it (only `## Captain's intent` and `## Firstmate spec`).
Each fixture brief was scaffolded with `bin/fm-brief.sh` (ship `--mode no-mistakes` or `--scout`), its two placeholders filled, and both resolvers run on the same file against the same rules.

Generic rules: a hardest-tier rule that requires the brief itself to call the work unusually difficult or high-risk and excludes routine builds, ports, and installers; routine feature, port, or installer builds; bug fixes with a stated root cause; trivial mechanical edits; and read-only investigations or audits.
Sixteen fixtures: ten clear-cut briefs (two per rule) and six borderline ones (a large port with signed installers, an installer after a broken upgrade, a large file split, a table migration, an unexplained slowdown, and a retry policy).

| Measure | Whole brief | Task sections |
| --- | --- | --- |
| Top rule matched the label | 16 of 16 | 16 of 16 |
| Input tokens per ship brief | 4,327 to 4,379 | 583 to 624 |
| Input tokens per scout brief | 2,861 to 2,874 | 584 to 597 |
| Borderline top-rule confidence below 0.99 | 0.77 split, 0.72 slowdown | 0.59 split, 0.70 slowdown |

The top rule matched the label on 16 of 16 fixtures under both shapes, so on these generic briefs the change did not improve routing accuracy.
Every clear-cut fixture answered at probability 0.99 or 1.0 under both shapes, so the scaffold boilerplate neither caused nor prevented a wrong pick.
The one routing difference is a regression: the large-file-split fixture went from clear (confidence 0.77, probability 0.82 on its labeled routine-build rule) to `ambiguous` (confidence 0.59, probability 0.66, the rest going to the neutral option), just under the 0.6 floor.
The gain that holds across the set is size: about 4,350 input tokens down to about 600 per ship brief.

### A routine port the hardest tier over-claims

Run 2026-09-23 against `jev-latest` (answering as `jev-1.13.0`).
The brief was a generic scaffolded ship brief for a routine port of a macOS-only capture helper to Windows plus a Windows installer, described as a straightforward port, with a long never-do-X safety list in its spec.
The rules were the same generic five-rule set with two changes: a loosely worded top-tier rule ("Large or hard engineering work that needs the strongest model, such as a multi-platform build or anything where a mistake is costly.") and the routine rule broadened to "Implementation where the worker must design parts of the solution itself within an existing codebase."
The task-sections row is the shape this change sends: the two task sections, with no kind line because it is a ship brief.

| Shape | Runs | Input tokens | Top-tier rule probability | Confidence | Implementation rule probability |
| --- | --- | --- | --- | --- | --- |
| Whole brief | 3 | 4,436 | 0.90 to 0.93 | 0.87 to 0.92 | 0.07 to 0.10 |
| Task sections | 5 | 670 | 0.88 to 0.91 | 0.84 to 0.89 | 0.09 to 0.12 |

Extraction does not prevent the top-tier pick; a loosely worded rule is matched from the task text alone.
With `min_confidence: 0.95` declared on the top-tier rule, the task-sections shape returned `ambiguous` in 3 of 3 runs, because the pick's probability was below its floor and no other option cleared its own floor.
Additionally declaring `min_confidence: 0.05` on the implementation rule returned a `fallback:` line to that rule in 3 of 3 runs.

Two scaffolded scout briefs (592 and 605 input tokens, sent with the `Brief kind: scout (report only)` line) matched the investigation rule at probability 1.0 in 4 of 4 runs.
A free-form brief with neither task section (561 input tokens, sent whole with no kind line) matched the trivial-edit rule at probability 1.0.

Negative finding: an intermediate variant that also sent `Brief kind: ship, mode=no-mistakes` moved the same routine port brief to the top-tier rule at probability 0.96 to 0.97 in 7 of 7 runs, above a 0.95 floor.
The delivery mode is the same on most ship briefs and says nothing about difficulty, so it is deliberately not sent.

These live runs cover the scout line, the free-form whole-brief fallback, the ship-brief package, the top-tier floor turning the pick `ambiguous`, and the fallback to a runner-up.
Current regression coverage for brief parsing, confidence gates, and configuration validation is listed below; the [operator contract](../configuration.md#confidence-and-fallback-rules) owns the current gates.

## Runoff on an ambiguous answer

A live probe on 2026-10-04 ran the runoff against `jev-1.13.0` on TypeSafe with the threshold raised through `FM_JEV_DISPATCH_MARGIN` so ordinary briefs turned `ambiguous`.
Under the home's own rules, three borderline briefs split between the open-ended-judgment rule and the well-scoped-implementation rule, and both contenders settled on the same Pi Sol lane at the assessed `medium` effort, so each became `picked` with no second call.
Under a three-rule synthetic file whose contenders settled on different Pi models, the runoff request was accepted and answered: a two-way race of 0.72 against 0.28 came back from the runoff at a 0.42 margin, and a 0.51 against 0.49 race at 0.04, so neither cleared that raised threshold and both stayed `ambiguous`.
Finding: a two-contender runoff on the same state largely restates the rule answer's split, so its practical gains are the agreement collapse and contenders whose probability the other rules were diluting; in these runs it did not settle a race the threshold called close.

## Offline behavior

The [operator contract](../configuration.md#typed-dispatch-resolution-env-typesafe_api_key) owns current outcomes, gates, settings, and privacy guarantees.
The dated live runs above predate the backup/default chain and do not establish its live accuracy.
Current behavioral regression entry points are:

- [`tests/fm-dispatch-resolve.test.sh`](../../tests/fm-dispatch-resolve.test.sh): typed-only compatibility, request and credential boundaries, effort ranges, confidence and quota gates, the backup/default chain, last-resort selection, and actual-lane reporting.
- [`tests/fm-dispatch-replay.test.sh`](../../tests/fm-dispatch-replay.test.sh): typed-only replay, call budgets, input isolation, and offline scoring.
- [`tests/fm-dispatch-selftest.test.sh`](../../tests/fm-dispatch-selftest.test.sh): the synthetic corpus, fail-closed never-send handling, default-lane misroutes, read-only prediction evidence, concurrency, and retry/alert cadence.
- [`tests/fm-home-route.test.sh`](../../tests/fm-home-route.test.sh): home-routing fallbacks, missing inputs, approved consult scopes, and override authority.
- [`tests/fm-bootstrap.test.sh`](../../tests/fm-bootstrap.test.sh) and [`tests/fm-session-start.test.sh`](../../tests/fm-session-start.test.sh): range validation, credential isolation, selftest auto-arming, and missing-samples alerts.
- [`tests/fm-spend-ledger.test.sh`](../../tests/fm-spend-ledger.test.sh): read-only prediction without cache, model, or state-directory writes.

Offline stubs cannot certify the operator's private rules against live judges.
Use the home-local routing selftest described in the operator contract for that proof; it can reach the backup CLI even without a typed-call key.
