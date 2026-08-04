-- SPDX-License-Identifier: Apache-2.0
-- Unauthorized Compute : DIAGNOSTIC / TEACHING view (DuckDB)
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/unauthorized-compute/README.md
-- DuckDB. Runs against the playground `bill` view (./run.sh). Athena/Trino: query.sql
WITH region_first_seen AS (
    SELECT subaccountid,
           regionid,
           MIN(CAST(chargeperiodstart AS DATE)) AS first_seen_date
    FROM bill
    WHERE billedcost > 0
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND regionid IS NOT NULL AND regionid != ''
    GROUP BY subaccountid, regionid
),
region_spend AS (
    SELECT t.subaccountid,
           t.regionid,
           COALESCE(t.providername, t.invoiceissuername, 'Unknown') AS provider,
           r.first_seen_date,
           DATE_DIFF('day', r.first_seen_date, CURRENT_DATE)        AS days_since_first_seen,
           COUNT(DISTINCT t.resourceid)                             AS resources,
           SUM(t.billedcost)                                        AS total_cost
    FROM bill t
    JOIN region_first_seen r
      ON t.regionid     = r.regionid
     AND t.subaccountid = r.subaccountid
    WHERE t.billedcost > 0
      AND t.resourceid IS NOT NULL AND t.resourceid != ''
      AND t.chargecategory = 'Usage'
      AND (t.chargeclass IS NULL OR t.chargeclass != 'Correction')
    GROUP BY 1, 2, 3, 4, 5
)
SELECT
    subaccountid,
    regionid,
    provider,
    first_seen_date,
    days_since_first_seen,
    resources,
    ROUND(total_cost, 2) AS total_cost,
    (days_since_first_seen <= 30) AS new_region,
    (total_cost > 0.01)           AS material,
    (days_since_first_seen <= 30 AND total_cost > 0.01) AS fires
FROM region_spend
ORDER BY days_since_first_seen ASC, total_cost DESC
LIMIT 12;
