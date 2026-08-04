-- SPDX-License-Identifier: Apache-2.0
-- Unauthorized Compute : PREFLIGHT / data-readiness check (DuckDB)
-- From FinOps Queries (https://github.com/dropinfinops/finops-queries) -- full explanation: queries/unauthorized-compute/README.md
-- DuckDB. Runs against the playground `bill` view (./run.sh). Athena/Trino: query.sql
WITH win AS (
    SELECT *
    FROM bill
    WHERE CAST(chargeperiodstart AS DATE) >= (CURRENT_DATE - INTERVAL 90 DAY)
),
usable AS (   -- the row filter every detector applies before its own logic
    SELECT *
    FROM win
    WHERE chargecategory = 'Usage'
      AND (chargeclass IS NULL OR chargeclass != 'Correction')
)
SELECT check_name, observed, needed, status FROM (
    SELECT 1 AS seq,
           'rows in the last 90 days'                                AS check_name,
           (SELECT COUNT(*) FROM win)::VARCHAR                             AS observed,
           '> 0'                                                           AS needed,
           CASE WHEN (SELECT COUNT(*) FROM win) > 0
                THEN 'PASS' ELSE 'FAIL' END                                AS status

    UNION ALL
    SELECT 2,
           'days of history available',
           (SELECT COUNT(DISTINCT CAST(chargeperiodstart AS DATE)) FROM win)::VARCHAR,
           '>= 30',
           CASE WHEN (SELECT COUNT(DISTINCT CAST(chargeperiodstart AS DATE)) FROM win) >= 30
                THEN 'PASS' ELSE 'FAIL' END

    UNION ALL
    -- The check that catches the classic silent-zero: a chargeclass/chargecategory
    -- convention that does not match what the detector filters on.
    SELECT 3,
           'rows surviving the Usage / non-Correction filter',
           (SELECT COUNT(*) FROM usable)::VARCHAR,
           '> 0',
           CASE WHEN (SELECT COUNT(*) FROM usable) > 0
                THEN 'PASS' ELSE 'FAIL' END

    UNION ALL
    SELECT 4,
           'distinct chargeclass values present',
           (SELECT COALESCE(STRING_AGG(DISTINCT COALESCE(chargeclass, '<null>'), ', '), '<none>') FROM win),
           'informational',
           'INFO'


    UNION ALL
    SELECT 5,
           'column populated: resourceid',
           COALESCE((SELECT ROUND(100.0 * COUNT(resourceid) / NULLIF(COUNT(*), 0), 1) FROM usable), 0)::VARCHAR || '%',
           '> 0%',
           CASE WHEN COALESCE((SELECT COUNT(resourceid) FROM usable), 0) > 0
                THEN 'PASS' ELSE 'FAIL' END

    UNION ALL
    SELECT 6,
           'column populated: billedcost',
           COALESCE((SELECT ROUND(100.0 * COUNT(billedcost) / NULLIF(COUNT(*), 0), 1) FROM usable), 0)::VARCHAR || '%',
           '> 0%',
           CASE WHEN COALESCE((SELECT COUNT(billedcost) FROM usable), 0) > 0
                THEN 'PASS' ELSE 'FAIL' END

    UNION ALL
    SELECT 7,
           'column populated: regionid',
           COALESCE((SELECT ROUND(100.0 * COUNT(regionid) / NULLIF(COUNT(*), 0), 1) FROM usable), 0)::VARCHAR || '%',
           '> 0%',
           CASE WHEN COALESCE((SELECT COUNT(regionid) FROM usable), 0) > 0
                THEN 'PASS' ELSE 'FAIL' END

) ORDER BY seq;
