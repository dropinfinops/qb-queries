-- SPDX-License-Identifier: Apache-2.0
-- QB15: Runaway Inference — AI inference billing spike > 2σ above 23-day baseline
--
-- Detects AWS Bedrock inference spend that has spiked suddenly above the account's own
-- baseline. Fires on suddenness, not magnitude: a workload that gradually grows 2× over
-- 30 days does not fire; a workload stable at $5/day that hits $40/day for 3 days fires.
--
-- The 2σ threshold self-calibrates: high-variance accounts require a larger absolute spike
-- to trigger than stable, low-variance accounts.
--
-- *** AWS-SPECIFIC QUERY ***
-- This query uses servicename LIKE '%Bedrock%' and x_usagetype LIKE '%InvokeModel%' to
-- isolate AWS Bedrock inference rows. It does not cover Azure OpenAI or Vertex AI.
-- x_usagetype is an AWS Data Exports extension column, not a FOCUS 1.0 standard field.
--
-- SETUP: Replace 'bill' with your FOCUS billing table name.
--
-- DIALECT: DuckDB — local playground.
--   (See query.sql in this folder for the Athena / Trino / Presto version.)
--
-- FOCUS 1.0 columns used (all standard unless noted):
--   subaccountid, chargeperiodstart, billedcost, servicename, chargecategory, chargeclass
-- Provider-specific columns:
--   x_usagetype (AWS extension) — used to isolate Bedrock InvokeModel rows

--
-- Run it (from the ./run.sh prompt):
--   .read queries/qb15-runaway-inference/query.duckdb.sql

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
