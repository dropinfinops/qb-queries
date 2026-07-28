-- SPDX-License-Identifier: Apache-2.0
-- QB02: Usage Spike — recent 3-day cost avg > 2× 30-day baseline
--
-- SETUP: Replace 'your_focus_table' with your FOCUS billing table name.
--        Adjust the 0.01 cost floor to match your minimum meaningful daily spend.
--
-- DIALECT: Athena / Trino / Presto.
--   BigQuery: replace DATE_ADD('day', -N, CURRENT_DATE) with DATE_SUB(CURRENT_DATE, INTERVAL N DAY)
--
-- FOCUS 1.0 columns used (all standard unless noted):
--   resourceid, servicename, subaccountid, chargeperiodstart, billedcost, consumedquantity,
--   chargecategory, chargeclass, providername, invoiceissuername
-- Provider-specific columns:
--   x_servicecode (AWS extension) — falls back to servicename if absent
--   resourcetype   (FOCUS 1.1+)  — will be null on FOCUS 1.0 exports; safe to include

WITH resource_daily AS (
    SELECT resourceid,
           resourcetype,
           COALESCE(x_servicecode, servicename, 'Unknown') AS service,
           subaccountid,
           COALESCE(providername, invoiceissuername, 'Unknown') AS provider,
           CAST(chargeperiodstart AS DATE)                      AS day,
           SUM(billedcost)                                      AS daily_cost,
           SUM(COALESCE(consumedquantity, 0))                   AS daily_qty
    FROM your_focus_table  -- << REPLACE with your FOCUS billing table name
    WHERE CAST(chargeperiodstart AS DATE) >= DATE_ADD('day', -30, CURRENT_DATE)
      AND billedcost > 0
      AND resourceid IS NOT NULL AND resourceid != ''
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
    GROUP BY 1, 2, 3, 4, 5, CAST(chargeperiodstart AS DATE)
)
, baseline AS (
    SELECT resourceid, service, provider,
           AVG(daily_cost)        AS avg_30d_cost,
           STDDEV_POP(daily_cost) AS stddev_30d_cost,
           AVG(daily_qty)         AS avg_30d_qty,
           AVG(CASE WHEN day < DATE_ADD('day', -18, CURRENT_DATE)
                    THEN daily_cost END) AS avg_early_15d_cost,
           AVG(CASE WHEN day >= DATE_ADD('day', -18, CURRENT_DATE)
                    THEN daily_cost END) AS avg_recent_15d_cost
    FROM resource_daily
    WHERE day >= DATE_ADD('day', -30, CURRENT_DATE)
      AND day <  DATE_ADD('day', -3,  CURRENT_DATE)
    GROUP BY 1, 2, 3
)
, recent AS (
    SELECT resourceid, service, provider,
           AVG(daily_cost) AS avg_3d_cost,
           AVG(daily_qty)  AS avg_3d_qty
    FROM resource_daily
    WHERE day >= DATE_ADD('day', -3, CURRENT_DATE)
    GROUP BY 1, 2, 3
)
SELECT r.resourceid, r.service, r.provider,
       r.avg_3d_cost, b.avg_30d_cost,
       r.avg_3d_qty,  b.avg_30d_qty,
       b.stddev_30d_cost,
       b.avg_early_15d_cost,
       b.avg_recent_15d_cost,
       ROUND(r.avg_3d_cost / NULLIF(b.avg_30d_cost, 0), 4)                          AS cost_acceleration_ratio,
       ROUND((r.avg_3d_cost - b.avg_30d_cost) / GREATEST(b.stddev_30d_cost, 0.001), 3) AS spike_strength
FROM recent r
JOIN baseline b ON r.resourceid = b.resourceid
WHERE b.avg_30d_cost > 0.01  -- minimum baseline cost; raise to suppress noise
  AND r.avg_3d_cost > b.avg_30d_cost * 2.0
ORDER BY (avg_3d_cost - avg_30d_cost) DESC
LIMIT 25
