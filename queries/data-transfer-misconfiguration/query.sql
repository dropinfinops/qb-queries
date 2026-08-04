-- SPDX-License-Identifier: Apache-2.0
-- Data Transfer Misconfiguration — NAT Gateway byte-processing waste and cross-AZ ratio
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/data-transfer-misconfiguration/README.md
-- Athena / Trino / Presto. Replace `your_focus_table` (below) with your FOCUS billing table.
WITH networking_daily AS (
    SELECT
        subaccountid,
        CAST(chargeperiodstart AS DATE) AS billing_day,
        -- AWS: NatGateway-Bytes; Azure: NAT Gateway Data Processed; GCP: NAT Data Processed
        SUM(CASE WHEN x_usagetype IN ('NatGateway-Bytes', 'NAT Gateway Data Processed', 'NAT Data Processed')
                      OR x_usagetype LIKE '%NatGateway-Bytes%'
                 THEN billedcost ELSE 0 END)                                      AS nat_bytes_cost,
        -- AWS: NatGateway-Hours; Azure: NAT Uptime
        SUM(CASE WHEN x_usagetype IN ('NatGateway-Hours', 'NAT Gateway Hours', 'NAT Uptime')
                      OR x_usagetype LIKE '%NatGateway-Hours%'
                 THEN billedcost ELSE 0 END)                                      AS nat_hours_cost,
        -- AWS: DataTransfer-Regional-Bytes; Azure: VNet Peering; GCP: Network Inter Zone Data Transfer Out
        SUM(CASE WHEN x_usagetype IN ('DataTransfer-Regional-Bytes', 'VNet Peering', 'Network Inter Zone Data Transfer Out')
                      OR x_usagetype LIKE '%DataTransfer-Regional-Bytes%'
                 THEN billedcost ELSE 0 END)                                      AS cross_az_cost,
        SUM(CASE WHEN servicename LIKE '%EC2%'
                      OR servicename LIKE '%Virtual Machine%'
                      OR servicename LIKE '%Compute Engine%'
                 THEN billedcost ELSE 0 END)                                      AS ec2_cost,
        SUM(CASE WHEN servicename IN ('Amazon VPC', 'Virtual Network', 'Cloud NAT')
                      OR servicename LIKE '%VPC%'
                 THEN billedcost ELSE 0 END)                                      AS vpc_cost
    FROM your_focus_table  -- << REPLACE with your FOCUS billing table name
    WHERE chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND chargeperiodstart >= CAST(DATE_ADD('day', -30, CURRENT_DATE) AS TIMESTAMP)
    GROUP BY subaccountid, CAST(chargeperiodstart AS DATE)
)
, account_metrics AS (
    SELECT
        subaccountid,
        SUM(nat_bytes_cost) AS total_nat_bytes_30d,
        SUM(nat_hours_cost) AS total_nat_hours_30d,
        SUM(cross_az_cost)  AS total_cross_az_30d,
        SUM(ec2_cost)       AS total_ec2_30d,
        SUM(vpc_cost)       AS total_vpc_30d
    FROM networking_daily
    GROUP BY subaccountid
)
SELECT
    subaccountid,
    total_nat_bytes_30d,
    total_nat_hours_30d,
    total_cross_az_30d,
    total_ec2_30d,
    total_vpc_30d,
    CASE WHEN (total_nat_bytes_30d + total_nat_hours_30d) > 0
         THEN total_nat_bytes_30d / (total_nat_bytes_30d + total_nat_hours_30d)
         ELSE 0 END AS nat_ratio,
    CASE WHEN total_ec2_30d > 0
         THEN total_cross_az_30d / total_ec2_30d
         ELSE 0 END AS cross_az_ratio,
    total_nat_bytes_30d + total_cross_az_30d AS total_networking_waste_30d
FROM account_metrics
WHERE (total_nat_bytes_30d + total_nat_hours_30d) > 0
  AND (total_nat_bytes_30d + total_cross_az_30d) > 100.0  -- $100 floor over 30 days
  AND (
      (total_nat_bytes_30d / NULLIF(total_nat_bytes_30d + total_nat_hours_30d, 0)) > 0.60
      OR (total_cross_az_30d / NULLIF(total_ec2_30d, 0)) > 0.12
  )
ORDER BY total_networking_waste_30d DESC
LIMIT 25
