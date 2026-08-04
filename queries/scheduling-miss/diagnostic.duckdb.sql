-- Scheduling Miss -- Scheduling Miss -- weekend cost barely drops from weekday : DIAGNOSTIC / TEACHING view (DuckDB)
--
-- This is NOT the detector. The detector (query.duckdb.sql) keeps ONLY the rows that
-- satisfy every condition. This view RANKS the field and exposes each condition as a
-- pass/fail flag, so you can see WHY a row does or does not fire -- and how far the
-- real finding sits from everything else.
--
-- Read it as the middle act: preflight (can the data answer?) -> diagnostic (what does
-- the field look like?) -> query (what actually fires?).
--
--   runs_weekends = weekend cost >= 85% of weekday cost (nothing is being shut down)
--   fires = the combination the detector requires
--
-- Run it (from the ./run.sh prompt):
--   .read queries/scheduling-miss/diagnostic.duckdb.sql

WITH resource_daily AS (
    SELECT resourceid,
           COALESCE(x_servicecode, servicename, 'Unknown')      AS service,
           subaccountid,
           COALESCE(providername, invoiceissuername, 'Unknown')  AS provider,
           CAST(chargeperiodstart AS DATE)                       AS day,
           EXTRACT(ISODOW FROM CAST(chargeperiodstart AS DATE))          AS dow,
           SUM(billedcost)                                       AS daily_cost
    FROM bill
    WHERE CAST(chargeperiodstart AS DATE) >= (CURRENT_DATE - INTERVAL 30 DAY)
      AND billedcost > 0
      AND resourceid IS NOT NULL AND resourceid != ''
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      -- Exclude data transfer rows so compute scheduling signal is not diluted
      -- by egress charges (which accumulate regardless of scheduling).
      -- Remove this filter if x_usagetype is not available in your FOCUS export.
      AND (x_usagetype IS NULL OR x_usagetype NOT IN (
              'DataTransfer-Out-Bytes',
              'Network Internet Egress',
              'Data Transfer'
          ))
    GROUP BY 1, 2, 3, 4,
             CAST(chargeperiodstart AS DATE),
             EXTRACT(ISODOW FROM CAST(chargeperiodstart AS DATE))
)
, resource_schedule AS (
    SELECT resourceid, service, provider, subaccountid,
           COUNT(DISTINCT day)                                                          AS days_seen,
           SUM(daily_cost)                                                              AS total_cost,
           AVG(CASE WHEN dow IN (6, 7) THEN daily_cost ELSE NULL END)                  AS avg_weekend_cost,
           AVG(CASE WHEN dow NOT IN (6, 7) THEN daily_cost ELSE NULL END)              AS avg_weekday_cost
    FROM resource_daily
    GROUP BY 1, 2, 3, 4
    HAVING COUNT(DISTINCT CASE WHEN dow IN (6, 7) THEN day END) >= 2
       AND COUNT(DISTINCT CASE WHEN dow NOT IN (6, 7) THEN day END) >= 5
),
scored AS (
    SELECT resourceid, service, provider, subaccountid,
           days_seen, total_cost,
           ROUND(avg_weekend_cost, 4)                                           AS avg_weekend_cost,
           ROUND(avg_weekday_cost, 4)                                           AS avg_weekday_cost,
           ROUND(avg_weekend_cost / NULLIF(avg_weekday_cost, 0), 4)            AS weekend_weekday_ratio
    FROM resource_schedule
        WHERE avg_weekday_cost > 0.001
)
SELECT
    regexp_extract(resourceid, '[^/]+$') AS resource, service, days_seen, ROUND(total_cost,2) AS total_cost, ROUND(avg_weekday_cost,4) AS avg_weekday_cost, ROUND(avg_weekend_cost,4) AS avg_weekend_cost, ROUND(avg_weekend_cost / NULLIF(avg_weekday_cost,0),3) AS weekend_weekday_ratio,
    (weekend_weekday_ratio >= 0.85) AS runs_weekends,
    (runs_weekends) AS fires
FROM scored
ORDER BY weekend_weekday_ratio DESC
LIMIT 10;
