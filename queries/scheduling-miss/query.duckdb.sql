-- SPDX-License-Identifier: Apache-2.0
-- Scheduling Miss — weekend cost >= 85% of weekday cost
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/scheduling-miss/README.md
-- DuckDB. Runs against the playground `bill` view (./run.sh). Athena/Trino: query.sql
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
LIMIT 25;
