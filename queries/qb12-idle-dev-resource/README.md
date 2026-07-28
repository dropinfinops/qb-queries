# QB12 — Idle Developer Resource

**Pattern:** A resource is used almost exclusively during weekday business hours (consumption
ratio 5:1 or more, weekday vs. weekend) but billed at the same flat rate 24/7. The billing
clock never stops; the developer goes home on Friday and the meter runs all weekend.

## Run it

From the `./run.sh` prompt. Three acts, each answering a different question:

```sql
.read queries/qb12-idle-dev-resource/preflight.duckdb.sql    -- CHECK: can this data answer the question?
.read queries/qb12-idle-dev-resource/diagnostic.duckdb.sql   -- LEARN: the ranked field, rules as pass/fail flags
.read queries/qb12-idle-dev-resource/query.duckdb.sql        -- TRUST: what actually fires
```

Against the sample bill the detector returns **1 row**. Run
`python3 tools/verify_corpus.py` to check every pattern at once.

**Reading a zero row.** Zero rows with every preflight check `PASS` is a real, honest zero —
the bill is clean on this pattern. Zero rows with any check `FAIL` means the data cannot
answer the question at all, which is a blind spot, not a clean bill.

## What this detects

Cloud VMs and compute resources bill by the instance-hour regardless of CPU utilization or
actual user activity. A developer VM used 8 hours per weekday still bills for all 168 hours
in a week. At least 65% of clock-hours in a month are nights and weekends — for a resource
with no weekend workload, that is 65% of the bill generating zero value.

The query identifies resources where weekday `consumedquantity` (API calls, instance-hours,
units of work) is more than 5× the weekend quantity, but the weekend bill is still 70% or
more of the weekday bill. The gap between activity and billing is the waste signal.

## What a hit means

The resource has a clear business-hours usage pattern but no shutdown policy. Implementing
scheduled stops/starts (e.g. AWS Instance Scheduler, Azure Start/Stop VMs, GCP scheduled
actions) outside business hours could recover 60–70% of the monthly cost for these
resources while maintaining full developer productivity during work hours.

## Key output columns

| Column | Meaning |
|---|---|
| `weekday_weekend_qty_ratio` | How many times more active the resource is on weekdays vs weekends — higher = stronger scheduling signal |
| `weekend_billing_ratio` | Weekend cost / weekday cost — close to 1.0 means billing is nearly flat despite low activity |
| `total_cost_30d` | 30-day total using `effectivecost` — sort by this to prioritize savings opportunity |

## Notes

- Uses `effectivecost` (post-discount, commitment-adjusted cost) rather than `billedcost`,
  which better reflects actual financial exposure for resources covered by RIs or Savings
  Plans.
- `DAY_OF_WEEK()` returns 1=Monday … 7=Sunday in Trino/Presto (ISO 8601). Adjust for
  BigQuery/MySQL where 1=Sunday … 7=Saturday.
- The `days_seen >= 21` requirement filters out resources with sparse billing history where
  a weekday/weekend pattern cannot be reliably measured.
- This pattern is related to but distinct from QB07 (Scheduling Miss): QB07 looks at
  absolute weekend cost relative to weekday cost. QB12 looks at activity-to-cost
  efficiency — a resource can pass QB07 (low weekend cost) but fail QB12 (activity is
  zero, cost is still 70% of weekday).
