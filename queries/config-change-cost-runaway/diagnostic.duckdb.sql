-- Config-Change Cost Runaway -- Config-Change Data-Processing Runaway : DIAGNOSTIC / TEACHING view (DuckDB)
--
-- This is NOT the detector. The detector (query.duckdb.sql / query.sql) keeps ONLY the
-- subaccounts that trip all three conditions -- in this sample that's a single row.
--
-- This view instead RANKS the top 10 subaccounts by the data-processing step and shows the
-- three triad conditions as pass/fail flags, so you can see the mechanics: how the real
-- runaway separates from normal accounts, and exactly which rule each account passes or fails.
-- Run it, then run query.duckdb.sql to see the detector keep only the confirmed one.
--
--   step  = data-processing spend >= 2.5x prior-30d baseline
--   flat  = compute growth < 1.3x  (rules out a real traffic surge)
--   days  = elevated on >= 5 of the last 7 days
--   FIRES = all three true

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
    FROM bill
    WHERE chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND CAST(chargeperiodstart AS DATE) >= CURRENT_DATE - INTERVAL 60 DAY
    GROUP BY 1, 2
),
baseline AS (
    SELECT subaccountid,
           SUM(dp_cost)      / NULLIF(COUNT(*), 0) AS dp_baseline_daily,
           SUM(compute_cost) / NULLIF(COUNT(*), 0) AS compute_baseline_daily,
           COUNT(*)                                AS baseline_days
    FROM dp_daily
    WHERE billing_day < CURRENT_DATE - INTERVAL 30 DAY
    GROUP BY subaccountid
),
recent AS (
    SELECT subaccountid,
           SUM(dp_cost)                            AS dp_recent_7d,
           SUM(dp_cost)      / NULLIF(COUNT(*), 0) AS dp_recent_daily,
           SUM(compute_cost) / NULLIF(COUNT(*), 0) AS compute_recent_daily
    FROM dp_daily
    WHERE billing_day >= CURRENT_DATE - INTERVAL 7 DAY
    GROUP BY subaccountid
),
persistence AS (
    SELECT d.subaccountid,
           COUNT(CASE WHEN d.billing_day >= CURRENT_DATE - INTERVAL 7 DAY
                       AND d.dp_cost >= b.dp_baseline_daily * 2.5 THEN 1 END) AS elevated_days
    FROM dp_daily d
    JOIN baseline b ON d.subaccountid = b.subaccountid
    WHERE d.billing_day >= CURRENT_DATE - INTERVAL 30 DAY
    GROUP BY d.subaccountid
),
scored AS (
    SELECT
        r.subaccountid,
        ROUND(r.dp_recent_daily / NULLIF(b.dp_baseline_daily, 0), 2)           AS dp_step_ratio,
        ROUND(r.compute_recent_daily / NULLIF(b.compute_baseline_daily, 0), 2) AS compute_growth,
        ROUND(r.dp_recent_7d, 2)                                               AS dp_recent_7d,
        p.elevated_days,
        (r.dp_recent_daily >= b.dp_baseline_daily * 2.5)                                    AS step,
        ((r.compute_recent_daily / NULLIF(b.compute_baseline_daily, 0)) < 1.3)              AS flat,
        (p.elevated_days >= 5)                                                              AS days
    FROM recent r
    JOIN baseline    b ON r.subaccountid = b.subaccountid
    JOIN persistence p ON r.subaccountid = p.subaccountid
    WHERE b.baseline_days >= 14
      AND b.dp_baseline_daily > 0
      AND r.dp_recent_7d >= 1        -- ignore dead subaccounts so the ranking is meaningful
)
SELECT
    subaccountid, dp_step_ratio, compute_growth, dp_recent_7d, elevated_days,
    step, flat, days,
    (step AND flat AND days) AS fires
FROM scored
ORDER BY dp_step_ratio DESC
LIMIT 10;
