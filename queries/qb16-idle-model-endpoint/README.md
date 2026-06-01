# QB16 — Idle Model Endpoint

**Pattern:** A SageMaker real-time inference endpoint is billing for instance-hours while
receiving fewer than 100 invocations in 7 days. The model is deployed, the meter is
running, and nobody is calling it.

## What this detects

SageMaker real-time inference endpoints have a fundamental billing property: they cannot
scale to zero. Auto Scaling can reduce the minimum instance count to 1, but the moment that
one instance is running, it generates instance-hour charges at the full rate — regardless of
whether any predictions are requested. A GPU-backed endpoint left idle after a demo or
experiment can cost $70–$170/day indefinitely.

The query detects this by joining two distinct billing row types: endpoint instance-hour
rows (the cost) against invocation count rows (the activity). An endpoint with $10+ in
7-day cost and fewer than 100 total invocations in that same window is idle by any
reasonable definition — real serving workloads receive 100–10,000+ invocations per day.

## What a hit means

An endpoint that has generated cost but almost no traffic in the last 7 days should
typically be deleted. Common causes: post-demo cleanup was skipped, an A/B test concluded
without removing the challenger endpoint, or a project ended and the team forgot the
endpoint was still running.

The `projected_monthly_cost` column shows what the endpoint will cost if left in its current
state for a full month. For GPU instances, this is typically $2,000–$5,000/month for a
single idle endpoint.

## Key output columns

| Column | Meaning |
|---|---|
| `idle_tier` | `ZERO_TRAFFIC` (0 invocations), `NEAR_ZERO_TRAFFIC` (<10), or `LOW_TRAFFIC` (<100) |
| `endpoint_hours_7d` | Instance-hours billed in the 7-day window |
| `hourly_rate` | Hourly billing rate — GPU instances are $3–$6/hr, CPU instances are $0.05–$0.30/hr |
| `projected_monthly_cost` | 7-day cost extrapolated to 30 days if no action is taken |

## Notes

- AWS-specific: uses `x_usagetype LIKE '%Hosting%'` and `x_usagetype LIKE '%Invocations%'`.
  `x_usagetype` is an AWS Data Exports extension, not a FOCUS 1.0 standard field.
- The LEFT JOIN means an endpoint with no invocation rows at all still appears, with
  `total_invocations_7d = 0` (the `ZERO_TRAFFIC` case). This is the most common pattern for
  truly forgotten endpoints.
- The `$10` cost floor catches any GPU endpoint (lowest GPU rate is ~$1.50/hr × ~7 hours/
  day = ~$10/day minimum), while excluding trivially small CPU micro-instances.
- For non-real-time workloads, consider switching to SageMaker Async Inference or
  Serverless Inference, which have built-in scale-to-zero behavior.
