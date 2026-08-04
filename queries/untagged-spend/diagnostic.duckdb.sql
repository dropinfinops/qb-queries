-- SPDX-License-Identifier: Apache-2.0
-- Untagged Spend -- Governance Gap : DIAGNOSTIC / TEACHING view (DuckDB)
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/untagged-spend/README.md
-- DuckDB. Runs against the playground `bill` view (./run.sh). Athena/Trino: query.sql
WITH resource_daily AS (
    SELECT resourceid,
           COALESCE(x_servicecode, servicename, 'Unknown')      AS service,
           subaccountid,
           COALESCE(providername, invoiceissuername, 'Unknown')  AS provider,
           CAST(chargeperiodstart AS DATE)                       AS day,
           SUM(billedcost)                                       AS daily_cost,
           MAX(tags)                                             AS tags
    FROM bill
    WHERE CAST(chargeperiodstart AS DATE) >= (CURRENT_DATE - INTERVAL 30 DAY)
      AND billedcost > 0
      AND resourceid IS NOT NULL AND resourceid != ''
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
    GROUP BY 1, 2, 3, 4, CAST(chargeperiodstart AS DATE)
),
tag_state AS (
    SELECT subaccountid,
           provider,
           resourceid,
           (MAX(tags) IS NULL OR MAX(tags) = '' OR MAX(tags) = '{}' OR MAX(tags) = 'null') AS untagged,
           SUM(daily_cost) AS resource_cost
    FROM resource_daily
    GROUP BY 1, 2, 3
),
scored AS (
    SELECT subaccountid,
           provider,
           COUNT(*)                                                    AS resources,
           COUNT(*) FILTER (WHERE untagged)                            AS untagged_resources,
           SUM(resource_cost)                                          AS total_cost_30d,
           SUM(resource_cost) FILTER (WHERE untagged)                  AS untagged_cost_30d
    FROM tag_state
    GROUP BY 1, 2
)
SELECT
    subaccountid,
    provider,
    resources,
    untagged_resources,
    ROUND(total_cost_30d, 2)                                              AS total_cost_30d,
    ROUND(COALESCE(untagged_cost_30d, 0), 2)                              AS untagged_cost_30d,
    ROUND(COALESCE(untagged_cost_30d, 0) / NULLIF(total_cost_30d, 0) * 100, 1) AS untagged_pct,
    (COALESCE(untagged_cost_30d, 0) > 0)     AS has_gap,
    (COALESCE(untagged_cost_30d, 0) > 0.30)  AS material,
    (COALESCE(untagged_cost_30d, 0) > 0.30)  AS fires
FROM scored
ORDER BY untagged_cost_30d DESC NULLS LAST
LIMIT 12;
