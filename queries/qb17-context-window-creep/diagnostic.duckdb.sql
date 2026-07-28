-- QB17 -- Context-Window Creep -- token cost climbing month over month : DIAGNOSTIC / TEACHING view (DuckDB)
--
-- This is NOT the detector. The detector (query.duckdb.sql) keeps ONLY the rows that
-- satisfy every condition. This view RANKS the field and exposes each condition as a
-- pass/fail flag, so you can see WHY a row does or does not fire -- and how far the
-- real finding sits from everything else.
--
-- Read it as the middle act: preflight (can the data answer?) -> diagnostic (what does
-- the field look like?) -> query (what actually fires?).
--
--   growing     = >15% month-over-month cost growth on the same workload
--   has_history = prior month must exceed $10 (excludes brand-new workloads)
--   fires = the combination the detector requires
--
-- Run it (from the ./run.sh prompt):
--   .read queries/qb17-context-window-creep/diagnostic.duckdb.sql

WITH inference_monthly AS (
    SELECT
        subaccountid,
        resourceid,
        CASE
            WHEN CAST(chargeperiodstart AS DATE) >= (CURRENT_DATE - INTERVAL 30 DAY)
                THEN 'current'
            ELSE 'prior'
        END                   AS period,
        SUM(billedcost)       AS period_cost,
        SUM(consumedquantity) AS period_tokens_k
    FROM bill
    WHERE servicename    LIKE '%Bedrock%'
      AND x_usagetype    LIKE '%InvokeModel%'  -- AWS extension: isolates model invocation charges
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= (CURRENT_DATE - INTERVAL 60 DAY)
    GROUP BY 1, 2, 3
)
, pivoted AS (
    SELECT
        subaccountid,
        resourceid,
        SUM(CASE WHEN period = 'current' THEN period_cost     ELSE 0 END) AS current_cost,
        SUM(CASE WHEN period = 'prior'   THEN period_cost     ELSE 0 END) AS prior_cost,
        SUM(CASE WHEN period = 'current' THEN period_tokens_k ELSE 0 END) AS current_tokens_k,
        SUM(CASE WHEN period = 'prior'   THEN period_tokens_k ELSE 0 END) AS prior_tokens_k
    FROM inference_monthly
    GROUP BY 1, 2
),
scored AS (
    SELECT
        subaccountid,
        resourceid,
        ROUND(current_cost, 4)                                                    AS current_month_cost,
        ROUND(prior_cost, 4)                                                      AS prior_month_cost,
        ROUND(current_tokens_k, 2)                                                AS current_tokens_k,
        ROUND(prior_tokens_k, 2)                                                  AS prior_tokens_k,
        ROUND(
            (current_cost - prior_cost) / NULLIF(prior_cost, 0) * 100.0,
            2
        )                                                                         AS token_growth_pct,
        ROUND(current_cost - prior_cost, 4)                                       AS monthly_cost_delta
    FROM pivoted
        WHERE prior_cost > 0.5
)
SELECT
    subaccountid, regexp_extract(resourceid, '[^/]+$') AS resource, prior_month_cost, current_month_cost, token_growth_pct AS growth_pct,
    (growth_pct > 15.0) AS growing,
    (prior_month_cost > 10.0) AS has_history,
    (growing AND has_history) AS fires
FROM scored
ORDER BY growth_pct DESC
LIMIT 10;
