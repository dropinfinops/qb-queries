# Over-Provisioned Capacity — Utilization Ratio

> **Known design limitation.** This query is included for reference and community review,
> but has a known semantic issue with FOCUS 1.0 data. Read the limitations section before
> running in production.

**Pattern:** Resources where average consumed quantity is less than 30% of priced quantity
over a 30-day window — a signal for committed capacity where actual consumption is a
fraction of what was provisioned.

## Run it

From the `./run.sh` prompt. Three acts, each answering a different question:

```sql
.read queries/over-provisioned-capacity/preflight.duckdb.sql    -- CHECK: can this data answer the question?
.read queries/over-provisioned-capacity/diagnostic.duckdb.sql   -- LEARN: the ranked field, rules as pass/fail flags
.read queries/over-provisioned-capacity/query.duckdb.sql        -- TRUST: what actually fires
```

Against the sample bill the detector returns **2 rows**. Run
`python3 tools/verify_corpus.py` to check every pattern at once.

**Reading a zero row.** Zero rows with every preflight check `PASS` is a real, honest zero —
the bill is clean on this pattern. Zero rows with any check `FAIL` means the data cannot
answer the question at all, which is a blind spot, not a clean bill.

## What this detects (intent)

Reserved Instance or Savings Plan capacity that was purchased for a workload which has since
scaled down or been terminated. The commitment billing continues at the committed rate while
actual consumption is a small fraction of the provisioned quantity.

## Known design limitation

In FOCUS 1.0, `consumedquantity` and `pricingquantity` are both measured in their
respective units per billing row. For the majority of standard on-demand usage rows, the
ratio `consumedquantity / pricingquantity` is approximately 1.0 — not because utilization is
high, but because both fields measure the same thing at the same unit scale.

The ratio is meaningfully sub-1.0 only for:
- Reserved Instance rows where a committed hour is partially matched to a running instance
- Services where the consumed unit and pricing unit differ by a fixed block size

This means on-demand EC2 instances at low CPU utilization will typically NOT appear in
results, because they bill for the hours they ran (consumedquantity = pricingquantity = hours
running). The query is most useful for committed/reserved capacity rows specifically.

**For a more reliable commitment waste signal, use Commitment Loss (Commitment Loss)**, which uses
`CommitmentDiscountStatus = 'Unused'` rows directly.

## Key output columns

| Column | Meaning |
|---|---|
| `avg_utilization_ratio` | avg(consumedquantity / pricingquantity) — < 0.30 to fire |
| `consumedunit` | The unit the ratio is expressed in |
| `days_seen` | Must be ≥ 7 days to reduce transient noise |

## Notes

- Storage units (`GB-Mo`, `GB`, `GiB-Mo`, etc.) are excluded because storage billing
  mechanics produce different ratio semantics than compute.
- This query is deferred from the active DropInFinOps detector set pending a redesign.
  Contributions and design suggestions welcome.
