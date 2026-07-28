-- QB01 -- Waste -- full-rate billing with near-zero consumption : DIAGNOSTIC / TEACHING view (DuckDB)
--
-- This is NOT the detector. The detector (query.duckdb.sql) keeps ONLY the rows that
-- satisfy every condition. This view RANKS the field and exposes each condition as a
-- pass/fail flag, so you can see WHY a row does or does not fire -- and how far the
-- real finding sits from everything else.
--
-- Read it as the middle act: preflight (can the data answer?) -> diagnostic (what does
-- the field look like?) -> query (what actually fires?).
--
--   idle_days = near-zero consumption on >= 5 days
--   starved   = consumption per dollar under 0.1
--   FIRES     = EITHER condition (this detector is a disjunction)
--   fires = the combination the detector requires
--
-- Run it (from the ./run.sh prompt):
--   .read queries/qb01-waste/diagnostic.duckdb.sql

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
, resource_stats AS (
    SELECT resourceid, service, provider, subaccountid,
           COUNT(DISTINCT day)                                          AS days_seen,
           AVG(daily_cost)                                              AS avg_daily_cost,
           SUM(daily_cost)                                              AS total_cost,
           AVG(daily_qty)                                               AS avg_daily_qty,
           SUM(CASE WHEN daily_qty < 0.01 THEN 1 ELSE 0 END)           AS near_zero_qty_days
    FROM resource_daily
    WHERE day >= (CURRENT_DATE - INTERVAL 30 DAY)
    GROUP BY 1, 2, 3, 4
),
scored AS (
    SELECT resourceid, service, provider, subaccountid,
           days_seen, avg_daily_cost, total_cost, avg_daily_qty, near_zero_qty_days,
           CASE
             WHEN near_zero_qty_days >= 5 THEN 'configured_forgotten'
             ELSE 'over_provisioned'
           END AS waste_signal
    FROM resource_stats
        WHERE avg_daily_cost > 0.001
)
SELECT
    regexp_extract(resourceid, '[^/]+$') AS resource, service, provider, ROUND(total_cost,2) AS total_cost, ROUND(avg_daily_cost,4) AS avg_daily_cost, ROUND(avg_daily_qty,4) AS avg_daily_qty, near_zero_qty_days,
    (near_zero_qty_days >= 5) AS idle_days,
    (avg_daily_qty < avg_daily_cost * 0.1) AS starved,
    (idle_days OR starved) AS fires
FROM scored
ORDER BY total_cost DESC
LIMIT 10;
