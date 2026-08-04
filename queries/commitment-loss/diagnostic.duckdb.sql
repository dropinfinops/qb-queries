-- SPDX-License-Identifier: Apache-2.0
-- Commitment Loss -- RI/SP utilization getting worse : DIAGNOSTIC / TEACHING view (DuckDB)
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/commitment-loss/README.md
-- DuckDB. Runs against the playground `bill` view (./run.sh). Athena/Trino: query.sql
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
    FROM bill
    WHERE commitmentdiscountid IS NOT NULL
      AND chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND chargeperiodstart >= CAST((CURRENT_DATE - INTERVAL 37 DAY) AS TIMESTAMP)
    GROUP BY commitmentdiscountid, CAST(chargeperiodstart AS DATE)
)
, commitment_metrics AS (
    SELECT
        commitmentdiscountid, subaccountid, provider, service, commitment_type,
        SUM(CASE WHEN billing_day >= (CURRENT_DATE - INTERVAL 7 DAY) THEN unused_cost ELSE 0 END) AS recent_unused_7d,
        SUM(CASE WHEN billing_day >= (CURRENT_DATE - INTERVAL 7 DAY) THEN total_cost  ELSE 0 END) AS recent_total_7d,
        SUM(CASE WHEN billing_day >= (CURRENT_DATE - INTERVAL 7 DAY) THEN used_cost   ELSE 0 END) AS recent_used_7d,
        SUM(CASE WHEN billing_day <  (CURRENT_DATE - INTERVAL 7 DAY) THEN unused_cost ELSE 0 END) AS baseline_unused_30d,
        SUM(CASE WHEN billing_day <  (CURRENT_DATE - INTERVAL 7 DAY) THEN total_cost  ELSE 0 END) AS baseline_total_30d,
        SUM(unused_cost)                                                                             AS total_unused_37d
    FROM daily_commitment
    GROUP BY 1, 2, 3, 4, 5
),
scored AS (
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
        WHERE total_unused_37d > 0
)
SELECT
    commitmentdiscountid, provider, service, commitment_type, ROUND(baseline_waste_ratio,3) AS baseline_waste_ratio, ROUND(recent_waste_ratio,3)   AS recent_waste_ratio, ROUND(waste_ratio_delta,3)    AS waste_ratio_delta, is_stranded, ROUND(total_unused_37d,2) AS total_unused_37d,
    (waste_ratio_delta > 0.20) AS severe,
    (waste_ratio_delta > 0.15) AS moderate,
    (is_stranded = 1) AS stranded,
    (total_unused_37d > 16.67) AS material,
    ((severe OR moderate OR stranded) AND material) AS fires
FROM scored
ORDER BY waste_ratio_delta DESC
LIMIT 10;
