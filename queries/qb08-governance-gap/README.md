# QB08 — Governance Gap

**Pattern:** A resource has been accruing real spend for at least part of a 30-day window
but carries no cost allocation tags. There is no owner, no cost center, and no environment
label — it cannot be attributed or chargeback'd.

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
