# QB17 — Context Window Creep

**Pattern:** An AI inference workload's token cost has grown more than 15% month-over-month
with no corresponding increase in traffic or user load. Prompt inflation is compounding
silently.

## Run it

From the `./run.sh` prompt. Three acts, each answering a different question:

```sql
.read queries/qb17-context-window-creep/preflight.duckdb.sql    -- CHECK: can this data answer the question?
.read queries/qb17-context-window-creep/diagnostic.duckdb.sql   -- LEARN: the ranked field, rules as pass/fail flags
.read queries/qb17-context-window-creep/query.duckdb.sql        -- TRUST: what actually fires
```

Against the sample bill the detector returns **1 row**. Run
`python3 tools/verify_corpus.py` to check every pattern at once.

**Reading a zero row.** Zero rows with every preflight check `PASS` is a real, honest zero —
the bill is clean on this pattern. Zero rows with any check `FAIL` means the data cannot
answer the question at all, which is a blind spot, not a clean bill.

## What this detects

Developers iteratively improve AI prompts — adding safety instructions, few-shot examples,
longer RAG document chunks, extended conversation history windows, or larger tool schemas.
Each individual sprint adds a small number of tokens to the system prompt. Because token
cost is proportional to prompt size, a 30% growth in average prompt length translates
directly to a 30% increase in the inference bill — with no new users, no new features
visible to end users, and no alert firing anywhere.

This pattern is invisible to standard cost monitoring because:
- Total spend grows slowly enough to look like normal growth
- No individual day looks anomalous
- The per-token rate is flat (no rate change to trigger an alert)

The 15% month-over-month threshold identifies workloads where prompt growth is outpacing
what would be explained by organic usage growth alone.

## What a hit means

An inference workload's cost grew > 15% this month vs last month. This warrants an audit of
prompt sizes: measure average token counts for system prompts, few-shot examples, RAG
chunks, and conversation history, then compare to the prior period.

Common fixes: conditional prompt injection (don't include the full security policy if the
diff doesn't touch policy-relevant code), prompt caching for stable system prompts,
conversation history truncation strategies, and smaller RAG chunk sizes with more targeted
retrieval.

## Key output columns

| Column | Meaning |
|---|---|
| `token_growth_pct` | (current_month_cost − prior_month_cost) / prior_month_cost × 100 |
| `monthly_cost_delta` | Absolute dollar increase month-over-month |
| `current_tokens_k` / `prior_tokens_k` | Token volume (in provider-reported `consumedquantity` units) — if this grew in proportion to cost, it confirms token growth rather than a rate change |

## Notes

- AWS-specific: uses `x_usagetype LIKE '%InvokeModel%'` which is an AWS Data Exports
  extension field, not a FOCUS 1.0 standard column.
- The 60-day lookback window covers the current 30 days plus the prior 30 days. Both
  periods must have data for a resource to appear.
- `prior_cost > $10` excludes new workloads with no meaningful prior-period history.
  Brand-new workloads going from $0 to $5 are not context window creep.
- The `token_growth_pct` is a cost growth proxy for token volume growth. This is only a
  valid proxy when per-token rates are stable. A provider repricing event would produce the
  same signal — verify with the `consumedquantity` columns to confirm the pattern is
  driven by volume rather than rate.
