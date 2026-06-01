-- SPDX-License-Identifier: Apache-2.0
-- QB16: Idle Model Endpoint — SageMaker endpoint billing with < 100 invocations in 7 days
--
-- SageMaker real-time inference endpoints cannot scale to zero. Auto Scaling can reduce
-- the minimum instance count to 1, but never 0. The meter runs from CreateEndpoint until
-- DeleteEndpoint — there is no sleep mode and no credit for zero-traffic periods.
--
-- This query joins endpoint cost rows (x_usagetype LIKE '%Hosting%') against invocation
-- count rows (x_usagetype LIKE '%Invocations%'). An endpoint with < 100 invocations over
-- 7 days while billing > $10 is idle (100 invocations = ~15/day, well below any real
-- serving workload which typically sees 100–10,000+ calls/day).
--
-- *** AWS-SPECIFIC QUERY ***
-- Uses servicename LIKE '%SageMaker%' and x_usagetype patterns for Hosting/Invocations.
-- x_usagetype is an AWS Data Exports extension column, not a FOCUS 1.0 standard field.
--
-- SETUP: Replace 'your_focus_table' with your FOCUS billing table name.
--
-- DIALECT: Athena / Trino / Presto.
--   BigQuery: replace DATE_ADD('day', -N, CURRENT_DATE) with DATE_SUB(CURRENT_DATE, INTERVAL N DAY)
--
-- FOCUS 1.0 columns used (all standard unless noted):
--   resourceid, subaccountid, chargeperiodstart, billedcost, consumedquantity,
--   servicename, chargecategory, chargeclass
-- Provider-specific columns:
--   x_usagetype (AWS extension) — used to separate endpoint-hour from invocation rows

WITH endpoint_cost AS (
    SELECT
        subaccountid,
        resourceid,
        SUM(billedcost)                             AS endpoint_cost_7d,
        SUM(consumedquantity)                       AS endpoint_hours_7d,
        MAX(billedcost / NULLIF(consumedquantity, 0)) AS hourly_rate
    FROM your_focus_table  -- << REPLACE with your FOCUS billing table name
    WHERE servicename  LIKE '%SageMaker%'
      AND x_usagetype  LIKE '%Hosting%'   -- AWS extension: endpoint instance-hour rows
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= DATE_ADD('day', -7, CURRENT_DATE)
    GROUP BY subaccountid, resourceid
)
, invocation_count AS (
    SELECT
        subaccountid,
        resourceid,
        SUM(consumedquantity) AS total_invocations_7d
    FROM your_focus_table  -- << REPLACE with your FOCUS billing table name
    WHERE servicename  LIKE '%SageMaker%'
      AND x_usagetype  LIKE '%Invocations%'  -- AWS extension: invocation count rows
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= DATE_ADD('day', -7, CURRENT_DATE)
    GROUP BY subaccountid, resourceid
)
SELECT
    e.subaccountid,
    e.resourceid,
    ROUND(e.endpoint_cost_7d, 4)                 AS endpoint_cost_7d,
    ROUND(e.endpoint_hours_7d, 2)                AS endpoint_hours_7d,
    ROUND(e.hourly_rate, 4)                      AS hourly_rate,
    COALESCE(i.total_invocations_7d, 0)          AS total_invocations_7d,
    ROUND(e.endpoint_cost_7d * (30.0 / 7.0), 2) AS projected_monthly_cost,
    CASE
        WHEN COALESCE(i.total_invocations_7d, 0) = 0  THEN 'ZERO_TRAFFIC'
        WHEN COALESCE(i.total_invocations_7d, 0) < 10 THEN 'NEAR_ZERO_TRAFFIC'
        ELSE                                                'LOW_TRAFFIC'
    END                                          AS idle_tier
FROM endpoint_cost e
LEFT JOIN invocation_count i
    ON e.subaccountid = i.subaccountid AND e.resourceid = i.resourceid
WHERE e.endpoint_cost_7d > 10.0                            -- $10 floor: any GPU catches; CPU micro-instances excluded
  AND COALESCE(i.total_invocations_7d, 0) < 100            -- < 100 invocations in 7 days
ORDER BY e.endpoint_cost_7d DESC
LIMIT 25
