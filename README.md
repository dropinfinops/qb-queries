# DropInFinOps QB Pattern Library

A collection of standalone FOCUS 1.0 SQL queries for detecting cloud cost anomalies directly
from your billing data — no proprietary tooling required.

These are the detection patterns behind [DropInFinOps](https://dropinfinops.com), published
here so any practitioner can run them against their own billing data today.

---

## Try it in 60 seconds (local playground)

This repo ships a small synthetic multi-cloud FOCUS dataset with deliberately planted waste, plus
a one-command playground. You run the detectors yourself against it. The only dependency is
[DuckDB](https://duckdb.org).

```bash
git clone https://github.com/dropinfinops/qb-queries
cd qb-queries
./run.sh
```

`run.sh` verifies DuckDB is installed, loads the sample data (shifted so it's dated through today)
as a view named `bill`, and leaves you at the SQL prompt. It runs nothing for you. Run the first
detector:

```sql
.read queries/qb22-config-change-data-processing-runaway/query.duckdb.sql
```

Expected result — one row, the planted anomaly:

```
┌────────────────────────┬───────────────┬────────────────┬──────────────┬──────────────────────┐
│      subaccountid      │ dp_step_ratio │ compute_growth │ dp_recent_7d │ elevated_days_recent │
├────────────────────────┼───────────────┼────────────────┼──────────────┼──────────────────────┤
│ 112233445566-us-west-2 │          5.41 │           1.01 │       383.39 │                    8 │
└────────────────────────┴───────────────┴────────────────┴──────────────┴──────────────────────┘
```

_(Figures shift slightly each run — the data is re-dated to today on load. The shape is the point.)_

Data-processing spend stepped up sharply and held for a week (a few hundred dollars) while compute
stayed flat (~1.0×) — the signature of a networking config change with no cost guardrail, not
organic growth. Open **`samples/guide.html`** in a browser for the full answer key (what's planted,
what each detector should surface), then explore: adjust a threshold, group by service, inspect the
days around `onset_day`.

**See the mechanics.** The detector keeps only confirmed hits — one row here. To watch that row
*separate from the field*, run the ranked diagnostic, which lists the top subaccounts with the
three rules exposed as pass/fail flags:

```sql
.read queries/qb22-config-change-data-processing-runaway/diagnostic.duckdb.sql
```

The real runaway trips all three (`fires = true`); every normal account sits near a 1.0× step and
fails. That separation — not a lone row — is the proof.

**Run it on your own bill.** Replace `bill` with your own FOCUS table. Note the shape: this sample
is in DropInFinOps' normalized FOCUS form — complex fields (`tags`, discounts) are JSON strings,
not native maps — which is what the processor produces from a raw export and what these queries
expect. Normalize a raw provider export (or run against your processed export) and the queries
drop in.

---

## What is FOCUS?

[FOCUS](https://focus.finops.org) (FinOps Open Cost and Usage Specification) is an open
standard for cloud billing data maintained by the FinOps Foundation. It normalises cost and
usage data across AWS, Azure, and GCP into a common schema so the same query can work across
providers.

**Supported exports by provider:**
- **AWS** — Amazon Data Exports (FOCUS 1.0) in Athena or S3
- **Azure** — Cost Management exports (FOCUS 1.0 preview)
- **GCP** — BigQuery billing export (FOCUS support varies by export version)

---

## How to use these queries on your own data

1. **Identify your FOCUS billing table.** In AWS, this is typically an Athena table created
   by Amazon Data Exports. Note the full table reference
   (e.g. `my_database.focus_billing_export`).

2. **Substitute the table placeholder.** Every `query.sql` contains `your_focus_table`. Replace
   it with your actual table reference before running.

3. **Adjust the cost floor (optional).** Queries use a small minimum daily cost floor to
   suppress noise from trivially small resources. Raise it if you want to focus only on material
   spend.

4. **Run in your query engine.** Each pattern ships in two dialects:
   - `query.sql` — **Athena / Trino / Presto** (run against your real billing table).
   - `query.duckdb.sql` — **DuckDB** (used by the local playground above).

---

## SQL dialect notes

- `DATE_ADD('day', -N, CURRENT_DATE)` — Trino/Presto/Athena syntax. DuckDB:
  `CURRENT_DATE - INTERVAL N DAY`. BigQuery: `DATE_SUB(CURRENT_DATE, INTERVAL N DAY)`.
- `DAY_OF_WEEK(date)` — Trino/Presto returns 1=Monday … 7=Sunday (ISO 8601). DuckDB `dayofweek()`
  returns 0=Sunday … 6=Saturday; BigQuery/MySQL return 1=Sunday … 7=Saturday. Adjust weekend
  tests accordingly.
- `STDDEV_POP()` — available in Trino/Presto, DuckDB, and BigQuery alike.

---

## Provider-specific columns

Some queries use columns that are AWS Data Exports extensions to the FOCUS 1.0 core schema:

| Column | Status | Notes |
|---|---|---|
| `x_servicecode` | AWS extension | AWS product service code (e.g. `AmazonEC2`). Queries fall back to `servicename` if absent. |
| `x_usagetype` | AWS extension | AWS line-item usage type string (e.g. `NatGateway-Bytes`). Required for AWS-specific patterns (QB11, QB15, QB16, QB18, QB22). |
| `resourcetype` | FOCUS 1.1+ | Not in FOCUS 1.0 core. Safe to include; will be null on FOCUS 1.0 exports. |

---

## Query index

| Query | What it detects |
|---|---|
| [QB01 — Waste](queries/qb01-waste/) | Resources billing at full rate with near-zero consumption |
| [QB02 — Usage Spike](queries/qb02-usage-spike/) | 3-day cost avg > 2× 30-day baseline |
| [QB03 — Runaway Cost Acceleration](queries/qb03-runaway-cost-acceleration/) | Sustained cost elevation: 4+ of last 7 days > 1.5× baseline |
| [QB04 — Utilization Ratio](queries/qb04-utilization-ratio/) | ⚠️ Committed capacity used < 30% of provisioned — see limitations |
| [QB07 — Scheduling Miss](queries/qb07-scheduling-miss/) | Weekend cost ≥ 85% of weekday cost on resources that should idle |
| [QB08 — Governance Gap](queries/qb08-governance-gap/) | Significant spend with no cost allocation tags |
| [QB09 — Unauthorized Compute](queries/qb09-unauthorized-compute/) | Spend appearing in a region with no prior billing history |
| [QB10 — Commitment Loss](queries/qb10-commitment-loss/) | RI/SP utilization waste ratio deteriorating vs baseline |
| [QB11 — Data Transfer Misconfiguration](queries/qb11-data-transfer-misconfig/) | NAT Gateway byte cost and cross-AZ transfer disproportionate to compute |
| [QB12 — Idle Developer Resource](queries/qb12-idle-dev-resource/) | Weekday activity >> weekend activity but billing is flat 24/7 |
| [QB15 — Runaway Inference](queries/qb15-runaway-inference/) | AI inference cost spike > 2σ above 23-day baseline (AWS Bedrock) |
| [QB16 — Idle Model Endpoint](queries/qb16-idle-model-endpoint/) | SageMaker real-time endpoint billing with < 100 invocations/7d |
| [QB17 — Context Window Creep](queries/qb17-context-window-creep/) | AI inference token cost growing > 15% month-over-month (AWS Bedrock) |
| [QB18 — Orphaned KB OCU](queries/qb18-orphaned-kb-ocu/) | OpenSearch OCU charges with no matching Bedrock inference activity |
| [QB21 — Compromised API Credential](queries/qb21-compromised-api-credential/) | AI service spend appearing with zero prior history + high untagged rate |
| [QB22 — Config-Change Data-Processing Runaway](queries/qb22-config-change-data-processing-runaway/) | Per-GB data-processing spend steps up and persists while compute stays flat |

Each folder has a `README.md` (what it detects + how to read the output), a `query.sql`
(Athena/Trino), and — where wired into the playground — a `query.duckdb.sql`.

---

## About DropInFinOps

These queries are the detection layer of [DropInFinOps](https://dropinfinops.com) — a
self-hosted FinOps platform for multi-cloud cost intelligence. The briefing engine that
scores, ranks, and explains these signals is separate and not included here.

Questions or contributions: [dropinfinops.com](https://dropinfinops.com)
