# Runaway AI Inference — Runaway Inference

**Pattern:** AI inference billing has spiked suddenly above this account's own 23-day
baseline by more than 2 standard deviations. An agent loop, recursive tool call, or
unbounded context accumulation is burning tokens faster than intended.

## Run it

From the `./run.sh` prompt. Three acts, each answering a different question:

```sql
.read queries/runaway-ai-inference/preflight.duckdb.sql    -- CHECK: can this data answer the question?
.read queries/runaway-ai-inference/diagnostic.duckdb.sql   -- LEARN: the ranked field, rules as pass/fail flags
.read queries/runaway-ai-inference/query.duckdb.sql        -- TRUST: what actually fires
```

Against the sample bill the detector returns **1 row**. Run
`python3 tools/verify_corpus.py` to check every pattern at once.

**Reading a zero row.** Zero rows with every preflight check `PASS` is a real, honest zero —
the bill is clean on this pattern. Zero rows with any check `FAIL` means the data cannot
answer the question at all, which is a blind spot, not a clean bill.

## What this detects

AI agent and inference costs follow a quadratic growth curve when context accumulates
naively. Each failed tool call retries with the full conversation history appended; each
retry makes the next retry more expensive. An autonomous agent left running over a long
weekend can consume thousands of dollars.

This query detects the billing signature: inference spend stable at baseline for weeks,
then a sharp step-function increase in the last 3 days. The 2σ threshold self-calibrates to
each account's own variance — a high-variance AI account needs a proportionally larger spike
to trigger than a stable low-usage one.

The `baseline_floor > $1/day` requirement excludes accounts with essentially no inference
history. A brand-new account spending $5 for the first time does not fire this query — see
Compromised API Key (Compromised API Credential) for zero-history detection.

## What a hit means

AI inference spend jumped significantly above the account's own normal range in the last
3 days. Check:
- Are any autonomous agents running without budget caps or token limits?
- Did a deployment change the system prompt size, retrieval chunk size, or conversation
  history window?
- Is any retry/fallback logic sending repeated large-context requests?

## Key output columns

| Column | Meaning |
|---|---|
| `spike_ratio` | recent_avg / baseline_avg — how many times above normal the recent spend is |
| `sigma_distance` | Z-score: standard deviations above the baseline mean — higher = more statistically unusual |
| `baseline_stddev` | Baseline volatility — a low stddev with a high sigma_distance means this is a clean, unusual event |
| `recent_max_daily_cost` | Peak single-day inference cost in the last 3 days |

## Notes

- AWS-specific: uses `servicename LIKE '%Bedrock%'` and `x_usagetype LIKE '%InvokeModel%'`.
  `x_usagetype` is an AWS Data Exports extension, not a FOCUS 1.0 standard field.
- Results are at the account (`subaccountid`) level. Bedrock does not surface per-application
  or per-agent breakdown in FOCUS billing rows without custom tagging.
- The 23-day baseline window (days −30 to −7) excludes the spike period from the mean and
  stddev calculation, preventing a long-running spike from contaminating its own baseline.
