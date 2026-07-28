-- DropInFinOps — FOCUS anomaly playground: session init
-- Loaded automatically by ./run.sh (duckdb -init playground.sql).
--
-- Creates the `bill` view over the sample billing data and shifts every timestamp
-- forward so the newest billing day always lands on TODAY. The detectors use relative
-- windows (e.g. "last 7 days", "prior 30-day baseline"), so the data must be current or
-- they'd return nothing. The parquet on disk never changes — only this view is shifted,
-- recomputed every time you start the playground.

-- One resource in the corpus is tagged "weekly-profile": "business-hours" -- a dev
-- box billed flat 24/7 whose CPU is only used on weekdays. Its weekend dip is applied
-- HERE, against the shifted date, rather than baked into the parquet. The shift above
-- changes by one day every day, so a weekday pattern frozen into the file would rotate
-- through the week (Saturday becomes Wednesday tomorrow) and the weekday-sensitive
-- detectors -- QB07, QB12 -- would fire or not depending on what day you ran them.
-- Deriving it from the shifted date keeps the weekly shape stable while the data
-- stays current. Cost is untouched: it is flat every day, which is the whole point.
CREATE OR REPLACE VIEW bill AS
SELECT b.* REPLACE (
  b.chargeperiodstart  + to_days(o.off::INT) AS chargeperiodstart,
  b.chargeperiodend    + to_days(o.off::INT) AS chargeperiodend,
  b.billingperiodstart + to_days(o.off::INT) AS billingperiodstart,
  b.billingperiodend   + to_days(o.off::INT) AS billingperiodend,
  CASE
    WHEN b.tags LIKE '%"weekly-profile": "business-hours"%'
     AND EXTRACT(ISODOW FROM (b.chargeperiodstart + to_days(o.off::INT))) IN (6, 7)
    THEN b.consumedquantity * 0.05
    ELSE b.consumedquantity
  END AS consumedquantity
)
FROM read_parquet('samples/*/*.parquet') b
CROSS JOIN (
  SELECT date_diff('day', max(chargeperiodstart)::date, current_date) AS off
  FROM read_parquet('samples/*/*.parquet')
) o;

.print
.print ==================================================================
.print   DropInFinOps -- FOCUS anomaly playground
.print
.print   The  bill  view is loaded: synthetic multi-cloud FOCUS 1.0
.print   billing data, dated through today.
.print
.print   Poke around:
.print     SELECT servicename, ROUND(SUM(billedcost),2) AS cost
.print     FROM bill GROUP BY 1 ORDER BY 2 DESC LIMIT 10;
.print
.print   Run the QB22 detector yourself:
.print     .read queries/qb22-config-change-data-processing-runaway/query.duckdb.sql
.print
.print   Answer key: open samples/guide.html   Walkthrough: README.md   Quit: .quit
.print ==================================================================
.print
