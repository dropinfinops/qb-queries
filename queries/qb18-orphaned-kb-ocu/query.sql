-- SPDX-License-Identifier: Apache-2.0
-- QB18: Orphaned Bedrock Knowledge Base OCU — OpenSearch OCU cost with no matching Bedrock inference
--
-- When AWS Bedrock Knowledge Base Quick-create provisions a vector store, it silently
-- creates an Amazon OpenSearch Serverless collection. Deleting the Knowledge Base from
-- the Bedrock console does NOT delete the OpenSearch collection. OCU charges continue
-- appearing under "Amazon OpenSearch Service" — invisible to anyone monitoring Bedrock spend.
--
-- This query detects the billing disguise: OpenSearch OCU cost in an account where
-- Bedrock inference spend is less than 10% of the OCU cost. The OCU floor continues
-- billing at ~$345/month (2 OCU minimum × $0.24/hr × 24hr × 30d) regardless of
-- whether the Knowledge Base or any queries exist.
--
-- *** AWS-SPECIFIC QUERY ***
-- Uses servicename LIKE '%OpenSearch%' / '%Bedrock%' and x_usagetype LIKE '%OCU%' / '%InvokeModel%'.
-- x_usagetype is an AWS Data Exports extension column, not a FOCUS 1.0 standard field.
--
-- SETUP: Replace 'your_focus_table' with your FOCUS billing table name.
--
-- DIALECT: Athena / Trino / Presto.
--   BigQuery: replace DATE_ADD('day', -N, CURRENT_DATE) with DATE_SUB(CURRENT_DATE, INTERVAL N DAY)
--
-- FOCUS 1.0 columns used (all standard unless noted):
--   resourceid, subaccountid, chargeperiodstart, billedcost, servicename,
--   chargecategory, chargeclass
-- Provider-specific columns:
--   x_usagetype (AWS extension) — used to isolate OCU and InvokeModel rows

WITH ocu_daily AS (
    SELECT
        subaccountid,
        SUM(CASE WHEN x_usagetype LIKE '%OCU%' THEN billedcost ELSE 0 END) AS ocu_cost_30d,
        COUNT(DISTINCT resourceid)                                          AS ocu_collection_count
    FROM your_focus_table  -- << REPLACE with your FOCUS billing table name
    WHERE servicename  LIKE '%OpenSearch%'
      AND x_usagetype  LIKE '%OCU%'   -- AWS extension: OpenSearch Compute Unit rows
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= DATE_ADD('day', -30, CURRENT_DATE)
    GROUP BY subaccountid
)
, bedrock_inference AS (
    SELECT
        subaccountid,
        SUM(billedcost) AS bedrock_inference_cost_30d
    FROM your_focus_table  -- << REPLACE with your FOCUS billing table name
    WHERE servicename  LIKE '%Bedrock%'
      AND x_usagetype  LIKE '%InvokeModel%'  -- AWS extension: model invocation rows
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= DATE_ADD('day', -30, CURRENT_DATE)
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
LIMIT 25
