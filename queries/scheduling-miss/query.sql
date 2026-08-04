-- SPDX-License-Identifier: Apache-2.0
-- Scheduling Miss: Scheduling Miss — weekend cost >= 85% of weekday cost
--
-- Detects resources that should idle on weekends but don't. The signal is the
-- absence of expected cost reduction, not a cost spike.
--
-- SETUP: Replace 'your_focus_table' with your FOCUS billing table name.
--        Adjust the 0.01 cost floor to match your minimum meaningful daily spend.
--
-- DIALECT: Athena / Trino / Presto.
--   DAY_OF_WEEK() returns 1=Monday … 7=Sunday (ISO 8601) in Trino/Presto.
--   BigQuery/MySQL return 1=Sunday … 7=Saturday — adjust dow IN (6, 7) accordingly.
--   BigQuery: replace DATE_ADD('day', -N, CURRENT_DATE) with DATE_SUB(CURRENT_DATE, INTERVAL N DAY)
--
-- FOCUS 1.0 columns used (all standard unless noted):
--   resourceid, servicename, subaccountid, chargeperiodstart, billedcost,
--   chargecategory, chargeclass, providername, invoiceissuername
-- Provider-specific columns:
--   x_servicecode (AWS extension) — falls back to servicename if absent
--   x_usagetype   (AWS extension) — used here only to exclude data transfer rows from the
--                                   compute cost comparison. Remove this filter if your FOCUS
--                                   export does not include x_usagetype.

WITH resource_daily AS (
    SELECT resourceid,
           COALESCE(x_servicecode, servicename, 'Unknown')      AS service,
           subaccountid,
           COALESCE(providername, invoiceissuername, 'Unknown')  AS provider,
           CAST(chargeperiodstart AS DATE)                       AS day,
           DAY_OF_WEEK(CAST(chargeperiodstart AS DATE))          AS dow,
           SUM(billedcost)                                       AS daily_cost
    FROM your_focus_table  -- << REPLACE with your FOCUS billing table name
    WHERE CAST(chargeperiodstart AS DATE) >= DATE_ADD('day', -30, CURRENT_DATE)
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
             DAY_OF_WEEK(CAST(chargeperiodstart AS DATE))
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
)
SELECT resourceid, service, provider, subaccountid,
       days_seen, total_cost,
       ROUND(avg_weekend_cost, 4)                                           AS avg_weekend_cost,
       ROUND(avg_weekday_cost, 4)                                           AS avg_weekday_cost,
       ROUND(avg_weekend_cost / NULLIF(avg_weekday_cost, 0), 4)            AS weekend_weekday_ratio
FROM resource_schedule
WHERE avg_weekday_cost > 0.01  -- minimum weekday cost; raise to suppress noise
  AND avg_weekend_cost / NULLIF(avg_weekday_cost, 0) >= 0.85
ORDER BY weekend_weekday_ratio DESC
LIMIT 25
