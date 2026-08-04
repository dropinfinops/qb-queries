-- SPDX-License-Identifier: Apache-2.0
-- Runaway AI Inference: Runaway Inference — AI inference billing spike > 2σ above 23-day baseline
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/runaway-ai-inference/README.md
-- Athena / Trino / Presto. Replace `your_focus_table` (below) with your FOCUS billing table.
WITH inference_daily AS (
    SELECT
        subaccountid,
        CAST(chargeperiodstart AS DATE) AS charge_date,
        SUM(billedcost)                 AS daily_cost
    FROM your_focus_table  -- << REPLACE with your FOCUS billing table name
    WHERE servicename  LIKE '%Bedrock%'
      AND x_usagetype  LIKE '%InvokeModel%'  -- AWS extension: isolates model invocation charges
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= DATE_ADD('day', -30, CURRENT_DATE)
    GROUP BY 1, 2
)
, baseline AS (
    SELECT
        subaccountid,
        AVG(daily_cost)        AS avg_daily_cost,
        STDDEV_POP(daily_cost) AS stddev_daily_cost
    FROM inference_daily
    WHERE charge_date >= DATE_ADD('day', -30, CURRENT_DATE)
      AND charge_date <  DATE_ADD('day', -7,  CURRENT_DATE)  -- baseline: days -30 to -7
    GROUP BY subaccountid
)
, recent AS (
    SELECT
        subaccountid,
        AVG(daily_cost) AS recent_avg_daily_cost,
        MAX(daily_cost) AS recent_max_daily_cost
    FROM inference_daily
    WHERE charge_date >= DATE_ADD('day', -3, CURRENT_DATE)   -- detection: last 3 days
    GROUP BY subaccountid
)
SELECT
    r.subaccountid,
    ROUND(r.recent_avg_daily_cost, 4)                                            AS recent_avg_daily_cost,
    ROUND(b.avg_daily_cost, 4)                                                   AS baseline_avg_daily_cost,
    ROUND(b.stddev_daily_cost, 4)                                                AS baseline_stddev,
    ROUND(r.recent_max_daily_cost, 4)                                            AS recent_max_daily_cost,
    ROUND(r.recent_avg_daily_cost / NULLIF(b.avg_daily_cost, 0), 4)             AS spike_ratio,
    ROUND(
        (r.recent_avg_daily_cost - b.avg_daily_cost)
        / NULLIF(b.stddev_daily_cost, 0),
        2
    )                                                                            AS sigma_distance
FROM recent r
JOIN baseline b ON r.subaccountid = b.subaccountid
WHERE r.recent_avg_daily_cost > b.avg_daily_cost + 2.0 * b.stddev_daily_cost
  AND b.avg_daily_cost > 1.0  -- baseline floor: account must have >$1/day inference history
ORDER BY spike_ratio DESC
LIMIT 25
