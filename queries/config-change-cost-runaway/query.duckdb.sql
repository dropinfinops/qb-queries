-- SPDX-License-Identifier: Apache-2.0
-- Config-Change Cost Runaway -- Config-Change Data-Processing Runaway (DuckDB)
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/config-change-cost-runaway/README.md
-- DuckDB. Runs against the playground `bill` view (./run.sh). Athena/Trino: query.sql
WITH dp_daily AS (
    SELECT
        subaccountid,
        CAST(chargeperiodstart AS DATE) AS billing_day,
        -- data-processing (per-GB) legs: NAT bytes, cross-AZ, egress, inspection/firewall
        SUM(CASE WHEN (
                (x_usagetype LIKE '%NatGateway-Bytes%'
                 OR x_usagetype LIKE '%DataTransfer-Regional-Bytes%'
                 OR x_usagetype LIKE '%DataTransfer-Out-Bytes%'
                 OR x_usagetype LIKE '%Firewall%'
                 OR x_usagetype LIKE '%GWLBytes%')
                AND NOT (x_usagetype LIKE '%Hours%' OR x_usagetype LIKE '%Uptime%')
            ) THEN billedcost ELSE 0 END) AS dp_cost,
        -- compute legs (the discriminant): EC2 / VM / Compute Engine, excluding the byte legs
        SUM(CASE WHEN (
                (servicename LIKE '%EC2%' OR servicename LIKE '%Virtual Machine%'
                 OR servicename LIKE '%Compute Engine%')
                AND NOT (
                    (x_usagetype LIKE '%NatGateway-Bytes%'
                     OR x_usagetype LIKE '%DataTransfer-Regional-Bytes%'
                     OR x_usagetype LIKE '%DataTransfer-Out-Bytes%'
                     OR x_usagetype LIKE '%Firewall%'
                     OR x_usagetype LIKE '%GWLBytes%')
                    AND NOT (x_usagetype LIKE '%Hours%' OR x_usagetype LIKE '%Uptime%')
                )
            ) THEN billedcost ELSE 0 END) AS compute_cost
    FROM bill
    WHERE chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= CURRENT_DATE - INTERVAL 60 DAY
    GROUP BY 1, 2
),
baseline AS (   -- prior-30-day baseline: days -60..-31
    SELECT subaccountid,
           SUM(dp_cost)      / NULLIF(COUNT(*), 0) AS dp_baseline_daily,
           SUM(compute_cost) / NULLIF(COUNT(*), 0) AS compute_baseline_daily,
           COUNT(*)                                AS baseline_days
    FROM dp_daily
    WHERE billing_day < CURRENT_DATE - INTERVAL 30 DAY
    GROUP BY subaccountid
),
recent AS (     -- last 7 days
    SELECT subaccountid,
           SUM(dp_cost)                            AS dp_recent_7d,
           SUM(dp_cost)      / NULLIF(COUNT(*), 0) AS dp_recent_daily,
           SUM(compute_cost) / NULLIF(COUNT(*), 0) AS compute_recent_daily
    FROM dp_daily
    WHERE billing_day >= CURRENT_DATE - INTERVAL 7 DAY
    GROUP BY subaccountid
),
persistence AS ( -- how many of the last 7 days were elevated (>= 2.5x baseline)
    SELECT d.subaccountid,
           COUNT(CASE WHEN d.billing_day >= CURRENT_DATE - INTERVAL 7 DAY
                       AND d.dp_cost >= b.dp_baseline_daily * 2.5 THEN 1 END) AS elevated_days_recent,
           MIN(CASE WHEN d.dp_cost >= b.dp_baseline_daily * 2.5 THEN d.billing_day END) AS onset_day
    FROM dp_daily d
    JOIN baseline b ON d.subaccountid = b.subaccountid
    WHERE d.billing_day >= CURRENT_DATE - INTERVAL 30 DAY
    GROUP BY d.subaccountid
)
SELECT
    r.subaccountid,
    ROUND(b.dp_baseline_daily, 2)                                          AS dp_baseline_daily,
    ROUND(r.dp_recent_daily, 2)                                            AS dp_recent_daily,
    ROUND(r.dp_recent_daily / NULLIF(b.dp_baseline_daily, 0), 2)           AS dp_step_ratio,
    ROUND(r.compute_recent_daily / NULLIF(b.compute_baseline_daily, 0), 2) AS compute_growth,
    ROUND(r.dp_recent_7d, 2)                                               AS dp_recent_7d,
    p.elevated_days_recent,
    p.onset_day
FROM recent r
JOIN baseline    b ON r.subaccountid = b.subaccountid
JOIN persistence p ON r.subaccountid = p.subaccountid
WHERE b.baseline_days >= 14
  AND b.dp_baseline_daily > 0
  AND r.dp_recent_daily >= b.dp_baseline_daily * 2.5     -- STEP
  AND (r.compute_recent_daily / NULLIF(b.compute_baseline_daily, 0)) < 1.3  -- FLAT COMPUTE
  AND p.elevated_days_recent >= 5                        -- PERSISTENCE
  AND r.dp_recent_7d >= 50.0                             -- dollar floor (suppress noise)
ORDER BY r.dp_recent_7d DESC
LIMIT 25;
