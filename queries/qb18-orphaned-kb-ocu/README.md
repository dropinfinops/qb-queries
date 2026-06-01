# QB18 — Orphaned Bedrock Knowledge Base OCU

**Pattern:** OpenSearch Serverless OCU charges are accumulating in an account where Bedrock
inference activity is less than 10% of the OCU cost. A Knowledge Base vector store is
running without its parent application.

## What this detects

AWS Bedrock Knowledge Base Quick-create silently provisions an Amazon OpenSearch Serverless
collection as its vector store. The Bedrock console handles Knowledge Base creation; the
OpenSearch console is never opened. When a developer deletes the Knowledge Base from the
Bedrock console, the OpenSearch Serverless collection is **not automatically deleted** — it
must be removed separately from the OpenSearch console under Serverless → Collections.

The billing consequence: OpenSearch Serverless bills a minimum of 2 OCUs (1 Search OCU +
1 Indexing OCU) at $0.24/OCU-hour, regardless of query volume. This floor cost runs
approximately $345/month whether 0 or 10,000 queries run against the collection.

The billing disguise: these charges appear as "Amazon OpenSearch Service" line items, not as
Bedrock charges. FinOps tools monitoring the Bedrock spend line find nothing anomalous —
because the Bedrock charges have stopped. The waste is invisible without a cross-service
query comparing OpenSearch OCU cost against Bedrock inference activity in the same account.

## What a hit means

An account has OpenSearch OCU charges that significantly exceed its Bedrock inference
activity. At least one OpenSearch Serverless collection is running without a corresponding
active Knowledge Base workload. The fix: open the Amazon OpenSearch Service console,
navigate to Serverless → Collections, and delete any collections named
`bedrock-knowledge-base-*` that are no longer associated with an active application.

## Key output columns

| Column | Meaning |
|---|---|
| `ocu_cost_30d` | OpenSearch OCU charges in the last 30 days |
| `ocu_collection_count` | Number of distinct OpenSearch resource IDs with OCU charges |
| `bedrock_inference_cost_30d` | Bedrock InvokeModel charges in the same 30-day window |
| `ocu_waste_ratio` | ocu_cost / bedrock_inference_cost — a very large number (or NULL) confirms mismatch |

## Notes

- AWS-specific: uses service name filtering for OpenSearch and Bedrock plus `x_usagetype`
  (AWS Data Exports extension) to isolate OCU and InvokeModel rows.
- Results are at the account (`subaccountid`) level because OCU charges and inference
  activity are often in the same AWS account but under different service line items.
- The `10%` inference threshold means: if Bedrock inference activity exists but is less than
  10% of the OCU cost, the collection is likely orphaned or significantly over-provisioned
  for its actual query load.
- The `$50` OCU cost floor corresponds to roughly 2 days of minimum OCU charges. This
  excludes very recently-created collections that may still be in initial setup.
