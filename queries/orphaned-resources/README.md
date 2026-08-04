# Orphaned Resources — Waste

**Pattern:** A resource is being charged at its normal rate while delivering little or no
measurable consumption. The bill keeps coming; the workload has effectively stopped.

## Run it

From the `./run.sh` prompt. Three acts, each answering a different question:

```sql
.read queries/orphaned-resources/preflight.duckdb.sql    -- CHECK: can this data answer the question?
.read queries/orphaned-resources/diagnostic.duckdb.sql   -- LEARN: the ranked field, rules as pass/fail flags
.read queries/orphaned-resources/query.duckdb.sql        -- TRUST: what actually fires
```

Against the sample bill the detector returns **1 row**. Run
`python3 tools/verify_corpus.py` to check every pattern at once.

**Reading a zero row.** Zero rows with every preflight check `PASS` is a real, honest zero —
the bill is clean on this pattern. Zero rows with any check `FAIL` means the data cannot
answer the question at all, which is a blind spot, not a clean bill.

## What this detects

Two sub-patterns share the same root cause — cost without consumption:

| Signal | Condition | Typical root cause |
|---|---|---|
| `configured_forgotten` | ConsumedQuantity near-zero for 5+ of last 30 days | Reserved Instance or Savings Plan commitment still billing after the workload was terminated or migrated |
| `over_provisioned` | Average daily quantity < 10% of average daily cost | Committed capacity where actual consumption is a small fraction of what was provisioned |

Both require the resource to be above the minimum cost floor so trivially small line items
are excluded.

## What a hit means

A `configured_forgotten` result is a strong indicator that a commitment (RI, Savings Plan,
or reserved capacity) is running untouched. The fix is typically: identify the commitment,
verify no matching workload exists, then sell, exchange, or wait out the term.

An `over_provisioned` result means the resource is running but at a much lower utilization
than its provisioned size suggests. The fix is usually right-sizing or instance family
migration.

## Key output columns

| Column | Meaning |
|---|---|
| `near_zero_qty_days` | How many of the last 30 days had ConsumedQuantity < 0.01 |
| `avg_daily_qty` | Average daily consumption — low relative to cost indicates waste |
| `total_cost` | 30-day billed cost — sort by this to prioritize |
| `waste_signal` | `configured_forgotten` or `over_provisioned` |

## Notes

- The `near_zero_qty_days >= 5` threshold is intentionally permissive. Resources idle for 5
  of 30 days may include legitimate batch jobs with long gaps. Raising the threshold to 10+
  reduces false positives from seasonal or intermittent workloads.
- The `over_provisioned` path is unit-dependent: it compares quantity (in the service's
  native units) to cost (in USD). It is a reliable signal for RI/SP waste and request-based
  services with minimum charges; it is less reliable for time-based services where quantity
  naturally produces large numbers.
