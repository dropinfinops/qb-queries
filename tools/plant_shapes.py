#!/usr/bin/env python3
"""Plant the four missing leak shapes into the sample corpus.

Four published detectors had no matching leak in samples/, so they correctly
returned zero rows while the answer key implied otherwise:

  QB01  waste              -- billed at full rate, near-zero consumption
  QB04  utilization ratio  -- provisioned far above what is consumed
  QB10  commitment loss    -- RI/SP utilization DETERIORATING week over week
  QB12  idle dev resource  -- flat billing, business-hours-only activity

This is additive by design: existing rows are never modified, so every detector
that already worked keeps its exact published figures (notably QB22's worked
example in samples/guide.html).

Deterministic -- no randomness. Re-running produces byte-identical output, and
it is idempotent: previously planted rows are dropped before re-inserting.

Usage:  python3 tools/plant_shapes.py
"""
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SAMPLES = REPO / "samples"

# Every planted resource carries this marker so the script is idempotent and so
# anyone can isolate (or exclude) synthetic additions.
MARK = "dif-planted"

# Anchor = the corpus's own latest billing day. Planted rows must never exceed it,
# or the playground's "shift to today" offset changes and every other figure moves.
ANCHOR = "(SELECT MAX(CAST(chargeperiodstart AS DATE)) FROM base)"


def sql_for(cloud: str) -> str:
    """Build the INSERT statements for one cloud's parquet file."""
    common = """
        billingcurrency, chargecategory, chargefrequency,
        billingperiodstart, billingperiodend, chargeperiodstart, chargeperiodend
    """
    if cloud == "aws":
        # -- QB01: idle Elastic IP -- billed hourly, consumes nothing at all.
        # -- QB04: over-provisioned instance -- 24 provisioned hours, ~4 consumed.
        return f"""
        INSERT INTO t BY NAME
        SELECT
            'us-east-1a'                    AS availabilityzone,
            3.60                            AS billedcost,
            '112233445566'                  AS billingaccountid,
            'acme-production'               AS billingaccountname,
            'USD'                           AS billingcurrency,
            'Usage'                         AS chargecategory,
            'Usage-Based'                   AS chargefrequency,
            'Amazon EC2 - ElasticIP:IdleAddress' AS chargedescription,
            d                               AS chargeperiodstart,
            d + INTERVAL 1 DAY              AS chargeperiodend,
            date_trunc('month', d)          AS billingperiodstart,
            date_trunc('month', d) + INTERVAL 1 MONTH AS billingperiodend,
            0.0                             AS consumedquantity,
            'Hours'                         AS consumedunit,
            3.60                            AS contractedcost,
            0.15                            AS contractedunitprice,
            3.60                            AS effectivecost,
            'Amazon Web Services, Inc.'     AS invoiceissuername,
            3.60                            AS listcost,
            0.15                            AS listunitprice,
            'Standard'                      AS pricingcategory,
            24.0                            AS pricingquantity,
            'Hours'                         AS pricingunit,
            'AWS'                           AS providername,
            'Amazon Web Services, Inc.'     AS publishername,
            'us-east-1'                     AS regionid,
            'US East (N. Virginia)'         AS regionname,
            'eipalloc-0idle7f3a21'          AS resourceid,
            'legacy-nat-failover-ip'        AS resourcename,
            'networking'                    AS resourcetype,
            'Networking'                    AS servicecategory,
            'Amazon EC2'                    AS servicename,
            'AmazonEC2-ElasticIP:IdleAddress' AS skuid,
            'AmazonEC2-ElasticIP:IdleAddress-price' AS skupriceid,
            '112233445566-us-east-1'        AS subaccountid,
            'acme-production / US East (N. Virginia)' AS subaccountname,
            '{{"{MARK}": "qb01", "env": "production"}}' AS tags,
            'AmazonEC2'                     AS x_servicecode,
            'ElasticIP:IdleAddress'         AS x_usagetype
        FROM (SELECT unnest(generate_series({ANCHOR} - 29, {ANCHOR}, INTERVAL 1 DAY)) AS d);

        INSERT INTO t BY NAME
        SELECT
            'us-east-1b'                    AS availabilityzone,
            7.20                            AS billedcost,
            '112233445566'                  AS billingaccountid,
            'acme-production'               AS billingaccountname,
            'USD'                           AS billingcurrency,
            'Usage'                         AS chargecategory,
            'Usage-Based'                   AS chargefrequency,
            'Amazon RDS - InstanceUsage:db.r5.2xlarge' AS chargedescription,
            d                               AS chargeperiodstart,
            d + INTERVAL 1 DAY              AS chargeperiodend,
            date_trunc('month', d)          AS billingperiodstart,
            date_trunc('month', d) + INTERVAL 1 MONTH AS billingperiodend,
            4.2                             AS consumedquantity,
            'Hours'                         AS consumedunit,
            7.20                            AS contractedcost,
            0.30                            AS contractedunitprice,
            7.20                            AS effectivecost,
            'Amazon Web Services, Inc.'     AS invoiceissuername,
            7.20                            AS listcost,
            0.30                            AS listunitprice,
            'Standard'                      AS pricingcategory,
            24.0                            AS pricingquantity,
            'Hours'                         AS pricingunit,
            'AWS'                           AS providername,
            'Amazon Web Services, Inc.'     AS publishername,
            'us-east-1'                     AS regionid,
            'US East (N. Virginia)'         AS regionname,
            'db-reporting-replica-01'       AS resourceid,
            'reporting-replica'             AS resourcename,
            'database'                      AS resourcetype,
            'Databases'                     AS servicecategory,
            'Amazon RDS'                    AS servicename,
            'AmazonRDS-InstanceUsage:db.r5.2xlarge' AS skuid,
            'AmazonRDS-InstanceUsage:db.r5.2xlarge-price' AS skupriceid,
            '112233445566-us-east-1'        AS subaccountid,
            'acme-production / US East (N. Virginia)' AS subaccountname,
            '{{"{MARK}": "qb04", "env": "production", "team": "analytics"}}' AS tags,
            'AmazonRDS'                     AS x_servicecode,
            'InstanceUsage:db.r5.2xlarge'   AS x_usagetype
        FROM (SELECT unnest(generate_series({ANCHOR} - 29, {ANCHOR}, INTERVAL 1 DAY)) AS d);
        """

    if cloud == "azure":
        # -- QB10: a reserved instance whose utilisation collapses in the last 8 days.
        # Baseline (days -37..-8): 40 Used / 4 Unused  -> ~9% wasted
        # Recent   (days  -7..0 ): 8 Used  / 36 Unused -> ~82% wasted  (delta ~73pp)
        rows = []
        for status, base_amt, recent_amt in (("Used", 40.0, 8.0), ("Unused", 4.0, 36.0)):
            rows.append(f"""
        INSERT INTO t BY NAME
        SELECT
            'USD'                           AS billingcurrency,
            'Usage'                         AS chargecategory,
            'Recurring'                     AS chargefrequency,
            'Reserved Instance - SQL Database vCore' AS chargedescription,
            d                               AS chargeperiodstart,
            d + INTERVAL 1 DAY              AS chargeperiodend,
            date_trunc('month', d)          AS billingperiodstart,
            date_trunc('month', d) + INTERVAL 1 MONTH AS billingperiodend,
            'Committed'                     AS commitmentdiscountcategory,
            'ri-az-sqldb-3yr-7742'          AS commitmentdiscountid,
            'sqldb-prod-reservation-3yr'    AS commitmentdiscountname,
            '{status}'                      AS commitmentdiscountstatus,
            'Reserved'                      AS commitmentdiscounttype,
            CASE WHEN d >= {ANCHOR} - 7 THEN {recent_amt} ELSE {base_amt} END AS consumedquantity,
            'Hours'                         AS consumedunit,
            CASE WHEN d >= {ANCHOR} - 7 THEN {recent_amt} ELSE {base_amt} END AS billedcost,
            CASE WHEN d >= {ANCHOR} - 7 THEN {recent_amt} ELSE {base_amt} END AS effectivecost,
            CASE WHEN d >= {ANCHOR} - 7 THEN {recent_amt} ELSE {base_amt} END AS contractedcost,
            CASE WHEN d >= {ANCHOR} - 7 THEN {recent_amt} ELSE {base_amt} END AS listcost,
            'Microsoft'                     AS invoiceissuername,
            'Committed'                     AS pricingcategory,
            CASE WHEN d >= {ANCHOR} - 7 THEN {recent_amt} ELSE {base_amt} END AS pricingquantity,
            'Hours'                         AS pricingunit,
            'Microsoft'                     AS providername,
            'Microsoft'                     AS publishername,
            'japaneast'                     AS regionid,
            'Japan East'                    AS regionname,
            '/subscriptions/sub-ee15fa21/resourceGroups/rg-az-sub-prod--sqldb/providers/Microsoft.Sql/servers/sql-prod-7742' AS resourceid,
            'sql-prod-7742'                 AS resourcename,
            'database'                      AS resourcetype,
            'Databases'                     AS servicecategory,
            'SQL Database'                  AS servicename,
            'AzureSQL-vCore-Reserved'       AS skuid,
            'AzureSQL-vCore-Reserved-price' AS skupriceid,
            'az-sub-prod-0001-japaneast'    AS subaccountid,
            'acme-prod / Japan East'        AS subaccountname,
            '{{"{MARK}": "qb10", "env": "production"}}' AS tags,
            'AzureSQL'                      AS x_servicecode,
            'vCore-Reserved'                AS x_usagetype
        FROM (SELECT unnest(generate_series({ANCHOR} - 36, {ANCHOR}, INTERVAL 1 DAY)) AS d);
            """)
        return "\n".join(rows)

    # gcp -- QB12: a dev VM billed flat 24/7 whose CPU is only used on weekdays.
    # Cost is identical every day (billing_ratio 1.0). Consumption is stored at the
    # WEEKDAY level here and dropped to ~5% at weekends by playground.sql, keyed off
    # the tag "weekly-profile": "business-hours".
    #
    # Why the weekend dip is applied at load time and not baked in: the playground
    # shifts every date forward so the corpus always ends today, and that offset
    # changes daily. A weekday pattern frozen into the parquet would rotate through
    # the week -- Saturday becomes Wednesday tomorrow -- and QB12/QB07 would fire or
    # not depending on which day you ran them. Deriving it from the SHIFTED date is
    # what makes the weekly shape stable while the data stays current.
    #
    # Placed in a long-established subaccount/region on purpose: a brand-new one
    # would trip QB09 (compute in a region with no prior history) as a side effect.
    return f"""
        INSERT INTO t BY NAME
        SELECT
            'USD'                           AS billingcurrency,
            'Usage'                         AS chargecategory,
            'Usage-Based'                   AS chargefrequency,
            'Compute Engine - n2-standard-8 running' AS chargedescription,
            d                               AS chargeperiodstart,
            d + INTERVAL 1 DAY              AS chargeperiodend,
            date_trunc('month', d)          AS billingperiodstart,
            date_trunc('month', d) + INTERVAL 1 MONTH AS billingperiodend,
            22.0                            AS consumedquantity,
            'Hours'                         AS consumedunit,
            3.10                            AS billedcost,
            3.10                            AS effectivecost,
            3.10                            AS contractedcost,
            3.10                            AS listcost,
            0.129                           AS contractedunitprice,
            0.129                           AS listunitprice,
            'Google Cloud'                  AS invoiceissuername,
            'Standard'                      AS pricingcategory,
            24.0                            AS pricingquantity,
            'Hours'                         AS pricingunit,
            'GCP'                           AS providername,
            'Google Cloud'                  AS publishername,
            'europe-west1'                  AS regionid,
            'europe-west1'                  AS regionname,
            '//compute.googleapis.com/projects/acme-dev-001-devbox/zones/europe-west1-b/instances/instance-devbox-idle91' AS resourceid,
            'instance-devbox-idle91'        AS resourcename,
            'compute'                       AS resourcetype,
            'Compute'                       AS servicecategory,
            'Compute Engine'                AS servicename,
            'GCP-ComputeEngine-n2-standard-8' AS skuid,
            'GCP-ComputeEngine-n2-standard-8-price' AS skupriceid,
            'acme-dev-001-europe-west1'     AS subaccountid,
            'acme-dev / europe-west1'       AS subaccountname,
            '{{"{MARK}": "qb12", "weekly-profile": "business-hours", "env": "dev", "team": "platform"}}' AS tags,
            'ComputeEngine'                 AS x_servicecode,
            'n2-standard-8-running'         AS x_usagetype
        FROM (SELECT unnest(generate_series({ANCHOR} - 29, {ANCHOR}, INTERVAL 1 DAY)) AS d);
    """


def main() -> int:
    for cloud in ("aws", "azure", "gcp"):
        src = SAMPLES / cloud / "billing.parquet"
        tmp = SAMPLES / cloud / "_billing.tmp.parquet"
        script = f"""
        CREATE TABLE base AS SELECT * FROM read_parquet('{src}');
        -- idempotent: strip any previously planted rows before re-inserting
        CREATE TABLE t AS
            SELECT * FROM base
            WHERE tags IS NULL OR tags NOT LIKE '%{MARK}%';
        {sql_for(cloud)}
        COPY (SELECT * FROM t ORDER BY chargeperiodstart, resourceid)
            TO '{tmp}' (FORMAT PARQUET, COMPRESSION ZSTD);
        """
        r = subprocess.run(["duckdb", "-c", script], capture_output=True, text=True)
        if r.returncode != 0:
            print(f"[FAIL] {cloud}\n{r.stderr}", file=sys.stderr)
            return 1
        tmp.replace(src)
        print(f"  planted -> {src.relative_to(REPO)}")
    print("\ndone. re-run the detectors to confirm.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
