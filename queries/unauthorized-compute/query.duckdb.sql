-- SPDX-License-Identifier: Apache-2.0
-- Unauthorized Compute: Unauthorized Compute — spend in a region with no prior billing history
--
-- Detection rule: find account/region pairs whose FIRST billing row appeared within the
-- last 30 days. Any spend in a brand-new region for that account is anomalous.
-- No cost threshold is required — any spend in a historically absent region is suspicious.
-- Scoped per (subaccountid, regionid) so that an established region in account A does not
-- mask that same region being brand-new in a compromised account B.
--
-- SETUP: Replace 'bill' with your FOCUS billing table name.
--        The per-resource cost floor (0.01) suppresses trivial noise. Attackers launching
--        real compute generate material spend quickly.
--
-- DIALECT: DuckDB — local playground.
--   (See query.sql in this folder for the Athena / Trino / Presto version.)
--
-- FOCUS 1.0 columns used (all standard unless noted):
--   resourceid, regionid, servicename, subaccountid, chargeperiodstart, billedcost,
--   consumedquantity, chargecategory, chargeclass, pricingcategory, tags,
--   providername, invoiceissuername
-- Provider-specific columns:
--   x_servicecode (AWS extension) — falls back to servicename if absent
--   x_usagetype   (AWS extension) — included as informational output only, not a filter

--
-- Run it (from the ./run.sh prompt):
--   .read queries/unauthorized-compute/query.duckdb.sql

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
    FROM bill t
    JOIN region_first_seen r
      ON t.regionid      = r.regionid
     AND t.subaccountid  = r.subaccountid
    WHERE t.billedcost > 0
      AND t.resourceid IS NOT NULL AND t.resourceid != ''
      AND t.chargecategory = 'Usage'
      AND (t.chargeclass IS NULL OR t.chargeclass != 'Correction')
      AND r.first_seen_date >= (CURRENT_DATE - INTERVAL 30 DAY)
    GROUP BY 1, 2, 3, 4, 5
    HAVING SUM(t.billedcost) > 0.01  -- any non-trivial spend in a new region is suspicious
)
SELECT * FROM new_region_spend
ORDER BY total_cost DESC
LIMIT 40
