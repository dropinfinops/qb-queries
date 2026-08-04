-- SPDX-License-Identifier: Apache-2.0
-- Cost Spike -- Usage Spike -- 3-day cost far above the 30-day baseline : DIAGNOSTIC / TEACHING view (DuckDB)
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/cost-spike/README.md
-- DuckDB. Runs against the playground `bill` view (./run.sh). Athena/Trino: query.sql
WITH resource_daily AS (
    SELECT resourceid,
           resourcetype,
           COALESCE(x_servicecode, servicename, 'Unknown') AS service,
           subaccountid,
           COALESCE(providername, invoiceissuername, 'Unknown') AS provider,
           CAST(chargeperiodstart AS DATE)                      AS day,
           SUM(billedcost)                                      AS daily_cost,
           SUM(COALESCE(consumedquantity, 0))                   AS daily_qty
    FROM bill
    WHERE CAST(chargeperiodstart AS DATE) >= (CURRENT_DATE - INTERVAL 30 DAY)
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
           AVG(CASE WHEN day < (CURRENT_DATE - INTERVAL 18 DAY)
                    THEN daily_cost END) AS avg_early_15d_cost,
           AVG(CASE WHEN day >= (CURRENT_DATE - INTERVAL 18 DAY)
                    THEN daily_cost END) AS avg_recent_15d_cost
    FROM resource_daily
    WHERE day >= (CURRENT_DATE - INTERVAL 30 DAY)
      AND day <  (CURRENT_DATE - INTERVAL 3 DAY)
    GROUP BY 1, 2, 3
)
, recent AS (
    SELECT resourceid, service, provider,
           AVG(daily_cost) AS avg_3d_cost,
           AVG(daily_qty)  AS avg_3d_qty
    FROM resource_daily
    WHERE day >= (CURRENT_DATE - INTERVAL 3 DAY)
    GROUP BY 1, 2, 3
),
scored AS (
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
        WHERE b.avg_30d_cost > 0.001
)
SELECT
    regexp_extract(resourceid, '[^/]+$') AS resource, service, ROUND(avg_3d_cost,4) AS avg_3d_cost, ROUND(avg_30d_cost,4) AS avg_30d_cost, ROUND(cost_acceleration_ratio,2) AS accel_ratio,
    (accel_ratio >= 2.0) AS spike,
    (spike) AS fires
FROM scored
ORDER BY accel_ratio DESC
LIMIT 10;
