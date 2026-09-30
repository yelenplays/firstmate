# report-only: measurements.csv row count and value sum

## Conclusion
`measurements.csv` holds **2 data rows** (plus 1 header row), and those values add up to **3**.

## What I did
I read `measurements.csv` in the task worktree
(`.../projects/sample/.treehouse/sample-3c822b/1/sample/measurements.csv`). I did the scratch
calculations in `scratch-notes.txt` in that same worktree. That file is scratch only and is
not a deliverable.

## Evidence
File contents (`cat -A`, which shows LF line endings, no CR characters and no trailing blank line):

```
item,value$     <- line 1: header
b,2$            <- line 2
a,1$            <- line 3
```

Commands and output:

```
$ wc -l measurements.csv
3 measurements.csv                      # 1 header + 2 data rows

$ tail -n +2 measurements.csv | wc -l
2

$ tail -n +2 measurements.csv | awk -F, '{s+=$2} END{print s}'
3
```

- `measurements.csv:2`: `b,2`
- `measurements.csv:3`: `a,1`
- Sum = 2 + 1 = 3

## Notes
- The rows are not sorted by `item` (`b` comes before `a`). This does not affect the count or the sum.
- Every value is an integer, and no fields are missing or malformed.

## Recommendation
None. The figures are simple to state: 2 rows, sum 3. Nothing needs to ship, and no decision is waiting on the captain.
