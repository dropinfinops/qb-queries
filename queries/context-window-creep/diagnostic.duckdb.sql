-- SPDX-License-Identifier: Apache-2.0
-- Context Window Creep -- Context-Window Creep -- token cost climbing month over month : DIAGNOSTIC / TEACHING view (DuckDB)
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/context-window-creep/README.md
-- DuckDB. Runs against the playground `bill` view (./run.sh). Athena/Trino: query.sql
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
