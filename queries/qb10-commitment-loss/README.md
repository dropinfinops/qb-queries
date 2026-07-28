# QB10 — Commitment Loss

**Pattern:** A Reserved Instance, Savings Plan, or Committed Use Discount has started
generating significantly more `Unused` spend relative to `Used` spend in the last 7 days
compared to its prior 30-day baseline. The waste ratio is deteriorating.

## Run it

From the `./run.sh` prompt. Three acts, each answering a different question:

```sql
.read queries/qb10-commitment-loss/preflight.duckdb.sql    -- CHECK: can this data answer the question?
.read queries/qb10-commitment-loss/diagnostic.duckdb.sql   -- LEARN: the ranked field, rules as pass/fail flags
.read queries/qb10-commitment-loss/query.duckdb.sql        -- TRUST: what actually fires
```

Against the sample bill the detector returns **1 row**. Run
`python3 tools/verify_corpus.py` to check every pattern at once.

**Reading a zero row.** Zero rows with every preflight check `PASS` is a real, honest zero —
the bill is clean on this pattern. Zero rows with any check `FAIL` means the data cannot
answer the question at all, which is a blind spot, not a clean bill.

## What this detects

Commitment loss is an inverse anomaly — the commitment fee stays fixed while the usage it
covers shrinks. The total bill may actually decrease (the workload consuming on-demand
capacity is gone), while the commitment quietly burns to waste at 60–100% unused.

Two failure modes:

**Cliff** — A workload is decommissioned, migrated to a different instance family, or moved
to containers. Utilization drops sharply within a 7-day window. The commitment continues
billing at the committed rate.

**Drift** — Gradual right-sizing, seasonal headcount reduction, or incremental workload
migration. Utilization declines 2–5 percentage points per week. Each individual week looks
unremarkable, but the 7-day-vs-30-day delta accumulates until it crosses the threshold.

## What a hit means

The `waste_ratio_delta` column shows how much the unused fraction has worsened. A delta of
`0.30` means 30 percentage points more of the commitment spent on unused rows this week vs
the prior 3-week average — a significant shift.

`is_stranded = 1` means zero `Used` rows in the last 7 days. The commitment has no matching
workload at all.

Typical fix: sell or exchange the commitment (AWS allows marketplace RI listings), modify
the instance family, or right-size a replacement workload to absorb the commitment before
it expires.

## Key output columns

| Column | Meaning |
|---|---|
| `recent_waste_ratio` | Fraction of 7-day commitment spend going to Unused rows |
| `baseline_waste_ratio` | Fraction of prior 30-day commitment spend going to Unused rows |
| `waste_ratio_delta` | recent − baseline: how much worse the waste has gotten |
| `is_stranded` | 1 if zero Used rows in the last 7 days |
| `total_unused_37d` | Total unused commitment cost over the full 37-day window |

## Notes

- Requires `CommitmentDiscountStatus` field populated with `'Used'` and `'Unused'` values.
  AWS populates this via Data Exports; Azure and GCP support varies by export version.
- The 37-day window in `daily_commitment` (= 30-day baseline + 7-day recent window) is
  required because both windows are computed from the same CTE.
- For a utilization-ratio approach using `consumedquantity / pricingquantity`, see QB04
  (with its documented limitations).
