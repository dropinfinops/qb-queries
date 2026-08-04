-- SPDX-License-Identifier: Apache-2.0
-- Unauthorized Compute — spend in a region with no prior billing history
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/unauthorized-compute/README.md
-- Athena / Trino / Presto. Replace `your_focus_table` (below) with your FOCUS billing table.
WITH region_first_seen AS (
    SELECT subaccountid,
           regionid,
           MIN(CAST(chargeperiodstart AS DATE)) AS first_seen_date
    FROM your_focus_table  -- << REPLACE with your FOCUS billing table name
    WHERE billedcost > 0
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND regionid IS NOT NULL AND regionid != ''
    GROUP BY subaccountid, regionid
)
, new_region_spend AS (
    SELECT t.resourceid,
           t.regionid,
           COALESCE(t.x_servicecode, t.servicename, 'Unknown') AS service,
           t.subaccountid,
           COALESCE(t.providername, t.invoiceissuername, 'Unknown') AS provider,
           MAX(t.x_usagetype)     AS x_usagetype,      -- informational; AWS extension
           MAX(t.pricingcategory) AS pricingcategory,  -- informational
           MAX(t.tags)            AS tags,
           COUNT(DISTINCT CAST(t.chargeperiodstart AS DATE)) AS days_seen,
           SUM(t.billedcost)      AS total_cost,
           AVG(t.billedcost)      AS avg_daily_cost,
           SUM(COALESCE(t.consumedquantity, 0)) AS total_consumed_qty
    FROM your_focus_table t  -- << REPLACE with your FOCUS billing table name
    JOIN region_first_seen r
      ON t.regionid      = r.regionid
     AND t.subaccountid  = r.subaccountid
    WHERE t.billedcost > 0
      AND t.resourceid IS NOT NULL AND t.resourceid != ''
      AND t.chargecategory = 'Usage'
      AND (t.chargeclass IS NULL OR t.chargeclass != 'Correction')
      AND r.first_seen_date >= DATE_ADD('day', -30, CURRENT_DATE)
    GROUP BY 1, 2, 3, 4, 5
    HAVING SUM(t.billedcost) > 0.01  -- any non-trivial spend in a new region is suspicious
)
SELECT * FROM new_region_spend
ORDER BY total_cost DESC
LIMIT 40
