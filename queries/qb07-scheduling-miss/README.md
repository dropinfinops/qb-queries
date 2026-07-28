# QB07 — Scheduling Miss

**Pattern:** A resource's weekend cost is at least 85% of its weekday cost — meaning it
barely reduces spend when the business is closed. Resources with weekday-only workloads
should show a clear weekend dip; the absence of that dip is the signal.

## Run it

From the `./run.sh` prompt. Three acts, each answering a different question:

```sql
.read queries/qb07-scheduling-miss/preflight.duckdb.sql    -- CHECK: can this data answer the question?
.read queries/qb07-scheduling-miss/diagnostic.duckdb.sql   -- LEARN: the ranked field, rules as pass/fail flags
.read queries/qb07-scheduling-miss/query.duckdb.sql        -- TRUST: what actually fires
```

Against the sample bill the detector returns **110 rows**. Run
`python3 tools/verify_corpus.py` to check every pattern at once.

> **This is a posture measure, not an alarm.** It describes a property of the whole estate
> rather than finding one thing that is wrong, so it returns many rows by design — 110 against
> the sample bill. It cannot know which of *your* resources were meant to be shut down or
> tagged. Read it as a list to triage. The query caps output at 25 rows; remove the `LIMIT`
> to see the full population.

**Reading a zero row.** Zero rows with every preflight check `PASS` is a real, honest zero —
the bill is clean on this pattern. Zero rows with any check `FAIL` means the data cannot
answer the question at all, which is a blind spot, not a clean bill.

## What this detects

Non-production environments, batch pipelines, and developer tooling that should follow a
shutdown schedule but don't. These resources run 24/7 and bill 24/7, even when no one is
using them on Saturday and Sunday.

The query requires at least 2 weekend days and 5 weekdays of observed data to reduce false
positives from resources with sparse billing history.

## What a hit means

A `weekend_weekday_ratio` near 1.0 means the resource costs almost as much on a Saturday
as a Tuesday. For a resource that serves business users only, this represents roughly 2 days
per week of unnecessary spend — about 29% of the monthly bill generating no business value.

Typical fix: implement a scheduling policy (e.g. AWS Instance Scheduler, Azure Start/Stop
VMs, GCP VM scheduled actions) to stop the resource outside business hours.

## Key output columns

| Column | Meaning |
|---|---|
| `weekend_weekday_ratio` | avg_weekend_cost / avg_weekday_cost — 1.0 means no scheduling, 0.0 means properly scheduled |
| `avg_weekend_cost` | Average daily cost on Saturdays and Sundays |
| `avg_weekday_cost` | Average daily cost Monday through Friday |
| `total_cost` | 30-day total — sort by this to prioritize by absolute savings opportunity |

## Notes

- The `DAY_OF_WEEK()` function returns 1=Monday … 7=Sunday in Trino/Presto (ISO 8601).
  BigQuery and MySQL return 1=Sunday … 7=Saturday — adjust the `dow IN (6, 7)` weekend
  check if running outside Trino/Presto/Athena.
- Data transfer rows are excluded from the cost comparison because egress charges accumulate
  based on outbound traffic, not on whether a scheduler is running. Including them would
  dilute the scheduling signal for compute resources.
- This pattern is distinct from QB12 (Idle Developer Resource): QB07 catches resources
  with high absolute weekend COST (batch jobs, always-on services). QB12 catches resources
  where weekend ACTIVITY (consumed quantity) is near-zero but billing remains flat.
