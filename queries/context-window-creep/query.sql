-- SPDX-License-Identifier: Apache-2.0
-- Context Window Creep — Bedrock inference token cost growing > 15% month-over-month
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/context-window-creep/README.md
-- Athena / Trino / Presto. Replace `bill` with your FOCUS billing table.
WITH inference_monthly AS (
    SELECT
        subaccountid,
        resourceid,
        CASE
            WHEN CAST(chargeperiodstart AS DATE) >= DATE_ADD('day', -30, CURRENT_DATE)
                THEN 'current'
            ELSE 'prior'
        END                   AS period,
        SUM(billedcost)       AS period_cost,
        SUM(consumedquantity) AS period_tokens_k
    FROM your_focus_table  -- << REPLACE with your FOCUS billing table name
    WHERE servicename    LIKE '%Bedrock%'
      AND x_usagetype    LIKE '%InvokeModel%'  -- AWS extension: isolates model invocation charges
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= DATE_ADD('day', -60, CURRENT_DATE)
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
)
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
WHERE prior_cost > 10.0          -- floor: exclude new workloads with no meaningful history
  AND current_cost > prior_cost * 1.15  -- >15% MoM growth
ORDER BY token_growth_pct DESC
LIMIT 25
