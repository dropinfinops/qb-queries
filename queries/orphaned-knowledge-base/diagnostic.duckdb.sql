-- SPDX-License-Identifier: Apache-2.0
-- Orphaned Knowledge Base -- Orphaned Knowledge-Base OCU -- index capacity with no inference : DIAGNOSTIC / TEACHING view (DuckDB)
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/orphaned-knowledge-base/README.md
-- DuckDB. Runs against the playground `bill` view (./run.sh). Athena/Trino: query.sql
WITH ocu_daily AS (
    SELECT
        subaccountid,
        SUM(CASE WHEN x_usagetype LIKE '%OCU%' THEN billedcost ELSE 0 END) AS ocu_cost_30d,
        COUNT(DISTINCT resourceid)                                          AS ocu_collection_count
    FROM bill
    WHERE servicename  LIKE '%OpenSearch%'
      AND x_usagetype  LIKE '%OCU%'   -- AWS extension: OpenSearch Compute Unit rows
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= (CURRENT_DATE - INTERVAL 30 DAY)
    GROUP BY subaccountid
)
, bedrock_inference AS (
    SELECT
        subaccountid,
        SUM(billedcost) AS bedrock_inference_cost_30d
    FROM bill
    WHERE servicename  LIKE '%Bedrock%'
      AND x_usagetype  LIKE '%InvokeModel%'  -- AWS extension: model invocation rows
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= (CURRENT_DATE - INTERVAL 30 DAY)
    GROUP BY subaccountid
),
scored AS (
    SELECT
        o.subaccountid,
        ROUND(o.ocu_cost_30d, 4)                                              AS ocu_cost_30d,
        o.ocu_collection_count,
        ROUND(COALESCE(b.bedrock_inference_cost_30d, 0.0), 4)                 AS bedrock_inference_cost_30d,
        ROUND(
            o.ocu_cost_30d / NULLIF(COALESCE(b.bedrock_inference_cost_30d, 0.0), 0),
            2
        )                                                                     AS ocu_waste_ratio
    FROM ocu_daily o
    LEFT JOIN bedrock_inference b ON o.subaccountid = b.subaccountid
        WHERE o.ocu_cost_30d > 1
)
SELECT
    subaccountid, ocu_cost_30d, ocu_collection_count, bedrock_inference_cost_30d AS inference_cost_30d, ocu_waste_ratio,
    (inference_cost_30d < ocu_cost_30d * 0.10) AS no_inference,
    (ocu_cost_30d > 50.0) AS material,
    (no_inference AND material) AS fires
FROM scored
ORDER BY ocu_cost_30d DESC
LIMIT 10;
