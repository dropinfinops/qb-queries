-- SPDX-License-Identifier: Apache-2.0
-- Runaway AI Inference -- Runaway Inference -- AI spend beyond statistical norm : DIAGNOSTIC / TEACHING view (DuckDB)
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/runaway-ai-inference/README.md
-- DuckDB. Runs against the playground `bill` view (./run.sh). Athena/Trino: query.sql
WITH inference_daily AS (
    SELECT
        subaccountid,
        CAST(chargeperiodstart AS DATE) AS charge_date,
        SUM(billedcost)                 AS daily_cost
    FROM bill
    WHERE servicename  LIKE '%Bedrock%'
      AND x_usagetype  LIKE '%InvokeModel%'  -- AWS extension: isolates model invocation charges
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= (CURRENT_DATE - INTERVAL 30 DAY)
    GROUP BY 1, 2
)
, baseline AS (
    SELECT
        subaccountid,
        AVG(daily_cost)        AS avg_daily_cost,
        STDDEV_POP(daily_cost) AS stddev_daily_cost
    FROM inference_daily
    WHERE charge_date >= (CURRENT_DATE - INTERVAL 30 DAY)
      AND charge_date <  (CURRENT_DATE - INTERVAL 7 DAY)  -- baseline: days -30 to -7
    GROUP BY subaccountid
)
, recent AS (
    SELECT
        subaccountid,
        AVG(daily_cost) AS recent_avg_daily_cost,
        MAX(daily_cost) AS recent_max_daily_cost
    FROM inference_daily
    WHERE charge_date >= (CURRENT_DATE - INTERVAL 3 DAY)   -- detection: last 3 days
    GROUP BY subaccountid
),
scored AS (
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
        WHERE b.avg_daily_cost > 0.01
)
SELECT
    subaccountid, baseline_avg_daily_cost AS baseline_daily, baseline_stddev, recent_avg_daily_cost AS recent_daily, spike_ratio, sigma_distance,
    (sigma_distance > 2.0) AS sigma_breach,
    (baseline_daily > 1.0) AS has_history,
    (sigma_breach AND has_history) AS fires
FROM scored
ORDER BY sigma_distance DESC NULLS LAST
LIMIT 10;
