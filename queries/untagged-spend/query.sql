-- SPDX-License-Identifier: Apache-2.0
-- Untagged Spend: Governance Gap — significant spend with no cost allocation tags
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/untagged-spend/README.md
-- Athena / Trino / Presto. Replace `your_focus_table` (below) with your FOCUS billing table.
WITH resource_daily AS (
    SELECT resourceid,
           COALESCE(x_servicecode, servicename, 'Unknown')      AS service,
           subaccountid,
           COALESCE(providername, invoiceissuername, 'Unknown')  AS provider,
           CAST(chargeperiodstart AS DATE)                       AS day,
           SUM(billedcost)                                       AS daily_cost,
           MAX(tags)                                             AS tags
    FROM your_focus_table  -- << REPLACE with your FOCUS billing table name
    WHERE CAST(chargeperiodstart AS DATE) >= DATE_ADD('day', -30, CURRENT_DATE)
      AND billedcost > 0
      AND resourceid IS NOT NULL AND resourceid != ''
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
    GROUP BY 1, 2, 3, 4, CAST(chargeperiodstart AS DATE)
)
SELECT resourceid, service, provider, subaccountid,
       COUNT(DISTINCT day) AS days_seen,
       SUM(daily_cost)     AS total_cost,
       AVG(daily_cost)     AS avg_daily_cost
FROM resource_daily
WHERE (tags IS NULL OR tags = '' OR tags = '{}' OR tags = 'null')
GROUP BY 1, 2, 3, 4
HAVING SUM(daily_cost) > 0.01 * 30  -- 30-day cost floor; raise to focus on material spend
ORDER BY total_cost DESC
LIMIT 25
