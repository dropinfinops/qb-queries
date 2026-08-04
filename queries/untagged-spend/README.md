# Untagged Spend — Governance Gap

**Pattern:** A resource has been accruing real spend for at least part of a 30-day window
but carries no cost allocation tags. There is no owner, no cost center, and no environment
label — it cannot be attributed or chargeback'd.

## Run it

From the `./run.sh` prompt. Three acts, each answering a different question:

```sql
.read queries/untagged-spend/preflight.duckdb.sql    -- CHECK: can this data answer the question?
.read queries/untagged-spend/diagnostic.duckdb.sql   -- LEARN: the ranked field, rules as pass/fail flags
.read queries/untagged-spend/query.duckdb.sql        -- TRUST: what actually fires
```

Against the sample bill the detector returns **176 rows**. Run
`python3 tools/verify_corpus.py` to check every pattern at once.

> **This is a posture measure, not an alarm.** It describes a property of the whole estate
> rather than finding one thing that is wrong, so it returns many rows by design — 176 against
> the sample bill. It cannot know which of *your* resources were meant to be shut down or
> tagged. Read it as a list to triage. The query caps output at 25 rows; remove the `LIMIT`
> to see the full population.

**Reading a zero row.** Zero rows with every preflight check `PASS` is a real, honest zero —
the bill is clean on this pattern. Zero rows with any check `FAIL` means the data cannot
answer the question at all, which is a blind spot, not a clean bill.

## What this detects

Untagged resources with material spend. In a well-governed cloud environment, every resource
that generates cost should carry tags identifying its team, cost center, environment, and
workload. When tags are absent, the resource is effectively invisible to FinOps processes:
it cannot be attributed to a budget, assigned to a team for action, or included in accurate
departmental cost reporting.

Common causes: resources created manually outside IaC processes, bootstrapped environments
that skipped tagging policies, long-lived resources predating a tagging standard, or
automation that creates resources without passing tag context.

## What a hit means

A resource appeared in billing with no tags for at least one day in the last month and its
total 30-day cost exceeds the minimum threshold. This resource needs an owner assigned and
tags applied before it can be managed.

Priority order: sort by `total_cost` and work down from the most expensive untagged
resources first. High-cost untagged resources represent the largest attribution gap.

## Key output columns

| Column | Meaning |
|---|---|
| `total_cost` | 30-day total billed cost — sort by this to prioritize |
| `days_seen` | How many days in the window had billing rows with no tags |
| `avg_daily_cost` | Average daily spend — useful for projecting monthly exposure |

## Notes

- The tag check covers four common empty representations: SQL NULL, empty string, empty
  JSON object `{}`, and the string `'null'` (which some providers write for missing tags).
- A resource that has some tagged days and some untagged days will still appear if its total
  untagged-day spend exceeds the threshold (because `MAX(tags)` is taken per day — if a day
  has no tags that day's row has null/empty tags, and the untagged-day count filters apply).
  In practice this query is most useful for resources that are consistently untagged.
- Provider-specific tag key names (`Environment`, `Team`, `CostCenter`) are not checked
  here — the query only checks for the presence of any tags at all.
