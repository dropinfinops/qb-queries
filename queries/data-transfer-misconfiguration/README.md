# Data Transfer Misconfiguration

**Pattern:** Networking costs are disproportionate to compute costs for the same account —
a signature of architecture-level data routing inefficiencies that compound silently as
traffic grows.

## Run it

From the `./run.sh` prompt. Three acts, each answering a different question:

```sql
.read queries/data-transfer-misconfiguration/preflight.duckdb.sql    -- CHECK: can this data answer the question?
.read queries/data-transfer-misconfiguration/diagnostic.duckdb.sql   -- LEARN: the ranked field, rules as pass/fail flags
.read queries/data-transfer-misconfiguration/query.duckdb.sql        -- TRUST: what actually fires
```

Against the sample bill the detector returns **3 rows**. Run
`python3 tools/verify_corpus.py` to check every pattern at once.

**Reading a zero row.** Zero rows with every preflight check `PASS` is a real, honest zero —
the bill is clean on this pattern. Zero rows with any check `FAIL` means the data cannot
answer the question at all, which is a blind spot, not a clean bill.

## What this detects

Two sub-patterns with a shared root cause: traffic taking an expensive path when a free or
cheaper path exists:

**NAT Gateway over-processing (`nat_ratio > 0.60`):** NAT Gateway byte-processing charges
are more than 60% of total VPC cost. This indicates high-volume traffic (often to S3 or
DynamoDB) is routing through NAT Gateway at $0.045/GB when free Gateway VPC Endpoints would
cost $0.00/GB. The fix is adding Gateway VPC Endpoints for S3 and DynamoDB, routing private
subnet traffic directly without the NAT Gateway.

**Cross-AZ traffic (`cross_az_ratio > 0.12`):** Cross-Availability-Zone transfer costs are
more than 12% of compute cost. This indicates application components (app servers, databases,
caches, Kubernetes pods) are deployed in different AZs, paying $0.02/GB round-trip on every
request. The fix is co-locating resources within the same AZ, or using topology-aware routing
in Kubernetes.

## What a hit means

Unlike most other patterns here, data transfer misconfiguration is not a spike. It is
persistent, proportional cost waste baked into the architecture at deployment time. The cost
accumulates at a fixed ratio to traffic volume — as the application grows, so does the waste.

A single NAT Gateway handling S3 backup traffic for multiple teams can easily generate
$200–$500/month in avoidable charges. Cross-AZ microservice architectures have generated
thousands per month in cases where all inter-service calls cross AZ boundaries.

## Key output columns

| Column | Meaning |
|---|---|
| `nat_ratio` | NAT byte-processing cost / total NAT cost — >0.60 suggests traffic should use VPC Endpoints |
| `cross_az_ratio` | Cross-AZ transfer cost / EC2 cost — >0.12 suggests AZ alignment issue |
| `total_networking_waste_30d` | Combined NAT bytes + cross-AZ cost estimate over 30 days |

## Notes

- This query uses `x_usagetype` (a provider-specific column) to classify networking line
  items. The usage type strings are provider-specific: AWS uses `NatGateway-Bytes`,
  `DataTransfer-Regional-Bytes`; Azure uses `VNet Peering`; GCP uses
  `Network Inter Zone Data Transfer Out`. The query includes patterns for all three but was
  calibrated primarily against AWS billing patterns.
- Results are aggregated at the account (`subaccountid`) level, not per-resource, because
  NAT Gateway costs appear against the NAT resource while the traffic generating them comes
  from many resources across the account.
- The `$100` 30-day floor suppresses noise for small accounts with low absolute networking
  spend. Lower this threshold for small accounts or raise it for very large ones.
