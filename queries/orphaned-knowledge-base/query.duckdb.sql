-- SPDX-License-Identifier: Apache-2.0
-- Orphaned Knowledge Base: Orphaned Bedrock Knowledge Base OCU — OpenSearch OCU cost with no matching Bedrock inference
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
)
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
WHERE o.ocu_cost_30d > 50.0                                              -- $50 floor: ~2 days of minimum OCU charges
  AND COALESCE(b.bedrock_inference_cost_30d, 0.0) < (o.ocu_cost_30d * 0.10)  -- inference < 10% of OCU cost
ORDER BY o.ocu_cost_30d DESC
LIMIT 25;
