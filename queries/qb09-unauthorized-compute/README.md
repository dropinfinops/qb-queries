# QB09 — Unauthorized Compute

**Pattern:** Spend appearing in a cloud region that this account has never used before.
New-region activity with no prior billing history is the billing-observable fingerprint of
credential compromise.

## What this detects

When an attacker obtains cloud credentials — via a leaked environment variable, a repository
secret, or an IAM misconfiguration — they typically launch compute in regions outside the
victim's normal operational footprint. This avoids colliding with existing workloads and
exploits the fact that most monitoring tools focus on established regions.

The detection logic is deliberately threshold-free: **any spend in a previously-unseen
region is anomalous**. The only legitimate false positive is a planned geographic expansion,
which is a coordinated, documented change — not a sudden simultaneous multi-region launch.

The query is scoped per `(subaccountid, regionid)` pair. A region that is established in
account A is not a signal in account A, but the same region appearing for the first time in
account B is flagged independently.

## What a hit means

A resource is billing in a region this account has never used in its entire billing history,
and that first activity appeared within the last 30 days. Treat this as a security incident
until proven otherwise: verify whether your team intentionally expanded into this region, and
if not, rotate credentials and audit IAM.

Common attacker patterns include launching GPU or compute-heavy instances for
cryptocurrency mining, running proxies, or using the account as infrastructure for other
attacks.

## Key output columns

| Column | Meaning |
|---|---|
| `regionid` | The region that first appeared in the last 30 days |
| `first_seen_date` | When the first billing row appeared for this account/region pair |
| `total_cost` | Accumulated cost in this new region |
| `x_usagetype` | (AWS extension) Usage type string — GPU instance types are a strong secondary signal for crypto mining |
| `tags` | Attacker-launched resources typically carry no workload attribution tags |

## Notes

- The 30-day lookback window means the query catches attacks that started within the last
  month. It will NOT catch a breach that began 35 days ago and is now ongoing.
- `x_usagetype` is an AWS provider extension. It is included as informational context only
  and does not affect detection logic.
- The `LIMIT 40` is intentionally higher than other queries because a single attack may
  launch resources in multiple new regions simultaneously — each shows as a separate row.
