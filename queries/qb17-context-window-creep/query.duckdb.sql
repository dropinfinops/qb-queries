-- SPDX-License-Identifier: Apache-2.0
-- QB17: Context Window Creep — Bedrock inference token cost growing > 15% month-over-month
--
-- Developers silently grow system prompts over sprints — adding few-shot examples, safety
-- instructions, longer RAG chunks, or extended conversation history windows — without
-- measuring the cost impact. Token cost is proportional to prompt size, so a 30% prompt
-- growth compounds silently across quarters, invisible in standard budget dashboards that
-- only watch total spend trends.
--
-- This query compares per-resource inference cost: current 30 days vs prior 30 days.
-- A > 15% MoM cost increase is used as a proxy for token volume growth, since per-token
-- rates are flat (rate changes would appear as step functions, not gradual ramps).
--
-- *** AWS-SPECIFIC QUERY ***
-- Uses servicename LIKE '%Bedrock%' and x_usagetype LIKE '%InvokeModel%'.
-- x_usagetype is an AWS Data Exports extension column, not a FOCUS 1.0 standard field.
--
-- SETUP: Replace 'bill' with your FOCUS billing table name.
--
-- DIALECT: DuckDB — local playground.
--   (See query.sql in this folder for the Athena / Trino / Presto version.)
--
-- FOCUS 1.0 columns used (all standard unless noted):
--   resourceid, subaccountid, chargeperiodstart, billedcost, consumedquantity,
--   servicename, chargecategory, chargeclass
-- Provider-specific columns:
--   x_usagetype (AWS extension) — used to isolate Bedrock InvokeModel rows

--
-- Run it (from the ./run.sh prompt):
--   .read queries/qb17-context-window-creep/query.duckdb.sql

WITH inference_monthly AS (
    SELECT
        subaccountid,
        resourceid,
        CASE
            WHEN CAST(chargeperiodstart AS DATE) >= (CURRENT_DATE - INTERVAL 30 DAY)
                THEN 'current'
            ELSE 'prior'
        END                   AS period,
        SUM(billedcost)       AS period_cost,
        SUM(consumedquantity) AS period_tokens_k
    FROM bill
    WHERE servicename    LIKE '%Bedrock%'
      AND x_usagetype    LIKE '%InvokeModel%'  -- AWS extension: isolates model invocation charges
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= (CURRENT_DATE - INTERVAL 60 DAY)
    GROUP BY 1, 2, 3
)
, pivoted AS (
    SELECT
        subaccountid,
        resourceid,
        SUM(CASE WHEN period = 'current' THEN period_cost     ELSE 0 END) AS current_cost,
        SUM(CASE WHEN period = 'prior'   THEN period_cost     ELSE 0 END) AS prior_cost,
        SUM(CASE WHEN period = 'current' THEN period_tokens_k ELSE 0 END) AS current_tokens_k,
        SUM(CASE WHEN period = 'prior'   THEN period_tokens_k ELSE 0 END) AS prior_tokens_k
    FROM inference_monthly
    GROUP BY 1, 2
)
SELECT
    subaccountid,
    resourceid,
    ROUND(current_cost, 4)                                                    AS current_month_cost,
    ROUND(prior_cost, 4)                                                      AS prior_month_cost,
    ROUND(current_tokens_k, 2)                                                AS current_tokens_k,
    ROUND(prior_tokens_k, 2)                                                  AS prior_tokens_k,
    ROUND(
        (current_cost - prior_cost) / NULLIF(prior_cost, 0) * 100.0,
        2
    )                                                                         AS token_growth_pct,
    ROUND(current_cost - prior_cost, 4)                                       AS monthly_cost_delta
FROM pivoted
WHERE prior_cost > 10.0          -- floor: exclude new workloads with no meaningful history
  AND current_cost > prior_cost * 1.15  -- >15% MoM growth
ORDER BY token_growth_pct DESC
LIMIT 25
