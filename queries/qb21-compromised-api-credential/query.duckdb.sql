-- SPDX-License-Identifier: Apache-2.0
-- QB21: Compromised API Credential — AI service spend with no prior history + high untagged rate
--
-- Detects stolen or exposed AI API keys being abused. The billing signature:
--   1. AI service spend appearing in a 48-hour window (recent_spend_48h > $50)
--   2. Zero AI billing history for this service in the prior 30 days (ZERO_HISTORY)
--      OR recent spend > 50% of the 30-day baseline (SKU_ESCALATION / SPEND_SPIKE)
--   3. > 80% of recent AI rows carry no workload attribution tags
--
-- The structural asymmetry: legitimate AI API calls come from deployed applications with
-- Environment, Team, Application, and WorkloadId tags. Attacker traffic (curl, Python
-- scripts) carries no attribution headers. The billing rows arrive tagless.
--
-- Detection window: 48 hours (key abuse burns fast, then stops on rotation — opposite of
-- QB15's sustained drift pattern).
--
-- CROSS-CLOUD NOTE:
-- Uses servicecategory = 'AI/ML' which is a standard FOCUS field and captures:
--   AWS:   Amazon Bedrock (servicename), Google Cloud Vertex AI, Azure OpenAI Service
-- Individual servicename values are provider-specific — results are grouped by
-- (subaccountid, servicename) so each provider's AI service appears as a separate row.
--
-- SETUP: Replace 'bill' with your FOCUS billing table name.
--
-- DIALECT: DuckDB — local playground.
--   (See query.sql in this folder for the Athena / Trino / Presto version.)
--             and BETWEEN with appropriate DATE functions
--
-- FOCUS 1.0 columns used (all standard):
--   subaccountid, servicename, servicecategory, effectivecost, chargeperiodstart,
--   chargecategory, chargeclass, tags

--
-- Run it (from the ./run.sh prompt):
--   .read queries/qb21-compromised-api-credential/query.duckdb.sql

WITH ai_baseline AS (
    SELECT
        subaccountid,
        servicename,
        SUM(effectivecost) AS baseline_spend_30d
    FROM bill
    WHERE servicecategory = 'AI/ML'           -- FOCUS 1.0 standard service category
      AND chargecategory  = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE)
            BETWEEN (CURRENT_DATE - INTERVAL 33 DAY)
                AND (CURRENT_DATE - INTERVAL 3 DAY)  -- 30-day baseline, excludes recent window
    GROUP BY subaccountid, servicename
)
, ai_recent AS (
    SELECT
        subaccountid,
        servicename,
        SUM(effectivecost)                                  AS recent_spend_48h,
        COUNT(*)                                            AS total_rows,
        COUNT(CASE WHEN tags IS NULL THEN 1 END)            AS untagged_rows
    FROM bill
    WHERE servicecategory = 'AI/ML'
      AND chargecategory  = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= (CURRENT_DATE - INTERVAL 2 DAY)  -- last 48 hours
    GROUP BY subaccountid, servicename
)
SELECT
    r.subaccountid,
    r.servicename,
    COALESCE(b.baseline_spend_30d, 0.0)                                          AS baseline_spend_30d,
    ROUND(r.recent_spend_48h, 4)                                                  AS recent_spend_48h,
    r.total_rows,
    r.untagged_rows,
    ROUND(CAST(r.untagged_rows AS DOUBLE) / NULLIF(r.total_rows, 0), 4)          AS untagged_ratio,
    CASE
        WHEN b.baseline_spend_30d IS NULL
                                               THEN 'ZERO_HISTORY'
        WHEN r.recent_spend_48h > COALESCE(b.baseline_spend_30d, 0.0) * 0.5
                                               THEN 'SKU_ESCALATION'
        ELSE                                        'SPEND_SPIKE'
    END                                                                           AS credential_abuse_tier
FROM ai_recent r
LEFT JOIN ai_baseline b
    ON r.subaccountid = b.subaccountid AND r.servicename = b.servicename
WHERE r.recent_spend_48h > 50.0  -- $50 minimum in 48h; attacker sessions burn fast
  AND (
      b.baseline_spend_30d IS NULL                                                    -- no prior AI history
      OR r.recent_spend_48h > COALESCE(b.baseline_spend_30d, 0.0) * 0.5             -- 48h > 50% of 30-day baseline
  )
  AND ROUND(CAST(r.untagged_rows AS DOUBLE) / NULLIF(r.total_rows, 0), 4) > 0.80   -- >80% untagged rows
ORDER BY r.recent_spend_48h DESC
LIMIT 25
