-- SPDX-License-Identifier: Apache-2.0
-- Data Transfer Misconfiguration -- Data-Transfer Misconfiguration -- per-GB legs dominating : DIAGNOSTIC / TEACHING view (DuckDB)
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/data-transfer-misconfiguration/README.md
-- DuckDB. Runs against the playground `bill` view (./run.sh). Athena/Trino: query.sql
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
    FROM bill
    WHERE chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
      AND chargeperiodstart >= CAST((CURRENT_DATE - INTERVAL 30 DAY) AS TIMESTAMP)
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
),
scored AS (
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
)
SELECT
    subaccountid, ROUND(total_nat_bytes_30d,2) AS nat_bytes, ROUND(total_nat_hours_30d,2) AS nat_hours, ROUND(total_cross_az_30d,2) AS cross_az, ROUND(nat_ratio,3) AS nat_ratio, ROUND(cross_az_ratio,3) AS cross_az_ratio, ROUND(total_networking_waste_30d,2) AS networking_waste_30d,
    (nat_ratio > 0.60) AS nat_heavy,
    (cross_az_ratio > 0.12) AS cross_az_heavy,
    (networking_waste_30d > 100.0) AS material,
    ((nat_heavy OR cross_az_heavy) AND material) AS fires
FROM scored
ORDER BY networking_waste_30d DESC
LIMIT 10;
