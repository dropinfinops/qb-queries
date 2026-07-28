-- QB12 -- Idle Developer Resource -- flat billing, business-hours-only activity : DIAGNOSTIC / TEACHING view (DuckDB)
--
-- This is NOT the detector. The detector (query.duckdb.sql) keeps ONLY the rows that
-- satisfy every condition. This view RANKS the field and exposes each condition as a
-- pass/fail flag, so you can see WHY a row does or does not fire -- and how far the
-- real finding sits from everything else.
--
-- Read it as the middle act: preflight (can the data answer?) -> diagnostic (what does
-- the field look like?) -> query (what actually fires?).
--
--   activity_gap = weekday consumption > 5x weekend  (the resource is idle)
--   flat_billing = weekend cost still >70% of weekday (you are billed anyway)
--   BOTH must hold. A resource whose COST drops with usage is working
--   correctly -- that is why billing_ratio is the discriminating rule.
--   fires = the combination the detector requires
--
-- Run it (from the ./run.sh prompt):
--   .read queries/qb12-idle-dev-resource/diagnostic.duckdb.sql

WITH resource_daily AS (
    SELECT
        resourceid,
        COALESCE(servicename, 'Unknown')                      AS servicename,
        COALESCE(providername, invoiceissuername, 'Unknown')  AS providername,
        subaccountid,
        CAST(chargeperiodstart AS DATE)                       AS billing_day,
        EXTRACT(ISODOW FROM CAST(chargeperiodstart AS DATE))          AS day_of_week,
        SUM(effectivecost)                                    AS daily_cost,
        SUM(consumedquantity)                                 AS daily_qty
    FROM bill
    WHERE chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= (CURRENT_DATE - INTERVAL 30 DAY)
      AND resourceid IS NOT NULL AND resourceid != ''
    GROUP BY 1, 2, 3, 4, 5, 6
)
, resource_segments AS (
    SELECT
        resourceid, servicename, providername, subaccountid,
        AVG(CASE WHEN day_of_week BETWEEN 1 AND 5 THEN daily_cost END)  AS avg_weekday_cost,
        AVG(CASE WHEN day_of_week IN (6, 7)       THEN daily_cost END)  AS avg_weekend_cost,
        SUM(CASE WHEN day_of_week BETWEEN 1 AND 5 THEN daily_qty ELSE 0 END)
            / NULLIF(COUNT(CASE WHEN day_of_week BETWEEN 1 AND 5 THEN 1 END), 0)
            AS avg_weekday_qty,
        SUM(CASE WHEN day_of_week IN (6, 7) THEN daily_qty ELSE 0 END)
            / NULLIF(COUNT(CASE WHEN day_of_week IN (6, 7) THEN 1 END), 0)
            AS avg_weekend_qty,
        SUM(daily_cost)             AS total_cost_30d,
        COUNT(DISTINCT billing_day) AS days_seen
    FROM resource_daily
    GROUP BY 1, 2, 3, 4
),
scored AS (
    SELECT
        resourceid, servicename, providername, subaccountid,
        ROUND(avg_weekday_cost,  4) AS avg_weekday_cost,
        ROUND(avg_weekend_cost,  4) AS avg_weekend_cost,
        ROUND(avg_weekday_qty,   4) AS avg_weekday_qty,
        ROUND(avg_weekend_qty,   4) AS avg_weekend_qty,
        ROUND(avg_weekday_qty / GREATEST(avg_weekend_qty, 0.001), 2)    AS weekday_weekend_qty_ratio,
        ROUND(avg_weekend_cost / GREATEST(avg_weekday_cost, 0.001), 4)  AS weekend_billing_ratio,
        ROUND(total_cost_30d, 4)    AS total_cost_30d,
        days_seen
    FROM resource_segments
        WHERE total_cost_30d > 1
)
SELECT
    regexp_extract(resourceid, '[^/]+$') AS resource, providername, ROUND(total_cost_30d,2) AS total_cost_30d, days_seen, ROUND(avg_weekday_qty,3) AS avg_weekday_qty, ROUND(avg_weekend_qty,3) AS avg_weekend_qty, ROUND(avg_weekday_qty / GREATEST(avg_weekend_qty,0.001),2) AS qty_ratio, ROUND(avg_weekend_cost / GREATEST(avg_weekday_cost,0.001),3) AS billing_ratio,
    (qty_ratio > 5) AS activity_gap,
    (billing_ratio > 0.70) AS flat_billing,
    (total_cost_30d > 50) AS material,
    (days_seen >= 21) AS has_history,
    (activity_gap AND flat_billing AND material AND has_history) AS fires
FROM scored
ORDER BY qty_ratio DESC
LIMIT 10;
