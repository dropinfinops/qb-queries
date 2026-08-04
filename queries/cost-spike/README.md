# Cost Spike — Usage Spike

**Pattern:** A resource's cost in the last 3 days is more than double its own 30-day
historical baseline. Something changed recently and the bill reflects it.

## Run it

From the `./run.sh` prompt. Three acts, each answering a different question:

```sql
.read queries/cost-spike/preflight.duckdb.sql    -- CHECK: can this data answer the question?
.read queries/cost-spike/diagnostic.duckdb.sql   -- LEARN: the ranked field, rules as pass/fail flags
.read queries/cost-spike/query.duckdb.sql        -- TRUST: what actually fires
```

Against the sample bill the detector returns **6 rows**. Run
`python3 tools/verify_corpus.py` to check every pattern at once.

**Reading a zero row.** Zero rows with every preflight check `PASS` is a real, honest zero —
the bill is clean on this pattern. Zero rows with any check `FAIL` means the data cannot
answer the question at all, which is a blind spot, not a clean bill.

## What this detects

Cost spikes driven by increased consumption on an existing resource — not a price change,
not a new resource in a new region. Common root causes include runaway autoscaling triggered
by traffic bursts or attacks, Lambda recursion loops, accidental load tests pointed at
production, and data pipeline misconfigurations scanning far more data than intended.

The 2× threshold is deliberately high. AWS Cost Anomaly Detection alerts at ~40% deviation
by default; Cost Spike requires 100% (2×). This means Cost Spike catches major, actionable incidents
while skipping moderate daily variation.

## What a hit means

The resource cost today is at least double its recent normal. This warrants immediate
investigation: check deployment history, autoscaling activity, and traffic patterns for the
last 3 days.

## Key output columns

| Column | Meaning |
|---|---|
| `cost_acceleration_ratio` | avg_3d_cost / avg_30d_cost — how many times above baseline |
| `spike_strength` | Z-score: standard deviations above the 30-day mean. High values indicate the spike is statistically unusual for this resource. |
| `avg_early_15d_cost` vs `avg_recent_15d_cost` | If recent_15d > early_15d, spend was already trending up before the spike — may indicate growth rather than a sudden event |
| `stddev_30d_cost` | Baseline volatility. A high stddev means the resource has naturally variable cost; the z-score (`spike_strength`) adjusts for this. |

## Notes

- The 3-day recent window means the query fires on spikes that started up to 3 days ago,
  even if they have partially recovered.
- Month-end batch jobs that legitimately run at 3× baseline on the same days each period
  will trigger false positives. The `spike_strength` z-score helps distinguish statistical
  anomalies from seasonal patterns.
- If a spike has been running for more than ~2 weeks, it contaminates the 30-day baseline
  and the ratio drops below 2×. In that case Persistent Cost Overrun (Runaway) fires instead.
