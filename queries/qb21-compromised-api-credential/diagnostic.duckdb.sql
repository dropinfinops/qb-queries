-- QB21 -- Compromised API Credential -- AI spend burst with no ownership : DIAGNOSTIC / TEACHING view (DuckDB)
--
-- This is NOT the detector. The detector (query.duckdb.sql) keeps ONLY the rows that
-- satisfy every condition. This view RANKS the field and exposes each condition as a
-- pass/fail flag, so you can see WHY a row does or does not fire -- and how far the
-- real finding sits from everything else.
--
-- Read it as the middle act: preflight (can the data answer?) -> diagnostic (what does
-- the field look like?) -> query (what actually fires?).
--
--   burst    = no prior AI history, or 48h spend >50% of the 30-day baseline
--   untagged = >80% of rows carry no tags (nobody owns this workload)
--   material = >$50 burned in 48 hours
--   fires = the combination the detector requires
--
-- Run it (from the ./run.sh prompt):
--   .read queries/qb21-compromised-api-credential/diagnostic.duckdb.sql

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
),
scored AS (
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
        WHERE r.recent_spend_48h > 1
)
SELECT
    subaccountid, servicename, baseline_spend_30d, recent_spend_48h, untagged_ratio, credential_abuse_tier,
    (credential_abuse_tier = 'ZERO_HISTORY' OR recent_spend_48h > baseline_spend_30d * 0.5) AS burst,
    (untagged_ratio > 0.80) AS untagged,
    (recent_spend_48h > 50.0) AS material,
    (burst AND untagged AND material) AS fires
FROM scored
ORDER BY recent_spend_48h DESC
LIMIT 10;
