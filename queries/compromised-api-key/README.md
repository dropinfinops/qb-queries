# Compromised API Key

**Pattern:** AI service spend appearing in a 48-hour window with no prior billing history
for that service, and more than 80% of the billing rows carrying no workload attribution
tags. The signature of a stolen API key being actively abused.

## Run it

From the `./run.sh` prompt. Three acts, each answering a different question:

```sql
.read queries/compromised-api-key/preflight.duckdb.sql    -- CHECK: can this data answer the question?
.read queries/compromised-api-key/diagnostic.duckdb.sql   -- LEARN: the ranked field, rules as pass/fail flags
.read queries/compromised-api-key/query.duckdb.sql        -- TRUST: what actually fires
```

Against the sample bill the detector returns **2 rows**. Run
`python3 tools/verify_corpus.py` to check every pattern at once.

**Reading a zero row.** Zero rows with every preflight check `PASS` is a real, honest zero —
the bill is clean on this pattern. Zero rows with any check `FAIL` means the data cannot
answer the question at all, which is a blind spot, not a clean bill.

## What this detects

AI API keys exposed in public code repositories, shared in Slack channels, embedded in
client-side applications, or compromised through phishing are a growing attack vector.
When an attacker obtains a valid API key, they call the AI service directly — typically with
a script or wrapper — generating billing charges against the victim account.

The billing signature of this attack is structurally different from legitimate AI usage:

- **Timing**: Attacker sessions are concentrated in a short window (hours to 2 days) then
  stop abruptly when the key is rotated.
- **History**: Attackers typically target AI services the victim hasn't used before, or
  escalate into higher-cost SKUs the account hasn't touched.
- **Tags**: Legitimate applications carry workload attribution tags (Environment, Team,
  Application) propagated from IAM context. Attacker scripts carry no headers — the billing
  rows arrive completely tagless into the FOCUS dataset.

The `ZERO_HISTORY` tier is the strongest signal: AI spend appearing on an account that has
never used that AI service at all, with >80% untagged rows, in a 48-hour burst.

## What a hit means

Treat this as a security incident until proven otherwise:
1. Rotate the suspected API key / bearer token immediately
2. Audit IAM roles and policies attached to the key
3. Review CloudTrail / activity logs for the 48-hour window
4. Verify whether the charges are from internal applications or unknown sources

## Key output columns

| Column | Meaning |
|---|---|
| `credential_abuse_tier` | `ZERO_HISTORY` (no prior AI spend for this service), `SKU_ESCALATION` (48h > 50% of monthly baseline), `SPEND_SPIKE` |
| `baseline_spend_30d` | AI spend for this service in the prior 30 days — `0.0` means ZERO_HISTORY |
| `recent_spend_48h` | Total AI spend in the last 48 hours |
| `untagged_ratio` | Fraction of recent AI rows with no tags — >0.80 required to fire |

## Notes

- Uses `servicecategory = 'AI/ML'` which is a standard FOCUS 1.0 field. This captures all
  AI/ML services across providers (Bedrock, Vertex AI, Azure OpenAI) in a single query.
  Results are grouped by `servicename` so each provider's service appears as a separate row.
- The `$50` 48-hour floor is deliberately low — a compromised API key generating $50 in
  2 days is an incident worth investigating. Raise this if you want to focus only on
  high-value breaches.
- This pattern is complementary to Runaway AI Inference (Runaway Inference): Runaway AI Inference detects sustained drift
  over 3+ days on accounts with existing AI history. Compromised API Key detects the fast-burn, zero-history
  scenario characteristic of external credential abuse.
