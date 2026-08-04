-- Persistent Cost Overrun -- Runaway Cost Acceleration -- sustained elevation, not a blip : DIAGNOSTIC / TEACHING view (DuckDB)
--
-- This is NOT the detector. The detector (query.duckdb.sql) keeps ONLY the rows that
-- satisfy every condition. This view RANKS the field and exposes each condition as a
-- pass/fail flag, so you can see WHY a row does or does not fire -- and how far the
-- real finding sits from everything else.
--
-- Read it as the middle act: preflight (can the data answer?) -> diagnostic (what does
-- the field look like?) -> query (what actually fires?).
--
--   sustained = elevated on >= 4 days (a one-day blip fails)
--   fires = the combination the detector requires
--
-- Run it (from the ./run.sh prompt):
--   .read queries/persistent-cost-overrun/diagnostic.duckdb.sql

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
           AVG(daily_cost) AS avg_baseline_cost,
           AVG(daily_qty)  AS avg_baseline_qty
    FROM resource_daily
    WHERE day >= (CURRENT_DATE - INTERVAL 30 DAY)
      AND day <  (CURRENT_DATE - INTERVAL 7 DAY)
    GROUP BY 1, 2, 3
)
, daily_flagged AS (
    SELECT rd.resourceid, rd.service, rd.provider, rd.day,
           rd.daily_cost, rd.daily_qty,
           b.avg_baseline_cost,
           CASE WHEN rd.daily_cost > b.avg_baseline_cost * 1.5 THEN 1 ELSE 0 END AS above_threshold
    FROM resource_daily rd
    JOIN baseline b ON rd.resourceid = b.resourceid
    WHERE rd.day >= (CURRENT_DATE - INTERVAL 7 DAY)
      AND b.avg_baseline_cost > 0.01  -- minimum baseline cost; raise to suppress noise
)
, resource_runaway AS (
    SELECT resourceid, service, provider,
           SUM(above_threshold)   AS high_days,
           COUNT(*)               AS total_days,
           AVG(daily_cost)        AS avg_recent_cost,
           STDDEV_POP(daily_cost) AS stddev_recent_cost,
           MAX(daily_cost)        AS max_recent_cost,
           MIN(daily_cost)        AS min_recent_cost,
           AVG(daily_qty)         AS avg_recent_qty,
           MAX(avg_baseline_cost) AS avg_baseline_cost
    FROM daily_flagged
    GROUP BY 1, 2, 3
),
scored AS (
    SELECT resourceid, service, provider,
           high_days, total_days,
           avg_recent_cost, avg_baseline_cost,
           stddev_recent_cost,
           max_recent_cost, min_recent_cost,
           ROUND((avg_recent_cost - avg_baseline_cost) / NULLIF(avg_baseline_cost, 0) * 100, 2) AS pct_above_baseline,
           ROUND(avg_recent_cost / NULLIF(avg_baseline_cost, 0), 4)                             AS cost_ratio
    FROM resource_runaway
        WHERE avg_baseline_cost > 0
)
SELECT
    regexp_extract(resourceid, '[^/]+$') AS resource, service, high_days, total_days, ROUND(avg_baseline_cost,4) AS avg_baseline_cost, ROUND(avg_recent_cost,4) AS avg_recent_cost, ROUND(avg_recent_cost / NULLIF(avg_baseline_cost,0),2) AS cost_ratio,
    (high_days >= 4) AS sustained,
    (sustained) AS fires
FROM scored
ORDER BY cost_ratio DESC
LIMIT 10;
