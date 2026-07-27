-- SPDX-License-Identifier: Apache-2.0
-- QB12: Idle Developer Resource — flat billing with business-hours-only activity
--
-- Signal: weekday consumed quantity >> weekend quantity (5× threshold), but weekend
-- billing cost is close to weekday cost (>70% ratio). The resource is only used during
-- business hours but billed 24/7 at the same flat rate.
--
-- Distinct from QB07 (Scheduling Miss):
--   QB07 catches high absolute weekend COST on batch jobs / always-on services.
--   QB12 catches flat billing with near-zero weekend ACTIVITY — cost per unit of work
--   is dramatically higher on weekends than weekdays, but the absolute cost looks normal.
--
-- SETUP: Replace 'bill' with your FOCUS billing table name.
--        The $50 / 21-day floor targets resources with material sustained spend.
--
-- DIALECT: DuckDB — local playground.
--   (See query.sql in this folder for the Athena / Trino / Presto version.)
--   EXTRACT(ISODOW FROM ) returns 1=Monday … 7=Sunday (ISO 8601) in Trino/Presto.
--   DuckDB note: ISODOW is used (1=Monday ... 7=Sunday) to match the Presto
--   day_of_week semantics. Do NOT swap in dayofweek() -- it returns 0=Sunday,
--   which would silently drop Sunday from IN (6, 7) and undercount weekend idle.
--
-- FOCUS 1.0 columns used (all standard unless noted):
--   resourceid, servicename, subaccountid, chargeperiodstart, effectivecost,
--   consumedquantity, chargecategory, chargeclass, providername, invoiceissuername

--
-- Run it (from the ./run.sh prompt):
--   .read queries/qb12-idle-dev-resource/query.duckdb.sql

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
)
SELECT
    resourceid, servicename, providername, subaccountid,
    ROUND(avg_weekday_cost,  4) AS avg_weekday_cost,
    ROUND(avg_weekend_cost,  4) AS avg_weekend_cost,
    ROUND(avg_weekday_qty,   4) AS avg_weekday_qty,
    ROUND(avg_weekend_qty,   4) AS avg_weekend_qty,
    ROUND(avg_weekday_qty / NULLIF(avg_weekend_qty, 0.001), 2)    AS weekday_weekend_qty_ratio,
    ROUND(avg_weekend_cost / NULLIF(avg_weekday_cost, 0.001), 4)  AS weekend_billing_ratio,
    ROUND(total_cost_30d, 4)    AS total_cost_30d,
    days_seen
FROM resource_segments
WHERE total_cost_30d > 50       -- $50 minimum 30-day cost; adjust for your scale
  AND days_seen >= 21           -- must have >=21 days of data to establish a pattern
  AND avg_weekday_qty / NULLIF(avg_weekend_qty, 0.001) > 5   -- weekday activity 5× weekend
  AND avg_weekend_cost / NULLIF(avg_weekday_cost, 0.001) > 0.70  -- but billing barely drops
ORDER BY total_cost_30d DESC
LIMIT 25
