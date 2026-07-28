# QB03 — Runaway Cost Acceleration

**Pattern:** A resource has been running above 1.5× its historical baseline for at least
4 of the last 7 days. Something changed and nobody fixed it.

## Run it

From the `./run.sh` prompt. Three acts, each answering a different question:

```sql
.read queries/qb03-runaway-cost-acceleration/preflight.duckdb.sql    -- CHECK: can this data answer the question?
.read queries/qb03-runaway-cost-acceleration/diagnostic.duckdb.sql   -- LEARN: the ranked field, rules as pass/fail flags
.read queries/qb03-runaway-cost-acceleration/query.duckdb.sql        -- TRUST: what actually fires
```

Against the sample bill the detector returns **11 rows**. Run
`python3 tools/verify_corpus.py` to check every pattern at once.

**Reading a zero row.** Zero rows with every preflight check `PASS` is a real, honest zero —
the bill is clean on this pattern. Zero rows with any check `FAIL` means the data cannot
answer the question at all, which is a blind spot, not a clean bill.

## What this detects

QB03 fires on persistence, not magnitude. A 10× spike for 2 days is QB02's domain. QB03
catches the "nobody looked at this" scenario: costs elevated for most of the week.

Two real-world onset profiles both fire this pattern:

**Step-function runaways** — ECS/Lambda/Cloud Run events that spike within hours, exceed
the 1.5× threshold, and remain elevated because no one noticed or acted. If QB02 fires
first and the issue isn't fixed, QB03 confirms it by day 4.

**Gradual-ramp runaways** — storage autoscaling, deployment drift, incremental capacity
additions. Each day is only slightly more expensive than the last. No single day triggers
QB02. But looking back over a week, the resource has been above 1.5× baseline every day.
This is the class of issue that goes unnoticed for months: a $15/day resource slowly
climbing to $39/day over a billing period.

## What a hit means

A `high_days = 7` result means every day this week cost more than 1.5× the prior 3-week
average. The question to answer: was there a deployment, configuration change, or traffic
event that explains the elevation? If not, investigate for misconfigured autoscaling or
gradual resource accumulation.

## Key output columns

| Column | Meaning |
|---|---|
| `high_days` | How many of the last 7 days exceeded 1.5× baseline (4 minimum to fire) |
| `pct_above_baseline` | Percentage above the baseline average |
| `cost_ratio` | avg_recent_cost / avg_baseline_cost |
| `stddev_recent_cost` | Cost variance in the recent window — low stddev with high pct_above_baseline means the elevation is consistent, not volatile |

## Notes

- The baseline window is days −30 to −7. This means if a spike has been running for 2+
  weeks, it partially contaminates the baseline, reducing the detected ratio. Both QB02
  and QB03 may underreport magnitude for long-running incidents.
- `high_days >= 4` (4 of 7 days) means the pattern fires even with a weekend gap for
  resources that are legitimately idle on weekends. See QB07 (Scheduling Miss) for
  resources where the weekend idle pattern is the signal itself.
