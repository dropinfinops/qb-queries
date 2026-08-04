-- SPDX-License-Identifier: Apache-2.0
-- Over-Provisioned Capacity: Utilization Ratio — consumed quantity < 30% of pricing quantity
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/over-provisioned-capacity/README.md
-- DuckDB. Runs against the playground `bill` view (./run.sh). Athena/Trino: query.sql
WITH resource_daily AS (
    SELECT resourceid,
           COALESCE(x_servicecode, servicename, 'Unknown') AS service,
           subaccountid,
           COALESCE(providername, invoiceissuername, 'Unknown') AS provider,
           CAST(chargeperiodstart AS DATE) AS day,
           SUM(billedcost)                                    AS daily_cost,
           SUM(COALESCE(consumedquantity, 0))                 AS daily_qty,
           SUM(COALESCE(pricingquantity, 0))                  AS daily_pricing_qty,
           MAX(consumedunit)                                  AS consumedunit
    FROM bill
    WHERE CAST(chargeperiodstart AS DATE) >= (CURRENT_DATE - INTERVAL 30 DAY)
      AND billedcost > 0
      AND resourceid IS NOT NULL AND resourceid != ''
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND pricingquantity > 0
    GROUP BY 1, 2, 3, 4, CAST(chargeperiodstart AS DATE)
)
, resource_stats AS (
    SELECT resourceid, service, provider, subaccountid,
           MAX(consumedunit)   AS consumedunit,
           COUNT(DISTINCT day) AS days_seen,
           AVG(daily_cost)     AS avg_daily_cost,
           SUM(daily_cost)     AS total_cost,
           AVG(CASE WHEN daily_pricing_qty > 0
                    THEN daily_qty / daily_pricing_qty
                    ELSE NULL END) AS avg_utilization_ratio
    FROM resource_daily
    GROUP BY 1, 2, 3, 4
)
SELECT resourceid, service, provider, subaccountid,
       consumedunit, days_seen, avg_daily_cost, total_cost,
       ROUND(avg_utilization_ratio, 4) AS avg_utilization_ratio
FROM resource_stats
WHERE avg_daily_cost > 0.01  -- minimum avg daily cost; raise to suppress noise
  AND avg_utilization_ratio IS NOT NULL
  AND avg_utilization_ratio < 0.30
  AND days_seen >= 7
  -- Exclude storage-unit resources: storage billing is by capacity provisioned, not
  -- consumed vs priced in the way compute is. These would produce misleading ratios.
  AND consumedunit NOT IN ('GB-Mo', 'GB', 'GB-Month', 'GiB-Mo', 'GiB')
ORDER BY total_cost DESC
LIMIT 25;
