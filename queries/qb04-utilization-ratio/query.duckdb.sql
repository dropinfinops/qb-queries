-- SPDX-License-Identifier: Apache-2.0
-- QB04: Utilization Ratio — consumed quantity < 30% of pricing quantity
--
-- *** DESIGN LIMITATION — READ BEFORE RUNNING ***
-- This query computes AVG(consumedquantity / pricingquantity) across all usage rows.
-- In FOCUS 1.0, consumedquantity and pricingquantity use the same unit for most services,
-- making the ratio ~1.0 for the majority of on-demand usage rows. The ratio is only
-- meaningfully sub-1.0 for:
--   (a) Reserved Instance / Savings Plan rows where committed hours are partially matched
--   (b) Services where ConsumedUnit and PricingUnit differ by a fixed block size
-- On-demand EC2 instances at 100% utilization will typically produce a ratio of 1.0 and
-- will NOT appear in results. This query is most useful for committed/reserved capacity
-- validation, not general compute utilization checking.
-- This query is DEFERRED from the DropInFinOps active detector set pending a redesign that
-- uses CommitmentDiscountStatus rows directly (see QB10 for the commitment-aware approach).
--
-- SETUP: Replace 'bill' with your FOCUS billing table name.
--
-- DIALECT: DuckDB — local playground.
--   (See query.sql in this folder for the Athena / Trino / Presto version.)
--
-- FOCUS 1.0 columns used (all standard unless noted):
--   resourceid, servicename, subaccountid, chargeperiodstart, billedcost, consumedquantity,
--   pricingquantity, consumedunit, chargecategory, chargeclass, providername, invoiceissuername
-- Provider-specific columns:
--   x_servicecode (AWS extension) — falls back to servicename if absent

--
-- Run it (from the ./run.sh prompt):
--   .read queries/qb04-utilization-ratio/query.duckdb.sql

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
LIMIT 25
