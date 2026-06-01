-- SPDX-License-Identifier: Apache-2.0
-- QB08: Governance Gap — significant spend with no cost allocation tags
--
-- Resources above the cost threshold with null or empty tags have no owner,
-- no cost centre, and no environment label — a governance process gap.
--
-- SETUP: Replace 'your_focus_table' with your FOCUS billing table name.
--        The HAVING threshold below is 0.01 * 30 = $0.30 over 30 days. Raise the
--        multiplier (or replace with an absolute value) to focus on material untagged spend.
--
-- DIALECT: Athena / Trino / Presto.
--   BigQuery: replace DATE_ADD('day', -N, CURRENT_DATE) with DATE_SUB(CURRENT_DATE, INTERVAL N DAY)
--
-- FOCUS 1.0 columns used (all standard):
--   resourceid, servicename, subaccountid, chargeperiodstart, billedcost, tags,
--   chargecategory, chargeclass, providername, invoiceissuername
-- Provider-specific columns:
--   x_servicecode (AWS extension) — falls back to servicename if absent

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
