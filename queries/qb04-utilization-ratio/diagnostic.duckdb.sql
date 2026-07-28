-- QB04 -- Utilization Ratio -- paying for capacity you are not consuming : DIAGNOSTIC / TEACHING view (DuckDB)
--
-- This is NOT the detector. The detector (query.duckdb.sql) keeps ONLY the rows that
-- satisfy every condition. This view RANKS the field and exposes each condition as a
-- pass/fail flag, so you can see WHY a row does or does not fire -- and how far the
-- real finding sits from everything else.
--
-- Read it as the middle act: preflight (can the data answer?) -> diagnostic (what does
-- the field look like?) -> query (what actually fires?).
--
--   under_used  = utilization below 30%
--   has_history = >= 7 days of data to trust the ratio
--   fires = the combination the detector requires
--
-- Run it (from the ./run.sh prompt):
--   .read queries/qb04-utilization-ratio/diagnostic.duckdb.sql

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
),
scored AS (
    SELECT resourceid, service, provider, subaccountid,
           consumedunit, days_seen, avg_daily_cost, total_cost,
           ROUND(avg_utilization_ratio, 4) AS avg_utilization_ratio
    FROM resource_stats
        WHERE avg_daily_cost > 0.001
          AND avg_utilization_ratio IS NOT NULL
          AND consumedunit NOT IN ('GB-Mo','GB','GB-Month','GiB-Mo','GiB')
)
SELECT
    regexp_extract(resourceid, '[^/]+$') AS resource, service, consumedunit, days_seen, ROUND(total_cost,2) AS total_cost, ROUND(avg_utilization_ratio,4) AS avg_utilization_ratio,
    (avg_utilization_ratio < 0.30) AS under_used,
    (days_seen >= 7) AS has_history,
    (under_used AND has_history) AS fires
FROM scored
ORDER BY avg_utilization_ratio ASC
LIMIT 10;
