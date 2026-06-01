-- SPDX-License-Identifier: Apache-2.0
-- QB10: Commitment Loss — RI/SP utilization waste ratio deteriorating vs baseline
--
-- Detects committed discounts (Reserved Instances, Savings Plans, CUDs) where the
-- fraction of spend going to 'Unused' rows has increased meaningfully in the last 7 days
-- compared to the prior 30-day baseline. Also flags commitments that have generated zero
-- 'Used' rows for the entire recent window (stranded commitment).
--
-- Dollar floor: total unused spend over 37 days > $16.67 suppresses noise on tiny commitments.
--
-- SETUP: Replace 'your_focus_table' with your FOCUS billing table name.
--
-- DIALECT: Athena / Trino / Presto.
--   BigQuery: replace DATE_ADD('day', -N, CURRENT_DATE) with DATE_SUB(CURRENT_DATE, INTERVAL N DAY)
--             and CAST(... AS TIMESTAMP) with CAST(... AS DATETIME)
--
-- FOCUS 1.0 columns used (all standard):
--   commitmentdiscountid, commitmentdiscountstatus, commitmentdiscounttype,
--   effectivecost, subaccountid, chargeperiodstart, chargecategory, chargeclass,
--   servicename, providername, invoiceissuername
-- Provider-specific columns:
--   x_servicecode (AWS extension) — falls back to servicename if absent

WITH daily_commitment AS (
    SELECT
        commitmentdiscountid,
        CAST(chargeperiodstart AS DATE) AS billing_day,
        SUM(CASE WHEN commitmentdiscountstatus = 'Used'   THEN effectivecost ELSE 0 END) AS used_cost,
        SUM(CASE WHEN commitmentdiscountstatus = 'Unused' THEN effectivecost ELSE 0 END) AS unused_cost,
        SUM(effectivecost)                                                                AS total_cost,
        MAX(COALESCE(subaccountid, ''))                                                   AS subaccountid,
        MAX(COALESCE(providername, invoiceissuername, 'Unknown'))                         AS provider,
        MAX(COALESCE(x_servicecode, servicename, 'Unknown'))                             AS service,
        MAX(commitmentdiscounttype)                                                       AS commitment_type
    FROM your_focus_table  -- << REPLACE with your FOCUS billing table name
    WHERE commitmentdiscountid IS NOT NULL
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND chargeperiodstart >= CAST(DATE_ADD('day', -37, CURRENT_DATE) AS TIMESTAMP)
    GROUP BY commitmentdiscountid, CAST(chargeperiodstart AS DATE)
)
, commitment_metrics AS (
    SELECT
        commitmentdiscountid, subaccountid, provider, service, commitment_type,
        SUM(CASE WHEN billing_day >= DATE_ADD('day', -7,  CURRENT_DATE) THEN unused_cost ELSE 0 END) AS recent_unused_7d,
        SUM(CASE WHEN billing_day >= DATE_ADD('day', -7,  CURRENT_DATE) THEN total_cost  ELSE 0 END) AS recent_total_7d,
        SUM(CASE WHEN billing_day >= DATE_ADD('day', -7,  CURRENT_DATE) THEN used_cost   ELSE 0 END) AS recent_used_7d,
        SUM(CASE WHEN billing_day <  DATE_ADD('day', -7,  CURRENT_DATE) THEN unused_cost ELSE 0 END) AS baseline_unused_30d,
        SUM(CASE WHEN billing_day <  DATE_ADD('day', -7,  CURRENT_DATE) THEN total_cost  ELSE 0 END) AS baseline_total_30d,
        SUM(unused_cost)                                                                             AS total_unused_37d
    FROM daily_commitment
    GROUP BY 1, 2, 3, 4, 5
)
SELECT
    commitmentdiscountid,
    subaccountid, provider, service, commitment_type,
    CASE WHEN recent_total_7d    > 0 THEN recent_unused_7d    / recent_total_7d    ELSE 0 END AS recent_waste_ratio,
    CASE WHEN baseline_total_30d > 0 THEN baseline_unused_30d / baseline_total_30d ELSE 0 END AS baseline_waste_ratio,
    CASE WHEN recent_total_7d > 0 AND baseline_total_30d > 0
         THEN (recent_unused_7d / recent_total_7d) - (baseline_unused_30d / baseline_total_30d)
         ELSE 0 END                                                                            AS waste_ratio_delta,
    CASE WHEN recent_used_7d = 0 AND recent_total_7d > 0 THEN 1 ELSE 0 END                    AS is_stranded,
    total_unused_37d
FROM commitment_metrics
WHERE total_unused_37d > 16.67  -- dollar floor: ~$0.45/day minimum waste to fire
  AND (
      -- Primary: waste ratio worsened by > 20 percentage points in the last 7 days
      ((recent_unused_7d / NULLIF(recent_total_7d, 0)) - (baseline_unused_30d / NULLIF(baseline_total_30d, 0))) > 0.20
      -- Secondary: moderate deterioration (15–20pp)
      OR ((recent_unused_7d / NULLIF(recent_total_7d, 0)) - (baseline_unused_30d / NULLIF(baseline_total_30d, 0))) > 0.15
      -- Tertiary: fully stranded commitment (zero Used rows this week)
      OR (recent_used_7d = 0 AND recent_total_7d > 0)
  )
ORDER BY total_unused_37d DESC
LIMIT 25
