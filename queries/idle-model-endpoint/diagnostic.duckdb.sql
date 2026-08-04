-- Idle Model Endpoint -- Idle Model Endpoint -- GPU billing with no traffic : DIAGNOSTIC / TEACHING view (DuckDB)
--
-- This is NOT the detector. The detector (query.duckdb.sql) keeps ONLY the rows that
-- satisfy every condition. This view RANKS the field and exposes each condition as a
-- pass/fail flag, so you can see WHY a row does or does not fire -- and how far the
-- real finding sits from everything else.
--
-- Read it as the middle act: preflight (can the data answer?) -> diagnostic (what does
-- the field look like?) -> query (what actually fires?).
--
--   no_traffic = fewer than 100 invocations in 7 days
--   material   = >$10 of endpoint cost in that window
--   fires = the combination the detector requires
--
-- Run it (from the ./run.sh prompt):
--   .read queries/idle-model-endpoint/diagnostic.duckdb.sql

WITH endpoint_cost AS (
    SELECT
        subaccountid,
        resourceid,
        SUM(billedcost)                             AS endpoint_cost_7d,
        SUM(consumedquantity)                       AS endpoint_hours_7d,
        MAX(billedcost / NULLIF(consumedquantity, 0)) AS hourly_rate
    FROM bill
    WHERE servicename  LIKE '%SageMaker%'
      AND x_usagetype  LIKE '%Hosting%'   -- AWS extension: endpoint instance-hour rows
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= (CURRENT_DATE - INTERVAL 7 DAY)
    GROUP BY subaccountid, resourceid
)
, invocation_count AS (
    SELECT
        subaccountid,
        resourceid,
        SUM(consumedquantity) AS total_invocations_7d
    FROM bill
    WHERE servicename  LIKE '%SageMaker%'
      AND x_usagetype  LIKE '%Invocations%'  -- AWS extension: invocation count rows
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= (CURRENT_DATE - INTERVAL 7 DAY)
    GROUP BY subaccountid, resourceid
),
scored AS (
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
        WHERE e.endpoint_cost_7d > 0.5
)
SELECT
    subaccountid, regexp_extract(resourceid, '[^/]+$') AS resource, endpoint_cost_7d, endpoint_hours_7d, total_invocations_7d AS invocations_7d, projected_monthly_cost AS projected_monthly, idle_tier,
    (invocations_7d < 100) AS no_traffic,
    (endpoint_cost_7d > 10.0) AS material,
    (no_traffic AND material) AS fires
FROM scored
ORDER BY endpoint_cost_7d DESC
LIMIT 10;
