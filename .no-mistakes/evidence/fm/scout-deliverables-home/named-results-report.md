# named-results: measurements.csv investigation

## What I did
- Read the input `measurements.csv` in the task worktree
  (`.l.FkmYln/projects/sample/.treehouse/sample-3c822b/1/sample/measurements.csv`).
- Sorted the data rows by `item` and kept the header:
  `{ head -1 measurements.csv; tail -n +2 measurements.csv | LC_ALL=C sort -t, -k1,1; } > results.csv`
- Wrote `report.html` with the same two-row table, then copied `results.csv` and `report.html` into this directory.
- Kept temporary notes in `scratch-notes.txt` in the worktree only. It is not a deliverable, so I didn't copy it here.

## Findings
The input has a header and two data rows, and they are not in sorted order:

```
measurements.csv:1  item,value
measurements.csv:2  b,2
measurements.csv:3  a,1
```

After sorting by item (`results.csv`):

| item | value |
|------|-------|
| a    | 1     |
| b    | 2     |

- 2 rows, no duplicate items, no missing or non-numeric values.
- Sorting leaves every item/value pair intact. It only reverses the row order (b and a swap places).
- Total of values = 3, mean = 1.5.

## Deliverables (in this directory)
- `results.csv`: the header plus rows `a,1` and `b,2`, sorted by item.
- `report.html`: an HTML table with the same two rows, a/1 then b/2.
- `report.md`: this report.

No PDF was requested, so none was produced.

## Recommendation
Nothing needs to ship and nothing is waiting on the captain. The data is clean, and the only change was putting the rows in order.
