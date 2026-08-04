-- SPDX-License-Identifier: Apache-2.0
-- Compromised API Key — AI service spend with no prior history + high untagged rate
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/compromised-api-key/README.md
-- Athena / Trino / Presto. Replace `bill` with your FOCUS billing table.
WITH ai_baseline AS (
    SELECT
        subaccountid,
        servicename,
        SUM(effectivecost) AS baseline_spend_30d
    FROM your_focus_table  -- << REPLACE with your FOCUS billing table name
    WHERE servicecategory = 'AI/ML'           -- FOCUS 1.0 standard service category
      AND chargecategory  = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE)
            BETWEEN DATE_ADD('day', -33, CURRENT_DATE)
                AND DATE_ADD('day', -3,  CURRENT_DATE)  -- 30-day baseline, excludes recent window
    GROUP BY subaccountid, servicename
)
, ai_recent AS (
    SELECT
        subaccountid,
        servicename,
        SUM(effectivecost)                                  AS recent_spend_48h,
        COUNT(*)                                            AS total_rows,
        COUNT(CASE WHEN tags IS NULL THEN 1 END)            AS untagged_rows
    FROM your_focus_table  -- << REPLACE with your FOCUS billing table name
    WHERE servicecategory = 'AI/ML'
      AND chargecategory  = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= DATE_ADD('day', -2, CURRENT_DATE)  -- last 48 hours
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
