-- QB22 -- Config-Change Data-Processing Runaway
-- DIALECT: Athena / Trino / Presto.  (See query.duckdb.sql for the local-playground version.)
--
-- What it catches: per-GB data-processing spend (NAT-gateway bytes, cross-AZ transfer,
-- traffic-inspection bytes) STEPS UP and STAYS elevated while compute stays flat -- the
-- billing shape of a networking/routing config change shipped without cost guardrails,
-- not an organic traffic surge (which would move compute too).
--
-- The triad (all three must hold, per subaccount):
--   1. STEP         -- recent data-processing daily cost >= 2.5x the prior-30-day baseline
--   2. FLAT COMPUTE -- recent compute daily cost < 1.3x its baseline (rules out real growth)
--   3. PERSISTENCE  -- elevated on >= 5 of the last 7 days (rules out a one-day blip)
--
-- Replace  your_focus_table  with your FOCUS billing table before running.

WITH dp_daily AS (
    SELECT
        subaccountid,
        CAST(chargeperiodstart AS DATE) AS billing_day,
        SUM(CASE WHEN (
                (x_usagetype LIKE '%NatGateway-Bytes%'
                 OR x_usagetype LIKE '%DataTransfer-Regional-Bytes%'
                 OR x_usagetype LIKE '%DataTransfer-Out-Bytes%'
                 OR x_usagetype LIKE '%Firewall%'
                 OR x_usagetype LIKE '%GWLBytes%')
                AND NOT (x_usagetype LIKE '%Hours%' OR x_usagetype LIKE '%Uptime%')
            ) THEN billedcost ELSE 0 END) AS dp_cost,
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
    FROM your_focus_table
    WHERE chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= DATE_ADD('day', -60, CURRENT_DATE)
    GROUP BY 1, 2
),
baseline AS (
    SELECT subaccountid,
           SUM(dp_cost)      / NULLIF(COUNT(*), 0) AS dp_baseline_daily,
           SUM(compute_cost) / NULLIF(COUNT(*), 0) AS compute_baseline_daily,
           COUNT(*)                                AS baseline_days
    FROM dp_daily
    WHERE billing_day < DATE_ADD('day', -30, CURRENT_DATE)
    GROUP BY subaccountid
),
recent AS (
    SELECT subaccountid,
           SUM(dp_cost)                            AS dp_recent_7d,
           SUM(dp_cost)      / NULLIF(COUNT(*), 0) AS dp_recent_daily,
           SUM(compute_cost) / NULLIF(COUNT(*), 0) AS compute_recent_daily
    FROM dp_daily
    WHERE billing_day >= DATE_ADD('day', -7, CURRENT_DATE)
    GROUP BY subaccountid
),
persistence AS (
    SELECT d.subaccountid,
           COUNT(CASE WHEN d.billing_day >= DATE_ADD('day', -7, CURRENT_DATE)
                       AND d.dp_cost >= b.dp_baseline_daily * 2.5 THEN 1 END) AS elevated_days_recent,
           MIN(CASE WHEN d.dp_cost >= b.dp_baseline_daily * 2.5 THEN d.billing_day END) AS onset_day
    FROM dp_daily d
    JOIN baseline b ON d.subaccountid = b.subaccountid
    WHERE d.billing_day >= DATE_ADD('day', -30, CURRENT_DATE)
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
  AND r.dp_recent_daily >= b.dp_baseline_daily * 2.5
  AND (r.compute_recent_daily / NULLIF(b.compute_baseline_daily, 0)) < 1.3
  AND p.elevated_days_recent >= 5
  AND r.dp_recent_7d >= 50.0
ORDER BY r.dp_recent_7d DESC
LIMIT 25;
