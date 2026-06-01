# QB04 — Utilization Ratio

> **Known design limitation.** This query is included for reference and community review,
> but has a known semantic issue with FOCUS 1.0 data. Read the limitations section before
> running in production.

**Pattern:** Resources where average consumed quantity is less than 30% of priced quantity
over a 30-day window — a signal for committed capacity where actual consumption is a
fraction of what was provisioned.

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

**For a more reliable commitment waste signal, use QB10 (Commitment Loss)**, which uses
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
