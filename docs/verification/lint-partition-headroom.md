# Lint timeout: partition capacity, not token-burn analysis growth

## Evidence

The failed run is `38936930893`, attempt 2, at `cb2c7994`.
The successful main comparison is `38937179705`, at `3a9eb4b3`.
Both used Ubuntu image `20261012.334.1`, ShellCheck 0.11.0, full
source-following analysis, one concurrent root, a 1,200-second root deadline,
and a 20-GiB address-space limit.

The retained `fm-lint-roots-v1` artifacts contain executable root lifecycle
records, not estimates from source text. The original supplied evidence covered
partition 1; partition 2 artifacts from both runs complete the comparison:

```bash
gh-axi run download 38936930893 --repo yelenplays/firstmate \
  --name fm-lint-telemetry-2 --dir <branch-evidence-directory>
gh-axi run download 38937179705 --repo yelenplays/firstmate \
  --name fm-lint-telemetry-2 --dir <main-evidence-directory>
```

| Run | Partition | Completed roots | Sum of root durations |
| --- | --- | ---: | ---: |
| main | 1 | 299 | 1,728.391 s |
| main | 2 | 299 | 1,208.793 s |
| branch | 1 | 286, then cancellation | 1,807.529 s |
| branch | 2 | 299 | 1,102.816 s |

Main partition 1 took 28m58s end to end. Branch partition 1 was cancelled
at the 30-minute job limit, with `tests/fm-tmux-agent-liveness.test.sh`
begun but unfinished. The inventory is 598 roots on both revisions.

## Causal isolation

`4055cbd6` introduced two canonical CI partitions using largest-first greedy
packing of **direct file bytes**, with inventory-index tie breaking.
`503ba82b` later changed analysis to bounded, per-root processes, eventually
one concurrent process per runner. It retained byte-based cross-runner packing.
Bytes balance storage, not ShellCheck's source-following/dataflow work.

Replay the historical inventory and byte sizes from `git ls-tree -rl <ref>`
through that packing rule. Both main partitions exactly match their artifact
membership. The branch's second partition also matches exactly; its first
contains every begun root plus the roots not reached before cancellation.
Its byte loads differ by just seven bytes: 10,147,483 versus 10,147,490.
Nevertheless, its analysis loads are very different.

For a controlled comparison, hold every root's analysis cost constant: use its
branch duration when completed, otherwise its main duration. Only 13 roots
need the main observation. No root lacks a measured cost.

| Byte-size inputs, same 598 roots and same costs | Partition 1 | Partition 2 |
| --- | ---: | ---: |
| successful main `3a9eb4b3` | 1,581.180 s | 1,349.183 s |
| PR base `8045dac2` | 1,694.404 s | 1,235.959 s |
| branch `cb2c7994` | 1,827.547 s | 1,102.816 s |

The smallest isolated trigger is the **two-byte** increase in
`bin/fm-cross-review.sh` (`high` to `medium`). Substituting only that weight
into the base inventory, without changing any analysis cost, moves 220 roots
between runners. Partition 1 rises from 1,694.404 to 1,849.199 seconds.
This is sufficient to cross the job deadline. It does not mean the required
medium-effort change should be reverted: any small edit can change greedy
assignment downstream. The complete branch moves 368 roots relative to the
successful main partitioning.

Disconfirming evidence:

- Across all 585 roots completed in both runs, aggregate branch analysis time
  is **6.821 seconds lower**, not higher. The original partition-1-only
  comparison had only 110 shared completed roots; it was not a full cost
  comparison.
- Individual roots do vary: the largest increase across both partitions is
  14.955 seconds for `tests/fm-stat-shadowing.test.sh`. Thus the evidence does
  not establish zero per-root variation, but a generalized source-graph
  slowdown cannot explain the aggregate timeout.
- Main partition 1's measured roots consume 1,728.391 seconds of its 1,738-second
  step. Branch completed roots alone consume 1,807.529 seconds. Setup or
  telemetry overhead is not the dominant cost.
- A local Darwin full-source timing attempt was stopped after 20 minutes,
  with only 18 previously unmeasured roots completed. It did not enforce the
  Linux address-space envelope and is **not** mixed into the Linux estimates.

## Fix and headroom

Use three canonical CI partitions. This is the smallest runner-count increase;
it retains the existing byte-packing rule rather than adding a timing database,
new generator, or hand-tuned assignment. No generated data changes.

The executable `--partition Nof3 --list-files` output at this fix selects
200, 199, and 199 roots, complete and disjoint. Replaying the same observed costs
through those actual selected inventories gives:

| Partition | Latest observed costs | Main costs only | Maximum observed cost per root |
| --- | ---: | ---: | ---: |
| 1 | 1,005.897 s | 1,011.960 s | 1,070.346 s |
| 2 | 1,222.767 s | 1,234.354 s | 1,285.037 s |
| 3 | 701.699 s | 690.870 s | 735.134 s |

Even the conservative maximum-of-both-runs replay fits a 24-minute analysis
packing target. Its slowest partition takes 21m25s, leaving 8m35s of the
unchanged 30-minute job for installation, variation, workflow validation,
and artifact upload. These
are trace replays, **not a newly completed hosted CI run**, and byte packing
still cannot guarantee future runtime balance. Future growth must be measured
again, not disguised with whitespace changes that reshuffle the queues.

`Lint 1` and `Lint 2` keep their names; `Lint 3` is added. ShellCheck/actionlint
pins, analysis flags, full canonical coverage, memory fallback policy, root
bounds, and `FM_LINT_JOBS=1` in CI are unchanged. Local two-worker scheduling is
unchanged. Raising the timeout alone would retain the imbalance; enabling two
concurrent roots would violate the runner's memory-sizing rationale. Neither
is needed.

## Behavioral verification

- `bash tests/fm-ci-workflow.test.sh` executes the workflow's interpolated lint
  step against the real owner with a deterministic virtual-cost analyzer. A
  skewed workload that exceeds 32 minutes with two runners must fit an 80%-of-
  timeout packing budget, without dropping or duplicating a root. The test
  failed before the fix and passes with three partitions. It uses no sleeps
  or live model calls.
- `bash tests/fm-lint.test.sh` proves that each listed partition equals its
  executed roots, the union equals the full canonical inventory exactly once,
  full analysis/source-following flags remain set, and weakened or mismatched
  partition requests are refused. Existing deterministic-worker, fallback,
  diagnostics, cleanup, and local-mode regressions pass. Four Linux-envelope
  tests skip on Darwin because that host cannot enforce `ulimit -v`; the
  refusal test passes.
- Pinned ShellCheck passes on all three changed shell files. Pinned actionlint
  validates all three workflow files; shell syntax and `git diff --check` pass.
