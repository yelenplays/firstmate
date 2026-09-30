# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints come from successful portable-parallel jobs on `ubuntu-latest`.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not CI duration.
Local timings are not interchangeable with CI timings because platform and machine load can affect each script differently.

Both hint tables were refreshed on 2026-09-30 from five Ubuntu CI runs: [36583881812](https://github.com/kunchenguid/firstmate/actions/runs/36583881812), [36658498535](https://github.com/kunchenguid/firstmate/actions/runs/36658498535), [36663947738](https://github.com/kunchenguid/firstmate/actions/runs/36663947738), [36664663190](https://github.com/kunchenguid/firstmate/actions/runs/36664663190), and [36669175457](https://github.com/kunchenguid/firstmate/actions/runs/36669175457).
Use the slowest successful `duration_ms` per script across their uploaded portable timing artifacts and completed `FM_TEST_END` log markers, with the two version/platform exceptions below.
All artifact records were cross-checked against the corresponding job's markers.
This covers all 24 parallel and 201 serial members; an existing live-capability skip is a portable-runner measurement, not a timing claim for the unavailable live integration.
Observed maxima provide conservative packing weights, not an upper bound on future durations.

Two serial-5 jobs were cancelled at their 30-minute cap and uploaded no artifact.
Their completed log markers supplement the complete runs, but a cancelled job's wall time is only a lower bound and its unfinished or never-started scripts have no completed sample.
A failed script's duration is excluded even when its lane uploaded an artifact.
In particular, run 36664663190's serial 5 finished in 22m15s with an assertion failure, not a timeout; treating that as a healthy whole-lane sample would hide the failure.
Collect successful per-script measurements for every member before calculating a split.

`tests/fm-supervision-host.test.sh` uses 789123 ms from run 36669175457, after the merged [host runtime fix](https://github.com/kunchenguid/firstmate/pull/6179), rather than its pre-fix maximum of 1065298 ms.
That post-fix value has only one sample in this baseline, so further green runs must establish its variance.
The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` retains its separate 5121 ms measurement from 2026-09-06T21:02Z instead of a portable capability skip.
The session-start hint retains its pre-optimization maximum until CI measures the shorter fixture-only home-summary bound; do not discount a local speedup from CI packing weights.

This fork merges that upstream baseline with its own CI samples: a script both sets measured keeps the slower value, and a script only one set measured keeps that sample.
The fork's parallel-lane samples follow.
The previous two-lane split ran close to its ten-minute job timeout.
These recent artifact `summary.duration_ms` values measure the lane invocation itself, before job setup and tool installation are included:

| Run on 2026-09-23 | Parallel 1 | Parallel 2 |
|---|---:|---:|
| [35810327490](https://github.com/yelenplays/firstmate/actions/runs/35810327490) | 466469 ms (7m46s) | 476458 ms (7m56s) |
| [35815500617](https://github.com/yelenplays/firstmate/actions/runs/35815500617) | 555368 ms (9m15s) | 505938 ms (8m26s) |
| [35817153075](https://github.com/yelenplays/firstmate/actions/runs/35817153075) | 577218 ms (9m37s) | 502302 ms (8m22s) |

Both parallel jobs completed successfully in all three runs; the last run's overall failure was in the separate Herdr lane.
The cancelled PR run [35774219507](https://github.com/yelenplays/firstmate/actions/runs/35774219507) produced no shard 1 artifact because cancellation interrupted the runner before it wrote the timing JSON, so it is not a duration sample.
Each of the 24 proven-isolated candidates has three successful per-script samples across these six artifacts.
`portable_parallel_weight_hints` retains the slowest completed sample for each script, which is a packing input and not an upper bound on future durations.

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over those hints, with the Pi typecheck pinned to the job that installs its prerequisite.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap follows the three-tier timeout policy in [Timeouts](#timeouts) below.
Three parallel lanes use deterministic longest-processing-time assignment over the per-script maxima.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) owns the duration values in `portable_parallel_weight_hints` and the ordered memberships beside `list_portable_parallel_1`, `list_portable_parallel_2`, and `list_portable_parallel_3`.
Shard 1 retains `tests/fm-pi-primary-types.test.sh` because its CI job installs the Pi package required by that test.

| Lane | Packed estimate |
|---|---:|
| `portable-parallel-1` | 445438 ms (7m25s) |
| `portable-parallel-2` | 445444 ms (7m25s) |
| `portable-parallel-3` | 445425 ms (7m25s) |

The largest packed estimate is 34556 ms below the eight-minute target.
The target was seven minutes until upstream's 2026-09-30 hint refresh, whose longer samples put the best three-lane split at about 445 s.
`bin/fm-test-run.sh --check-coverage` enforces that the largest estimate stays below 480000 ms and reports the largest-minus-smallest lane difference.
[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh) verifies that all three lanes are fully hinted, below eight minutes, and within five percent of each other.
The largest individual hint is 347610 ms for `tests/fm-captain-hold-lifecycle.test.sh`, which is the indivisible floor for a three-way split.
These estimates do not guarantee job wall time if a script outgrows its observed samples.
The ten-minute CI cap and its rationale remain owned by [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

Refresh `portable_parallel_weight_hints` with the slowest successful `duration_ms` per script from several recent runs where all parallel jobs completed:

```sh
for run in <run-id> <run-id> <run-id>; do
  mkdir -p "/tmp/fm-parallel/$run"
  for shard in 1 2 3; do
    npx -y gh-axi run download "$run" \
      --name "fm-test-timing-portable-parallel-$shard" \
      --dir "/tmp/fm-parallel/$run" \
      --repo=yelenplays/firstmate
  done
done
jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' /tmp/fm-parallel/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A cancelled lane may not produce an artifact, so do not treat its elapsed job time as a successful sample.
Collect completed per-script measurements for every member before calculating a split.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
[Verification inputs](#verification-inputs) owns the measurement provenance and exceptions.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
`bin/fm-test-run.sh --check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`.
That catches missing hints, not stale existing hints: the host suite still had a 41512 ms hint after growing to over 1000 seconds in CI, so the old split placed it beside another 12 minutes of work while passing the guard.
Refresh the hints whenever a serial member grows materially or the lane gains scripts, rather than waiting for missing-hint coverage to trip.
The two history test scripts are provisionally seeded with local green measurements because no CI timing artifacts exist for them yet; replace both with the slowest successful CI sample at the next refresh.
These provisional values are balance inputs only and are not presented as CI evidence.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size and coverage rather than a copied inventory.
Its header and `--help` own the modeled-budget check and output fields; read the current estimates from `--check-coverage` instead of retaining copied lane sums here.
[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_serial_packing_budget_boundary`, verifies acceptance exactly at the budget and refusal one millisecond above it through the executable runner.
The longest script, `tests/fm-watch-triage.test.sh`, is the indivisible floor for this layout.
The estimates use per-file maxima from different runs, not measured rebalanced jobs or an end-to-end latency guarantee.
The baseline watch-triage samples range from 944375 to 1074843 ms, while each observed completed portable job adds at most 30 seconds beyond its summed scripts in these runs.
Even so, maxima from five runs do not establish a P95 or guarantee future headroom.
Job timeouts remain hang tripwires under the policy in [Timeouts](#timeouts) below; they are not the desired healthy duration.
`tests/fm-ci-workflow.test.sh` compares the parsed CI matrix to the executable runner lanes, and the runner rejects parallel `--jobs` on a serial lane even when that shard has only one member.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs and replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh-axi run download "$run" -R kunchenguid/firstmate --dir "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/fm-test-timing-portable-serial-*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard may upload no artifact, so include a complete green run or the slowest scripts go unmeasured in exactly the shard that needs them most.
Completed shards from a partial run can supplement that complete baseline, but never treat missing tail scripts or the timeout duration as successful samples.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that all three parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
Its hint-coverage and modeled-budget checks are described in [Portable serial CI shards](#portable-serial-ci-shards); neither replaces inspection of actual CI timing artifacts.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Lint partitions and end-to-end latency

`bin/fm-lint.sh` owns two canonical CI partitions, each running full source-aware ShellCheck analysis, workflow validation, and backend-purity checks.
CI requires its per-root bounds, so an unenforceable deadline or address-space limit refuses lint rather than running uncapped; the script header owns the envelope and per-root execution contract.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots and unchanged analysis flags.
The workflow uploads each partition's quiet telemetry plus its per-root lifecycle sidecar to distinguish analysis cost, memory use, and host contention.
No fast mode, path skips, reduced checks, or paid runner provisioning is part of this layout.

The longer-term performance objective remains a complete green run under fifteen minutes including start delay, but the current watch-triage floor alone exceeds that objective.
The immediate packing target is the runner's modeled script budget, not a claim that more shards alone can make an indivisible script faster.
The layout uses fifteen long-lived Linux jobs (nine serial, three parallel, Herdr, two lint), plus short checks and macOS; insufficient shared account capacity can erase the packing gain.
Compare complete before/after runs, preserve cancelled and partial-run evidence, and measure a representative normal-run sample before claiming a P95 improvement.
The workflow retains per-PR supersession without cancelling main pushes or changing the compliance workflow's event semantics.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

CI job timeouts follow one three-tier policy, so the workflow reads as a policy rather than as a collection of per-job numbers.
Every tier is a hang tripwire with headroom above the healthy duration, never a packing estimate or a runtime target.
A lane that reaches its tier bound needs investigation and a distribution or runtime fix, not a larger timeout to fit the same work.

| Tier | Jobs | Bound | Rationale |
|---|---|---|---|
| Fast | coverage guard, repo invariants, timing aggregate | 5 minutes | Seconds-long local work, so the tripwire only catches a hung runner. |
| Normal | lint partitions, portable parallel shards, portable serial shards, macOS stock Bash | 30 minutes, one value shared by every job in the tier | One shared hang tripwire keeps every ordinary test and lint lane on the same policy instead of allowing per-lane packing estimates or one-off caps to set the bound. |
| Heavy | Herdr | family-run step 20 minutes under a 75-minute job-level last-resort backstop | Healthy runs finish in about 7-10 minutes, so the step tripwire fails a wedged suite while the `always()` cleanup and timing upload still run, and the job cap only catches a hang outside that step. |

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) holds the executable values and names each job's tier beside its `timeout-minutes`.
[`tests/fm-ci-workflow.test.sh`](../tests/fm-ci-workflow.test.sh) holds the policy against the parsed workflow: every job belongs to exactly one tier, the workflow carries exactly three distinct job-level values, the fast tier stays within 5-10 minutes, the normal jobs share one 30-minute budget, and the Herdr family-run step is the 20-minute tripwire below its job backstop with an `always()` teardown after it.
A passing coverage guard does not establish a healthy job duration; refresh the healthy figures above from the lanes' uploaded timing artifacts.
